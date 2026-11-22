import AppKit
import SwiftUI

/// Статус строки: цвет и значок, который выводится по значению.
struct RowStatus {
    let tone: Tone
    let symbol: String
}

/// Классификация значения диагностики по тексту (проверки, пинги, ошибки).
func rowStatus(_ row: DiagnosticRow) -> RowStatus {
    let value = row.value
    if value == "—" || value.isEmpty || value == "Выключен" || value == "Нет активного профиля" {
        return RowStatus(tone: .neutral, symbol: "minus.circle")
    }
    let badPrefixes = ["Нет", "Ошибка", "Таймаут", "HTTP", "Некорректный", "Отсутствует", "Ответ не HTTP", "Не "]
    if badPrefixes.contains(where: { value.hasPrefix($0) }) {
        return RowStatus(tone: .bad, symbol: "xmark.circle.fill")
    }
    if value.hasPrefix("OK") || value.hasPrefix("0%") || value.hasSuffix(" мс") {
        return RowStatus(tone: .good, symbol: "checkmark.circle.fill")
    }
    return RowStatus(tone: .neutral, symbol: "minus.circle")
}

/// Окно «Диагностика»: карточка скорости, сворачиваемые секции-карточки с цветовыми статусами
/// и нижняя панель («Обновить», «Скопировать отчёт»).
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
        (title: "Локальная сеть и маршрутизация", symbol: "wifi"),
        (title: "Доступность", symbol: "checkmark.shield")
    ]

    init(model: DiagnosticsModel) {
        self.model = model
    }

    private var theme: Theme { Theme(colorScheme) }

    var body: some View {
        let theme = self.theme
        return VStack(alignment: .leading, spacing: 14) {
            header(theme: theme)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    speedCard(theme: theme)
                    ForEach(model.groups.indices, id: \.self) { index in
                        section(index: index, theme: theme)
                    }
                }
                .padding(.bottom, 4)
            }
            footer(theme: theme)
        }
        .padding(20)
        .background {
            Rectangle().fill(theme.windowFill)
        }
        .frame(minWidth: 550, minHeight: 450)
    }

    // MARK: Шапка

    private func header(theme: Theme) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.mint)
                .frame(width: 42, height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.mint.opacity(0.14))
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Диагностика сети")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(checkedText)
                    .font(.caption)
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.formattedSpeed ?? "—")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.color(tone))
                Text(model.speedUnitTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let upload = model.formattedUpload {
                    Text("↑ \(upload)")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }
                Spacer(minLength: 0)
                if model.speedBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            HStack(spacing: 10) {
                Text(speedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: model.testSpeed) {
                    Label(model.speedBusy ? "Тест идёт…" : "Измерить скорость", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.mint)
                .disabled(model.speedBusy || model.busy)
            }
            if model.speedFailed {
                Text("Тест не завершился. Попробуйте ещё раз.")
                    .font(.caption)
                    .foregroundStyle(theme.amber)
            }
            let records = Array(SpeedHistory.shared.records.suffix(5))
            if !records.isEmpty {
                SpeedBars(records: records, threshold: threshold, theme: theme)
            }
        }
        .padding(15)
        .cardSurface(theme)
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
        let problems = model.groups[index].filter { rowStatus($0).tone == .bad }.count
        return VStack(alignment: .leading, spacing: 9) {
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.mint)
                        .frame(width: 18)
                    Text(info.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 8)
                    if problems > 0 {
                        Text("проблем: \(problems)")
                            .font(.caption)
                            .foregroundStyle(theme.coral)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isCollapsed ? "Развернуть секцию" : "Свернуть секцию")
            if !isCollapsed {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.groups[index]) { row in
                        rowView(row, theme: theme)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(13)
        .cardSurface(theme)
    }

    private func rowView(_ row: DiagnosticRow, theme: Theme) -> some View {
        let state = rowStatus(row)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color(state.tone))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(row.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(row.value)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            copyButton(row, theme: theme)
        }
        .padding(.vertical, 2)
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
                .font(.system(size: 10, weight: .semibold))
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

    private func footer(theme: Theme) -> some View {
        HStack(spacing: 10) {
            Text("Внешний IP определяет ipify для текущего маршрута.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: model.refresh) {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy || model.speedBusy)
            Button(action: copyReport) {
                Label("Скопировать отчёт", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.mint)
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
