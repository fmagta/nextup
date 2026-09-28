import AppKit
import SQLite3

/// One Slack banner mirrored from macOS Notification Center.
struct SlackItem: Identifiable, Hashable {
    let id: Int
    let date: Date
    let title: String
    let subtitle: String
    let body: String
    let link: URL?
}

enum SlackStatus: Equatable {
    case loading
    case ok
    case needsFullDiskAccess
    case error(String)
}

enum StoreError: Error {
    case noAccess
    case sqlite(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Reads delivered notifications from usernoted's SQLite store (macOS 15+). The store is
/// private to macOS, so reading it needs Full Disk Access. Opened read-only: usernoted owns it.
enum NotificationStore {
    static let slackBundleID = "com.tinyspeck.slackmacgap"

    static let dbURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")

    /// Newest modification time of the database and its WAL, used to skip reads when nothing changed.
    static func lastModified() -> Date? {
        [dbURL.path, dbURL.path + "-wal"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .max()
    }

    static func fetchSlack(since: Date, limit: Int = 50) -> Result<[SlackItem], StoreError> {
        withDatabase { db in
            var items: [SlackItem] = []
            let sql = """
                SELECT r.rec_id, r.data, COALESCE(r.delivered_date, r.request_date) AS delivered
                FROM record r JOIN app a ON a.app_id = r.app_id
                WHERE lower(a.identifier) = lower(?1) AND delivered > ?2
                ORDER BY delivered DESC
                LIMIT ?3
                """
            try rows(db, sql, bind: { stmt in
                sqlite3_bind_text(stmt, 1, slackBundleID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, since.timeIntervalSinceReferenceDate)
                sqlite3_bind_int(stmt, 3, Int32(limit))
            }) { stmt in
                let id = Int(sqlite3_column_int64(stmt, 0))
                let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
                if let data = blob(stmt, 1), let item = SlackItem(id: id, date: date, record: data) {
                    items.append(item)
                }
            }
            return items
        }
    }

    static func plist(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // MARK: SQLite plumbing

    private static func withDatabase<T>(_ body: (OpaquePointer) throws -> T) -> Result<T, StoreError> {
        // TCC denies the open() itself, which is the one reliable signal that Full Disk Access is missing.
        let fd = Darwin.open(dbURL.path, O_RDONLY)
        guard fd >= 0 else {
            let code = errno
            return .failure(code == EPERM || code == EACCES ? .noAccess : .sqlite(String(cString: strerror(code))))
        }
        Darwin.close(fd)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open notification store"
            sqlite3_close(handle)
            return .failure(.sqlite(message))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        do {
            return .success(try body(db))
        } catch let error as StoreError {
            return .failure(error)
        } catch {
            return .failure(.sqlite("\(error)"))
        }
    }

    private static func rows(
        _ db: OpaquePointer,
        _ sql: String,
        bind: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) -> Void
    ) throws {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let stmt = handle else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row(stmt)
            case SQLITE_DONE: return
            default: throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private static func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    // MARK: Debug dump

    /// Writes the structure of recent Slack records so the parser can be checked against the real
    /// format. Message bodies are redacted and long strings truncated.
    static func dump(to path: String) {
        var out = "NextUp notification store dump, \(Date())\nstore: \(dbURL.path)\n\n"
        let result = withDatabase { db -> String in
            var text = "record columns:"
            try rows(db, "PRAGMA table_info(record)") { stmt in text += " \(Self.text(stmt, 1) ?? "?")" }
            text += "\n\napps:\n"
            try rows(db, "SELECT identifier FROM app ORDER BY identifier") { stmt in
                text += "  \(Self.text(stmt, 0) ?? "?")\n"
            }
            text += "\nrecent Slack records:\n"
            let sql = """
                SELECT r.rec_id, r.data, r.delivered_date, r.presented FROM record r
                JOIN app a ON a.app_id = r.app_id
                WHERE lower(a.identifier) = lower(?1) ORDER BY r.rec_id DESC LIMIT 6
                """
            try rows(db, sql, bind: { sqlite3_bind_text($0, 1, slackBundleID, -1, SQLITE_TRANSIENT) }) { stmt in
                text += "--- rec_id \(sqlite3_column_int64(stmt, 0)) delivered \(sqlite3_column_double(stmt, 2)) presented \(sqlite3_column_int(stmt, 3))\n"
                if let data = blob(stmt, 1), let root = plist(data) {
                    text += describe(root, indent: 1)
                    if let req = root["req"] as? [String: Any], let item = SlackItem(id: 0, date: Date(), record: data) {
                        text += "  => link: \(item.link?.absoluteString ?? "none"), req keys: \(req.keys.sorted())\n"
                    }
                }
            }
            return text
        }
        switch result {
        case .success(let text): out += text
        case .failure(let error): out += "error: \(error)\n"
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func describe(_ value: Any, indent: Int, key: String? = nil) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case let dict as [String: Any]:
            return dict.keys.sorted().map { name in
                let child = dict[name]!
                if child is [String: Any] || child is [Any] || (child as? Data).flatMap(plist) != nil {
                    return "\(pad)\(name):\n" + describe(child, indent: indent + 1, key: name)
                }
                return "\(pad)\(name): \(scalar(child, key: name))\n"
            }.joined()
        case let array as [Any]:
            return array.map { describe($0, indent: indent, key: key) }.joined()
        case let data as Data:
            if let nested = plist(data) { return describe(nested, indent: indent) }
            return "\(pad)<data \(data.count) bytes>\n"
        default:
            return "\(pad)- \(scalar(value, key: key))\n"
        }
    }

    private static func scalar(_ value: Any, key: String?) -> String {
        if key == "body", let text = value as? String { return "<redacted, \(text.count) chars>" }
        if let data = value as? Data { return "<data \(data.count) bytes>" }
        let text = "\(value)"
        return text.count > 70 ? String(text.prefix(70)) + "…" : text
    }
}

extension SlackItem {
    /// Parses a usernoted record: a binary plist whose `req` dictionary carries the banner text
    /// (`titl`, `subt`, `body`) plus identifiers the sender attached.
    init?(id: Int, date: Date, record: Data) {
        guard let root = NotificationStore.plist(record), let request = root["req"] as? [String: Any] else { return nil }
        let title = (request["titl"] as? String) ?? ""
        let body = (request["body"] as? String) ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }
        self.init(
            id: id,
            date: date,
            title: title,
            subtitle: (request["subt"] as? String) ?? "",
            body: body,
            link: SlackLink.resolve(from: request)
        )
    }
}

/// Builds a `slack://` deep link from whatever channel and team IDs the notification carries.
enum SlackLink {
    private static let channelPattern = try! NSRegularExpression(pattern: #"\b[CDG](?=[A-Z0-9]*[0-9])[A-Z0-9]{8,12}\b"#)
    private static let teamPattern = try! NSRegularExpression(pattern: #"\bT(?=[A-Z0-9]*[0-9])[A-Z0-9]{8,12}\b"#)

    static func resolve(from request: [String: Any]) -> URL? {
        var hints: [String] = []
        collect(request, into: &hints)
        let text = hints.joined(separator: " ")
        guard let channel = firstMatch(channelPattern, in: text) else { return nil }
        var components = URLComponents()
        components.scheme = "slack"
        components.host = "channel"
        components.queryItems = [URLQueryItem(name: "id", value: channel)]
        if let team = firstMatch(teamPattern, in: text) {
            components.queryItems?.insert(URLQueryItem(name: "team", value: team), at: 0)
        }
        return components.url
    }

    /// Gathers every string except the human-readable banner text, descending into nested plists.
    private static func collect(_ value: Any, into hints: inout [String], key: String? = nil) {
        switch value {
        case let text as String where !["titl", "subt", "body"].contains(key ?? ""):
            hints.append(text)
        case let dict as [String: Any]:
            for (name, child) in dict { collect(child, into: &hints, key: name) }
        case let array as [Any]:
            for child in array { collect(child, into: &hints) }
        case let data as Data:
            if let nested = NotificationStore.plist(data) { collect(nested, into: &hints) }
        default:
            break
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }
}

enum SlackApp {
    static let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: NotificationStore.slackBundleID)

    static func open(_ link: URL?) {
        if let link, NSWorkspace.shared.open(link) { return }
        if let bundleURL {
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
