import AppKit
import EventKit

struct Todo: Identifiable, Hashable {
    let id: String
    let title: String
    /// Nil for reminders without a due date.
    let due: Date?
    /// False for all-day due dates, so the row says "Today" rather than midnight.
    let dueHasTime: Bool
    /// Where the todo came from, such as the Slack message it was made from.
    var url: URL? = nil

    func isOverdue(at now: Date) -> Bool {
        guard let due else { return false }
        return dueHasTime ? due < now : due < Calendar.current.startOfDay(for: now)
    }
}

extension Todo {
    init(reminder: EKReminder) {
        let components = reminder.dueDateComponents
        self.init(
            id: reminder.calendarItemIdentifier,
            title: (reminder.title ?? "").isEmpty ? "Untitled" : reminder.title,
            due: components.flatMap { Calendar.current.date(from: $0) },
            dueHasTime: components?.hour != nil,
            url: reminder.url
        )
    }
}

enum TodoError: LocalizedError {
    case noAccount

    var errorDescription: String? { "no Reminders account to hold the \(TodoStore.listName) list" }
}

/// Reads phrases like "tomorrow", "friday 3pm", or "oct 25" into a due date. A phrase without
/// a time gives an all-day due date, the way Reminders shows "Today" rather than noon.
enum DuePhrase {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    static func parse(_ text: String) -> DateComponents? {
        guard let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date else { return nil }
        // timeIsSignificant isn't public API, so check it exists and assume a time when it doesn't.
        let selector = Selector(("timeIsSignificant"))
        let hasTime = match.responds(to: selector) ? (match.value(forKey: "timeIsSignificant") as? Bool ?? true) : true
        let units: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
        return Calendar.current.dateComponents(units, from: date)
    }
}

/// `NextUp --add <title> [when]`, run by scripts/todo through `open` so it has NextUp's Reminders grant.
enum TodoCommand {
    static func add(_ arguments: [String]) -> Int32 {
        guard let title = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            print("usage: todo <title> [when]")
            return 64
        }
        let store = TodoStore()
        guard store.access == .granted else {
            print("error: NextUp has no Reminders access. Click Allow in the To do section of the popover.")
            return 1
        }
        let when = arguments.dropFirst().joined(separator: " ")
        var due: DateComponents?
        if !when.isEmpty {
            guard let parsed = DuePhrase.parse(when) else {
                print("error: can't read a date from \"\(when)\". Try \"tomorrow\", \"friday 3pm\", or \"oct 25\".")
                return 1
            }
            due = parsed
        }
        do {
            try store.add(title, due: due)
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        let dueText = due.flatMap { Calendar.current.date(from: $0) }.map { date in
            due?.hour == nil ? date.formatted(date: .abbreviated, time: .omitted) : date.formatted(date: .abbreviated, time: .shortened)
        }
        print("Added \"\(title)\" to \(TodoStore.listName)" + (dueText.map { ", due \($0)" } ?? ""))
        return 0
    }
}

/// Reads and writes a "NextUp" list in Reminders. It lives in the same account as the default
/// list (usually iCloud), so todos also show up on iPhone and through Siri.
final class TodoStore {
    static let listName = "NextUp"

    private var store = EKEventStore()
    private let defaults = UserDefaults.standard

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        // A store made before the grant sees no accounts, so it can't find or create the list until replaced.
        if granted { store = EKEventStore() }
        return granted
    }

    /// Open todos: dated ones soonest first, then undated ones oldest first.
    func todos() async throws -> [Todo] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [try list()])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let sorted = (reminders ?? []).sorted(by: Self.order)
                continuation.resume(returning: sorted.map(Todo.init(reminder:)))
            }
        }
    }

    func add(_ title: String, due: DateComponents? = nil, notes: String? = nil, url: URL? = nil) throws {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.dueDateComponents = due
        reminder.notes = notes
        reminder.url = url
        reminder.calendar = try list()
        try store.save(reminder, commit: true)
    }

    /// Saves every change in one commit, so "mark all done" and its undo are a single write.
    func setCompleted(_ ids: [String], _ completed: Bool) throws {
        do {
            for id in ids {
                guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { continue }
                reminder.isCompleted = completed
                try store.save(reminder, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            throw error
        }
    }

    static func openRemindersApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The NextUp list, created on first use. Remembered by identifier so renaming it in Reminders keeps it linked.
    private func list() throws -> EKCalendar {
        if let id = defaults.string(forKey: "todoListID"), let list = store.calendar(withIdentifier: id) { return list }
        if let list = store.calendars(for: .reminder).first(where: { $0.title == Self.listName }) {
            defaults.set(list.calendarIdentifier, forKey: "todoListID")
            return list
        }
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) else { throw TodoError.noAccount }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listName
        list.cgColor = NSColor.systemIndigo.cgColor
        list.source = source
        try store.saveCalendar(list, commit: true)
        defaults.set(list.calendarIdentifier, forKey: "todoListID")
        return list
    }

    private static func order(_ a: EKReminder, _ b: EKReminder) -> Bool {
        let calendar = Calendar.current
        switch (a.dueDateComponents.flatMap(calendar.date(from:)), b.dueDateComponents.flatMap(calendar.date(from:))) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
        }
    }
}
