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

/// Поверхность карточки: фон, тонкая обводка, скругление.
struct CardSurface: ViewModifier {
    let theme: Theme
    var radius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(theme.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.cardStroke, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func cardSurface(_ theme: Theme, radius: CGFloat = Radius.card) -> some View {
        modifier(CardSurface(theme: theme, radius: radius))
    }
}

/// Точка статуса со мягким свечением. Цвет плавно меняется при смене состояния.
struct StatusDot: View {
    let tone: Tone
    let theme: Theme
    var size: CGFloat = 10

    var body: some View {
        let color = theme.color(tone)
        return ZStack {
            Circle()
                .fill(color.opacity(0.45))
                .frame(width: size * 2, height: size * 2)
                .blur(radius: size * 0.5)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
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

/// Мини-спарклайн последних проверок: линия с заливкой, провалы коралловыми точками.
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
                    Gradient(colors: [accent.opacity(0.28), accent.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height))
                context.fill(area, with: fill)
                context.stroke(line, with: .color(accent),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            let baseline = size.height - 3
            for x in layout.failures {
                context.fill(Path(ellipseIn: CGRect(x: x - 2, y: baseline - 2, width: 4, height: 4)),
                             with: .color(coral))
            }
            if let last = layout.segments.last?.last {
                context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)),
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
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
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
        let height: CGFloat = record.down.map { 6 + 22 * CGFloat($0 / peak) } ?? 4
        let color: Color = record.down.map { theme.color(speedTone($0, threshold: threshold)) } ?? theme.track
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 14, height: height)
    }
}

/// Последние замеры скорости в виде компактных столбиков.
struct SpeedBars: View {
    let records: [SpeedRecord]
    let threshold: Int
    let theme: Theme

    var body: some View {
        let peak = max(records.compactMap { $0.down }.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<records.count, id: \.self) { index in
                SpeedBar(record: records[index], peak: peak, threshold: threshold, theme: theme)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Последние замеры скорости: \(records.count)")
    }
}

/// Переключатель периода «1 ч / 24 ч / 7 дн» с анимированной подсветкой.
struct RangeSwitch: View {
    @Binding var selection: HistoryRange
    let theme: Theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryRange.allCases, id: \.self) { range in
                let selected = selection == range
                Button {
                    animateUI { selection = range }
                } label: {
                    Text(range.shortTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(minWidth: 40)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.chip)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Период: \(range.title)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.track.opacity(0.5))
        }
    }
}

/// Иконка-кнопка нижней панели. Точка-бейдж показывает доступное обновление.
struct FooterIcon: View {
    let symbol: String
    let title: String
    let theme: Theme
    var badge = false
    let action: () -> Void
    @State var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 34, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hovering ? theme.chip : Color.clear)
                }
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(theme.mint)
                            .frame(width: 7, height: 7)
                            .offset(x: -6, y: 6)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(badge ? "Есть обновление" : "")
    }
}

/// Плитка метрики для сетки дашборда. Значение nil — пустое состояние с подсказкой в `caption`.
/// Если задан `copyValue`, клик копирует значение.
struct MetricTile: View {
    let title: String
    let symbol: String
    let value: String?
    var unit: String = ""
    let caption: String
    let theme: Theme
    var tone: Tone = .neutral
    var valueSize: CGFloat = 20
    var signalBars: Int? = nil
    var copyValue: String? = nil
    @State var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.color(tone))
                Text(title)
                    .font(Typo.label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if copyValue != nil {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(copied ? theme.mint : Color.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—")
                    .font(Typo.display(valueSize))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(value == nil ? Color.secondary : theme.color(tone))
                if value != nil && !unit.isEmpty {
                    Text(unit)
                        .font(Typo.label)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let signalBars {
                    SignalBars(bars: signalBars, tone: tone, theme: theme)
                }
            }
            Text(caption)
                .font(Typo.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(theme)
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture { copy() }
        .help(copyValue == nil ? "" : "Нажмите, чтобы скопировать")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value ?? "нет данных") \(unit)")
        .accessibilityHint(caption)
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
