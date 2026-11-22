import SwiftUI

/// Шкала графика: окно времени и диапазон значений с запасом 15%.
struct LatencyScale {
    let start: Date
    let interval: TimeInterval
    let low: Double
    let high: Double

    init(range: HistoryRange, now: Date, values: [Double]) {
        start = now.addingTimeInterval(-range.interval)
        interval = range.interval
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 100
        let span = max(maximum - minimum, 20)
        low = max(0, minimum - span * 0.15)
        high = maximum + span * 0.15
    }

    func y(_ ms: Double, height: CGFloat) -> CGFloat {
        CGFloat((high - ms) / (high - low)) * height
    }

    func x(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / interval) * width
    }

    func date(atX x: CGFloat, width: CGFloat) -> Date {
        start.addingTimeInterval(Double(x / max(width, 1)) * interval)
    }
}

/// Геометрия линии: отрезки без разрывов и точки провалов у базовой линии.
struct LatencyLayout {
    let lines: [[CGPoint]]
    let failures: [CGPoint]
}

func latencyLayout(points: [HistoryPoint], scale: LatencyScale, width: CGFloat, height: CGFloat) -> LatencyLayout {
    var lines: [[CGPoint]] = []
    var current: [CGPoint] = []
    var failures: [CGPoint] = []
    var previous: Date?
    for point in points {
        // Большой промежуток без замеров (приложение было закрыто) разрывает линию.
        if let previous, point.date.timeIntervalSince(previous) > 600, !current.isEmpty {
            lines.append(current)
            current = []
        }
        previous = point.date
        let x = scale.x(point.date, width: width)
        if let ms = point.ms {
            current.append(CGPoint(x: x, y: scale.y(ms, height: height)))
        } else {
            if !current.isEmpty { lines.append(current) }
            current = []
            failures.append(CGPoint(x: x, y: height - 3))
        }
    }
    if !current.isEmpty { lines.append(current) }
    return LatencyLayout(lines: lines, failures: failures)
}

