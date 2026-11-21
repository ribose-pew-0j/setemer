import AppKit
import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class Updater: ObservableObject {
    static let repo = "ribose-pew-0j/setemer"

    enum State {
        case idle
        case checking
        case available(version: String, notes: String)
        case downloading
        case failed(String)
        case upToDate
    }

    @Published private(set) var state: State = .idle

    private static let zipName = "Setemeter.zip"
    private static let keychainService = "Setemeter"
    private static let keychainAccount = "github-token"
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    private let session = URLSession(configuration: .ephemeral)
    private var timer: Timer?
    private var pending: (release: Release, asset: Asset)?

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        case .idle, .available, .failed, .upToDate: return false
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Проверка при старте и далее раз в 6 часов. Окон не показывает, только меняет состояние.
    func start() {
        guard timer == nil else { return }
        checkNow()
        let timer = Timer(timeInterval: Updater.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Действие кнопки в меню: проверить, либо установить уже найденную версию.
    func performPrimaryAction() {
        switch state {
        case .checking, .downloading:
            return
        case .available:
            guard let pending else {
                checkNow()
                return
            }
            Task { await self.install(pending.release, pending.asset) }
        case .idle, .upToDate, .failed:
            checkNow()
        }
    }

    func checkNow() {
        guard !isBusy else { return }
        Task { await self.check() }
    }

    private func check() async {
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            let latest = Updater.normalized(release.tagName)
            guard Updater.isNewer(latest, than: currentVersion) else {
                pending = nil
                state = .upToDate
                return
            }
            guard let asset = release.assets.first(where: { $0.name == Updater.zipName }) else {
                pending = nil
                state = .failed("В релизе \(release.tagName) нет файла \(Updater.zipName)")
                return
            }
            pending = (release, asset)
            state = .available(version: latest, notes: release.body ?? "")
        } catch {
            pending = nil
            state = .failed(error.localizedDescription)
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest") else {
            throw UpdateError.message("Некорректный адрес репозитория")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Setemeter", forHTTPHeaderField: "User-Agent")
        if let token = Updater.keychainToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        try Updater.validate(response)
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func install(_ release: Release, _ asset: Asset) async {
        let appURL = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            state = .failed("Переместите приложение в /Applications")
            return
        }
        state = .downloading
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SetemeterUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let token = Updater.keychainToken()
            let zip = work.appendingPathComponent(Updater.zipName)
            try await download(asset, token: token, to: zip)
            guard let sumAsset = release.assets.first(where: { $0.name == Updater.zipName + ".sha256" }) else {
                throw UpdateError.message("В релизе нет файла \(Updater.zipName).sha256 — установка отменена")
            }
            try await verify(zip, against: sumAsset, token: token)

            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try await runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            let items = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            guard let newApp = items.first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.message("В архиве нет приложения .app")
            }

            let helper = work.appendingPathComponent("install.sh")
            try helperScript.write(to: helper, atomically: true, encoding: .utf8)
            let log = work.appendingPathComponent("update.log")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path,
                                 String(ProcessInfo.processInfo.processIdentifier),
                                 newApp.path,
                                 appURL.path,
                                 log.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
            try? FileManager.default.removeItem(at: work)
        }
    }

    private func download(_ asset: Asset, token: String?, to destination: URL) async throws {
        let request = try Updater.assetRequest(asset, token: token)
        let (tempURL, response) = try await session.download(for: request)
        try Updater.validate(response)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func verify(_ zip: URL, against sumAsset: Asset, token: String?) async throws {
        let request = try Updater.assetRequest(sumAsset, token: token)
        let (data, response) = try await session.data(for: request)
        try Updater.validate(response)
        guard let text = String(data: data, encoding: .utf8),
              let expected = text.split(whereSeparator: { $0.isWhitespace }).first else {
            throw UpdateError.message("Не удалось прочитать \(Updater.zipName).sha256")
        }
        let digest = try Updater.sha256Hex(of: zip)
        guard digest == expected.lowercased() else {
            throw UpdateError.message("Контрольная сумма SHA-256 не совпадает")
        }
    }

    private func runProcess(_ path: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.message("Не удалось распаковать архив (код \(finished.terminationStatus))"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Вспомогательные функции

    private static func assetRequest(_ asset: Asset, token: String?) throws -> URLRequest {
        // Для приватного репо скачиваем через API-адрес ассета, для публичного — напрямую.
        let address = token == nil ? asset.browserDownloadURL : asset.apiURL
        guard let url = URL(string: address) else {
            throw UpdateError.message("Некорректный адрес файла обновления")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Setemeter", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.message("Нет ответа от сервера обновлений")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 {
                throw UpdateError.message("Релиз не найден (для приватного репо нужен токен в Keychain)")
            }
            throw UpdateError.message("Сервер обновлений ответил HTTP \(http.statusCode)")
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func keychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    private static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Численное сравнение по компонентам: 1.10 > 1.9, 1.5 == 1.5.0.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let lhs = versionNumbers(remote)
        let rhs = versionNumbers(local)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func versionNumbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}

private enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

private struct Release: Decodable {
    let tagName: String
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

private struct Asset: Decodable {
    let name: String
    let browserDownloadURL: String
    let apiURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case apiURL = "url"
    }
}

// Хелпер запускается отдельным процессом: дожидается выхода приложения,
// заменяет бандл, снимает карантин и открывает новую версию.
// Аргументы: $1 — PID, $2 — новый .app, $3 — текущий .app, $4 — лог.
private let helperScript = """
#!/bin/bash
pid="$1"
src="$2"
dst="$3"
log="$4"
exec >>"$log" 2>&1
echo "update started $(date)"
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 150 ]; do
    sleep 0.2
    waited=$((waited + 1))
done
if /usr/bin/ditto "$src" "$dst.new" && rm -rf "$dst" && mv "$dst.new" "$dst"; then
    xattr -dr com.apple.quarantine "$dst" 2>/dev/null
    open "$dst"
    echo "update installed"
else
    echo "update failed"
    rm -rf "$dst.new"
    if [ -d "$dst" ]; then open "$dst"; fi
fi

"""
