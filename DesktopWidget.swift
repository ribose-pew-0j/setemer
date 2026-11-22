import SwiftUI

/// Виджет на рабочем столе: статус со свечением, пинг, спарклайн, uptime за час, скорость и сводка сети.
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
                .frame(height: 34)
            HStack(spacing: 4) {
                Text("Uptime за час")
                Text(percentText(uptime))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .font(Typo.caption)
            .foregroundStyle(.secondary)
            Divider().overlay(theme.track)
            speedRow(theme: theme)
            summaryRows
        }
        .padding(Spacing.window)
        .frame(width: 300)
        .background {
            RoundedRectangle(cornerRadius: Radius.window, style: .continuous).fill(theme.windowFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.window, style: .continuous)
                .strokeBorder(theme.color(tone).opacity(0.3), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    /// Заголовок. Всё, кроме кнопки закрытия, перетаскивает окно.
    private var titleRow: some View {
        HStack {
            HStack {
                Label("Сетеметр", systemImage: "waveform.path")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 22)
            .overlay { WindowDragArea() }
            Button(action: toggleWidget) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Скрыть виджет")
            .accessibilityLabel("Скрыть виджет")
        }
    }

    private func statusRow(theme: Theme, tone: Tone) -> some View {
        HStack(alignment: .center, spacing: 10) {
            StatusDot(tone: tone, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(status(monitor.latest))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(lastCheckText)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(pingText)
                    .font(Typo.display(28))
                    .monospacedDigit()
                    .foregroundStyle(theme.color(tone))
                Text("мс")
                    .font(Typo.label)
                    .foregroundStyle(.secondary)
            }
            .help("Время ответа HTTPS")
        }
    }

    private func speedRow(theme: Theme) -> some View {
        HStack(spacing: 6) {
            Label("Скачивание", systemImage: "arrow.down.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(diagnostics.speedSummary)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.color(speedToneValue))
            Button(action: diagnostics.testSpeed) {
                Image(systemName: diagnostics.speedBusy ? "arrow.clockwise" : "bolt.fill")
            }
            .controlSize(.small)
            .disabled(diagnostics.busy || diagnostics.speedBusy)
            .help(diagnostics.speedHelp)
            .accessibilityLabel("Измерить среднюю скорость")
        }
    }

    private var summaryRows: some View {
        VStack(alignment: .leading, spacing: 5) {
            summaryRow("Внешний IPv4", diagnostics.value("Внешний IPv4"))
            summaryRow("Внешний IPv6", diagnostics.value("Внешний IPv6"))
            summaryRow("Локальный IPv4", diagnostics.localIPv4)
            summaryRow("Маршрут", diagnostics.routeSummary)
            summaryRow("Шлюз", diagnostics.gatewaySummary)
            summaryRow("DNS / прокси", diagnostics.dnsSummary)
            summaryRow("Проверки", diagnostics.httpsSummary)
        }
        .font(.system(size: 11))
        .help(diagnostics.checked.map { "Проверено в \($0.formatted(date: .omitted, time: .standard))" }
              ?? "Проверяем подключение…")
    }

    private func summaryRow(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value ?? "—")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
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
