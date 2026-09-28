import AppKit
import EventKit
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    /// The menu bar starts counting down once the next meeting is this close.
    static let countdownWindow: TimeInterval = 60 * 60
    /// A meeting stays in the menu bar for this long after it starts.
    static let justStartedGrace: TimeInterval = 5 * 60
    /// Slack notifications older than this drop off the list.
    static let slackWindow: TimeInterval = 24 * 3600

    @Published private(set) var now = Date()
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var calendarAccess: CalendarAccess
    @Published private(set) var slackStatus: SlackStatus = .loading
    @Published private(set) var slackItems: [SlackItem] = []
    @Published private(set) var unseenCount = 0
    /// Items newer than this get the "new" dot while the popover is open.
    @Published private(set) var highlightSince = Date.distantFuture
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var closePopover: () -> Void = {}

    private let calendar = CalendarStore()
    private let reminders = MeetingReminders()
    private var fetchedSlack: [SlackItem] = []
    private var storeModified: Date?
    private var popoverOpen = false
    private var timers: [Timer] = []
    private var observers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard

    // Read state lives in UserDefaults so the badge survives relaunches.
    private var lastSeen: Date {
        get { Date(timeIntervalSinceReferenceDate: defaults.double(forKey: "lastSeen")) }
        set { defaults.set(newValue.timeIntervalSinceReferenceDate, forKey: "lastSeen") }
    }
    private var clearedBefore: Date {
        get { Date(timeIntervalSinceReferenceDate: defaults.double(forKey: "clearedBefore")) }
        set { defaults.set(newValue.timeIntervalSinceReferenceDate, forKey: "clearedBefore") }
    }
    private var dismissed: Set<Int> {
        get { Set(defaults.array(forKey: "dismissed") as? [Int] ?? []) }
        set { defaults.set(Array(newValue), forKey: "dismissed") }
    }

    init() {
        calendarAccess = calendar.access
        // First launch: count only what arrives from now on, not the last day of history.
        if defaults.object(forKey: "lastSeen") == nil { lastSeen = Date() }
    }

    func start() {
        reminders.activate()
        repeatEvery(5) { $0.pollSlack() }
        repeatEvery(15) { $0.tick() }
        repeatEvery(300) { $0.reloadCalendar() }
        observe(.EKEventStoreChanged, on: .default) { $0.reloadCalendar() }
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter) {
            $0.tick()
            $0.reloadCalendar()
        }
        pollSlack(force: true)
        if calendarAccess == .notDetermined { requestCalendarAccess() } else { reloadCalendar() }
    }

    // MARK: Derived state

    /// Meetings that have not ended yet, soonest first.
    var upcoming: [Meeting] { meetings.filter { $0.end > now } }

    /// The meeting the menu bar counts down to, if one is close enough to matter.
    var menuBarMeeting: Meeting? {
        upcoming.first {
            $0.start > now.addingTimeInterval(-Self.justStartedGrace) && $0.start < now.addingTimeInterval(Self.countdownWindow)
        }
    }

    // MARK: Refresh

    func tick() {
        now = Date()
        recomputeSlack()
    }

    func pollSlack(force: Bool = false) {
        let modified = NotificationStore.lastModified()
        if !force, slackStatus == .ok, let modified, modified == storeModified { return }

        switch NotificationStore.fetchSlack(since: Date().addingTimeInterval(-Self.slackWindow)) {
        case .success(let items):
            fetchedSlack = items
            storeModified = modified
            slackStatus = .ok
        case .failure(.noAccess):
            fetchedSlack = []
            slackStatus = .needsFullDiskAccess
        case .failure(.sqlite(let message)):
            slackStatus = .error(message)
        }
        recomputeSlack()
    }

    private func recomputeSlack() {
        if popoverOpen { lastSeen = Date() }
        let hidden = dismissed
        let cutoff = max(now.addingTimeInterval(-Self.slackWindow), clearedBefore)
        let visible = fetchedSlack.filter { $0.date > cutoff && !hidden.contains($0.id) }
        if visible != slackItems { slackItems = visible }

        let unseen = visible.filter { $0.date > lastSeen }.count
        if unseen != unseenCount { unseenCount = unseen }

        // Forget dismissals for records macOS has already purged.
        if slackStatus == .ok {
            let live = Set(fetchedSlack.map(\.id))
            let pruned = hidden.intersection(live)
            if pruned.count != hidden.count { dismissed = pruned }
        }
    }

    func reloadCalendar() {
        calendarAccess = calendar.access
        guard calendarAccess == .granted else {
            meetings = []
            return
        }
        now = Date()
        meetings = calendar.meetings(around: now)
        reminders.schedule(meetings, now: now)
    }

    // MARK: Actions

    func popoverWillShow() {
        highlightSince = lastSeen
        popoverOpen = true
        tick()
        pollSlack(force: true)
    }

    func popoverDidClose() {
        popoverOpen = false
        highlightSince = .distantFuture
        recomputeSlack()
    }

    func open(_ item: SlackItem) {
        dismissed.insert(item.id)
        recomputeSlack()
        closePopover()
        SlackApp.open(item.link)
    }

    func clearSlack() {
        clearedBefore = Date()
        dismissed = []
        recomputeSlack()
    }

    func openSlack() {
        closePopover()
        SlackApp.open(nil)
    }

    func open(_ meeting: Meeting) {
        closePopover()
        if let url = meeting.destination { NSWorkspace.shared.open(url) }
    }

    func showInCalendar(_ meeting: Meeting) {
        closePopover()
        if let url = meeting.calendarURL { NSWorkspace.shared.open(url) }
    }

    func requestCalendarAccess() {
        if calendarAccess == .denied {
            openPrivacySettings("Privacy_Calendars")
            return
        }
        Task {
            _ = await calendar.requestAccess()
            reloadCalendar()
        }
    }

    func openFullDiskAccessSettings() {
        openPrivacySettings("Privacy_AllFiles")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("NextUp: launch at login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Full Disk Access applies to processes started after the grant, so offer a one-click restart.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func openPrivacySettings(_ anchor: String) {
        closePopover()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Scheduling helpers

    private func repeatEvery(_ seconds: TimeInterval, _ action: @escaping (AppState) -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        timer.tolerance = seconds * 0.2
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, _ action: @escaping (AppState) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        })
    }
}

