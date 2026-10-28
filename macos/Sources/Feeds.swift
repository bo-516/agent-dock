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

// One limit as a column shows it: what it is, how much is used, when it resets.
struct UsageRow: Identifiable, Equatable {
    let id: String
    let label: String
    let percentUsed: Double
    let resetsAt: String
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

        // Top-level conversations someone has written in, leaving out ones another
        // agent started (subagents, sidekicks) and side questions (/btw).
        let sql = """
            SELECT conversation_id, title, workspace_uris, status,
                   CAST(strftime('%s', last_modified_time) AS INTEGER)
            FROM conversation_summaries
            WHERE nesting_depth = 0 AND parent_conversation_id = '' AND agent_name = ''
              AND step_count > 0
              AND lower(title) NOT LIKE 'btw%' AND lower(ltrim(preview)) NOT LIKE '/btw%'
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

// Antigravity's plan limits (5-hour and weekly, per model group), from the
// quota summary its Agent Manager shows. Its language server answers on a
// local port and wants the token it was started with; both are read from the
// running process each time and kept nowhere. Internal and undocumented: a
// new Antigravity may change it.
final class AntigravityQuota: NSObject, URLSessionDelegate {
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    private let queue = DispatchQueue(label: "agent-dock.antigravity-quota")

    // Calls back on the main queue: the rows, or nil when Antigravity did not answer.
    func fetch(_ done: @escaping ([UsageRow]?) -> Void) {
        queue.async {
            guard let server = Self.findServer() else {
                DispatchQueue.main.async { done(nil) }
                return
            }
            self.request(ports: server.ports, token: server.token, done: done)
        }
    }

    private func request(ports: [String], token: String, done: @escaping ([UsageRow]?) -> Void) {
        guard let port = ports.first,
              let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")
        else {
            DispatchQueue.main.async { done(nil) }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Data("{}".utf8)
        session.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, let rows = Self.rows(from: data) else {
                self.request(ports: Array(ports.dropFirst()), token: token, done: done)
                return
            }
            DispatchQueue.main.async { done(rows) }
        }.resume()
    }

    // The language server is local and signs its own certificate.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.host == "127.0.0.1",
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private struct Summary: Decodable {
        let response: Response?

        struct Response: Decodable {
            let groups: [Group]?
        }

        struct Group: Decodable {
            let displayName: String?
            let buckets: [Bucket]?
        }

        struct Bucket: Decodable {
            let bucketId: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
    }

    private static func rows(from data: Data) -> [UsageRow]? {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data),
              let groups = summary.response?.groups else { return nil }
        let order = ["5h": 0, "daily": 1, "weekly": 2]
        return groups.flatMap { group -> [UsageRow] in
            let name = shortName(group.displayName ?? "")
            return (group.buckets ?? [])
                .filter { $0.remainingFraction != nil }
                .sorted { order[$0.window ?? "", default: 9] < order[$1.window ?? "", default: 9] }
                .map { bucket in
                    let used = (1 - (bucket.remainingFraction ?? 1)) * 100
                    return UsageRow(id: bucket.bucketId ?? "\(name)-\(bucket.window ?? "")",
                                    label: "\(name) · \(windowLabel(bucket.window ?? ""))",
                                    percentUsed: (used * 10).rounded() / 10,
                                    resetsAt: bucket.resetTime ?? "")
                }
        }
    }

    // "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude / GPT".
    private static func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: " models", with: "", options: [.caseInsensitive, .anchored, .backwards])
            .replacingOccurrences(of: " and ", with: " / ")
    }

    private static func windowLabel(_ window: String) -> String {
        switch window {
        case "5h": return "5 小时"
        case "daily": return "每天"
        case "weekly": return "每周"
        default: return window
        }
    }

    // The Antigravity language server's token (from its arguments) and the ports it listens on.
    private static func findServer() -> (token: String, ports: [String])? {
        guard let processes = run("/bin/ps", ["-axo", "pid=,command="]) else { return nil }
        for line in processes.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.contains("Antigravity"), text.contains("/bin/language_server "),
                  let flag = text.range(of: "--csrf_token ") else { continue }
            let token = String(text[flag.upperBound...].prefix { $0 != " " })
            let pid = String(text.prefix { $0 != " " })
            guard !token.isEmpty,
                  let listening = run("/usr/sbin/lsof", ["-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN", "-Fn"])
            else { continue }
            let ports = listening.split(separator: "\n")
                .filter { $0.hasPrefix("n") }
                .compactMap { $0.split(separator: ":").last.map(String.init) }
            if !ports.isEmpty { return (token, ports) }
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Board

final class BoardModel: ObservableObject {
    @Published var claude: [Session] = []
    @Published var antigravity: [Session] = []
    @Published var usage: [UsageWindow] = []
    @Published var usageAt: Date?
    @Published var antigravityUsage: [UsageRow] = []
    @Published var antigravityUsageAt: Date?
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
    private let antigravityQuota = AntigravityQuota()
    private var quotaAskedAt = Date.distantPast
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
        refreshQuota(every: isShown ? 15 : 60)
        animator.setSpinning(runningCount > 0)
    }

    // Asks Antigravity for its limits at most every `seconds`, while it runs and its column shows.
    private func refreshQuota(every seconds: TimeInterval) {
        guard showAntigravity, Date().timeIntervalSince(quotaAskedAt) >= seconds else { return }
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            AntigravityFeed.bundleIDs.contains($0.bundleIdentifier ?? "")
        }
        guard isRunning else { return }
        quotaAskedAt = Date()
        antigravityQuota.fetch { [weak self] rows in
            guard let self, let rows else { return }
            if rows != self.antigravityUsage { self.antigravityUsage = rows }
            self.antigravityUsageAt = Date()
        }
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

// "35m ago", then whole hours ("2h ago"), then days ("2d ago").
func ago(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes)m ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h ago" }
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
