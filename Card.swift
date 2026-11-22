import SwiftUI

/// Содержимое окна: виджет на рабочем столе (menu: false) или дашборд меню-панели (menu: true).
@MainActor
struct Card: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var diagnostics: DiagnosticsModel
    @ObservedObject var updater: Updater
    var menu = false
    var widgetVisible = true
    let toggleWidget: () -> Void
    let diagnose: () -> Void
    let quit: () -> Void
    let close: () -> Void

    var body: some View {
        if menu {
            DashboardView(monitor: monitor, diagnostics: diagnostics, updater: updater,
                          widgetVisible: widgetVisible, toggleWidget: toggleWidget,
                          diagnose: diagnose, quit: quit, close: close)
        } else {
            DesktopWidget(monitor: monitor, diagnostics: diagnostics, toggleWidget: toggleWidget)
        }
    }
}

/// Короткие строки сводки сети для виджета (значения берутся из DiagnosticsModel).
extension DiagnosticsModel {
    var speedSummary: String {
        if let value = formattedSpeed { return "\(value) \(speedUnitTitle)" }
        if speedBusy { return "Замер…" }
        return speedFailed ? "Нет замера" : "— \(speedUnitTitle)"
    }

    var speedHelp: String {
        if speedBusy { return "Идёт замер скорости" }
        if speedFailed { return "Последний замер не завершился. Нажмите, чтобы повторить." }
        if let date = speedDate {
            return "Последний замер: \(date.formatted(date: .abbreviated, time: .shortened)). Нажмите, чтобы повторить."
        }
        return "Измерить среднюю скорость · 3 загрузки по 5 МБ"
    }

    var localIPv4: String? {
        if let wifiAddress = value("IPv4 Wi‑Fi"), wifiAddress != "—" { return wifiAddress }
        return value("IPv4 на основном интерфейсе")
    }

    var gatewaySummary: String? {
        guard let address = value("Шлюз Wi‑Fi") ?? value("Шлюз") else { return nil }
        guard let ping = value("Пинг шлюза"), ping.hasSuffix(" мс") else { return address }
        return "\(address) · \(ping)"
    }

    var dnsSummary: String? {
        guard let dns = value("DNS-серверы macOS"),
              let proxy = value("Системный прокси") else { return nil }
        return "\(dns) · \(proxy == "Выключен" ? "выкл." : proxy)"
    }

    var routeSummary: String? {
        guard let interface = value("Маршрут по умолчанию") else { return nil }
        guard let vpn = value("VPN macOS"), vpn != "Нет активного профиля" else { return interface }
        return "\(vpn) · \(interface)"
    }
}