extension AppState {
    /// Sample data for `--snapshot`, so the popover can be rendered without calendar or disk access.
    static func preview(now: Date = Date()) -> AppState {
        let state = AppState()
        let minute: TimeInterval = 60
        func meeting(_ title: String, in start: TimeInterval, for length: TimeInterval, _ color: NSColor, link: MeetingLink?) -> Meeting {
            Meeting(
                id: title, title: title,
                start: now.addingTimeInterval(start * minute), end: now.addingTimeInterval((start + length) * minute),
                color: .init(nsColor: color), link: link, eventIdentifier: nil
            )
        }
        let meet = MeetingLink(service: "Google Meet", url: URL(string: "https://meet.google.com/abc-defg-hij")!)
        state.now = now
        state.calendarAccess = .granted
        state.meetings = [
            meeting("Sprint planning", in: 12, for: 45, .systemBlue, link: meet),
            meeting("1:1 with Alex", in: 90, for: 30, .systemPurple, link: meet),
            meeting("Design review", in: 180, for: 60, .systemGreen, link: nil),
            meeting("Daily standup", in: 22 * 60, for: 15, .systemBlue, link: meet),
        ]
        state.slackStatus = .ok
        state.slackItems = [
            SlackItem(id: 1, date: now.addingTimeInterval(-2 * minute), title: "Alex Rivera", subtitle: "", body: "Can you look over the release notes before standup? Want to send them out this morning.", link: nil),
            SlackItem(id: 2, date: now.addingTimeInterval(-9 * minute), title: "#team-updates", subtitle: "Sam Taylor", body: "The deploy finished, everything looks good", link: nil),
            SlackItem(id: 3, date: now.addingTimeInterval(-3 * 3600), title: "Maya Chen", subtitle: "", body: "Thanks! Merged.", link: nil),
        ]
        state.unseenCount = 2
        state.highlightSince = now.addingTimeInterval(-10 * minute)
        return state
    }
}
