import AppKit
import SwiftUI

struct DiagnosticRow: Identifiable, Sendable {
    let name: String
    let value: String
    var id: String { name }
}

private enum NetworkDiagnostics {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func run() async -> [[DiagnosticRow]] {
        async let publicIPv4 = publicIP("api.ipify.org", family: AF_INET)
        async let publicIPv6 = publicIP("api6.ipify.org", family: AF_INET6)
        async let cloudflare = https("https://cp.cloudflare.com/generate_204", expected: 204)
        async let google = https("https://www.gstatic.com/generate_204", expected: 204)
        async let apple = https("https://www.apple.com/", expected: 200)
        async let numeric = https("https://1.1.1.1/cdn-cgi/trace")
        async let dns = Task.detached { systemDNS() }.value
        async let local = Task.detached { localNetwork() }.value
        return await [
            [.init(name: "Внешний IPv4", value: publicIPv4), .init(name: "Внешний IPv6", value: publicIPv6)],
            local,
            [.init(name: "Системный DNS · apple.com", value: dns),
             .init(name: "Cloudflare · HTTPS 204", value: cloudflare),
             .init(name: "Google · HTTPS 204", value: google),
             .init(name: "Apple · HTTPS 200", value: apple),
             .init(name: "1.1.1.1 · HTTPS по IP", value: numeric)]
        ]
    }

    static func downloadSpeed() async -> Double? {
        let bytes = 5_000_000
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 15
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        let speedSession = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { speedSession.finishTasksAndInvalidate() }

        var rates: [Double] = []
        for _ in 0..<3 {
            let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)")!
            var request = URLRequest(url: url)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let start = ProcessInfo.processInfo.systemUptime
            guard let (data, response) = try? await speedSession.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count == bytes else { return nil }
            let duration = ProcessInfo.processInfo.systemUptime - start
            guard duration > 0 else { return nil }
            rates.append(Double(data.count) * 8 / duration / 1_000_000)
        }
        return rates.reduce(0, +) / Double(rates.count)
    }

    private static func publicIP(_ host: String, family: Int32) async -> String {
        let url = URL(string: "https://\(host)/")!
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return "Нет ответа" }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = in6_addr()
        return address.withCString { inet_pton(family, $0, &bytes) } == 1 ? address : "Некорректный ответ"
    }

    private static func https(_ address: String, expected: Int? = nil) async -> String {
        let start = ProcessInfo.processInfo.systemUptime
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            guard let response = response as? HTTPURLResponse else { return "Ответ не HTTP" }
            let code = response.statusCode
            return expected == nil || code == expected ? "OK · \(code) · \(ms) мс" : "HTTP \(code) · \(ms) мс"
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return "Таймаут · 5 с"
            case .cannotFindHost, .dnsLookupFailed: return "Ошибка DNS"
            case .notConnectedToInternet: return "Нет подключения"
            case .cannotConnectToHost: return "Нет соединения с сервером"
            case .secureConnectionFailed, .serverCertificateUntrusted,
                    .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                    .serverCertificateNotYetValid: return "Ошибка TLS"
            default: return "Ошибка сети · \(error.errorCode)"
            }
        } catch {
            return "Ошибка запроса"
        }
    }

    private static func command(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "LANG": "C"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func field(_ key: String, in text: String) -> String? {
        let prefix = key + ":"
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
    }

    private static func localNetwork() -> [DiagnosticRow] {
        let route = command("/sbin/route", ["-n", "get", "default"])
        let routeInterface = field("interface", in: route)
        let ports = command("/usr/sbin/networksetup", ["-listallhardwareports"])
        let wifi = ports.components(separatedBy: "\n\n")
            .first { field("Hardware Port", in: $0) == "Wi-Fi" }
            .flatMap { field("Device", in: $0) }
        let wifiIP = wifi.map { command("/usr/sbin/ipconfig", ["getifaddr", $0]) } ?? ""
        let routeIP = routeInterface.map { interface -> String in
            let lines = command("/sbin/ifconfig", [interface]).split(separator: "\n")
            for line in lines {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count > 1, parts[0] == "inet" { return String(parts[1]) }
            }
            return ""
        } ?? ""
        let wifiGateway = wifiIP.isEmpty ? nil : wifi.flatMap {
            field("gateway", in: command("/sbin/route", ["-n", "get", "-ifscope", $0, "default"]))
        }
        let gateway = wifiGateway ?? field("gateway", in: route)
        let dns = command("/usr/sbin/scutil", ["--dns"]).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("nameserver[") }
            .compactMap { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let vpn = command("/usr/sbin/scutil", ["--nc", "list"]).split(separator: "\n")
            .filter { $0.contains("(Connected)") && $0.contains("VPN") }
            .compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
        let proxies = command("/usr/sbin/scutil", ["--proxy"])
        let proxyKeys = [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"),
                         ("ProxyAutoConfigEnable", "PAC"), ("ProxyAutoDiscoveryEnable", "WPAD")]
        let enabled = proxyKeys.compactMap { field($0.0 + " ", in: proxies) == "1" ? $0.1 : nil }
        let ping = gateway.map { address -> String in
            var bytes = in_addr()
            guard address.withCString({ inet_pton(AF_INET, $0, &bytes) }) == 1 else { return "—" }
            let output = command("/sbin/ping", ["-n", "-c", "1", "-W", "1000", "-t", "2", address])
            let time = output.components(separatedBy: "time=").dropFirst().first?
                .split(separator: "\n").first
            return time.map { String($0).replacingOccurrences(of: " ms", with: " мс") } ?? "Нет ICMP-ответа"
        } ?? "—"
        return [
            .init(name: "Маршрут по умолчанию", value: routeInterface ?? "Отсутствует"),
            .init(name: "IPv4 на основном интерфейсе", value: routeIP.isEmpty ? "—" : routeIP),
            .init(name: "IPv4 Wi‑Fi", value: wifiIP.isEmpty ? "—" : "\(wifiIP) · \(wifi ?? "")"),
            .init(name: wifiGateway == nil ? "Шлюз" : "Шлюз Wi‑Fi", value: gateway ?? "—"),
            .init(name: "Пинг шлюза", value: ping),
            .init(name: "DNS-серверы macOS", value: dns.isEmpty ? "—" : dns.joined(separator: ", ")),
            .init(name: "VPN macOS", value: vpn.isEmpty ? "Нет активного профиля" : vpn.joined(separator: ", ")),
            .init(name: "Системный прокси", value: proxies.isEmpty ? "—" : enabled.isEmpty ? "Выключен" : enabled.joined(separator: ", "))
        ]
    }

    private static func systemDNS() -> String {
        let start = ProcessInfo.processInfo.systemUptime
        var addresses: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo("apple.com", nil, nil, &addresses)
        if let addresses { freeaddrinfo(addresses) }
        let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1_000)
        return result == 0 ? "OK · \(ms) мс" : "Ошибка DNS · \(ms) мс"
    }
}

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var groups: [[DiagnosticRow]] = []
    @Published private(set) var checked: Date?
    @Published private(set) var busy = false
    @Published private(set) var speedBusy = false
    @Published private(set) var speed: Double?
    @Published private(set) var speedFailed = false
    @Published private(set) var speedDate: Date?
    private let speedCacheKey = "lastDownloadSpeed"

    init() {
        if let cached = UserDefaults.standard.dictionary(forKey: speedCacheKey),
           let result = cached["mbps"] as? Double, result.isFinite, result > 0,
           let date = cached["date"] as? Date {
            speed = result
            speedDate = date
        }
    }

    func start() {
        refresh()
        measureSpeed()
    }

    var formattedSpeed: String? {
        speed.map { $0.formatted(.number.precision(.fractionLength(1))) }
    }

    var httpsSummary: String {
        guard let checks = groups.last else { return "—" }
        let https = checks.filter { $0.name.contains("HTTPS") }
        let passed = https.filter { $0.value.hasPrefix("OK") }.count
        let dns = checks.first?.value.hasPrefix("OK") == true ? "DNS ✓" : "DNS ✕"
        return "\(passed)/\(https.count) HTTPS · \(dns)"
    }

    func value(_ name: String) -> String? {
        groups.lazy.flatMap { $0 }.first { $0.name == name }?.value
    }

    func refresh() {
        guard !busy && !speedBusy else { return }
        busy = true
        Task {
            groups = await NetworkDiagnostics.run()
            checked = .now
            busy = false
        }
    }

    func testSpeed() {
        guard !speedBusy && !busy else { return }
        measureSpeed()
    }

    private func measureSpeed() {
        speedBusy = true
        speedFailed = false
        Task {
            if let result = await NetworkDiagnostics.downloadSpeed() {
                let date = Date.now
                speed = result
                speedDate = date
                UserDefaults.standard.set(["mbps": result, "date": date], forKey: speedCacheKey)
            } else {
                speedFailed = true
            }
            speedBusy = false
        }
    }
}

