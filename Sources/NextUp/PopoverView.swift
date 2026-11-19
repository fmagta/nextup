import SwiftUI

/// The macOS 27 SDK makes `@State` a macro whose plugin ships only with Xcode, so a Command Line
/// Tools build can't expand it. An alias reaches the `State` property wrapper directly instead.
typealias ViewState = SwiftUI.State

struct PopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingsSection(state: state)
            Divider()
            TodosSection(state: state)
            Divider()
            MessagesSection(app: .slack, state: state)
            // Teams reads the same store as Slack, so Slack's section carries any permission prompt.
            if state.inboxStatus == .ok {
                Divider()
                MessagesSection(app: .teams, state: state)
            }
            Divider()
            Footer(state: state)
        }
        .frame(width: 360)
    }
}

// MARK: Meetings

private struct MeetingsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Next up")
            switch state.calendarAccess {
            case .granted:
                let upcoming = state.upcoming
                if let first = upcoming.first {
                    FeaturedMeeting(meeting: first, now: state.now, state: state)
                    let rest = Array(upcoming.dropFirst())
                    // The featured meeting counts as one of the visible rows.
                    CappedList(items: Array(rest.enumerated()), id: \.element.id, visible: visibleRows - 1) { index, meeting in
                        let previous = index == 0 ? first : rest[index - 1]
                        VStack(alignment: .leading, spacing: 0) {
                            if !Calendar.current.isDate(meeting.start, inSameDayAs: previous.start) {
                                DayLabel(date: meeting.start)
                            }
                            CompactMeetingRow(meeting: meeting, state: state)
                        }
                    }
                    Spacer().frame(height: 6)
                } else {
                    EmptyRow(symbol: "calendar", text: "No more meetings today or tomorrow")
                }
            case .notDetermined, .denied:
                PermissionRow(
                    symbol: "calendar",
                    message: "Allow calendar access to see your meetings.",
                    detail: state.calendarAccess == .denied
                        ? "Turn on NextUp in Privacy & Security › Calendars."
                        : "Uses the accounts in Calendar.app. Add Google in System Settings › Internet Accounts if it's missing."
                ) {
                    Button(state.calendarAccess == .denied ? "Open Settings" : "Allow") { state.requestCalendarAccess() }
                }
            }
        }
    }
}

private struct FeaturedMeeting: View {
    let meeting: Meeting
    let now: Date
    let state: AppState
    @ViewState private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(Format.timeRange(meeting))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(Format.countdown(meeting, now: now))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(countdownColor)
            }
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(meeting.color).frame(width: 4)
            }
            Spacer(minLength: 8)
            if let link = meeting.link {
                Button { state.open(meeting) } label: {
                    Label("Join", systemImage: "video.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("Join on \(link.service)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0.045)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.open(meeting) }
        .contextMenu { MeetingMenu(meeting: meeting, state: state) }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var countdownColor: Color {
        switch meeting.urgency(at: now) {
        case .live: .green
        case .imminent: .red
        case .soon: .orange
        case .later: .secondary
        }
    }
}

private struct CompactMeetingRow: View {
    let meeting: Meeting
    let state: AppState
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(meeting.color).frame(width: 7, height: 7)
            Text(Format.time.string(from: meeting.start))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(meeting.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if meeting.link != nil {
                Image(systemName: "video")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.open(meeting) }
        .contextMenu { MeetingMenu(meeting: meeting, state: state) }
        .padding(.horizontal, 6)
    }
}

private struct MeetingMenu: View {
    let meeting: Meeting
    let state: AppState

