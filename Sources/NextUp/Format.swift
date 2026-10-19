import Foundation

enum Format {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static func timeRange(_ meeting: Meeting) -> String {
        "\(time.string(from: meeting.start)) – \(time.string(from: meeting.end))"
    }

    /// Whole minutes until `date`, rounded up so "in 1 min" lasts until the start.
    static func minutes(until date: Date, from now: Date) -> Int {
        Int((date.timeIntervalSince(now) / 60).rounded(.up))
    }

    static func countdown(_ meeting: Meeting, now: Date) -> String {
        if meeting.start <= now {
            return "Now · \(max(1, minutes(until: meeting.end, from: now))) min left"
        }
        let total = minutes(until: meeting.start, from: now)
        if total < 60 { return "In \(total) min" }
        if Calendar.current.isDateInTomorrow(meeting.start) { return "Tomorrow" }
        let hours = total / 60, rest = total % 60
        return rest == 0 ? "In \(hours) h" : "In \(hours) h \(rest) min"
    }

    /// A time for todos due today, "Yesterday" or "Tomorrow" next to it, otherwise a short date.
    static func due(_ todo: Todo, now: Date) -> String {
        guard let due = todo.due else { return "" }
        let calendar = Calendar.current
        if calendar.isDate(due, inSameDayAs: now) { return todo.dueHasTime ? time.string(from: due) : "Today" }
        if calendar.isDateInYesterday(due) { return "Yesterday" }
        if calendar.isDateInTomorrow(due) { return "Tomorrow" }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    /// Meeting title shortened to fit beside the other menu bar icons.
    static func menuBarTitle(_ title: String, limit: Int = 18) -> String {
        guard title.count > limit else { return title }
        return title.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One or two initials for the avatar beside a Slack notification.
    static func initials(_ title: String) -> String {
        if title.hasPrefix("#") { return "#" }
        let words = title.split(whereSeparator: { !$0.isLetter })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
}
