// Where the dock's sessions come from: Claude Code sessions, from the file the
// agent-dock plugin keeps, and Antigravity conversations, from Antigravity's
// own summary database. Both are read on a timer into one BoardModel.

import AppKit
import Combine
import SQLite3

enum Source: String {
    case claude
    case antigravity
}

enum RunState: Equatable {
    case running
    case unread // stopped while nobody was looking
    case seen
}

struct Session: Identifiable, Equatable {
    let id: String
    let source: Source
    let title: String
    let project: String
    let projectKey: String
    let state: RunState
    let lastActivity: Date
    // A claude:// link for Claude; unused for Antigravity, which has no link to a conversation.
    let link: String

    var isRunning: Bool { state == .running }
    var isUnread: Bool { state == .unread }
}

struct ProjectGroup: Identifiable {
    let id: String
    let name: String
    let rows: [Session]
}

struct UsageWindow: Decodable, Equatable, Identifiable {
    let kind: String
    let percentUsed: Double
    let resetsAt: String

    var id: String { kind }
}

let home = FileManager.default.homeDirectoryForCurrentUser

func projectName(forPath path: String) -> (key: String, name: String) {
    if path.isEmpty || path.contains("/scratch-workspaces/") { return ("", "No Project") }
    return (path, URL(fileURLWithPath: path).lastPathComponent)
}

// MARK: - Claude

// ~/.claude/agent-dock/, written by the agent-dock Claude Code plugin: one
// session at a time lists every session into state.json, and whichever
// session got the latest reading of the plan's limits writes usage.json.
enum ClaudeFeed {
    static let bundleIDs = ["com.anthropic.claudefordesktop"]
    static let folder = home.appendingPathComponent(".claude/agent-dock")

    private struct State: Decodable {
        let updatedAt: String
        let sessions: [Row]
    }

    private struct Row: Decodable {
        let id: String
        let title: String
        let project: String
        let projectKey: String
        let status: String
        let lastActivityAt: String
        let link: String
    }

    private struct Usage: Decodable {
        let at: String
        let windows: [UsageWindow]
    }

    static func readSessions() -> (sessions: [Session], updatedAt: Date?)? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        let sessions = state.sessions.map { row in
            Session(
                id: row.id,
                source: .claude,
                title: row.title,
                project: row.project,
                projectKey: row.projectKey,
                state: row.status == "running" ? .running : row.status == "unread" ? .unread : .seen,
                lastActivity: parseDate(row.lastActivityAt) ?? .distantPast,
                link: row.link
            )
        }
        return (sessions, parseDate(state.updatedAt))
    }

    static func readUsage() -> (windows: [UsageWindow], at: Date?)? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("usage.json")),
              let usage = try? JSONDecoder().decode(Usage.self, from: data) else { return nil }
        return (usage.windows, parseDate(usage.at))
    }
}

// MARK: - Antigravity

// Antigravity keeps a summary of every conversation in a SQLite database it
// updates as agents work. It is read-only here, and an internal format: a new
// Antigravity may change it. Antigravity says nothing of which conversation
// is on screen, so a conversation that stops while Antigravity is not in
// front is unread until it is opened from the dock or runs again.
final class AntigravityFeed {
    static let bundleIDs = ["com.google.antigravity", "com.google.antigravity-ide"]
    private static let unreadKey = "antigravityUnread"

    private let path = home.appendingPathComponent(".gemini/antigravity/conversation_summaries.db").path
    private var wasRunning: Set<String>?
    private var unread: Set<String>
    private var last: [Session] = []

    init() {
        unread = Set(UserDefaults.standard.stringArray(forKey: Self.unreadKey) ?? [])
    }

    // The latest conversations, top-level only; the last good read when the
    // database is busy (Antigravity writes it while agents run).
    func read() -> [Session] {
        guard let rows = query() else { return last }
        let running = Set(rows.filter(\.isRunning).map(\.id))
        if let wasRunning {
            let isInFront = Self.bundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            let stopped = wasRunning.subtracting(running)
            if !isInFront { unread.formUnion(stopped) }
        }
        wasRunning = running
        unread.subtract(running)
        unread.formIntersection(Set(rows.map(\.id)))
        UserDefaults.standard.set(Array(unread), forKey: Self.unreadKey)

        last = rows.map { row in
            Session(id: row.id, source: .antigravity, title: row.title, project: row.project,
                    projectKey: row.projectKey,
                    state: row.isRunning ? .running : unread.contains(row.id) ? .unread : .seen,
                    lastActivity: row.lastActivity, link: "")
        }
        return last
    }

    func markSeen(_ id: String) {
        unread.remove(id)
        UserDefaults.standard.set(Array(unread), forKey: Self.unreadKey)
    }

    private struct Row {
        let id: String
        let title: String
        let project: String
        let projectKey: String
        let isRunning: Bool
        let lastActivity: Date
    }

