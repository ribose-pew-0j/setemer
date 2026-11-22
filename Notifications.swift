import Combine
import Foundation
import UserNotifications

/// Уведомления macOS. Включаются в настройках; не чаще одного уведомления одного типа в минуту.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// true, если система запретила уведомления для приложения.
    @Published private(set) var permissionDenied = false

    private enum Kind: String {
        case offline
        case online
        case ipChanged
        case slowSpeed
    }

    private let minimumGap: TimeInterval = 60
    private let offlineThreshold = 3
    private var lastSent: [Kind: Date] = [:]
    private var failures = 0
    private var isDown = false
    private var outageStart: Date?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Запрос разрешения (вызывается при первом включении уведомлений).
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            permissionDenied = !granted
        } catch {
            Log.notifications.error("Запрос разрешения: \(error.localizedDescription, privacy: .public)")
            permissionDenied = true
        }
    }

    /// Вызывается из Monitor после каждой проверки связи.
    /// «Пропала» — после 3 неудачных проверок подряд; «восстановлена» — с длительностью простоя.
    func observeCheck(online: Bool, at date: Date) {
        if online {
            if isDown {
                let seconds = outageStart.map { Int(date.timeIntervalSince($0)) } ?? 0
                send(.online, title: "Связь восстановлена", body: "Простой \(seconds) с")
            }
            isDown = false
            outageStart = nil
            failures = 0
        } else {
            failures += 1
            if outageStart == nil { outageStart = date }
            if failures >= offlineThreshold && !isDown {
                isDown = true
                send(.offline, title: "Связь пропала", body: "Нет ответа \(offlineThreshold) проверки подряд")
            }
        }
    }

    /// Вызывается из DiagnosticsModel, когда внешний IPv4 изменился.
    func notifyIPChanged(from old: String, to new: String) {
        send(.ipChanged, title: "Внешний IP изменился", body: "\(old) → \(new)")
    }

    /// Вызывается из DiagnosticsModel после замера скорости ниже порога.
    func notifySlowSpeed(mbps: Double, threshold: Int) {
        let value = mbps.formatted(.number.precision(.fractionLength(1)))
        send(.slowSpeed, title: "Скорость ниже порога",
             body: "Скачивание \(value) Мбит/с при пороге \(threshold) Мбит/с")
    }

    private func send(_ kind: Kind, title: String, body: String) {
        guard Settings.shared.notificationsEnabled else { return }
        let now = Date.now
        if let last = lastSent[kind], now.timeIntervalSince(last) < minimumGap { return }
        lastSent[kind] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(kind.rawValue)-\(UUID().uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: Notifier.logAddError)
    }

    nonisolated private static func logAddError(_ error: Error?) {
        guard let error else { return }
        Log.notifications.error("Не удалось показать уведомление: \(error.localizedDescription, privacy: .public)")
    }

    /// Показываем баннеры даже когда приложение активно (у меню-бар приложения это обычное состояние).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
