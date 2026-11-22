import AppKit
import Combine
import SwiftUI

private let probes = [
    URL(string: "https://cp.cloudflare.com/generate_204")!,
    URL(string: "https://www.gstatic.com/generate_204")!
]

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct Sample: Identifiable {
    let id = UUID()
    let date: Date
    let milliseconds: Int?

    var online: Bool { milliseconds != nil }
}

@MainActor
private final class Monitor: ObservableObject {
    @Published private(set) var samples: [Sample] = []
    var latest: Sample? { samples.last }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.9
        config.timeoutIntervalForResource = 0.9
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?

    func start() {
        tick()
        scheduleTimer(seconds: Settings.shared.checkIntervalSeconds)
        // Смена интервала в настройках перезапускает таймер (значение берём из замыкания: @Published отдаёт его до записи).
        settingsObserver = Settings.shared.$checkIntervalSeconds
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] seconds in self?.scheduleTimer(seconds: seconds) }
    }

    private func scheduleTimer(seconds: Int) {
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard pending == nil else { return }
        pending = Task {
            let result = await withTaskGroup(of: Int?.self, returning: Int?.self) { group in
                for url in probes {
                    group.addTask { [session] in
                        let started = ProcessInfo.processInfo.systemUptime
                        var request = URLRequest(url: url)
                        request.httpMethod = "HEAD"
                        guard let (_, response) = try? await session.data(for: request),
                              (response as? HTTPURLResponse)?.statusCode == 204 else { return nil }
                        return max(1, Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))
                    }
                }
                for await value in group {
                    if let value {
                        group.cancelAll()
                        return value
                    }
                }
                return nil
            }
            let date = Date.now
            samples = Array((samples + [Sample(date: date, milliseconds: result)]).suffix(30))
            HistoryStore.shared.append(date: date, milliseconds: result)
            Notifier.shared.observeCheck(online: result != nil, at: date)
            pending = nil
        }
    }
}

private func status(_ sample: Sample?) -> String {
    guard let sample else { return "Проверяем…" }
    return sample.online ? "Интернет есть" : "Нет ответа"
}

