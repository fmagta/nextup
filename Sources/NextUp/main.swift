import AppKit

let arguments = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// Debug modes. Launch them through `open NextUp.app --args ...` so they run with the app's
// privacy grants (Full Disk Access) rather than the terminal's.
if arguments.contains("--dump") {
    NotificationStore.dump(to: argument(after: "--dump") ?? NSTemporaryDirectory() + "nextup-dump.txt")
    exit(0)
}
// Top-level code runs on the main thread; assumeIsolated lets it touch main-actor types.
MainActor.assumeIsolated {
    if arguments.contains("--snapshot") {
        Snapshot.render(to: argument(after: "--snapshot") ?? NSTemporaryDirectory() + "nextup-snapshot")
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
