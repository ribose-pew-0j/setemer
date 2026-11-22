import AppKit
import SwiftUI

// Leaf-компоненты получают `theme` параметром и не используют `private` для свойств:
// так работает memberwise-инициализатор, который вызывают другие файлы.

extension HistoryRange {
    /// Короткая подпись переключателя периода.
    var shortTitle: String {
        switch self {
        case .hour: return "1 ч"
        case .day: return "24 ч"
        case .week: return "7 дн"
        }
    }
}

/// Фон группы в стиле inset-списка: заливка без обводки и тени.
struct GroupSurface: ViewModifier {
    let theme: Theme

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                .fill(theme.group)
        }
    }
}

extension View {
    func groupSurface(_ theme: Theme) -> some View {
        modifier(GroupSurface(theme: theme))
    }
}

/// Подсветка фона при наведении для плоских кнопок.
struct HoverHighlight: ViewModifier {
    let theme: Theme
    @State var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(hovering ? theme.hover : Color.clear)
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(_ theme: Theme) -> some View {
        modifier(HoverHighlight(theme: theme))
    }
}

/// Точка статуса. Цвет плавно меняется при смене состояния.
struct StatusDot: View {
    let tone: Tone
    let theme: Theme
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(theme.color(tone))
            .frame(width: size, height: size)
            .animation(Motion.animation, value: tone)
            .accessibilityHidden(true)
    }
}

/// Раскладка спарклайна: отрезки линии (без разрывов на провалах) и x-координаты провалов.
struct SparkLayout {
    let segments: [[CGPoint]]
    let failures: [CGFloat]
}

func sparklineLayout(samples: [Sample], slots: Int, size: CGSize, top: Double) -> SparkLayout {
    let step = size.width / CGFloat(max(slots - 1, 1))
    let baseline = size.height - 3
    let usable = max(size.height - 8, 1)
    var segments: [[CGPoint]] = []
    var current: [CGPoint] = []
    var failures: [CGFloat] = []
    for (index, sample) in samples.enumerated() {
        let x = CGFloat(slots - samples.count + index) * step
        guard let milliseconds = sample.milliseconds else {
            if !current.isEmpty { segments.append(current) }
            current = []
            failures.append(x)
            continue
        }
        let ratio = CGFloat(min(Double(milliseconds) / top, 1))
        current.append(CGPoint(x: x, y: baseline - ratio * usable))
    }
    if !current.isEmpty { segments.append(current) }
    return SparkLayout(segments: segments, failures: failures)
}

/// Мини-спарклайн последних проверок: тонкая линия 1.5 pt с лёгкой заливкой, провалы коралловыми точками.
struct Sparkline: View {
    let samples: [Sample]
    let tone: Tone
    let theme: Theme

    var body: some View {
        let peak = Double(samples.compactMap { $0.milliseconds }.max() ?? 0)
        let top = max(peak * 1.25, 40)
        let accent = theme.color(tone)
        let coral = theme.coral
        return Canvas { context, size in
            let layout = sparklineLayout(samples: samples, slots: 30, size: size, top: top)
            for segment in layout.segments {
                guard let first = segment.first, let last = segment.last else { continue }
                var line = Path()
                line.move(to: first)
                for point in segment.dropFirst() {
                    line.addLine(to: point)
                }
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                let fill = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [accent.opacity(0.12), accent.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height))
                context.fill(area, with: fill)
                context.stroke(line, with: .color(accent),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            let baseline = size.height - 3
            for x in layout.failures {
                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: baseline - 1.5, width: 3, height: 3)),
                             with: .color(coral))
            }
            if let last = layout.segments.last?.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)),
                             with: .color(accent))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Четыре полоски уровня Wi‑Fi сигнала.
struct SignalBars: View {
    let bars: Int
    let tone: Tone
    let theme: Theme

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(level <= bars ? theme.color(tone) : theme.track)
                    .frame(width: 3, height: CGFloat(2 + level * 2))
            }
        }
        .frame(height: 10, alignment: .bottom)
        .animation(Motion.animation, value: bars)
        .accessibilityHidden(true)
    }
}

/// Один столбик истории замеров скорости.
struct SpeedBar: View {
    let record: SpeedRecord
    let peak: Double
    let threshold: Int
    let theme: Theme

    var body: some View {
        let height: CGFloat = record.down.map { 4 + 18 * CGFloat($0 / peak) } ?? 3
        let color: Color = record.down.map { theme.color(speedTone($0, threshold: threshold)) } ?? theme.track
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 10, height: height)
    }
}

/// Последние замеры скорости в виде компактных столбиков.
struct SpeedBars: View {
    let records: [SpeedRecord]
    let threshold: Int
    let theme: Theme

    var body: some View {
        let peak = max(records.compactMap { $0.down }.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<records.count, id: \.self) { index in
                SpeedBar(record: records[index], peak: peak, threshold: threshold, theme: theme)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Последние замеры скорости: \(records.count)")
    }
}

/// Иконка-кнопка нижней панели: плоская, с подсветкой при наведении. Точка-бейдж показывает доступное обновление.
struct FooterIcon: View {
    let symbol: String
    let title: String
    let theme: Theme
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 26)
                .hoverHighlight(theme)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(theme.mint)
                            .frame(width: 6, height: 6)
                            .offset(x: -5, y: 5)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(badge ? "Есть обновление" : "")
    }
}

/// Ячейка метрики без рамок: серый заголовок с символом сверху, значение под ним, подписи ниже.
/// Каждая подпись — отдельная строка (до двух строк с уменьшением шрифта), поэтому текст не обрезается.
/// Если задан `copyValue`, клик копирует значение.
struct MetricTile: View {
    let title: String
    let symbol: String
    let value: String?
    var unit: String = ""
    var details: [String] = []
    let theme: Theme
    var tone: Tone = .neutral
    var signalBars: Int? = nil
    var copyValue: String? = nil
    @State var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .regular))
                Text(title)
                    .font(Typo.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if copyValue != nil {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(copied ? theme.mint : Color(nsColor: .tertiaryLabelColor))
                }
            }
            .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(Typo.value)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(valueColor)
                if value != nil && !unit.isEmpty {
                    Text(unit)
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let signalBars {
                    SignalBars(bars: signalBars, tone: tone, theme: theme)
                }
            }
            ForEach(details, id: \.self) { line in
                Text(line)
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { copy() }
        .help(copyValue == nil ? "" : "Нажмите, чтобы скопировать")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value ?? "нет данных") \(unit)")
        .accessibilityHint(details.joined(separator: ", "))
    }

    private var valueColor: Color {
        if value == nil { return Color(nsColor: .tertiaryLabelColor) }
        return tone == .neutral ? Color(nsColor: .labelColor) : theme.color(tone)
    }

    func copy() {
        guard let copyValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyValue, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}
