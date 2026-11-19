import AppKit
import EventKit
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    /// The menu bar starts counting down once the next meeting is this close.
    static let countdownWindow: TimeInterval = 60 * 60
    /// A meeting stays in the menu bar for this long after it starts.
    static let justStartedGrace: TimeInterval = 5 * 60
    /// Slack and Teams notifications older than this drop off the list.
    static let messageWindow: TimeInterval = 24 * 3600
    /// Slack notifications NextUp never shows or counts. Add a line to mute another channel or sender.
    static let mutedSlack: [SlackMute] = [
        .channelsStarting(with: "#technical-dribble"), // also #technical-dribble-prod
        .channel("#github-notifications"),
        .channel("#azure-deployments"),
        .sender("GitHub"), // the GitHub app, in any channel or DM
    ]

    @Published private(set) var now = Date()
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var calendarAccess: CalendarAccess
    @Published private(set) var inboxStatus: InboxStatus = .loading
    /// Slack and Teams messages still in the list, newest first.
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var unseenCount = 0
    /// Items newer than this get the "new" dot while the popover is open.
    @Published private(set) var highlightSince = Date.distantFuture
    @Published private(set) var todos: [Todo] = []
    @Published private(set) var todoAccess: CalendarAccess
    @Published private(set) var todoError: String?
    /// Todos just marked done, kept for a few seconds so the popover can offer Undo.
    @Published private(set) var recentlyCompleted: [Todo] = []
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var closePopover: () -> Void = {}

    private let calendar = CalendarStore()
    private let reminders = MeetingReminders()
    private let todoStore = TodoStore()
    private var undoExpiry: Task<Void, Never>?
    private var fetchedMessages: [ChatMessage] = []
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
    private func clearedBefore(_ app: ChatApp) -> Date {
        Date(timeIntervalSinceReferenceDate: defaults.double(forKey: Self.clearedKey(app)))
    }
    private func setClearedBefore(_ date: Date, for app: ChatApp) {
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: Self.clearedKey(app))
    }
    // Slack keeps the key it had before Teams arrived, so an earlier Clear still holds.
    private static func clearedKey(_ app: ChatApp) -> String {
        app == .slack ? "clearedBefore" : "clearedBefore.\(app.rawValue)"
    }
    private var todoOrder: [String] {
        get { defaults.stringArray(forKey: "todoOrder") ?? [] }
        set { defaults.set(newValue, forKey: "todoOrder") }
    }
    private var dismissed: Set<Int> {
        get { Set(defaults.array(forKey: "dismissed") as? [Int] ?? []) }
        set { defaults.set(Array(newValue), forKey: "dismissed") }
    }

    init() {
        calendarAccess = calendar.access
        todoAccess = todoStore.access
        // First launch: count only what arrives from now on, not the last day of history.
        if defaults.object(forKey: "lastSeen") == nil { lastSeen = Date() }
    }

    func start() {
        reminders.activate()
        repeatEvery(5) { $0.pollMessages() }
        repeatEvery(15) { $0.tick() }
        repeatEvery(300) {
            $0.reloadCalendar()
            $0.reloadTodos()
        }
        observe(.EKEventStoreChanged, on: .default) {
            $0.reloadCalendar()
            $0.reloadTodos()
        }
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter) {
            $0.tick()
            $0.reloadCalendar()
            $0.reloadTodos()
        }
        pollMessages(force: true)
        if calendarAccess == .notDetermined { requestCalendarAccess() } else { reloadCalendar() }
        // Reminders access is asked from the popover, so it doesn't stack on the calendar prompt at launch.
        reloadTodos()
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
        recomputeMessages()
    }

    func messages(from app: ChatApp) -> [ChatMessage] {
        messages.filter { $0.app == app }
    }

    func pollMessages(force: Bool = false) {
        let modified = NotificationStore.lastModified()
        if !force, inboxStatus == .ok, let modified, modified == storeModified { return }

        // Fetch extra rows so muted channels can't crowd real messages out of the list.
        switch NotificationStore.fetchMessages(since: Date().addingTimeInterval(-Self.messageWindow), limit: 200) {
        case .success(let items):
            fetchedMessages = items.filter { item in !Self.mutedSlack.contains { $0.matches(item) } }
            storeModified = modified
            inboxStatus = .ok
        case .failure(.noAccess):
            fetchedMessages = []
            inboxStatus = .needsFullDiskAccess
        case .failure(.sqlite(let message)):
            inboxStatus = .error(message)
        }
        recomputeMessages()
    }

    private func recomputeMessages() {
        if popoverOpen { lastSeen = Date() }
        let hidden = dismissed
        let window = now.addingTimeInterval(-Self.messageWindow)
        let cutoffs = Dictionary(uniqueKeysWithValues: ChatApp.allCases.map { ($0, max(window, clearedBefore($0))) })
        let visible = fetchedMessages.filter { $0.date > cutoffs[$0.app]! && !hidden.contains($0.id) }
        if visible != messages { messages = visible }

        let unseen = visible.filter { $0.date > lastSeen }.count
        if unseen != unseenCount { unseenCount = unseen }

        // Forget dismissals for records macOS has already purged.
        if inboxStatus == .ok {
            let live = Set(fetchedMessages.map(\.id))
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

    func reloadTodos() {
        todoAccess = todoStore.access
        guard todoAccess == .granted else {
            todos = []
            return
        }
        Task {
            do {
                let fetched = TodoOrder.apply(todoOrder, to: try await todoStore.todos())
                if fetched != todos { todos = fetched }
                todoError = nil
            } catch {
                todoError = error.localizedDescription
            }
        }
    }

    // MARK: Actions

    func popoverWillShow() {
        highlightSince = lastSeen
        popoverOpen = true
        tick()
        pollMessages(force: true)
        reloadTodos()
    }

    func popoverDidClose() {
        popoverOpen = false
        highlightSince = .distantFuture
        recomputeMessages()
    }

    func open(_ item: ChatMessage) {
        dismissed.insert(item.id)
        recomputeMessages()
        closePopover()
        item.app.open(item.link)
    }

    func clear(_ app: ChatApp) {
        setClearedBefore(Date(), for: app)
        recomputeMessages()
    }

    func openApp(_ app: ChatApp) {
        closePopover()
        app.open(nil)
    }

    func open(_ meeting: Meeting) {
        closePopover()
        if let url = meeting.destination { NSWorkspace.shared.open(url) }
    }

    func showInCalendar(_ meeting: Meeting) {
        closePopover()
        if let url = meeting.calendarURL { NSWorkspace.shared.open(url) }
    }

    func complete(_ items: [Todo]) {
        guard !items.isEmpty else { return }
        do {
            try todoStore.setCompleted(items.map(\.id), true)
        } catch {
            todoError = error.localizedDescription
            return
        }
        let ids = Set(items.map(\.id))
        todos.removeAll { ids.contains($0.id) }
        recentlyCompleted = items
        undoExpiry?.cancel()
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.recentlyCompleted = [] }
        }
        reloadTodos()
    }

    /// Moves a todo into another's slot: below it when dragged down, above it when dragged up.
    func moveTodo(_ id: String, to targetID: String) {
        guard id != targetID,
              let from = todos.firstIndex(where: { $0.id == id }),
              let to = todos.firstIndex(where: { $0.id == targetID }) else { return }
        todos.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        todoOrder = todos.map(\.id)
    }

    func moveTodoToEnd(_ id: String, top: Bool) {
        guard let from = todos.firstIndex(where: { $0.id == id }) else { return }
        todos.move(fromOffsets: [from], toOffset: top ? 0 : todos.count)
        todoOrder = todos.map(\.id)
    }

    func completeAllTodos() {
        complete(todos)
    }

    func undoComplete() {
        undoExpiry?.cancel()
        let items = recentlyCompleted
        recentlyCompleted = []
        do {
            try todoStore.setCompleted(items.map(\.id), false)
        } catch {
            todoError = error.localizedDescription
        }
        reloadTodos()
    }

    func addTodo(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try todoStore.add(title)
        } catch {
            todoError = error.localizedDescription
        }
        reloadTodos()
    }

    /// Turns a Slack or Teams notification into a todo that links back to its chat.
    func addTodo(from item: ChatMessage) {
        let sender = item.subtitle.isEmpty ? item.title : "\(item.subtitle) in \(item.title)"
        let body = item.body.split(whereSeparator: \.isNewline).joined(separator: " ")
        let title = body.isEmpty ? "Reply to \(sender)" : "\(sender): \(Format.menuBarTitle(body, limit: 80))"
        do {
            try todoStore.add(title, notes: item.body.isEmpty ? nil : item.body, url: item.link)
        } catch {
            todoError = error.localizedDescription
        }
        reloadTodos()
    }

    /// Opens the chat the todo came from, otherwise Reminders.
    func open(_ todo: Todo) {
        closePopover()
        if let url = todo.url {
            if let app = ChatApp(link: url) { app.open(url) } else { NSWorkspace.shared.open(url) }
            return
        }
        TodoStore.openRemindersApp()
    }

    func openReminders() {
        closePopover()
        TodoStore.openRemindersApp()
    }

    func requestTodoAccess() {
        if todoAccess == .denied {
            openPrivacySettings("Privacy_Reminders")
            return
        }
        Task {
            _ = await todoStore.requestAccess()
            reloadTodos()
        }
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
        state.todoAccess = .granted
        state.todos = [
            Todo(id: "t1", title: "Send the release notes", due: now.addingTimeInterval(-26 * 3600), dueHasTime: false),
            Todo(id: "t2", title: "Review the onboarding PR", due: now.addingTimeInterval(3 * 3600), dueHasTime: true),
            Todo(id: "t3", title: "Book flights for the offsite", due: nil, dueHasTime: false),
            Todo(id: "t4", title: "Renew the domain", due: now.addingTimeInterval(5 * 86_400), dueHasTime: false),
        ]
        func message(_ id: Int, _ app: ChatApp, _ minutesAgo: Double, _ title: String, _ subtitle: String, _ body: String) -> ChatMessage {
            ChatMessage(id: id, app: app, date: now.addingTimeInterval(-minutesAgo * minute), title: title, subtitle: subtitle, body: body, link: nil)
        }
        state.inboxStatus = .ok
        state.messages = [
            message(1, .slack, 2, "Alex Rivera", "", "Can you look over the release notes before standup? Want to send them out this morning."),
            message(5, .teams, 4, "Jordan and Priya", "", "Priya: @you can you approve the vendor form today?"),
            message(2, .slack, 9, "#team-updates", "Sam Taylor", "The deploy finished, everything looks good"),
            message(6, .teams, 50, "Chris Lee", "", "Sent you the contract draft"),
            message(3, .slack, 180, "Maya Chen", "", "Thanks! Merged."),
            message(4, .slack, 240, "#design", "Jo Park", "New mocks are up for review"),
        ]
        state.unseenCount = 3
        state.highlightSince = now.addingTimeInterval(-10 * minute)
        return state
    }
}
