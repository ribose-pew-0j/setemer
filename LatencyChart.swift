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

/// Рисование сетки, медианы, заливки, линии и провалов.
func drawLatency(_ context: inout GraphicsContext, size: CGSize, layout: LatencyLayout,
                 medianY: CGFloat?, theme: Theme) {
    for fraction in [0.0, 0.5, 1.0] {
        var grid = Path()
        let y = (size.height - 1) * CGFloat(fraction) + 0.5
        grid.move(to: CGPoint(x: 0, y: y))
        grid.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(grid, with: .color(theme.grid), lineWidth: 1)
    }
    if let medianY {
        var median = Path()
        median.move(to: CGPoint(x: 0, y: medianY))
        median.addLine(to: CGPoint(x: size.width, y: medianY))
        context.stroke(median, with: .color(Color.secondary.opacity(0.7)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
            Gradient(colors: [theme.mint.opacity(0.30), theme.mint.opacity(0)]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height))
        context.fill(area, with: fill)
        context.stroke(path, with: .color(theme.mint),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }
    for failure in layout.failures {
        let dot = Path(ellipseIn: CGRect(x: failure.x - 2.5, y: failure.y - 2.5, width: 5, height: 5))
        context.fill(dot, with: .color(theme.coral))
    }
}

/// График задержки за выбранный период: линия с градиентной заливкой, сетка, подписи min/median/max,
/// провалы («нет ответа») коралловыми точками, подсказка при наведении или протягивании.
struct LatencyChart: View {
    let points: [HistoryPoint]
    let range: HistoryRange
    let stats: HistoryStats
    let theme: Theme
    let threshold: Int
    @State var hover: CGPoint? = nil

    let axisWidth: CGFloat = 36
    let plotHeight: CGFloat = 128

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
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
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
            .padding(.leading, axisWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("График задержки")
        .accessibilityValue(accessibilitySummary)
    }

    private func plot(size: CGSize, scale: LatencyScale) -> some View {
        let layout = latencyLayout(points: points, scale: scale, width: size.width, height: size.height)
        let medianY: CGFloat? = stats.medianMs.map { scale.y($0, height: size.height) }
        return ZStack(alignment: .topLeading) {
            Canvas { context, canvasSize in
                drawLatency(&context, size: canvasSize, layout: layout, medianY: medianY, theme: theme)
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
        let tipX = min(max(x, 64), size.width - 64)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(theme.grid)
                .frame(width: 1, height: size.height)
                .position(x: x, y: size.height / 2)
            Circle()
                .fill(markerColor)
                .frame(width: 8, height: 8)
                .position(x: x, y: y)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Typo.display(12))
                    .foregroundStyle(markerColor)
                Text(timeText(point.date))
                    .font(Typo.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.tooltip)
            }
            .position(x: tipX, y: 18)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

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
        .frame(width: axisWidth, height: plotHeight)
    }

    private func tick(_ value: Double?, y: CGFloat?) -> some View {
        let position = min(max(y ?? 0, 6), plotHeight - 6)
        return Text(value.map { "\(Int($0.rounded()))" } ?? "")
            .font(Typo.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: axisWidth - 6, alignment: .trailing)
            .offset(y: position - 6)
    }

    /// Подпись медианы скрываем, если она слишком близко к min или max.
    private func isApart(_ a: CGFloat?, _ b: CGFloat?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) > 12
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
