import SwiftUI

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
            chartSection(theme: theme, points: points, stats: stats)
                .padding(12)
                .groupSurface(theme)
            speedSection(theme: theme)
                .padding(12)
                .groupSurface(theme)
            metricsSection(theme: theme)
                .padding(.horizontal, 8)
            Divider()
            footer(theme: theme)
        }
        .padding(Spacing.window)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
    }

    // MARK: Шапка

    private func header(theme: Theme, tone: Tone) -> some View {
        HStack(spacing: 10) {
            Image(systemName: networkSymbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(theme.color(tone))
                .frame(width: 38, height: 38)
                .background(theme.color(tone).opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(status(monitor.latest))
                    .font(.system(size: 16, weight: .semibold))
                networkLine(theme: theme)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(pingText)
                        .font(Typo.hero)
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(theme.color(tone))
                    Text("мс")
                        .font(Typo.caption)
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
        HStack(spacing: 5) {
            Text(diagnostics.networkType ?? "Определяем сеть…")
                .lineLimit(1)
            if networkSymbol == "wifi", let rssi = diagnostics.wifiRSSI {
                let bars = signalBarCount(rssi)
                SignalBars(bars: bars, tone: signalTone(bars: bars), theme: theme)
            }
        }
        .font(Typo.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: График

    private func chartSection(theme: Theme, points: [HistoryPoint], stats: HistoryStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Задержка")
                    .font(Typo.value)
                Spacer(minLength: 8)
                Picker("Период", selection: $range) {
                    ForEach(HistoryRange.allCases, id: \.self) { item in
                        Text(item.shortTitle).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .fixedSize()
            }
            LatencyChart(points: points, range: range, stats: stats, theme: theme,
                         threshold: settings.slowPingThresholdMs)
                .id(range)
                .transition(.opacity)
            HStack(alignment: .top, spacing: 8) {
                statItem("Медиана", msText(stats.medianMs))
                statItem("p95", msText(stats.p95Ms))
                statItem("Доступность", percentText(stats.uptimePercent))
            }
        }
        .animation(Motion.animation, value: range)
    }

    private func statItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(Typo.value)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Скорость и метрики

    private func speedSection(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Скорость")
                    .font(Typo.value)
                Text(speedCaption)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: diagnostics.testSpeed) {
                    Label("Измерить", systemImage: "bolt.fill")
                }
                .controlSize(.small)
                .disabled(diagnostics.speedBusy)
            }
            HStack(alignment: .top, spacing: 16) {
                MetricTile(title: "Скачивание", symbol: "arrow.down", value: diagnostics.formattedSpeed,
                           unit: diagnostics.speedUnitTitle, theme: theme, tone: downloadTone, prominent: true)
                MetricTile(title: "Отдача", symbol: "arrow.up", value: diagnostics.formattedUpload,
                           unit: diagnostics.speedUnitTitle, theme: theme, tone: uploadTone, prominent: true)
            }
        }
    }

    private func metricsSection(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                MetricTile(title: "Джиттер", symbol: "waveform", value: jitterText, unit: "мс",
                           details: [jitterCaption], theme: theme, tone: jitterLevel)
                MetricTile(title: "Потери", symbol: "exclamationmark.triangle", value: lossText,
                           details: [lossCaption], theme: theme, tone: lossLevel)
            }
            HStack(alignment: .top, spacing: 16) {
                MetricTile(title: "Wi‑Fi", symbol: "wifi", value: rssiText, unit: "дБм",
                           details: wifiDetails, theme: theme, tone: wifiTone, signalBars: wifiBars)
                MetricTile(title: "Внешний IP", symbol: "globe", value: diagnostics.publicIPv4,
                           details: ipDetails, theme: theme, tone: ipTone,
                           copyValue: diagnostics.publicIPv4)
            }
        }
    }

    private var speedCaption: String {
        if diagnostics.speedBusy { return "Идёт замер…" }
        if let date = diagnostics.speedDate {
            return "Замер в \(date.formatted(date: .omitted, time: .shortened))"
        }
        return diagnostics.speedFailed ? "Замер не удался" : "Нет замера"
    }

    private var downloadTone: Tone {
        diagnostics.downMbps.map { speedTone($0, threshold: settings.speedWarningMbps) } ?? .neutral
    }

    private var uploadTone: Tone {
        diagnostics.upMbps.map { speedTone($0, threshold: settings.speedWarningMbps) } ?? .neutral
    }

    private var jitterText: String? {
        diagnostics.jitterMs.map { $0.formatted(.number.precision(.fractionLength(1))) }
    }

    private var jitterCaption: String {
        diagnostics.jitterMs == nil ? "Нет замера, ждём проверку" : "10 HEAD-запросов"
    }

    private var jitterLevel: Tone {
        diagnostics.jitterMs.map { jitterTone($0) } ?? .neutral
    }

    private var lossText: String? {
        diagnostics.lossPercent.map { "\(Int($0))%" }
    }

    private var lossCaption: String {
        diagnostics.lossPercent.map { "ответили \(10 - Int($0) / 10) из 10" } ?? "Нет замера, ждём проверку"
    }

    private var lossLevel: Tone {
        diagnostics.lossPercent.map { lossTone($0) } ?? .neutral
    }

    private var rssiText: String? {
        diagnostics.wifiRSSI.map { "\($0)" }
    }

    /// Диапазон и канал — в первой строке, скорость линка — во второй.
    private var wifiDetails: [String] {
        guard let wifi = diagnostics.wifi else { return ["Нет Wi‑Fi соединения"] }
        var lines: [String] = []
        var place: [String] = []
        if let band = wifi.band { place.append(band) }
        if let channel = wifi.channel { place.append("кан. \(channel)") }
        if !place.isEmpty { lines.append(place.joined(separator: " · ")) }
        if let rate = wifi.txRate { lines.append("\(Int(rate.rounded())) Мбит/с") }
        return lines.isEmpty ? ["Сигнал Wi‑Fi"] : lines
    }

    private var wifiBars: Int? {
        diagnostics.wifiRSSI.map { signalBarCount($0) }
    }

    private var wifiTone: Tone {
        wifiBars.map { signalTone(bars: $0) } ?? .neutral
    }

    /// Страна (с городом) и провайдер — каждое на своей строке.
    private var ipDetails: [String] {
        if diagnostics.publicIPv4 == nil { return ["Нет ответа, обновится при проверке"] }
        guard let info = diagnostics.ipInfo else { return ["Нажмите, чтобы скопировать"] }
        var lines: [String] = []
        let place = [info.country, info.city].compactMap { $0 }.filter { !$0.isEmpty }
        if !place.isEmpty { lines.append(place.joined(separator: ", ")) }
        if let provider = info.provider, !provider.isEmpty { lines.append(provider) }
        return lines.isEmpty ? ["Нажмите, чтобы скопировать"] : lines
    }

    private var ipTone: Tone {
        diagnostics.publicIPv4 == nil ? .neutral : .good
    }

    // MARK: Нижняя панель

    private func footer(theme: Theme) -> some View {
        HStack(spacing: 2) {
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
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 26)
                    .hoverHighlight(theme)
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
