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

struct Sample: Identifiable {
    let id = UUID()
    let date: Date
    let milliseconds: Int?

    var online: Bool { milliseconds != nil }
}

@MainActor
final class Monitor: ObservableObject {
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

func status(_ sample: Sample?) -> String {
    guard let sample else { return "Проверяем…" }
    return sample.online ? "Интернет есть" : "Нет ответа"
}

func symbol(_ sample: Sample?) -> String {
    guard let sample else { return "ellipsis" }
    return sample.online ? "checkmark.circle.fill" : "xmark.circle.fill"
}

struct WindowDragArea: NSViewRepresentable {
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
    private var menuBarObservation: AnyCancellable?
    private var diagnosticsTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(showMenu)
        item.button?.imagePosition = .imageLeading

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
        // Значение берём из замыкания: @Published отдаёт новое значение до записи в свойство.
        menuBarObservation = Settings.shared.$showPingInMenuBar
            .dropFirst()
            .sink { [weak self] show in
                self?.updateMenuBar(self?.monitor.latest, showPing: show)
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

    private func updateMenuBar(_ sample: Sample?, showPing: Bool? = nil) {
        let description = status(sample)
        let image = NSImage(systemSymbolName: symbol(sample), accessibilityDescription: description)
        image?.isTemplate = true
        item.button?.image = image
        let shouldShowPing = showPing ?? Settings.shared.showPingInMenuBar
        if shouldShowPing {
            // Фиксированная ширина под максимум «999»: иконка не прыгает при смене числа цифр и при «нет».
            item.length = pingItemLength
            item.button?.attributedTitle = menuBarTitle(sample)
        } else {
            item.length = NSStatusItem.variableLength
            item.button?.attributedTitle = NSAttributedString(string: "")
        }
        item.button?.toolTip = "Сетеметр · \(description)"
        item.button?.setAccessibilityLabel("Сетеметр, \(description)")
    }

    /// Моноширинные цифры, чтобы ширина текста не зависела от значения.
    private var pingFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    }

    /// Ширина, которую занимает максимальное значение «999».
    private var pingTextWidth: CGFloat {
        ceil(NSAttributedString(string: "999", attributes: [.font: pingFont]).size().width)
    }

    /// Полная ширина пункта: иконка (≈18 pt) + отступ + текст «999» + поля кнопки.
    private var pingItemLength: CGFloat {
        18 + 4 + pingTextWidth + 8
    }

    /// Короткий пинг рядом с иконкой: «74», а при отсутствии связи «нет».
    /// Текст выровнен по левому краю: справа добавляются пробелы-цифры до ширины «999»,
    /// поэтому группа «иконка + текст» не смещается при смене значения.
    private func menuBarTitle(_ sample: Sample?) -> NSAttributedString {
        let text: String
        if let sample {
            text = sample.milliseconds.map { String($0) } ?? "нет"
        } else {
            text = ""
        }
        let font = pingFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let figureSpace = "\u{2007}"
        let spaceWidth = NSAttributedString(string: figureSpace, attributes: attributes).size().width
        let textWidth = NSAttributedString(string: text, attributes: attributes).size().width
        let padding = spaceWidth > 0 ? max(0, Int(((pingTextWidth - textWidth) / spaceWidth).rounded(.down))) : 0
        return NSAttributedString(string: text + String(repeating: figureSpace, count: padding),
                                  attributes: attributes)
    }

    private func card(menu: Bool = false, widgetVisible: Bool = true) -> Card {
        Card(monitor: monitor, diagnostics: diagnostics, updater: updater, menu: menu, widgetVisible: widgetVisible,
             toggleWidget: { [weak self] in self?.toggleWidget() },
             diagnose: { [weak self] in self?.showDiagnostics() },
             quit: { NSApp.terminate(nil) },
             close: { [weak self] in self?.closeMenu() })
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
