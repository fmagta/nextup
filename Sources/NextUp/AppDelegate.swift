import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
            button.font = StatusLabel.font
        }

        let host = NSHostingController(rootView: PopoverView(state: state))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        state.closePopover = { [weak self] in self?.popover.performClose(nil) }

        // objectWillChange fires before the new value lands; hopping to the next run loop pass reads it after.
        subscription = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }

        state.start()
        refreshStatusItem()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        state.popoverWillShow()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        state.popoverDidClose()
    }

    private func refreshStatusItem() {
        guard let button = statusItem.button else { return }
        let label = StatusLabel(state: state)
        let image = NSImage(systemSymbolName: label.symbol, accessibilityDescription: "NextUp")
        image?.isTemplate = true
        button.image = image
        button.toolTip = label.tooltip
        if let attributed = label.attributedTitle {
            button.attributedTitle = attributed
        } else {
            button.title = label.title
        }
    }
}

/// What the menu bar shows: a bell with the unseen Slack count, then the next meeting's countdown.
struct StatusLabel {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    let symbol: String
    let title: String
    let tooltip: String
    /// Set only when the countdown needs color; plain titles keep the system's menu bar text styling.
    let attributedTitle: NSAttributedString?

    @MainActor
    init(state: AppState) {
        let count = state.unseenCount
        symbol = count > 0 ? "bell.badge.fill" : "bell"

        var parts: [String] = []
        var tips: [String] = []
        if count > 0 {
            parts.append(count > 99 ? "99+" : "\(count)")
            tips.append("\(count) new Slack notification\(count == 1 ? "" : "s")")
        }

        var countdown: (text: String, color: NSColor?)?
        if let meeting = state.menuBarMeeting {
            let minutes = Format.minutes(until: meeting.start, from: state.now)
            let time = minutes <= 0 ? "now" : "\(minutes)m"
            let color: NSColor? = switch meeting.urgency(at: state.now) {
            case .live, .imminent: .systemRed
            case .soon: .systemOrange
            case .later: nil
            }
            countdown = (time, color)
            parts.append("\(Format.menuBarTitle(meeting.title)) \(time)")
            tips.append("\(meeting.title) at \(Format.time.string(from: meeting.start))")
        }

        title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        tooltip = tips.isEmpty ? "NextUp: nothing new" : tips.joined(separator: "\n")

        if let countdown, let color = countdown.color {
            let text = NSMutableAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
            let range = (title as NSString).range(of: countdown.text, options: .backwards)
            text.addAttribute(.foregroundColor, value: color, range: range)
            attributedTitle = text
        } else {
            attributedTitle = nil
        }
    }
}
