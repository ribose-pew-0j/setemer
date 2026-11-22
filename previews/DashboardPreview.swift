import AppKit
import SwiftUI

@main
struct DashboardPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .aqua)
        let date = Date.now
        let monitor = Monitor()
        let diagnostics = DiagnosticsModel()
        diagnostics.setPreviewValues(date: date)
        for index in 0...180 {
            let ms = 82 + Int(6 * sin(Double(index) * 0.25)) + (index % 47 == 9 ? 26 : 0)
            HistoryStore.shared.append(date: date.addingTimeInterval(Double(index - 180) * 5), milliseconds: ms)
            if index == 180 { monitor.setPreviewSample(date: date, milliseconds: ms) }
        }

        let panel = DashboardView(monitor: monitor, diagnostics: diagnostics, updater: Updater(),
                                  widgetVisible: true, toggleWidget: {}, diagnose: {}, quit: {}, close: {})
            .environment(\.locale, Locale(identifier: "ru_RU"))
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: "build/panel.png"))
    }
}
