import AppKit
import Combine
import Network
import SwiftUI

struct DiagnosticRow: Identifiable, Sendable {
    let name: String
    let value: String
    var id: String { name }
}

/// Страна и провайдер внешнего адреса (ifconfig.co).
struct IPInfo: Sendable, Equatable {
    let country: String?
    let provider: String?
    let city: String?

    /// «Страна · Провайдер» (с городом, если известен).
    var summary: String {
        let parts = [country, provider, city].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

private enum NetworkDiagnostics {
    struct Snapshot: Sendable {
        let groups: [[DiagnosticRow]]
        let publicIPv4: String?
        let ipInfo: IPInfo?
        let wifi: WiFiStatus?
        let jitterMs: Double?
        let lossPercent: Double?
    }

    private struct Quality: Sendable {
        let jitterMs: Double?
        let lossPercent: Double
        let received: Int
    }

    private struct GeoResponse: Decodable, Sendable {
        let ip: String?
        let country: String?
        let city: String?
        let asn: String?
        let asnOrg: String?

        enum CodingKeys: String, CodingKey {
            case ip, country, city, asn
            case asnOrg = "asn_org"
        }
    }

    private static let session: URLSession = makeSession(timeout: 5)

    static func run(networkType: String?) async -> Snapshot {
        async let ipv4Lookup = publicIPv4AndInfo()
        async let publicIPv6 = publicIP("api6.ipify.org", family: AF_INET6)
        async let cloudflare = https("https://cp.cloudflare.com/generate_204", expected: 204)
        async let google = https("https://www.gstatic.com/generate_204", expected: 204)
        async let apple = https("https://www.apple.com/", expected: 200)
        async let numeric = https("https://1.1.1.1/cdn-cgi/trace")
        async let dns = Task.detached { systemDNS() }.value
        async let local = localNetwork()
        async let wifi = Task.detached(priority: .utility) { WiFiProbe.status() }.value
        async let quality = probeQuality()

        let (ipv4, ipInfo) = await ipv4Lookup
        let ipv6 = await publicIPv6
        let localRows = await local
        let wifiStatus = await wifi
        let probe = await quality
        let dnsResult = await dns
        let cloudflareResult = await cloudflare
        let googleResult = await google
        let appleResult = await apple
        let numericResult = await numeric

        let jitterText = probe.jitterMs.map { "\(fraction($0)) мс" } ?? "—"
        let lossText = "\(Int(probe.lossPercent))% · ответили \(probe.received) из 10"
        let groups: [[DiagnosticRow]] = [
            [.init(name: "Внешний IPv4", value: ipv4 ?? "Нет ответа"),
             .init(name: "Внешний IPv6", value: ipv6),
             .init(name: "Страна · Провайдер", value: ipInfo?.summary ?? "—")],
            [DiagnosticRow(name: "Тип сети", value: networkType ?? "—")] + localRows + wifiRows(wifiStatus),
            [.init(name: "Системный DNS · apple.com", value: dnsResult),
             .init(name: "Cloudflare · HTTPS 204", value: cloudflareResult),
             .init(name: "Google · HTTPS 204", value: googleResult),
             .init(name: "Apple · HTTPS 200", value: appleResult),
             .init(name: "1.1.1.1 · HTTPS по IP", value: numericResult),
             .init(name: "Джиттер · 10 проверок", value: jitterText),
             .init(name: "Потери пакетов", value: lossText)]
        ]
        return Snapshot(groups: groups,
                        publicIPv4: ipv4,
                        ipInfo: ipInfo,
                        wifi: wifiStatus,
                        jitterMs: probe.jitterMs,
                        lossPercent: probe.lossPercent)
    }

    static func downloadSpeed() async -> Double? {
        let bytes = 5_000_000
        let speedSession = makeSession(timeout: 15)
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

    /// Отдача: 2 POST по 5 МБ случайных данных на speed.cloudflare.com/__up. Возвращает Мбит/с.
    static func uploadSpeed() async -> Double? {
        let bytes = 5_000_000
        var payload = Data(count: bytes)
        payload.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                arc4random_buf(base, bytes)
            }
        }
        let speedSession = makeSession(timeout: 15)
        defer { speedSession.finishTasksAndInvalidate() }

        var rates: [Double] = []
        for _ in 0..<2 {
            var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!)
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let start = ProcessInfo.processInfo.systemUptime
            guard let (_, response) = try? await speedSession.upload(for: request, from: payload),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                Log.diagnostics.error("Тест отдачи: сервер не принял данные")
                return nil
            }
            let duration = ProcessInfo.processInfo.systemUptime - start
            guard duration > 0 else { return nil }
            rates.append(Double(bytes) * 8 / duration / 1_000_000)
        }
        return rates.reduce(0, +) / Double(rates.count)
    }

    /// 10 HEAD с интервалом 200 мс. Джиттер — среднее |задержка_i − задержка_(i-1)| по успешным парам.
    private static func probeQuality() async -> Quality {
        let probe = makeSession(timeout: 2)
        defer { probe.finishTasksAndInvalidate() }

        var latencies: [Double?] = []
        for index in 0..<10 {
            if index > 0 {
                _ = try? await Task.sleep(nanoseconds: 200_000_000)
            }
            latencies.append(await timedHead(probe))
        }
        let received = latencies.compactMap { $0 }.count
        var differences: [Double] = []
        for (previous, current) in zip(latencies, latencies.dropFirst()) {
            if let previous, let current {
                differences.append(abs(current - previous))
            }
        }
        let jitter = differences.isEmpty ? nil : differences.reduce(0, +) / Double(differences.count)
        return Quality(jitterMs: jitter,
                       lossPercent: Double(10 - received) * 10,
                       received: received)
    }

    private static func timedHead(_ probe: URLSession) async -> Double? {
        var request = URLRequest(url: URL(string: "https://cp.cloudflare.com/generate_204")!)
        request.httpMethod = "HEAD"
        let start = ProcessInfo.processInfo.systemUptime
        guard let (_, response) = try? await probe.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 204 else { return nil }
        return (ProcessInfo.processInfo.systemUptime - start) * 1_000
    }

    private static func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private static func fraction(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private static func isValid(_ address: String, family: Int32) -> Bool {
        var bytes = in6_addr()
        return address.withCString { inet_pton(family, $0, &bytes) } == 1
    }

    /// Внешний IPv4: api.ipify.org → api64.ipify.org → ifconfig.co. Страна и провайдер — из ifconfig.co.
    private static func publicIPv4AndInfo() async -> (ip: String?, info: IPInfo?) {
        async let geo = geoLookup()
        var address = await plainIPv4("https://api.ipify.org/")
        if address == nil {
            address = await plainIPv4("https://api64.ipify.org/")
        }
        let response = await geo
        if address == nil, let candidate = response?.ip, isValid(candidate, family: AF_INET) {
            address = candidate
        }
        let info = response.map { IPInfo(country: $0.country, provider: $0.asnOrg ?? $0.asn, city: $0.city) }
        return (address, info)
    }

    private static func plainIPv4(_ address: String) async -> String? {
        guard let url = URL(string: address),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValid(candidate, family: AF_INET) ? candidate : nil
    }

    private static func geoLookup() async -> GeoResponse? {
        guard let url = URL(string: "https://ifconfig.co/json"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(GeoResponse.self, from: data)
    }

    private static func publicIP(_ host: String, family: Int32) async -> String {
        let url = URL(string: "https://\(host)/")!
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return "Нет ответа" }
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValid(address, family: family) ? address : "Некорректный ответ"
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

    /// Вывод утилиты; при сбое или таймауте — пустая строка.
    private static func command(_ path: String, _ arguments: [String]) async -> String {
        await runCommand(path, arguments) ?? ""
    }

    private static func field(_ key: String, in text: String) -> String? {
        let prefix = key + ":"
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
    }

    /// Физический тип сети из NWPath и признак VPN (туннельные интерфейсы utun/ipsec/ppp).
    static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "Нет сети" }
        let base: String
        if path.usesInterfaceType(.wifi) {
            base = "Wi‑Fi"
        } else if path.usesInterfaceType(.wiredEthernet) {
            base = "Ethernet"
        } else if path.usesInterfaceType(.cellular) {
            base = "Сотовая сеть"
        } else {
            base = "Другая"
        }
        let tunnel = path.availableInterfaces.contains { interface in
            interface.type == .other && ["utun", "ipsec", "ppp"].contains { interface.name.hasPrefix($0) }
        }
        return tunnel ? "\(base) · VPN" : base
    }

    private static func wifiRows(_ wifi: WiFiStatus?) -> [DiagnosticRow] {
        guard let wifi else { return [] }
        var rows = [DiagnosticRow(name: "Wi‑Fi сигнал",
                                  value: "\(wifi.rssi) дБм · шум \(wifi.noise.map { String($0) } ?? "—") дБм")]
        if let channel = wifi.channel {
            rows.append(.init(name: "Wi‑Fi канал", value: wifi.band.map { "\(channel) · \($0)" } ?? "\(channel)"))
        }
        if let rate = wifi.txRate {
            rows.append(.init(name: "Wi‑Fi скорость связи", value: "\(Int(rate.rounded())) Мбит/с"))
        }
        return rows
    }

    private static func localNetwork() async -> [DiagnosticRow] {
        let route = await command("/sbin/route", ["-n", "get", "default"])
        let routeInterface = field("interface", in: route)
        let ports = await command("/usr/sbin/networksetup", ["-listallhardwareports"])
        let wifi = ports.components(separatedBy: "\n\n")
            .first { field("Hardware Port", in: $0) == "Wi-Fi" }
            .flatMap { field("Device", in: $0) }

        var wifiIP = ""
        if let wifi {
            wifiIP = await command("/usr/sbin/ipconfig", ["getifaddr", wifi])
        }

        var routeIP = ""
        if let routeInterface {
            let lines = await command("/sbin/ifconfig", [routeInterface]).split(separator: "\n")
            for line in lines {
                let parts = line.split(whereSeparator: { $0.isWhitespace })
                if parts.count > 1, parts[0] == "inet" {
                    routeIP = String(parts[1])
                    break
                }
            }
        }

        var wifiGateway: String?
        if !wifiIP.isEmpty, let wifi {
            let scoped = await command("/sbin/route", ["-n", "get", "-ifscope", wifi, "default"])
            wifiGateway = field("gateway", in: scoped)
        }
        let gateway = wifiGateway ?? field("gateway", in: route)

        let scutilDNS = await command("/usr/sbin/scutil", ["--dns"])
        let dns = scutilDNS.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("nameserver[") }
            .compactMap { $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        let networkList = await command("/usr/sbin/scutil", ["--nc", "list"])
        let vpn = networkList.split(separator: "\n")
            .filter { $0.contains("(Connected)") && $0.contains("VPN") }
            .compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }

        let proxies = await command("/usr/sbin/scutil", ["--proxy"])
        let proxyKeys = [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"),
                         ("ProxyAutoConfigEnable", "PAC"), ("ProxyAutoDiscoveryEnable", "WPAD")]
        let enabled = proxyKeys.compactMap { field($0.0 + " ", in: proxies) == "1" ? $0.1 : nil }

        var ping = "—"
        if let gateway {
            ping = await pingValue(gateway)
        }

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

    private static func pingValue(_ address: String) async -> String {
        var bytes = in_addr()
        guard address.withCString({ inet_pton(AF_INET, $0, &bytes) }) == 1 else { return "—" }
        let output = await command("/sbin/ping", ["-n", "-c", "1", "-W", "1000", "-t", "2", address])
        let time = output.components(separatedBy: "time=").dropFirst().first?
            .split(separator: "\n").first
        return time.map { String($0).replacingOccurrences(of: " ms", with: " мс") } ?? "Нет ICMP-ответа"
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
    /// Скачивание, Мбит/с.
    @Published private(set) var downMbps: Double?
    /// Отдача, Мбит/с.
    @Published private(set) var upMbps: Double?
    @Published private(set) var speedFailed = false
    @Published private(set) var speedDate: Date?
    /// Внешний IPv4 (nil, если не определён).
    @Published private(set) var publicIPv4: String?
    @Published private(set) var ipInfo: IPInfo?
    @Published private(set) var wifi: WiFiStatus?
    /// Джиттер по 10 HEAD-запросам, мс.
    @Published private(set) var jitterMs: Double?
    /// Потери пакетов, %.
    @Published private(set) var lossPercent: Double?
    /// Тип текущей сети: Wi‑Fi, Ethernet, «… · VPN» и т. п.
    @Published private(set) var networkType: String?

    private let speedCacheKey = "lastDownloadSpeed"
    private var pendingRefresh = false
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: String?
    private var settingsObserver: AnyCancellable?

    init() {
        if let cached = UserDefaults.standard.dictionary(forKey: speedCacheKey),
           let result = cached["mbps"] as? Double, result.isFinite, result > 0,
           let date = cached["date"] as? Date {
            downMbps = result
            speedDate = date
            if let up = cached["up"] as? Double, up.isFinite, up > 0 {
                upMbps = up
            }
        }
        // Смена единиц в настройках должна перерисовать карточки.
        settingsObserver = Settings.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func start() {
        startPathMonitor()
        refresh()
        measureSpeed()
    }

    /// Скорость в выбранных в настройках единицах (только число).
    var formattedSpeed: String? {
        downMbps.map { Settings.shared.speedUnit.convert(mbps: $0).formatted(.number.precision(.fractionLength(1))) }
    }

    var formattedUpload: String? {
        upMbps.map { Settings.shared.speedUnit.convert(mbps: $0).formatted(.number.precision(.fractionLength(1))) }
    }

    /// Подпись единиц: «Мбит/с» или «МБ/с».
    var speedUnitTitle: String { Settings.shared.speedUnit.title }

    var wifiRSSI: Int? { wifi?.rssi }

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
        let type = networkType
        Task {
            let snapshot = await NetworkDiagnostics.run(networkType: type)
            apply(snapshot)
            busy = false
            runPendingRefresh()
        }
    }

    func testSpeed() {
        guard !speedBusy && !busy else { return }
        measureSpeed()
    }

    private func apply(_ snapshot: NetworkDiagnostics.Snapshot) {
        let previousIP = publicIPv4
        groups = snapshot.groups
        checked = .now
        publicIPv4 = snapshot.publicIPv4
        ipInfo = snapshot.ipInfo
        wifi = snapshot.wifi
        jitterMs = snapshot.jitterMs
        lossPercent = snapshot.lossPercent
        if let previousIP, let current = snapshot.publicIPv4, previousIP != current {
            Notifier.shared.notifyIPChanged(from: previousIP, to: current)
        }
    }

    private func runPendingRefresh() {
        guard pendingRefresh, !busy, !speedBusy else { return }
        pendingRefresh = false
        refresh()
    }

    private func measureSpeed() {
        speedBusy = true
        speedFailed = false
        Task {
            let download = await NetworkDiagnostics.downloadSpeed()
            let upload = await NetworkDiagnostics.uploadSpeed()
            let date = Date.now
            if let download {
                downMbps = download
                upMbps = upload
                speedDate = date
                var cache: [String: Any] = ["mbps": download, "date": date]
                if let upload { cache["up"] = upload }
                UserDefaults.standard.set(cache, forKey: speedCacheKey)
                let threshold = Settings.shared.speedWarningMbps
                if download < Double(threshold) {
                    Notifier.shared.notifySlowSpeed(mbps: download, threshold: threshold)
                }
            } else {
                speedFailed = true
            }
            if download != nil || upload != nil {
                SpeedHistory.shared.append(date: date, down: download, up: upload)
            }
            speedBusy = false
            runPendingRefresh()
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = NetworkDiagnostics.describe(path)
            let signature = path.availableInterfaces.map { $0.name }.joined(separator: ",") + "|\(path.status)"
            Task { @MainActor [weak self] in
                self?.pathChanged(kind: kind, signature: signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.netpulse.monitor.path"))
        pathMonitor = monitor
    }

    private func pathChanged(kind: String, signature: String) {
        networkType = kind
        let previous = lastPathSignature
        lastPathSignature = signature
        guard let previous else {
            // Первый апдейт пути: стартовый refresh шёл без типа сети, повторяем.
            forceRefresh()
            return
        }
        guard previous != signature else { return }
        Log.diagnostics.info("Сеть изменилась: \(kind, privacy: .public)")
        // Даём системе время получить адрес и DNS, потом перепроверяем.
        Task { @MainActor [weak self] in
            _ = try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.forceRefresh()
        }
    }

    private func forceRefresh() {
        pendingRefresh = true
        if !busy && !speedBusy {
            runPendingRefresh()
        }
    }
}

#if PANEL_PREVIEW
extension DiagnosticsModel {
    func setPreviewValues(date: Date) {
        networkType = "Ethernet · VPN"
        speedDate = date
        downMbps = 59.1
        upMbps = 45.2
        jitterMs = 20.8
        lossPercent = 0
        wifi = WiFiStatus(rssi: -59, noise: nil, channel: 44, band: "5 ГГц", txRate: 300)
        publicIPv4 = "203.0.113.42"
        ipInfo = IPInfo(country: "Нидерланды", provider: "Example Network", city: "Амстердам")
    }
}
#endif
