import SwiftUI

/// Виджет на рабочем столе: статус, пинг, спарклайн, uptime за час, скорость и короткая сводка сети.
@MainActor
struct DesktopWidget: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var diagnostics: DiagnosticsModel
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) var colorScheme
    let toggleWidget: () -> Void

    init(monitor: Monitor, diagnostics: DiagnosticsModel, toggleWidget: @escaping () -> Void) {
        self.monitor = monitor
        self.diagnostics = diagnostics
        self.toggleWidget = toggleWidget
    }

    var body: some View {
        let theme = Theme(colorScheme)
        let tone = sampleTone(monitor.latest, threshold: settings.slowPingThresholdMs)
        let uptime = HistoryStore.shared.stats(for: .hour).uptimePercent
        return VStack(alignment: .leading, spacing: 10) {
            titleRow
            statusRow(theme: theme, tone: tone)
            Sparkline(samples: monitor.samples, tone: tone, theme: theme)
                .frame(height: 28)
            HStack(spacing: 4) {
                Text("Uptime за час")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(percentText(uptime))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .font(Typo.caption)
            .foregroundStyle(.secondary)
            Divider().opacity(0.6)
            speedRow(theme: theme)
            summaryRows
        }
        .padding(Spacing.window)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.window, style: .continuous))
    }

    /// Заголовок. Всё, кроме кнопки закрытия, перетаскивает окно.
    private var titleRow: some View {
        HStack {
            HStack {
                Label("Сетеметр", systemImage: "waveform.path")
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .overlay { WindowDragArea() }
            Button(action: toggleWidget) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Скрыть виджет")
            .accessibilityLabel("Скрыть виджет")
        }
    }

    private func statusRow(theme: Theme, tone: Tone) -> some View {
        HStack(alignment: .center, spacing: 8) {
            StatusDot(tone: tone, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(status(monitor.latest))
                    .font(Typo.value)
                    .lineLimit(1)
                Text(lastCheckText)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
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
            .help("Время ответа HTTPS")
        }
    }

    private func speedRow(theme: Theme) -> some View {
        HStack(spacing: 6) {
            Label("Скачивание", systemImage: "arrow.down")
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(diagnostics.speedSummary)
                .font(Typo.value)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(theme.color(speedToneValue))
            Button(action: diagnostics.testSpeed) {
                Image(systemName: diagnostics.speedBusy ? "arrow.clockwise" : "bolt")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .hoverHighlight(theme)
            }
            .buttonStyle(.plain)
            .disabled(diagnostics.busy || diagnostics.speedBusy)
            .help(diagnostics.speedHelp)
            .accessibilityLabel("Измерить среднюю скорость")
        }
    }

    /// Пять строк сводки: одна строка на пункт, длинные значения обрезаются посередине.
    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            summaryRow("Внешний IPv4", diagnostics.value("Внешний IPv4"))
            summaryRow("Локальный IPv4", diagnostics.localIPv4)
            summaryRow("Маршрут", diagnostics.routeSummary)
            summaryRow("Шлюз", diagnostics.gatewaySummary)
            summaryRow("Проверки", diagnostics.httpsSummary)
        }
        .font(Typo.caption)
        .help(diagnostics.checked.map { "Проверено в \($0.formatted(date: .omitted, time: .standard))" }
              ?? "Проверяем подключение…")
    }

    private func summaryRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(value ?? "—")
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var pingText: String {
        guard let milliseconds = monitor.latest?.milliseconds else { return "—" }
        return String(milliseconds)
    }

    private var lastCheckText: String {
        guard let date = monitor.latest?.date else { return "Проверяем…" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private var speedToneValue: Tone {
        diagnostics.downMbps.map { speedTone($0, threshold: settings.speedWarningMbps) } ?? .neutral
    }
}
