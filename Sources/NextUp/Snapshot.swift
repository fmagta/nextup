import AppKit
import SwiftUI

/// Renders the popover with sample data to PNGs (light and dark), for checking the layout
/// without calendar or disk access.
@MainActor
enum Snapshot {
    static func render(to basePath: String) {
        _ = NSApplication.shared
        let state = AppState.preview()
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = PopoverView(state: state).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(basePath)-\(suffix).png"))
        }
        print("menu bar title: \"\(StatusLabel(state: state).title)\"")
    }
}