    private func query() -> [Row]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)

        let sql = """
            SELECT conversation_id, title, workspace_uris, status,
                   CAST(strftime('%s', last_modified_time) AS INTEGER)
            FROM conversation_summaries
            WHERE nesting_depth = 0 AND (title <> '' OR step_count > 0)
            ORDER BY last_modified_time DESC
            LIMIT 300
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            let id = text(statement, 0)
            let title = text(statement, 1)
            let (key, name) = projectName(forPath: firstWorkspacePath(text(statement, 2)))
            rows.append(Row(
                id: id,
                title: title.isEmpty ? "Untitled conversation" : title,
                project: name,
                projectKey: key,
                isRunning: text(statement, 3) == "CASCADE_RUN_STATUS_RUNNING",
                lastActivity: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4)))
            ))
        }
        return rows
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    // `workspace_uris` is a JSON array of file URLs; the first names the project.
    private func firstWorkspacePath(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let uris = try? JSONDecoder().decode([String].self, from: data),
              let first = uris.first, let url = URL(string: first), url.isFileURL else { return "" }
        return url.path
    }
}

// MARK: - Board

final class BoardModel: ObservableObject {
    @Published var claude: [Session] = []
    @Published var antigravity: [Session] = []
    @Published var usage: [UsageWindow] = []
    @Published var usageAt: Date?
    @Published var claudeUpdatedAt: Date?
    @Published var now = Date()
    @Published var showClaude: Bool {
        didSet { UserDefaults.standard.set(showClaude, forKey: "showClaude") }
    }
    @Published var showAntigravity: Bool {
        didSet { UserDefaults.standard.set(showAntigravity, forKey: "showAntigravity") }
    }

    // Set by the dropdown; the clock behind "35m ago" only ticks while it shows.
    var isShown = false
    let animator = IconAnimator()
    private let antigravityFeed = AntigravityFeed()
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        showClaude = defaults.object(forKey: "showClaude") as? Bool ?? true
        showAntigravity = defaults.object(forKey: "showAntigravity") as? Bool ?? true
        load()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.load() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func load() {
        if isShown { now = Date() }
        if let reading = ClaudeFeed.readUsage() {
            if reading.windows != usage { usage = reading.windows }
            if reading.at != usageAt { usageAt = reading.at }
        }
        if let list = ClaudeFeed.readSessions() {
            if list.sessions != claude { claude = list.sessions }
            if list.updatedAt != claudeUpdatedAt { claudeUpdatedAt = list.updatedAt }
        }
        let conversations = antigravityFeed.read()
        if conversations != antigravity { antigravity = conversations }
        animator.setSpinning(runningCount > 0)
    }

    // The plugin stops writing when no Claude Code session is running it.
    var isClaudeStale: Bool {
        guard let claudeUpdatedAt else { return true }
        return Date().timeIntervalSince(claudeUpdatedAt) > 20
    }

    // What the menu bar item counts: the columns that are shown.
    private var shown: [Session] {
        (showClaude ? claude : []) + (showAntigravity ? antigravity : [])
    }

    var runningCount: Int { shown.filter(\.isRunning).count }
    var unreadCount: Int { shown.filter(\.isUnread).count }

    // Running sessions, and idle ones active within `limit` (every one when nil).
    func visible(_ list: [Session], within limit: TimeInterval?) -> [Session] {
        guard let limit else { return list }
        return list.filter { $0.isRunning || now.timeIntervalSince($0.lastActivity) <= limit }
    }

    func groups(of list: [Session]) -> [ProjectGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        var rows: [String: [Session]] = [:]
        for s in list {
            let key = "\(s.source.rawValue):\(s.projectKey)"
            if rows[key] == nil {
                order.append(key)
                names[key] = s.project
            }
            rows[key, default: []].append(s)
        }
        return order.map { ProjectGroup(id: $0, name: names[$0] ?? $0, rows: rows[$0] ?? []) }
    }

    func open(_ session: Session) {
        NotificationCenter.default.post(name: .closeDropdown, object: nil)
        switch session.source {
        case .claude:
            guard session.link.hasPrefix("claude://"), let url = URL(string: session.link) else { return }
            NSWorkspace.shared.open(url)
        case .antigravity:
            // No link reaches one conversation; this brings up the Agent Manager.
            antigravityFeed.markSeen(session.id)
            antigravity = antigravityFeed.read()
            openApp(AntigravityFeed.bundleIDs[0])
        }
    }

    func openApp(_ bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NotificationCenter.default.post(name: .closeDropdown, object: nil)
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Time

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoPlain = ISO8601DateFormatter()

func parseDate(_ text: String) -> Date? {
    isoFractional.date(from: text) ?? isoPlain.date(from: text)
}

// "35m ago", "1h 20m ago" (or "3h ago" on the hour), "2d ago" from a day on.
func ago(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return minutes % 60 == 0 ? "\(hours)h ago" : "\(hours)h \(minutes % 60)m ago" }
    return "\(hours / 24)d ago"
}

// "resets in 1h 12m", "resets in 2d 5h 30m": to the minute, zero parts left out.
func until(_ text: String, now: Date) -> String? {
    guard let date = parseDate(text) else { return nil }
    let seconds = date.timeIntervalSince(now)
    if seconds < 0 { return nil }
    let minutes = max(Int((seconds / 60).rounded(.up)), 1)
    let parts = [(minutes / 1440, "d"), (minutes / 60 % 24, "h"), (minutes % 60, "m")]
        .filter { $0.0 > 0 }
        .map { "\($0.0)\($0.1)" }
    return "resets in " + parts.joined(separator: " ")
}

func usageLabel(_ kind: String) -> String {
    switch kind {
    case "five_hour": return "5 小时额度"
    case "seven_day": return "每周 · 所有模型"
    case "seven_day_opus": return "每周 · Opus"
    case "seven_day_sonnet": return "每周 · Sonnet"
    case "spend_limit": return "消费上限"
    default: return kind
    }
}
