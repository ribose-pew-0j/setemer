import AppKit
import SwiftUI

/// Окно «Диагностика»: в стиле Системных настроек — сгруппированные inset-списки на системном фоне,
/// сворачиваемые секции, цветные значки только для статуса; нижняя панель с «Обновить» и «Скопировать отчёт».
@MainActor
struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    @ObservedObject var settings = Settings.shared
    @Environment(\.colorScheme) var colorScheme
    @State var collapsed: Set<Int> = []
    @State var hoveredRow: String? = nil
    @State var copiedRow: String? = nil

    let sections: [(title: String, symbol: String)] = [
        (title: "Внешний адрес", symbol: "globe"),
        (title: "Параметры сети", symbol: "wifi"),
        (title: "Проверки подключения", symbol: "checkmark.shield")
    ]

    init(model: DiagnosticsModel) {
        self.model = model
    }

    private var theme: Theme { Theme(colorScheme) }

    var body: some View {
        let theme = self.theme
        return VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    speedCard(theme: theme)
                    ForEach(model.groups.indices, id: \.self) { index in
                        section(index: index, theme: theme)
                    }
                }
                .padding(.bottom, 4)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 550, minHeight: 450)
    }

    // MARK: Шапка

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Диагностика сети")
                    .font(Typo.value)
                Text(checkedText)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.busy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var checkedText: String {
        model.checked.map { "Проверено в \($0.formatted(date: .omitted, time: .standard))" }
            ?? "Проверяем подключение…"
    }

    // MARK: Скорость

    private func speedCard(theme: Theme) -> some View {
        let threshold = settings.speedWarningMbps
        let tone = model.downMbps.map { speedTone($0, threshold: threshold) } ?? .neutral
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.formattedSpeed ?? "—")
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.color(tone))
                Text(model.speedUnitTitle)
                    .font(Typo.body)
                    .foregroundStyle(.secondary)
                if let upload = model.formattedUpload {
                    Text("↑ \(upload)")
                        .font(Typo.body)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 0)
                if model.speedBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            HStack(spacing: 10) {
                Text(speedCaption)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Button(action: model.testSpeed) {
                    Label(model.speedBusy ? "Тест идёт…" : "Измерить скорость", systemImage: "bolt")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .disabled(model.speedBusy || model.busy)
            }
            if model.speedFailed {
                Text("Тест не завершился. Попробуйте ещё раз.")
                    .font(Typo.caption)
                    .foregroundStyle(theme.amber)
            }
            let records = Array(SpeedHistory.shared.records.suffix(5))
            if !records.isEmpty {
                SpeedBars(records: records, threshold: threshold, theme: theme)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupSurface(theme)
    }

    private var speedCaption: String {
        model.speedDate.map { "Cloudflare · 3 замера · \($0.formatted(date: .omitted, time: .shortened))" }
            ?? "Cloudflare · 3 загрузки по 5 МБ"
    }

    // MARK: Секции

    private func title(for index: Int) -> String {
        index < sections.count ? sections[index].title : "Раздел"
    }

    private func section(index: Int, theme: Theme) -> some View {
        let info = index < sections.count ? sections[index] : (title: "Раздел", symbol: "list.bullet")
        let isCollapsed = collapsed.contains(index)
        let rows = model.groups[index]
        let problems = rows.filter { $0.needsAttention }.count
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                animateUI {
                    if isCollapsed {
                        collapsed.remove(index)
                    } else {
                        collapsed.insert(index)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: info.symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(info.title)
                        .font(Typo.body)
                    Spacer(minLength: 8)
                    if problems > 0 {
                        Label("Требует внимания · \(problems)", systemImage: "exclamationmark.circle")
                            .font(Typo.caption)
                            .foregroundStyle(theme.amber)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isCollapsed ? "Развернуть секцию" : "Свернуть секцию")
            if !isCollapsed {
                Divider()
                    .opacity(0.6)
                    .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        if rowIndex > 0 {
                            Divider()
                                .opacity(0.6)
                        }
                        rowView(rows[rowIndex], theme: theme)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupSurface(theme)
    }

    private func rowView(_ row: DiagnosticRow, theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
                .font(Typo.body)
            Spacer(minLength: 12)
            if row.needsAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(theme.amber)
                    .accessibilityLabel("Требует внимания")
            }
            Text(row.value.replacingOccurrences(of: "^OK · ", with: "Ответ получен · ", options: .regularExpression))
                .font(Typo.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            copyButton(row, theme: theme)
        }
        .padding(.vertical, 5)
        .onHover { inside in
            if inside {
                hoveredRow = row.name
            } else if hoveredRow == row.name {
                hoveredRow = nil
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Кнопка копирования значения: видна при наведении на строку, на время копирования показывает галочку.
    private func copyButton(_ row: DiagnosticRow, theme: Theme) -> some View {
        let copied = copiedRow == row.name
        let visible = copied || hoveredRow == row.name
        return Button {
            copy(row)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(copied ? theme.mint : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .help("Скопировать значение")
        .accessibilityLabel("Скопировать \(row.name)")
    }

    private func copy(_ row: DiagnosticRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.value, forType: .string)
        copiedRow = row.name
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedRow == row.name {
                copiedRow = nil
            }
        }
    }

    // MARK: Нижняя панель

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Внешний IP определяет ipify для текущего маршрута.")
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: model.refresh) {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.busy || model.speedBusy)
            Button(action: copyReport) {
                Label("Скопировать отчёт", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(model.groups.isEmpty || model.busy)
        }
    }

    /// Текстовый отчёт в буфер: скорость, отдача и все секции.
    private func copyReport() {
        var blocks: [String] = []
        if let speed = model.formattedSpeed {
            blocks.append("Средняя скорость скачивания: \(speed) \(model.speedUnitTitle) (Cloudflare, 3 замера)")
        }
        if let upload = model.formattedUpload {
            blocks.append("Средняя скорость отдачи: \(upload) \(model.speedUnitTitle) (Cloudflare, 2 замера)")
        }
        for (index, rows) in model.groups.enumerated() {
            var lines = [title(for: index)]
            lines += rows.map { "\($0.name): \($0.value)" }
            blocks.append(lines.joined(separator: "\n"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blocks.joined(separator: "\n\n"), forType: .string)
    }
}