    var body: some View {
        if let link = meeting.link {
            Button("Join on \(link.service)") { state.open(meeting) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
        Button("Show in Calendar") { state.showInCalendar(meeting) }
    }
}

private struct DayLabel: View {
    let date: Date

    var body: some View {
        Text(Calendar.current.isDateInTomorrow(date) ? "Tomorrow" : date.formatted(.dateTime.weekday(.wide)))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

// MARK: Todos

private struct TodosSection: View {
    @ObservedObject var state: AppState
    @ViewState private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "To do", detail: overdueCount > 0 ? "\(overdueCount) overdue" : nil) {
                if state.todoAccess == .granted && !state.todos.isEmpty {
                    Button("Mark all done") { withAnimation { state.completeAllTodos() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            switch state.todoAccess {
            case .granted:
                if let error = state.todoError {
                    EmptyRow(symbol: "exclamationmark.triangle", text: "Can't reach Reminders: \(error)")
                }
                CappedList(items: state.todos, id: \.id) { todo in
                    TodoRow(todo: todo, now: state.now, state: state)
                }
                if !state.recentlyCompleted.isEmpty {
                    UndoRow(count: state.recentlyCompleted.count) { withAnimation { state.undoComplete() } }
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    TextField("Add a todo", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit {
                            state.addTodo(draft)
                            draft = ""
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
            case .notDetermined, .denied:
                PermissionRow(
                    symbol: "checklist",
                    message: "Allow Reminders access to see your todos.",
                    detail: state.todoAccess == .denied
                        ? "Turn on NextUp in Privacy & Security › Reminders."
                        : "NextUp keeps them in a \(TodoStore.listName) list in Reminders, so they sync to your phone."
                ) {
                    Button(state.todoAccess == .denied ? "Open Settings" : "Allow") { state.requestTodoAccess() }
                }
            }
        }
    }

    private var overdueCount: Int {
        state.todos.filter { $0.isOverdue(at: state.now) }.count
    }
}

private struct TodoRow: View {
    let todo: Todo
    let now: Date
    let state: AppState
    @ViewState private var hovering = false
    @ViewState private var checked = false

    private var openLabel: String {
        todo.url.flatMap { ChatApp(link: $0) }.map { "Open in \($0.name)" } ?? "Open Link"
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                checked = true
                // Let the tick show before the row leaves.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation { state.complete([todo]) }
                }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help("Mark done")
            Text(todo.title)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 4)
            if todo.due != nil {
                Text(Format.due(todo, now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(todo.isOverdue(at: now) ? Color.red : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { state.open(todo) }
        .contextMenu {
            Button("Mark Done") { state.complete([todo]) }
            if todo.url != nil { Button(openLabel) { state.open(todo) } }
            Button("Open Reminders") { state.openReminders() }
        }
        .help(todo.url == nil ? "Open in Reminders" : openLabel)
        .padding(.horizontal, 6)
    }
}

private struct UndoRow: View {
    let count: Int
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(count == 1 ? "Marked done" : "\(count) marked done", systemImage: "checkmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Undo", action: undo)
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: Messages

private struct MessagesSection: View {
    let app: ChatApp
    @ObservedObject var state: AppState

    var body: some View {
        let items = state.messages(from: app)
        let newCount = items.filter { $0.date > state.highlightSince }.count
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: app.name, detail: newCount > 0 ? "\(newCount) new" : nil) {
                if !items.isEmpty {
                    Button("Clear") { state.clear(app) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            switch state.inboxStatus {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(12)
            case .needsFullDiskAccess:
                PermissionRow(
                    symbol: "lock.shield",
                    message: "Mirroring \(app.name) needs Full Disk Access.",
                    detail: "NextUp reads macOS's notification list read-only. In Full Disk Access, click +, pick NextUp from ~/Applications, then relaunch."
                ) {
                    Button("Open Settings") { state.openFullDiskAccessSettings() }
                    Button("Relaunch") { state.relaunch() }
                }
            case .error(let message):
                EmptyRow(symbol: "exclamationmark.triangle", text: "Can't read notifications: \(message)")
            case .ok:
                if items.isEmpty {
                    EmptyRow(symbol: "checkmark.circle", text: "All caught up")
                } else {
                    CappedList(items: items, id: \.id) { item in
                        MessageRow(item: item, isNew: item.date > state.highlightSince, now: state.now) {
                            state.open(item)
                        } addTodo: {
                            withAnimation { state.addTodo(from: item) }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

private struct MessageRow: View {
    let item: ChatMessage
    let isNew: Bool
    let now: Date
    let open: () -> Void
    let addTodo: () -> Void
    @ViewState private var hovering = false

    private var openLabel: String {
        item.link == nil ? "Open \(item.app.name)" : "Open in \(item.app.name)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(isNew ? Color.accentColor : .clear)
                .frame(width: 6, height: 6)
                .padding(.top, 10)
            Avatar(title: item.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if hovering {
                        Button(action: addTodo) {
                            Image(systemName: "checklist")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Add to To do")
                    }
                    Text(Format.ago(item.date, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.trailing, 8)
        .padding(.leading, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu {
            Button(openLabel, action: open)
            Button("Add to To do", action: addTodo)
        }
        .help(openLabel)
    }
}

private struct Avatar: View {
    let title: String

    var body: some View {
        // String.hashValue is seeded per launch; a hand-rolled hash keeps each sender's color stable.
        let seed = title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(seed % 360) / 360
        Text(Format.initials(title))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hue: hue, saturation: 0.45, brightness: 0.7)))
    }
}

// MARK: Shared pieces

/// Rows visible in each section before the rest scroll.
private let visibleRows = 3

/// Shows the first `visible` rows and scrolls the rest. The height comes from the rows themselves,
/// so a section with two-line Slack messages and one with one-line todos both show whole rows.
private struct CappedList<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    var visible = visibleRows
    @ViewBuilder let row: (Item) -> Row
    @ViewState private var heights: [ID: CGFloat] = [:]

    var body: some View {
        let scrolls = items.count > visible
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items, id: id) { item in
                    row(item).background(GeometryReader { proxy in
                        Color.clear.preference(key: RowHeights.self, value: [AnyHashable(item[keyPath: id]): proxy.size.height])
                    })
                }
            }
        }
        .scrollDisabled(!scrolls)
        .scrollIndicators(scrolls ? .visible : .hidden)
        .onPreferenceChange(RowHeights.self) { measured in
            heights = Dictionary(uniqueKeysWithValues: measured.compactMap { key, value in (key.base as? ID).map { ($0, value) } })
        }
        .frame(height: height)
    }

    /// The first rows' total height, or nil until they've been measured.
    private var height: CGFloat? {
        let shown = items.prefix(visible).compactMap { heights[$0[keyPath: id]] }
        guard !shown.isEmpty, shown.count == min(visible, items.count) else { return nil }
        return shown.reduce(0, +)
    }
}

private struct RowHeights: PreferenceKey {
    static let defaultValue: [AnyHashable: CGFloat] = [:]
    static func reduce(value: inout [AnyHashable: CGFloat], nextValue: () -> [AnyHashable: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SectionHeader<Accessory: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

private struct EmptyRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
    }
}

private struct PermissionRow<Actions: View>: View {
    let symbol: String
    let message: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack { actions() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

private struct Footer: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Open at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
            Spacer()
            Button("Open Slack") { state.openApp(.slack) }
                .buttonStyle(.borderless)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}
