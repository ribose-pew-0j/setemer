import SwiftUI

@MainActor
struct DashboardView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var diagnostics: DiagnosticsModel
    @ObservedObject var updater: Updater
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            VStack(alignment: .leading, spacing: 14) {
                header(theme: Theme(.dark), tone: tone)
                Divider().overlay(.white.opacity(0.14))
                chartSection(theme: Theme(.dark), points: points, stats: stats)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.15, blue: 0.24),
                                                  Color(red: 0.09, green: 0.21, blue: 0.28),
                                                  Color(red: 0.08, green: 0.30, blue: 0.32)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .environment(\.colorScheme, .dark)
            speedSection(theme: theme)
            metricsSection(theme: theme)
                .padding(12)
                .groupSurface(theme)
            Divider()
            footer(theme: theme)
        }
        .padding(12)
        .frame(width: 410)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
    }

    // MARK: Шапка

    private func header(theme: Theme, tone: Tone) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(status(monitor.latest))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                networkLine(theme: theme)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .center, spacing: 7) {
                    ZStack {
                        Circle().fill(theme.color(tone)).frame(width: 7, height: 7)
                        if !reduceMotion, let sample = monitor.latest {
                            PingRipple(color: theme.color(tone)).id(sample.id)
                        }
                    }
                    .frame(width: 19, height: 19)
                    .accessibilityHidden(true)
                    Text(pingText)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
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
            Image(systemName: networkSymbol)
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
                Label("Задержка", systemImage: "waveform.path.ecg")
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
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(speedCaption)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: diagnostics.testSpeed) {
                    Label("Измерить", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.small)
                .disabled(diagnostics.speedBusy)
            }
            HStack(alignment: .top, spacing: 8) {
                MetricTile(title: "Скачивание", symbol: "arrow.down.left.circle.fill", value: diagnostics.formattedSpeed,
                           unit: diagnostics.speedUnitTitle, theme: theme, accent: .blue, tone: downloadTone, prominent: true)
                MetricTile(title: "Отдача", symbol: "arrow.up.right.circle.fill", value: diagnostics.formattedUpload,
                           unit: diagnostics.speedUnitTitle, theme: theme, accent: .purple, tone: uploadTone, prominent: true)
            }
        }
    }

    private func metricsSection(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                MetricTile(title: "Джиттер", symbol: "waveform", value: jitterText, unit: "мс",
                           details: [jitterCaption], theme: theme, accent: .orange, tone: jitterLevel)
                MetricTile(title: "Потери", symbol: "square.stack.3d.up.fill", value: lossText,
                           details: [lossCaption], theme: theme, accent: .pink, tone: lossLevel)
            }
            HStack(alignment: .top, spacing: 16) {
                MetricTile(title: "Wi‑Fi", symbol: "wifi", value: rssiText, unit: "дБм",
                           details: wifiDetails, theme: theme, accent: .teal, tone: wifiTone, signalBars: wifiBars)
                MetricTile(title: "Внешний IP", symbol: "globe.europe.africa.fill", value: diagnostics.publicIPv4,
                           details: ipDetails, theme: theme, accent: .indigo, tone: ipTone,
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
            FooterIcon(symbol: "stethoscope", title: "Диагностика", theme: theme, action: diagnose)
            FooterIcon(symbol: "gearshape.fill", title: "Настройки", theme: theme, action: openSettings)
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

private struct PingRipple: View {
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .scaleEffect(expanded ? 1 : 0.35)
            .opacity(expanded ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeOut(duration: 0.85)) { expanded = true }
            }
    }
}
