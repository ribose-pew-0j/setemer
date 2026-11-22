import Combine
import Foundation
import ServiceManagement

extension Notification.Name {
    /// Пост этого имени открывает окно «Настройки» (AppDelegate подписан на него).
    static let setemeterOpenSettings = Notification.Name("SetemeterOpenSettings")
}

/// Пользовательские настройки (UserDefaults). Используйте `Settings.shared`.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    static let checkIntervalOptions = [1, 2, 5, 10]

    enum SpeedUnit: String, CaseIterable, Identifiable {
        case megabits
        case megabytes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .megabits: return "Мбит/с"
            case .megabytes: return "МБ/с"
            }
        }

        /// Переводит значение из Мбит/с в выбранные единицы.
        func convert(mbps: Double) -> Double {
            switch self {
            case .megabits: return mbps
            case .megabytes: return mbps / 8
            }
        }
    }

    private enum Key {
        static let checkInterval = "settings.checkIntervalSeconds"
        static let notifications = "settings.notificationsEnabled"
        static let slowPing = "settings.slowPingThresholdMs"
        static let speedUnit = "settings.speedUnit"
        static let speedWarning = "settings.speedWarningMbps"
        static let showPingInMenuBar = "settings.showPingInMenuBar"
    }

    private let defaults: UserDefaults

    /// Интервал проверки связи, секунд (1, 2, 5 или 10).
    @Published var checkIntervalSeconds: Int {
        didSet { defaults.set(checkIntervalSeconds, forKey: Key.checkInterval) }
    }

    /// Уведомления о событиях. При первом включении запрашивается разрешение.
    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Key.notifications)
            if notificationsEnabled {
                Task { await Notifier.shared.requestAuthorization() }
            }
        }
    }

    /// Автозапуск при входе. Меняется только через `setLaunchAtLogin(_:)`.
    @Published private(set) var launchAtLogin: Bool

    /// Порог «медленного» пинга, мс.
    @Published var slowPingThresholdMs: Int {
        didSet { defaults.set(slowPingThresholdMs, forKey: Key.slowPing) }
    }

    /// Единицы отображения скорости (значения внутри приложения всегда в Мбит/с).
    @Published var speedUnit: SpeedUnit {
        didSet { defaults.set(speedUnit.rawValue, forKey: Key.speedUnit) }
    }

    /// Порог «скорость ниже», Мбит/с: при более низком замере шлётся уведомление.
    @Published var speedWarningMbps: Int {
        didSet { defaults.set(speedWarningMbps, forKey: Key.speedWarning) }
    }

    /// Показывать текущий пинг рядом с иконкой в строке меню.
    @Published var showPingInMenuBar: Bool {
        didSet { defaults.set(showPingInMenuBar, forKey: Key.showPingInMenuBar) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let interval = defaults.integer(forKey: Key.checkInterval)
        checkIntervalSeconds = Settings.checkIntervalOptions.contains(interval) ? interval : 1
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        slowPingThresholdMs = defaults.object(forKey: Key.slowPing) as? Int ?? 200
        speedUnit = SpeedUnit(rawValue: defaults.string(forKey: Key.speedUnit) ?? "") ?? .megabits
        speedWarningMbps = defaults.object(forKey: Key.speedWarning) as? Int ?? 10
        showPingInMenuBar = defaults.object(forKey: Key.showPingInMenuBar) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Включает или выключает автозапуск через SMAppService (macOS 13+).
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.settings.error("Автозапуск: \(error.localizedDescription, privacy: .public)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
