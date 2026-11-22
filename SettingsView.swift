import SwiftUI

/// Окно «Настройки». Открывается через AppDelegate.openSettings() или Notification.Name.setemeterOpenSettings.
@MainActor
struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        Form {
            Section("Проверки") {
                Picker("Интервал проверки", selection: $settings.checkIntervalSeconds) {
                    ForEach(Settings.checkIntervalOptions, id: \.self) { seconds in
                        Text("\(seconds) с").tag(seconds)
                    }
                }
                Stepper("Медленный ответ от \(settings.slowPingThresholdMs) мс",
                        value: $settings.slowPingThresholdMs, in: 50...2000, step: 10)
            }

            Section("Уведомления") {
                Toggle("Уведомлять о событиях", isOn: $settings.notificationsEnabled)
                if notifier.permissionDenied {
                    Text("Уведомления запрещены. Разрешите их в Системных настройках → Уведомления.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Stepper("Порог скорости: \(settings.speedWarningMbps) Мбит/с",
                        value: $settings.speedWarningMbps, in: 1...1000, step: 1)
            }

            Section("Скорость") {
                Picker("Единицы", selection: $settings.speedUnit) {
                    ForEach(Settings.SpeedUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Система") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }

            Section("История") {
                Button("Экспортировать историю в CSV…") {
                    HistoryStore.shared.exportCSVWithPanel()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