@MainActor
struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    private let sections = ["Внешний адрес", "Локальная сеть и маршрутизация", "Доступность"]

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.mint)
                    .frame(width: 44, height: 44)
                    .background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Диагностика сети").font(.title2.bold())
                    Text(model.checked.map { "Проверено в \($0.formatted(date: .omitted, time: .standard))" }
                         ?? "Проверяем подключение…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(action: model.refresh) { Label("Обновить", systemImage: "arrow.clockwise") }
                    .disabled(model.busy || model.speedBusy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    speedCard
                    ForEach(model.groups.indices, id: \.self) { index in
                        section(index)
                    }
                }
            }
            HStack {
                Text("Внешний IP определяет ipify для текущего маршрута.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: copyReport) {
                    Label("Скопировать отчёт", systemImage: "doc.on.doc")
                }
                .disabled(model.groups.isEmpty || model.busy)
            }
        }
        .padding(22)
        .background {
            LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.18),
                                    Color(red: 0.06, green: 0.08, blue: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 550, minHeight: 450)
        
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Средняя скорость скачивания", systemImage: "arrow.down.circle")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.formattedSpeed ?? "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.mint)
                Text("Мбит/с").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.speedBusy { ProgressView().controlSize(.small) }
                Button(action: model.testSpeed) {
                    Label(model.speedBusy ? "Тест идёт…" : "Измерить скорость", systemImage: "speedometer")
                }
                .buttonStyle(.borderedProminent)
                .tint(.mint)
                .disabled(model.speedBusy || model.busy)
            }
            if model.speedFailed {
                Text("Тест не завершился. Попробуйте ещё раз.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(model.speedDate.map {
                "Cloudflare · 3 замера · \($0.formatted(date: .omitted, time: .shortened))"
            } ?? "Cloudflare · 3 загрузки по 5 МБ")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(15)
        .background(.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.mint.opacity(0.23))
                .allowsHitTesting(false)
        }
    }

    private func section(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sections[index]).font(.headline)
            ForEach(model.groups[index]) { row in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.name).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(row.value).font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(13)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.09))
                .allowsHitTesting(false)
        }
    }

    private func copyReport() {
        let report = model.groups.enumerated().map { index, rows in
            ([sections[index]] + rows.map { "\($0.name): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
        let speedLine = model.formattedSpeed.map {
            "Средняя скорость скачивания: \($0) Мбит/с (Cloudflare, 3 замера)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([speedLine, report].compactMap { $0 }.joined(separator: "\n\n"), forType: .string)
    }
}
