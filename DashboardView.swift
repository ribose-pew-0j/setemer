import SwiftUI

/// Дашборд меню-панели (~380 pt): шапка, график задержки, плитки метрик, скорость и нижняя панель.
@MainActor
struct DashboardView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var diagnostics: DiagnosticsModel
    @ObservedObject var updater: Updater
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) var colorScheme
    @State var range: HistoryRange = .hour
    let widgetVisible: Bool
    let toggleWidget: () -> Void
    let diagnose: () -> Void
    let quit: () -> Void
    let close: () -> Void

    init(monitor: Monitor, diagnostics: DiagnosticsModel, updater: Updater, widgetVisible: Bool,
         toggleWidget: @escaping () -> Void, diagnose: @escaping () -> Void,
         quit: @escaping () -> Void, close: @escaping () -> Void) {
        self.monitor = monitor
        self.diagnostics = diagnostics
        self.updater = updater
        self.widgetVisible = widgetVisible
        self.toggleWidget = toggleWidget
        self.diagnose = diagnose
        self.quit = quit
        self.close = close
    }

    var body: some View {
        let theme = Theme(colorScheme)
        let tone = sampleTone(monitor.latest, threshold: settings.slowPingThresholdMs)
        let points = HistoryStore.shared.points(for: range)
        let stats = HistoryStore.shared.stats(for: range)
        return VStack(alignment: .leading, spacing: 12) {
            header(theme: theme, tone: tone)
            chartCard(theme: theme, points: points, stats: stats)
            tiles(theme: theme)
            speedCard(theme: theme)
            footer(theme: theme)
        }
        .padding(Spacing.window)
        .frame(width: 380)
        .background {
            RoundedRectangle(cornerRadius: Radius.window, style: .continuous).fill(theme.windowFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                .strokeBorder(theme.color(tone).opacity(0.3), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    // MARK: Шапка

    private func header(theme: Theme, tone: Tone) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(tone: tone, theme: theme)
                    Text(status(monitor.latest))
                        .font(Typo.title)
                }
                networkLine(theme: theme)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(pingText)
                        .font(Typo.display(38))
                        .monospacedDigit()
                        .foregroundStyle(theme.color(tone))
                    Text("мс")
                        .font(Typo.label)
                        .foregroundStyle(.secondary)
                }
                Text(lastCheckText)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func networkLine(theme: Theme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: networkSymbol)
                .font(.system(size: 10, weight: .semibold))
            Text(diagnostics.networkType ?? "Определяем сеть…")
            if let rssi = diagnostics.wifiRSSI {
                let bars = signalBarCount(rssi)
                SignalBars(bars: bars, tone: signalTone(bars: bars), theme: theme)
                Text("\(rssi) дБм")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: График

    private func chartCard(theme: Theme, points: [HistoryPoint], stats: HistoryStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Задержка")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                RangeSwitch(selection: $range, theme: theme)
            }
            LatencyChart(points: points, range: range, stats: stats, theme: theme,
                         threshold: settings.slowPingThresholdMs)
                .id(range)
                .transition(.opacity)
            HStack(spacing: 14) {
                statItem("Медиана", msText(stats.medianMs))
                statItem("p95", msText(stats.p95Ms))
                statItem("Доступность", percentText(stats.uptimePercent))
                Spacer(minLength: 0)
            }
        }
        .padding(Spacing.card)
        .cardSurface(theme)
    }

    private func statItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: Плитки

    private func tiles(theme: Theme) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                MetricTile(title: "Скачивание", symbol: "arrow.down.circle",
                           value: diagnostics.formattedSpeed, unit: diagnostics.speedUnitTitle,
                           caption: downloadCaption, theme: theme, tone: downloadTone)
                MetricTile(title: "Отдача", symbol: "arrow.up.circle",
                           value: diagnostics.formattedUpload, unit: diagnostics.speedUnitTitle,
                           caption: uploadCaption, theme: theme, tone: uploadTone)
            }
            HStack(spacing: 10) {
                MetricTile(title: "Джиттер", symbol: "waveform",
                           value: jitterText, unit: "мс",
                           caption: jitterCaption, theme: theme, tone: jitterLevel)
                MetricTile(title: "Потери", symbol: "exclamationmark.triangle",
                           value: lossText, caption: lossCaption, theme: theme, tone: lossLevel)
            }
            HStack(spacing: 10) {
                MetricTile(title: "Wi-Fi", symbol: "wifi",
                           value: rssiText, unit: "дБм",
                           caption: wifiCaption, theme: theme, tone: wifiTone,
                           signalBars: wifiBars)
                MetricTile(title: "Внешний IP", symbol: "globe",
                           value: diagnostics.publicIPv4, caption: ipCaption, theme: theme,
                           tone: ipTone, valueSize: 16, copyValue: diagnostics.publicIPv4)
            }
        }
    }

    private var downloadCaption: String {
        diagnostics.speedDate.map { "Замер в \($0.formatted(date: .omitted, time: .shortened))" }
            ?? "Нет замера — нажмите ⚡"
    }

    private var downloadTone: Tone {
        diagnostics.downMbps.map { speedTone($0, threshold: settings.speedWarningMbps) } ?? .neutral
    }

    private var uploadCaption: String {
        diagnostics.upMbps == nil ? "Нет замера — нажмите ⚡" : "Cloudflare · 2 замера"
    }

    private var uploadTone: Tone {
        diagnostics.upMbps.map { speedTone($0, threshold: settings.speedWarningMbps) } ?? .neutral
    }

    private var jitterText: String? {
        diagnostics.jitterMs.map { $0.formatted(.number.precision(.fractionLength(1))) }
    }

    private var jitterCaption: String {
        diagnostics.jitterMs == nil ? "Нет замера — ждём проверку" : "10 HEAD-запросов"
    }

    private var jitterLevel: Tone {
        diagnostics.jitterMs.map { jitterTone($0) } ?? .neutral
    }

    private var lossText: String? {
        diagnostics.lossPercent.map { "\(Int($0))%" }
    }

    private var lossCaption: String {
        diagnostics.lossPercent.map { "ответили \(10 - Int($0) / 10) из 10" } ?? "Нет замера — ждём проверку"
    }

    private var lossLevel: Tone {
        diagnostics.lossPercent.map { lossTone($0) } ?? .neutral
    }

    private var rssiText: String? {
        diagnostics.wifiRSSI.map { "\($0)" }
    }

    private var wifiCaption: String {
        guard let wifi = diagnostics.wifi else { return "Нет Wi-Fi соединения" }
        var parts: [String] = []
        if let band = wifi.band { parts.append(band) }
        if let channel = wifi.channel { parts.append("канал \(channel)") }
        if let rate = wifi.txRate { parts.append("\(Int(rate.rounded())) Мбит/с") }
        return parts.isEmpty ? "Сигнал Wi-Fi" : parts.joined(separator: " · ")
    }

    private var wifiBars: Int? {
        diagnostics.wifiRSSI.map { signalBarCount($0) }
    }

    private var wifiTone: Tone {
        wifiBars.map { signalTone(bars: $0) } ?? .neutral
    }

    private var ipCaption: String {
        if diagnostics.publicIPv4 == nil { return "Нет ответа — обновится при проверке" }
        return diagnostics.ipInfo?.summary ?? "Нажмите, чтобы скопировать"
    }

    private var ipTone: Tone {
        diagnostics.publicIPv4 == nil ? .neutral : .good
    }

    // MARK: Скорость

    private func speedCard(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Скорость", systemImage: "speedometer")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                speedButton(theme: theme)
            }
            Text(lastSpeedText)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            let records = Array(SpeedHistory.shared.records.suffix(5))
            if !records.isEmpty {
                SpeedBars(records: records, threshold: settings.speedWarningMbps, theme: theme)
            }
        }
        .padding(Spacing.card)
        .cardSurface(theme)
    }

    private func speedButton(theme: Theme) -> some View {
        Button(action: diagnostics.testSpeed) {
            HStack(spacing: 5) {
                if diagnostics.speedBusy {
                    ProgressView()
                        .controlSize(.small)
                    Text("Замер…")
                } else {
                    Image(systemName: "bolt.fill")
                    Text("Измерить")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.mint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(theme.mint.opacity(0.16))
            }
        }
        .buttonStyle(.plain)
        .disabled(diagnostics.speedBusy || diagnostics.busy)
        .help(diagnostics.speedHelp)
        .accessibilityLabel("Измерить среднюю скорость")
    }

    private var lastSpeedText: String {
        guard let date = diagnostics.speedDate, let down = diagnostics.formattedSpeed else {
            return diagnostics.speedFailed ? "Последний замер не удался — попробуйте ещё раз" : "Нет замера — нажмите ⚡"
        }
        var text = "↓ \(down)"
        if let up = diagnostics.formattedUpload {
            text += " · ↑ \(up)"
        }
        return "\(text) \(diagnostics.speedUnitTitle) · \(date.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Нижняя панель

    private func footer(theme: Theme) -> some View {
        HStack(spacing: 4) {
            FooterIcon(symbol: "network", title: "Диагностика", theme: theme, action: diagnose)
            FooterIcon(symbol: "gearshape", title: "Настройки", theme: theme, action: openSettings)
            FooterIcon(symbol: "square.and.arrow.up", title: "Экспорт истории в CSV", theme: theme,
                       action: exportCSV)
            FooterIcon(symbol: "arrow.triangle.2.circlepath", title: updateTitle, theme: theme,
                       badge: updateAvailable, action: updater.performPrimaryAction)
            FooterIcon(symbol: widgetVisible ? "rectangle.on.rectangle" : "rectangle",
                       title: widgetVisible ? "Скрыть виджет" : "Показать виджет", theme: theme,
                       action: toggleWidget)
            Spacer(minLength: 0)
            Button(action: quit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Выход")
            .accessibilityLabel("Выход")
        }
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .setemeterOpenSettings, object: nil)
    }

    private func exportCSV() {
        close()
        HistoryStore.shared.exportCSVWithPanel()
    }

    private var updateAvailable: Bool {
        if case .available = updater.state { return true }
        return false
    }

    private var updateTitle: String {
        switch updater.state {
        case .idle: return "Проверить обновления"
        case .checking: return "Проверяем обновления…"
        case .available(let version, _): return "Доступна версия \(version) — Обновить"
        case .downloading: return "Загружаем обновление…"
        case .upToDate: return "Установлена последняя версия"
        case .failed(let message): return "Ошибка обновления: \(message)"
        }
    }

    // MARK: Общие значения

    private var pingText: String {
        guard let milliseconds = monitor.latest?.milliseconds else { return "—" }
        return String(milliseconds)
    }

    private var lastCheckText: String {
        guard let date = monitor.latest?.date else { return "Проверяем…" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private var networkSymbol: String {
        let type = diagnostics.networkType ?? ""
        if type.hasPrefix("Wi") { return "wifi" }
        if type.hasPrefix("Ethernet") { return "cable.connector" }
        return "network"
    }
}