private func symbol(_ sample: Sample?) -> String {
    guard let sample else { return "ellipsis" }
    return sample.online ? "checkmark.circle.fill" : "xmark.circle.fill"
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            window.performDrag(with: event)
            window.saveFrame(usingName: "NetPulseDesktopCard")
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

private struct Card: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var diagnostics: DiagnosticsModel
    @ObservedObject var updater: Updater
    var menu = false
    var widgetVisible = true
    let toggleWidget: () -> Void
    let diagnose: () -> Void
    let quit: () -> Void
    private let mint = Color(red: 0.39, green: 0.95, blue: 0.73)
    private let coral = Color(red: 1, green: 0.53, blue: 0.56)

    private var accent: Color {
        guard let sample = monitor.latest else { return .white.opacity(0.55) }
        return sample.online ? mint : coral
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack {
                    Label("Сетеметр", systemImage: "waveform.path")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                }
                .frame(height: 22)
                .overlay {
                    if !menu { WindowDragArea() }
                }
                if !menu {
                    Button(action: toggleWidget) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Скрыть виджет")
                    .accessibilityLabel("Скрыть виджет")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: symbol(monitor.latest))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(status(monitor.latest))
                    .font(.system(size: 21, weight: .semibold))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Последние 30 проверок")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.60))
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<max(0, 30 - monitor.samples.count), id: \.self) { _ in
                        Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                    }
                    ForEach(monitor.samples) { sample in
                        let height: CGFloat = sample.milliseconds.map { milliseconds in
                            min(24.0, 7.0 + CGFloat(milliseconds) / 18.0)
                        } ?? 5.0
                        Capsule().fill(sample.online ? mint : coral).frame(height: height)
                    }
                }
                .frame(height: 24, alignment: .bottom)
                .accessibilityLabel("История проверок")
                .accessibilityValue("Успешных \(monitor.samples.filter(\.online).count) из \(monitor.samples.count)")
            }
            HStack {
                Text(monitor.latest.map { $0.date.formatted(date: .omitted, time: .standard) } ?? "—")
                    .foregroundStyle(.white.opacity(0.62))
                    .accessibilityLabel("Время последней проверки")
                Spacer()
                Text(monitor.latest?.milliseconds.map { "\($0) мс" } ?? "— мс")
                    .foregroundStyle(accent)
                    .help("Время ответа HTTPS")
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            Divider().overlay(.white.opacity(0.10))
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Label("Скачивание", systemImage: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.70))
                    Spacer(minLength: 0)
                    Text(speedSummary)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(mint)
                    Button(action: diagnostics.testSpeed) {
                        Image(systemName: diagnostics.speedBusy ? "arrow.clockwise" : "speedometer")
                    }
                    .controlSize(.small)
                    .disabled(diagnostics.busy || diagnostics.speedBusy)
                    .help(speedHelp)
                    .accessibilityLabel("Измерить среднюю скорость")
                }
                summary("Внешний IPv4", diagnostics.value("Внешний IPv4"))
                summary("Внешний IPv6", diagnostics.value("Внешний IPv6"))
                summary("Локальный IPv4", localIPv4)
                summary("Маршрут", routeSummary)
                summary("Шлюз", gatewaySummary)
                summary("DNS / прокси", dnsSummary)
                summary("Проверки", diagnostics.httpsSummary)
            }
            .help(diagnostics.checked.map { "Проверено в \($0.formatted(date: .omitted, time: .standard))" }
                  ?? "Проверяем подключение…")
            if menu {
                Button(action: updater.performPrimaryAction) {
                    Label(updateTitle, systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
                .disabled(updater.isBusy)
            }
            HStack {
                Button(action: diagnose) {
                    Label("Диагностика", systemImage: "network")
                }
                Spacer(minLength: 0)
                if menu {
                    Button(widgetVisible ? "Скрыть виджет" : "Показать виджет", action: toggleWidget)
                    Button("Выход", action: quit).keyboardShortcut("q")
                }
            }
            .controlSize(.small)
        }
        .padding(17)
        .frame(width: 316)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.20),
                                              Color(red: 0.05, green: 0.08, blue: 0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20).strokeBorder(accent.opacity(0.27), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
    private var updateTitle: String {
        switch updater.state {
        case .idle: return "Проверить обновления"
        case .checking: return "Проверяем обновления…"
        case .available(let version, _): return "Доступна версия \(version) — Обновить"
        case .downloading: return "Загружаем обновление…"
        case .upToDate: return "Установлена последняя версия"
        case .failed(let message): return "Ошибка обновления: \(message)"
        }
    }

    private var speedSummary: String {
        if let value = diagnostics.formattedSpeed { return "\(value) \(diagnostics.speedUnitTitle)" }
        if diagnostics.speedBusy { return "Замер…" }
        return diagnostics.speedFailed ? "Нет замера" : "— \(diagnostics.speedUnitTitle)"
    }

    private var speedHelp: String {
        if diagnostics.speedBusy { return "Идёт замер скорости" }
        if diagnostics.speedFailed { return "Последний замер не завершился. Нажмите, чтобы повторить." }
        if let date = diagnostics.speedDate {
            return "Последний замер: \(date.formatted(date: .abbreviated, time: .shortened)). Нажмите, чтобы повторить."
        }
        return "Измерить среднюю скорость · 3 загрузки по 5 МБ"
    }

    private var localIPv4: String? {
        if let wifi = diagnostics.value("IPv4 Wi‑Fi"), wifi != "—" { return wifi }
        return diagnostics.value("IPv4 на основном интерфейсе")
    }

    private var gatewaySummary: String? {
        guard let address = diagnostics.value("Шлюз Wi‑Fi") ?? diagnostics.value("Шлюз") else { return nil }
        guard let ping = diagnostics.value("Пинг шлюза"), ping.hasSuffix(" мс") else { return address }
        return "\(address) · \(ping)"
    }

    private var dnsSummary: String? {
        guard let dns = diagnostics.value("DNS-серверы macOS"),
              let proxy = diagnostics.value("Системный прокси") else { return nil }
        return "\(dns) · \(proxy == "Выключен" ? "выкл." : proxy)"
    }

    private var routeSummary: String? {
        guard let interface = diagnostics.value("Маршрут по умолчанию") else { return nil }
        guard let vpn = diagnostics.value("VPN macOS"), vpn != "Нет активного профиля" else { return interface }
        return "\(vpn) · \(interface)"
    }

    private func summary(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.60))
            Spacer(minLength: 6)
            Text(value ?? "—")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
    }

}

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private let diagnostics = DiagnosticsModel()
    private let updater = Updater()
    private var menuPanel: MenuPanel?
    private var diagnosticsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var openSettingsObserver: Any?
    private var outsideClick: Any?
    private var localEvents: Any?
    private var item: NSStatusItem!
    private var widget: NSPanel!
    private var observation: Any?
    private var diagnosticsTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(showMenu)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let content = NSHostingView(rootView: card())
        let size = content.fittingSize
        widget = NSPanel(contentRect: NSRect(x: screen.maxX - size.width - 24,
                                              y: screen.maxY - size.height - 24,
                                              width: size.width, height: size.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        widget.title = "Сетеметр"
        widget.isOpaque = false
        widget.backgroundColor = .clear
        widget.hasShadow = true
        widget.isMovable = true
        widget.isFloatingPanel = false
        widget.level = .normal
        widget.hidesOnDeactivate = false
        widget.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        content.sizingOptions = []
        widget.contentView = content
        widget.setFrameAutosaveName("NetPulseDesktopCard")
        let previousFrame = widget.frame
        let visible = widget.screen?.visibleFrame ?? screen
        let origin = NSPoint(x: min(max(previousFrame.maxX - size.width, visible.minX), visible.maxX - size.width),
                             y: min(max(previousFrame.maxY - size.height, visible.minY), visible.maxY - size.height))
        widget.setFrame(NSRect(origin: origin, size: size), display: false)
        widget.contentMinSize = size
        if UserDefaults.standard.object(forKey: "showDesktopCard") as? Bool ?? true {
            widget.orderBack(nil)
        }

        observation = monitor.$samples.sink { [weak self] samples in
            self?.updateMenuBar(samples.last)
        }
        monitor.start()
        diagnostics.start()
        updater.start()
        let timer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.diagnostics.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer

        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: .setemeterOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.shared.flush()
    }

    private func updateMenuBar(_ sample: Sample?) {
        let description = status(sample)
        let image = NSImage(systemSymbolName: symbol(sample), accessibilityDescription: description)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Сетеметр · \(description)"
        item.button?.setAccessibilityLabel("Сетеметр, \(description)")
    }

    private func card(menu: Bool = false, widgetVisible: Bool = true) -> Card {
        Card(monitor: monitor, diagnostics: diagnostics, updater: updater, menu: menu, widgetVisible: widgetVisible,
             toggleWidget: { [weak self] in self?.toggleWidget() },
             diagnose: { [weak self] in self?.showDiagnostics() },
             quit: { NSApp.terminate(nil) })
    }

    @objc private func showMenu() {
        if menuPanel != nil {
            closeMenu()
            return
        }
        guard let button = item.button, let host = button.window,
              let screen = host.screen ?? NSScreen.main else { return }

        let content = NSHostingView(rootView: card(menu: true, widgetVisible: widget.isVisible))
        let size = content.fittingSize
        let anchor = host.convertToScreen(button.convert(button.bounds, to: nil))
        let safe = screen.visibleFrame.insetBy(dx: 8, dy: 0)
        let x = min(max(anchor.midX - size.width / 2, safe.minX), safe.maxX - size.width)
        let y = min(anchor.minY, safe.maxY) - size.height - 6
        let panel = MenuPanel(contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = content
        menuPanel = panel
        panel.makeKeyAndOrderFront(nil)

        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            if !anchor.contains(NSEvent.mouseLocation) {
                self?.closeMenu()
            }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                closeMenu()
                return nil
            }
            if event.window !== menuPanel && event.window !== item.button?.window {
                closeMenu()
            }
            return event
        }
    }

    private func closeMenu() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        outsideClick = nil
        localEvents = nil
        menuPanel?.orderOut(nil)
        menuPanel = nil
    }

    private func showDiagnostics() {
        closeMenu()
        if let diagnosticsWindow, diagnosticsWindow.isVisible {
            diagnosticsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 880
        let height = max(450, min(790, screenHeight - 60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: height),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Сетеметр"
        window.isReleasedWhenClosed = false
        diagnostics.refresh()
        let content = NSHostingView(rootView: DiagnosticsView(model: diagnostics))
        content.sizingOptions = []
        window.contentView = content
        window.contentMinSize = NSSize(width: 550, height: 450)
        window.center()
        diagnosticsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        closeMenu()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Настройки"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func toggleWidget() {
        let show = !widget.isVisible
        if show {
            widget.orderFrontRegardless()
        } else {
            widget.orderOut(nil)
        }
        UserDefaults.standard.set(show, forKey: "showDesktopCard")
        closeMenu()
    }
}

@main
struct Setemeter {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
