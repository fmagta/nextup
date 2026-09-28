import AppKit
import EventKit
import SwiftUI

struct Meeting: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let link: MeetingLink?
    let eventIdentifier: String?

    /// Opens the event in Calendar.app.
    var calendarURL: URL? {
        guard let eventIdentifier,
              let encoded = eventIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "ical://ekevent/\(encoded)?method=show&options=more")
    }

    /// Where a click should go: the call if there is one, otherwise the event itself.
    var destination: URL? { link?.launchURL ?? calendarURL }

    func urgency(at now: Date) -> Urgency {
        if start <= now { return .live }
        let minutes = Format.minutes(until: start, from: now)
        return minutes <= 5 ? .imminent : minutes <= 15 ? .soon : .later
    }
}

enum Urgency { case later, soon, imminent, live }

extension Meeting {
    init(event: EKEvent) {
        self.init(
            id: "\(event.calendarItemIdentifier)@\(event.startDate.timeIntervalSince1970)",
            title: (event.title ?? "").isEmpty ? "Untitled" : event.title,
            start: event.startDate,
            end: event.endDate,
            color: Color(nsColor: event.calendar?.color ?? .systemBlue),
            link: MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes]),
            eventIdentifier: event.eventIdentifier
        )
    }
}

enum CalendarAccess { case notDetermined, granted, denied }

/// Reads meetings through EventKit, so any account added to Calendar.app (Google, Exchange, iCloud) works.
final class CalendarStore {
    private let store = EKEventStore()

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Timed events from the start of today through the end of tomorrow, minus declined and cancelled ones.
    func meetings(around now: Date) -> [Meeting] {
        let calendar = Calendar.current
        let from = calendar.startOfDay(for: now)
        guard let to = calendar.date(byAdding: .day, value: 2, to: from) else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
            .map(Meeting.init(event:))
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }
}

/// A video-call link found in an event's URL, location, or notes.
struct MeetingLink: Hashable {
    let service: String
    let url: URL

    private static let patterns: [(service: String, regex: NSRegularExpression)] = [
        ("Google Meet", #"https://meet\.google\.com/[a-z]+-[a-z]+-[a-z]+"#),
        ("Zoom", #"https://(?:[\w-]+\.)?zoom\.us/(?:j|my|w|s)/[^\s<>"')\]]+"#),
        ("Teams", #"https://teams\.microsoft\.com/(?:l/meetup-join|meet)/[^\s<>"')\]]+"#),
        ("Teams", #"https://teams\.live\.com/meet/[^\s<>"')\]]+"#),
        ("Webex", #"https://[\w-]+\.webex\.com/[^\s<>"')\]]+"#),
        ("Slack huddle", #"https://app\.slack\.com/huddle/[^\s<>"')\]]+"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: .caseInsensitive)) }

    static func find(in texts: [String?]) -> MeetingLink? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                if let match = pattern.regex.firstMatch(in: text, range: range),
                   let matchRange = Range(match.range, in: text),
                   let url = URL(string: String(text[matchRange])) {
                    return MeetingLink(service: pattern.service, url: url)
                }
            }
        }
        return nil
    }

    /// Prefers the desktop app's URL scheme so joining skips the browser tab.
    var launchURL: URL {
        switch service {
        case "Zoom": return zoomAppURL ?? url
        case "Teams": return Self.canOpen("msteams://") ? URL(string: "msteams:" + url.absoluteString.dropFirst("https:".count)) ?? url : url
        default: return url
        }
    }

    private var zoomAppURL: URL? {
        guard Self.canOpen("zoommtg://"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "j" else { return nil }
        var app = URLComponents()
        app.scheme = "zoommtg"
        app.host = host
        app.path = "/join"
        app.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[1]))]
        if let password = components.queryItems?.first(where: { $0.name == "pwd" })?.value {
            app.queryItems?.append(URLQueryItem(name: "pwd", value: password))
        }
        return app.url
    }

    private static func canOpen(_ scheme: String) -> Bool {
        URL(string: scheme).flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) } != nil
    }
}