/// Рисование направляющих, медианы, заливки, линии и провалов.
/// Направляющих всего две: на уровне максимума и минимума, там же стоят подписи оси.
func drawLatency(_ context: inout GraphicsContext, size: CGSize, layout: LatencyLayout,
                 guideYs: [CGFloat], medianY: CGFloat?, theme: Theme) {
    for y in guideYs {
        var guide = Path()
        guide.move(to: CGPoint(x: 0, y: y))
        guide.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(guide, with: .color(theme.grid), lineWidth: 0.5)
    }
    if let medianY {
        var median = Path()
        median.move(to: CGPoint(x: 0, y: medianY))
        median.addLine(to: CGPoint(x: size.width, y: medianY))
        context.stroke(median, with: .color(Color(nsColor: .tertiaryLabelColor)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
    }
    for line in layout.lines {
        guard let first = line.first, let last = line.last else { continue }
        var path = Path()
        path.move(to: first)
        for point in line.dropFirst() {
            path.addLine(to: point)
        }
        var area = path
        area.addLine(to: CGPoint(x: last.x, y: size.height))
        area.addLine(to: CGPoint(x: first.x, y: size.height))
        area.closeSubpath()
        let fill = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [theme.mint.opacity(0.12), theme.mint.opacity(0)]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height))
        context.fill(area, with: fill)
        context.stroke(path, with: .color(theme.mint),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
    for failure in layout.failures {
        let dot = Path(ellipseIn: CGRect(x: failure.x - 2, y: failure.y - 2, width: 4, height: 4))
        context.fill(dot, with: .color(theme.coral))
    }
}

/// График задержки за выбранный период: тонкая линия с лёгкой заливкой, две направляющие,
/// подписи max/median/min на оси (строго внутри области графика), провалы коралловыми точками,
/// подсказка при наведении или протягивании.
struct LatencyChart: View {
    let points: [HistoryPoint]
    let range: HistoryRange
    let stats: HistoryStats
    let theme: Theme
    let threshold: Int
    @State var hover: CGPoint? = nil

    let axisWidth: CGFloat = 30
    let plotHeight: CGFloat = 72
    let labelHeight: CGFloat = 12

    private var values: [Double] {
        points.compactMap { $0.ms }
    }

    private var accessibilitySummary: String {
        let median = msText(stats.medianMs)
        let high = msText(values.max())
        let low = msText(values.min())
        return "Медиана \(median), максимум \(high), минимум \(low), доступность \(percentText(stats.uptimePercent))"
    }

    var body: some View {
        let scale = LatencyScale(range: range, now: .now, values: values)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                axis(scale: scale)
                GeometryReader { proxy in
                    plot(size: proxy.size, scale: scale)
                }
            }
            .frame(height: plotHeight)
            HStack {
                Text(timeText(scale.start))
                Spacer(minLength: 0)
                Text("сейчас")
            }
            .font(Typo.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, axisWidth + 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("График задержки")
        .accessibilityValue(accessibilitySummary)
    }

    private func plot(size: CGSize, scale: LatencyScale) -> some View {
        let layout = latencyLayout(points: points, scale: scale, width: size.width, height: size.height)
        let medianY: CGFloat? = stats.medianMs.map { scale.y($0, height: size.height) }
        let guideYs: [CGFloat] = [values.max(), values.min()]
            .compactMap { $0 }
            .map { scale.y($0, height: size.height) }
        return ZStack(alignment: .topLeading) {
            Canvas { context, canvasSize in
                drawLatency(&context, size: canvasSize, layout: layout, guideYs: guideYs,
                            medianY: medianY, theme: theme)
            }
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hover = location
                    case .ended:
                        hover = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { hover = $0.location }
                        .onEnded { _ in hover = nil }
                )
            if let current = hover,
               let point = nearestPoint(to: scale.date(atX: current.x, width: size.width)) {
                hoverLayer(point: point, scale: scale, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func hoverLayer(point: HistoryPoint, scale: LatencyScale, size: CGSize) -> some View {
        let x = scale.x(point.date, width: size.width)
        let y: CGFloat = point.ms.map { scale.y($0, height: size.height) } ?? (size.height - 3)
        let markerColor: Color = point.ms.map { theme.color(pingTone(Int($0.rounded()), threshold: threshold)) }
            ?? theme.coral
        let title = point.ms.map { "\(Int($0.rounded())) мс" } ?? "Нет ответа"
        let tipX = min(max(x, 56), size.width - 56)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(theme.grid)
                .frame(width: 0.5, height: size.height)
                .position(x: x, y: size.height / 2)
            Circle()
                .fill(markerColor)
                .frame(width: 6, height: 6)
                .position(x: x, y: y)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typo.value)
                    .monospacedDigit()
                    .foregroundStyle(markerColor)
                Text(timeText(point.date))
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(.regularMaterial)
            }
            .position(x: tipX, y: 18)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Подписи оси: max, median (если не слипается с краями), min.
    /// Каждая подпись центрируется по своей точке, но зажата внутри области графика и обрезается по её высоте.
    private func axis(scale: LatencyScale) -> some View {
        let yMax = values.max().map { scale.y($0, height: plotHeight) }
        let yMin = values.min().map { scale.y($0, height: plotHeight) }
        let yMedian = stats.medianMs.map { scale.y($0, height: plotHeight) }
        let showMedian = isApart(yMedian, yMax) && isApart(yMedian, yMin)
        return ZStack(alignment: .topLeading) {
            tick(values.max(), y: yMax)
            if showMedian {
                tick(stats.medianMs, y: yMedian)
            }
            tick(values.min(), y: yMin)
        }
        .frame(width: axisWidth, height: plotHeight, alignment: .topLeading)
        .clipped()
    }

    private func tick(_ value: Double?, y: CGFloat?) -> some View {
        let half = labelHeight / 2
        let center = min(max(y ?? half, half), plotHeight - half)
        return Text(value.map { "\(Int($0.rounded()))" } ?? "")
            .font(Typo.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: axisWidth, height: labelHeight, alignment: .trailing)
            .offset(y: center - half)
    }

    /// Подпись медианы скрываем, если она слишком близко к min или max.
    private func isApart(_ a: CGFloat?, _ b: CGFloat?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) > labelHeight + 2
    }

    private func nearestPoint(to date: Date) -> HistoryPoint? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func timeText(_ date: Date) -> String {
        if range == .hour {
            return date.formatted(date: .omitted, time: .standard)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
