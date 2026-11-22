import AppKit
import SwiftUI

/// Смысловой статус значения.
enum Tone: Equatable {
    case good
    case warning
    case bad
    case neutral
}

/// Палитра. Текст, разделители и фоны берутся из семантических цветов системы,
/// поэтому светлая и тёмная темы выглядят правильно автоматически.
/// Статусные акценты приглушены и используются только для статуса и линии графика.
/// В корневом view: `@Environment(\.colorScheme) var colorScheme`, затем `Theme(colorScheme)`.
/// Вложенным view цвета передаются параметром `theme`.
struct Theme {
    let isDark: Bool

    init(_ scheme: ColorScheme) {
        isDark = scheme == .dark
    }

    // MARK: Статусные акценты

    var mint: Color {
        isDark ? Color(red: 0.46, green: 0.85, blue: 0.70) : Color(red: 0.10, green: 0.50, blue: 0.38)
    }

    var amber: Color {
        isDark ? Color(red: 0.95, green: 0.78, blue: 0.45) : Color(red: 0.72, green: 0.50, blue: 0.14)
    }

    var coral: Color {
        isDark ? Color(red: 0.96, green: 0.60, blue: 0.62) : Color(red: 0.78, green: 0.28, blue: 0.31)
    }

    func color(_ tone: Tone) -> Color {
        switch tone {
        case .good: return mint
        case .warning: return amber
        case .bad: return coral
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        }
    }

    // MARK: Нейтральные цвета (семантические)

    /// Тонкий разделитель (применять с низкой opacity).
    var separator: Color { Color(nsColor: .separatorColor) }
    /// Направляющие графика.
    var grid: Color { Color(nsColor: .separatorColor).opacity(0.8) }
    /// Подсветка фона при наведении.
    var hover: Color { Color(nsColor: .labelColor).opacity(0.08) }
    /// Неактивные элементы: полоски сигнала, пустые столбики.
    var track: Color { Color(nsColor: .quaternaryLabelColor) }
    /// Фон группы в стиле inset-списка.
    var group: Color { Color(nsColor: .controlBackgroundColor) }
}

/// Типографика: только системный SF Pro, три размера — 28 (крупный пинг), 13 (основной), 11 (вторичный).
/// Числа выравнивать через `.monospacedDigit()` на view.
enum Typo {
    static let hero = Font.system(size: 28, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let value = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .regular)
}

/// Скругления.
enum Radius {
    static let window: CGFloat = 13
    static let group: CGFloat = 10
    static let control: CGFloat = 6
}

/// Отступы.
enum Spacing {
    static let window: CGFloat = 14
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
