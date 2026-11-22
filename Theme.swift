import AppKit
import SwiftUI

/// Смысловой статус значения.
enum Tone: Equatable {
    case good
    case warning
    case bad
    case neutral
}

/// Палитра и поверхности. Подбирается по теме оформления.
/// В корневом view: `@Environment(\.colorScheme) var colorScheme`, затем `Theme(colorScheme)`.
/// Вложенным view цвета передаются параметром `theme`.
struct Theme {
    let isDark: Bool

    init(_ scheme: ColorScheme) {
        isDark = scheme == .dark
    }

    // MARK: Статусные цвета

    var mint: Color {
        isDark ? Color(red: 0.39, green: 0.95, blue: 0.73) : Color(red: 0.04, green: 0.56, blue: 0.40)
    }

    var amber: Color {
        isDark ? Color(red: 1.00, green: 0.78, blue: 0.36) : Color(red: 0.80, green: 0.50, blue: 0.00)
    }

    var coral: Color {
        isDark ? Color(red: 1.00, green: 0.53, blue: 0.56) : Color(red: 0.85, green: 0.22, blue: 0.27)
    }

    func color(_ tone: Tone) -> Color {
        switch tone {
        case .good: return mint
        case .warning: return amber
        case .bad: return coral
        case .neutral: return Color.secondary
        }
    }

    // MARK: Поверхности

    var windowFill: LinearGradient {
        let top = isDark ? Color(red: 0.10, green: 0.16, blue: 0.20) : Color(red: 0.98, green: 0.99, blue: 1.00)
        let bottom = isDark ? Color(red: 0.05, green: 0.08, blue: 0.12) : Color(red: 0.90, green: 0.94, blue: 0.96)
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var card: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04) }
    var cardStroke: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08) }
    var track: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.10) }
    var grid: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.07) }
    var chip: Color { isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.06) }
    var tooltip: Color { isDark ? Color.black.opacity(0.75) : Color.white.opacity(0.95) }
}

/// Типографика: SF Rounded для цифр, моноширинные значения для технических строк.
enum Typo {
    static let title = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let label = Font.system(size: 11, weight: .medium)
    static let caption = Font.system(size: 10, weight: .medium)
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)

    static func display(_ size: CGFloat) -> Font {
        Font.system(size: size, weight: .semibold, design: .rounded)
    }
}

/// Скругления.
enum Radius {
    static let window: CGFloat = 18
    static let card: CGFloat = 14
    static let chip: CGFloat = 10
}

/// Отступы.
enum Spacing {
    static let window: CGFloat = 16
    static let card: CGFloat = 12
}

/// Анимация смены состояния. При включённом «Уменьшить движение» анимации нет.
enum Motion {
    static var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Animation.easeInOut(duration: 0.25)
    }
}

/// withAnimation с учётом настройки «Уменьшить движение».
func animateUI(_ changes: () -> Void) {
    withAnimation(Motion.animation) { changes() }
}

// MARK: - Оценка качества

/// Пинг: ≤ порог/2 — хорошо, ≤ порог — средне, выше — плохо.
func pingTone(_ ms: Int, threshold: Int) -> Tone {
    if ms <= threshold / 2 { return .good }
    if ms <= threshold { return .warning }
    return .bad
}

/// Статус последней проверки: нет данных — нейтрально, нет ответа — плохо.
func sampleTone(_ sample: Sample?, threshold: Int) -> Tone {
    guard let sample else { return .neutral }
    guard let milliseconds = sample.milliseconds else { return .bad }
    return pingTone(milliseconds, threshold: threshold)
}

/// Скорость, Мбит/с: ниже порога — плохо, до двойного порога — средне.
func speedTone(_ mbps: Double, threshold: Int) -> Tone {
    if mbps < Double(threshold) { return .bad }
    if mbps < Double(threshold) * 2 { return .warning }
    return .good
}

/// Джиттер, мс.
func jitterTone(_ ms: Double) -> Tone {
    if ms <= 10 { return .good }
    if ms <= 30 { return .warning }
    return .bad
}

/// Потери, %.
func lossTone(_ percent: Double) -> Tone {
    if percent <= 0 { return .good }
    if percent <= 10 { return .warning }
    return .bad
}

/// Уровень Wi‑Fi сигнала в полосках (1…4) по RSSI, дБм.
func signalBarCount(_ rssi: Int) -> Int {
    if rssi >= -60 { return 4 }
    if rssi >= -70 { return 3 }
    if rssi >= -80 { return 2 }
    return 1
}

func signalTone(bars: Int) -> Tone {
    if bars >= 3 { return .good }
    if bars == 2 { return .warning }
    return .bad
}

// MARK: - Форматирование

func msText(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded())) мс" } ?? "—"
}

func percentText(_ value: Double?) -> String {
    value.map { "\($0.formatted(.number.precision(.fractionLength(1))))%" } ?? "—"
}
