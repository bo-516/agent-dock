// Where the dock's sessions come from: Claude Code sessions (from the file the
// agent-dock plugin keeps), Codex threads (from ~/.codex SQLite databases and
// locks), and Antigravity conversations (from Antigravity's summary database).
// All three are read on a timer into one BoardModel.

import AppKit
import Combine
import Darwin
import SQLite3

enum Source: String {
    case claude
    case codex
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
    // A claude:// or codex:// link; unused for Antigravity, which has no link to a conversation.
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

    // Why the last read failed, for `AgentDock --print-conversations`.
    private(set) var lastError: String?

    // While Antigravity is idle its database has no -wal file, and a read-only
    // connection cannot create one, so the read fails; the main file then holds
    // everything, and an immutable open reads it as it is, writing nothing.
    private func query() -> [Row]? {
        if let rows = query(immutable: false) { return rows }
        return query(immutable: true)
    }

    private func query(immutable: Bool) -> [Row]? {
        var db: OpaquePointer?
        let file = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let name = immutable ? "file:\(file)?immutable=1" : "file:\(file)?mode=ro"
        guard sqlite3_open_v2(name, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            lastError = "open: \(String(cString: sqlite3_errmsg(db)))"
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
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = "prepare: \(String(cString: sqlite3_errmsg(db)))"
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                lastError = "step: \(String(cString: sqlite3_errmsg(db)))"
                return nil
            }
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
        lastError = nil
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

// MARK: - Codex

// Codex (both the ChatGPT/Codex desktop app and the `codex` CLI) stores local
// threads, projects, and read receipts in ~/.codex/state_<N>.sqlite, turn
// statuses in ~/.codex/thread_history_<N>.sqlite, and holds an exclusive flock
// on ~/.codex/thread-writer-locks/<id>.lock while a live process has a thread
// loaded. Everything here opens read-only and never touches auth files.
final class CodexFeed {
    static let bundleIDs = ["com.openai.codex"]
    private static let unreadKey = "codexUnread"
    private static let dismissedTurnsKey = "codexDismissedTurns"
    // When AgentDock first read Codex: read receipts older than this are history,
    // not something that just finished. A date rather than a flag, so two
    // processes starting together cannot leave it half done.
    private static let receiptsSinceKey = "codexReceiptsSince"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var folder: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return home.appendingPathComponent(".codex")
    }

    private var wasRunning: Set<String>?
    private var unread: Set<String>
    private var dismissedTurns: [String: String]
    private let receiptsSince: Date
    private var latestUnreadTurns: [String: String] = [:]
    private var last: [Session] = []

    // True while any live Codex process holds a thread writer lock (including CLI sessions).
    private(set) var hasActiveSessionLock = false
    private(set) var lastError: String?

    init() {
        unread = Set(UserDefaults.standard.stringArray(forKey: Self.unreadKey) ?? [])
        dismissedTurns = UserDefaults.standard.dictionary(forKey: Self.dismissedTurnsKey) as? [String: String] ?? [:]
        if let since = UserDefaults.standard.object(forKey: Self.receiptsSinceKey) as? Date {
            receiptsSince = since
        } else {
            receiptsSince = Date()
            UserDefaults.standard.set(receiptsSince, forKey: Self.receiptsSinceKey)
        }
        UserDefaults.standard.removeObject(forKey: "codexReceiptsSeeded")
    }

    func read() -> [Session] {
        let locked = lockedThreadIDs()
        hasActiveSessionLock = !locked.isEmpty

        guard let rows = query(locked: locked) else { return last }
        let running = Set(rows.filter(\.isRunning).map(\.id))
        if let wasRunning {
            let isInFront = Self.bundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            let stopped = wasRunning.subtracting(running)
            if !isInFront { unread.formUnion(stopped) }
        }
        wasRunning = running
        unread.subtract(running)
        unread.formIntersection(Set(rows.map(\.id)))

        var currentUnreadTurns: [String: String] = [:]
        for row in rows where row.hasReceipt && !row.firstUnreadTurn.isEmpty && !row.isRunning {
            currentUnreadTurns[row.id] = row.firstUnreadTurn
        }
        latestUnreadTurns = currentUnreadTurns
        dismissedTurns = dismissedTurns.filter { id, turn in
            !running.contains(id) && currentUnreadTurns[id] == turn
        }

        UserDefaults.standard.set(Array(unread), forKey: Self.unreadKey)
        UserDefaults.standard.set(dismissedTurns, forKey: Self.dismissedTurnsKey)

        last = rows.map { row in
            let isUnread: Bool
            if row.isRunning {
                isUnread = false
            } else if row.hasReceipt {
                isUnread = !row.firstUnreadTurn.isEmpty && row.lastActivity > receiptsSince
                    && dismissedTurns[row.id] != row.firstUnreadTurn
            } else {
                isUnread = unread.contains(row.id)
            }
            return Session(
                id: row.id,
                source: .codex,
                title: row.title,
                project: row.project,
                projectKey: row.projectKey,
                state: row.isRunning ? .running : isUnread ? .unread : .seen,
                lastActivity: row.lastActivity,
                link: "codex://threads/\(row.id)"
            )
        }
        return last
    }

    func markSeen(_ id: String) {
        unread.remove(id)
        if let turn = latestUnreadTurns[id], !turn.isEmpty {
            dismissedTurns[id] = turn
        }
        UserDefaults.standard.set(Array(unread), forKey: Self.unreadKey)
        UserDefaults.standard.set(dismissedTurns, forKey: Self.dismissedTurnsKey)
    }

    private struct Row {
        let id: String
        let title: String
        let project: String
        let projectKey: String
        let isRunning: Bool
        let hasReceipt: Bool
        let firstUnreadTurn: String
        let lastActivity: Date
    }

    private func query(locked: Set<String>) -> [Row]? {
        guard let statePath = Self.latestSQLite(prefix: "state_") else {
            lastError = nil
            return []
        }
        if let rows = queryState(at: statePath, locked: locked, immutable: false) { return rows }
        return queryState(at: statePath, locked: locked, immutable: true)
    }

    private func queryState(at path: String, locked: Set<String>, immutable: Bool) -> [Row]? {
        guard let db = Self.openReadOnly(path: path, immutable: immutable, errorOut: &lastError) else { return nil }
        defer { sqlite3_close(db) }

        let hasProjects = Self.tableExists(db, "projects")
        let hasReceipts = Self.tableExists(db, "thread_read_receipts")
        let hasSpawnEdges = Self.tableExists(db, "thread_spawn_edges")

        let projectSelect = hasProjects ? "COALESCE(p.name, '')" : "''"
        let projectJoin = hasProjects ? "LEFT JOIN projects p ON p.id = t.project_id" : ""
        let receiptSelect = hasReceipts
            ? "CASE WHEN r.thread_id IS NOT NULL THEN 1 ELSE 0 END, COALESCE(r.first_unread_turn, '')"
            : "0, ''"
        let receiptJoin = hasReceipts ? "LEFT JOIN thread_read_receipts r ON r.thread_id = t.id" : ""
        let spawnFilter = hasSpawnEdges ? "AND t.id NOT IN (SELECT child_thread_id FROM thread_spawn_edges)" : ""

        let sql = """
            SELECT t.id, COALESCE(t.name, ''), t.title, t.preview, t.cwd,
                   \(projectSelect),
                   COALESCE(NULLIF(t.recency_at_ms, 0), t.updated_at * 1000),
                   \(receiptSelect),
                   t.rollout_path
            FROM threads t
            \(projectJoin)
            \(receiptJoin)
            WHERE t.archived = 0
              AND trim(t.preview) <> ''
              AND (t.thread_source IS NULL OR t.thread_source = '' OR t.thread_source = 'user')
              AND t.source NOT LIKE '{"subagent"%'
              AND t.source <> 'exec'
              AND (t.agent_role IS NULL OR t.agent_role = '')
              AND (t.attached_thread_parent_id IS NULL OR t.attached_thread_parent_id = '')
              \(spawnFilter)
              AND lower(COALESCE(t.name, '')) NOT LIKE 'btw%'
              AND lower(t.title) NOT LIKE 'btw%'
              AND lower(ltrim(t.preview)) NOT LIKE '/btw%'
            ORDER BY COALESCE(NULLIF(t.recency_at_ms, 0), t.updated_at * 1000) DESC
            LIMIT 300
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = "prepare: \(String(cString: sqlite3_errmsg(db)))"
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rawRows: [(id: String, name: String, title: String, preview: String, cwd: String,
                       projectName: String, activityMs: Int64, hasReceipt: Bool,
                       firstUnread: String, rolloutPath: String)] = []
        var rolloutByID: [String: String] = [:]

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                lastError = "step: \(String(cString: sqlite3_errmsg(db)))"
                return nil
            }
            let id = Self.text(statement, 0)
            let rolloutPath = Self.text(statement, 9)
            if locked.contains(id), !rolloutPath.isEmpty { rolloutByID[id] = rolloutPath }
            rawRows.append((
                id: id,
                name: Self.text(statement, 1),
                title: Self.text(statement, 2),
                preview: Self.text(statement, 3),
                cwd: Self.text(statement, 4),
                projectName: Self.text(statement, 5),
                activityMs: sqlite3_column_int64(statement, 6),
                hasReceipt: sqlite3_column_int(statement, 7) != 0,
                firstUnread: Self.text(statement, 8),
                rolloutPath: rolloutPath
            ))
        }

        let activeIDs = runningThreadIDs(locked: locked, rolloutByID: rolloutByID)
        let rows = rawRows.map { item -> Row in
            let (projectKey, project) = Self.codexProject(cwd: item.cwd, explicitName: item.projectName)
            return Row(
                id: item.id,
                title: Self.cleanTitle(name: item.name, title: item.title, preview: item.preview),
                project: project,
                projectKey: projectKey,
                isRunning: activeIDs.contains(item.id),
                hasReceipt: item.hasReceipt,
                firstUnreadTurn: item.firstUnread,
                lastActivity: Date(timeIntervalSince1970: TimeInterval(item.activityMs) / 1000.0)
            )
        }
        lastError = nil
        return rows
    }

    // Threads whose writer lock file is currently held by a live Codex process.
    private func lockedThreadIDs() -> Set<String> {
        let dir = Self.folder.appendingPathComponent("thread-writer-locks")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var ids: Set<String> = []
        for name in names where !name.hasPrefix(".") && name.hasSuffix(".lock") {
            let path = dir.appendingPathComponent(name).path
            let fd = Darwin.open(path, O_RDONLY)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    ids.insert(String(name.dropLast(5)))
                }
            } else {
                _ = flock(fd, LOCK_UN)
            }
        }
        return ids
    }

    // A locked thread is loaded in memory; it is actively running only when its
    // latest turn in thread_history_<N>.sqlite is `inProgress` (or, before
    // paginated history catches up, its rollout file ends on `task_started`).
    private func runningThreadIDs(locked: Set<String>, rolloutByID: [String: String]) -> Set<String> {
        guard !locked.isEmpty else { return [] }
        var running: Set<String> = []
        var checkedInHistory: Set<String> = []

        if let historyPath = Self.latestSQLite(prefix: "thread_history_") {
            // A WAL database with no -wal file opens read-only but fails on the
            // first read; the immutable open then reads the main file as it is.
            for immutable in [false, true] {
                if let statuses = Self.latestTurnStatuses(at: historyPath, threads: locked, immutable: immutable) {
                    for (id, status) in statuses {
                        checkedInHistory.insert(id)
                        if status == "inProgress" { running.insert(id) }
                    }
                    break
                }
            }
        }

        for id in locked where !checkedInHistory.contains(id) {
            if let path = rolloutByID[id], Self.isRolloutRunning(at: path) {
                running.insert(id)
            }
        }
        return running
    }

    // Each thread's latest turn status, or nil when the database could not be read.
    private static func latestTurnStatuses(at path: String, threads: Set<String>, immutable: Bool) -> [String: String]? {
        var error: String?
        guard let db = openReadOnly(path: path, immutable: immutable, errorOut: &error) else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT status FROM thread_turns WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var statuses: [String: String] = [:]
        for id in threads {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                statuses[id] = text(statement, 0)
            } else if step != SQLITE_DONE {
                return nil
            }
        }
        return statuses
    }

    private static func isRolloutRunning(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let tailOffset = end > 65_536 ? end - 65_536 : 0
        try? handle.seek(toOffset: tailOffset)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return false }
        let started = text.range(of: "\"type\":\"task_started\"", options: .backwards)?.lowerBound
        let completed = text.range(of: "\"type\":\"task_complete\"", options: .backwards)?.lowerBound
        let aborted = text.range(of: "\"type\":\"turn_aborted\"", options: .backwards)?.lowerBound
        guard let started else { return false }
        if let completed, completed > started { return false }
        if let aborted, aborted > started { return false }
        return true
    }

    // The newest generation of a Codex database, e.g. state_5.sqlite over state_4.sqlite.
    static func latestSQLite(prefix: String) -> String? {
        let dir = folder
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var best: (version: Int, name: String)?
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".sqlite") {
            let numberPart = entry.dropFirst(prefix.count).dropLast(".sqlite".count)
            let version = Int(numberPart) ?? 0
            if best == nil || version > best!.version {
                best = (version, entry)
            }
        }
        return best.map { dir.appendingPathComponent($0.name).path }
    }

    static func openReadOnly(path: String, immutable: Bool, errorOut: inout String?) -> OpaquePointer? {
        var db: OpaquePointer?
        let file = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let uri = immutable ? "file:\(file)?immutable=1" : "file:\(file)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            errorOut = "open: \(String(cString: sqlite3_errmsg(db)))"
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 300)
        return db
    }

    private static func tableExists(_ db: OpaquePointer?, _ name: String) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    // Codex Desktop puts projectless chats in ~/Documents/Codex/YYYY-MM-DD/<slug>.
    private static func codexProject(cwd: String, explicitName: String) -> (key: String, name: String) {
        let scratchRoot = home.appendingPathComponent("Documents/Codex").path
        if cwd.isEmpty || cwd.contains("/scratch-workspaces/")
            || cwd == scratchRoot || cwd.hasPrefix(scratchRoot + "/") {
            return ("", "No Project")
        }
        let trimmed = explicitName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : trimmed
        return (cwd, name.isEmpty ? "No Project" : name)
    }

    private static func cleanTitle(name: String, title: String, preview: String) -> String {
        let short = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty, let first = short.split(whereSeparator: \.isNewline).first {
            return String(first)
        }
        var raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { raw = preview.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let marker = raw.range(of: "## My request:") {
            raw = String(raw[marker.upperBound...])
        }
        let line = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let unescaped = line.replacingOccurrences(of: "\\.", with: ".")
            .replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\_", with: "_")
        return unescaped.isEmpty ? "Untitled conversation" : unescaped
    }
}

// Codex's plan limits, read via the official `codex app-server` JSON-RPC
// `account/rateLimits/read` request on the bundled or user-installed `codex` CLI.
final class CodexQuota {
    private let queue = DispatchQueue(label: "agent-dock.codex-quota")

    func fetch(_ done: @escaping ([UsageRow]?) -> Void) {
        queue.async {
            let rows = Self.fetchViaAppServer()
            DispatchQueue.main.async { done(rows) }
        }
    }

    private struct RPCEnvelope: Decodable {
        let id: Int?
        let result: ResultPayload?

        struct ResultPayload: Decodable {
            let rateLimits: Snapshot?
            let rateLimitsByLimitId: [String: Snapshot]?
        }

        struct Snapshot: Decodable {
            let limitId: String?
            let limitName: String?
            let primary: Window?
            let secondary: Window?
        }

        struct Window: Decodable {
            let usedPercent: Double?
            let windowDurationMins: Int?
            let resetsAt: Int64?
        }
    }

    private static func fetchViaAppServer() -> [UsageRow]? {
        guard let executable = findExecutable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        defer {
            timeout.cancel()
            try? inPipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let initLine = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-dock","title":"Agent Dock","version":"1.0"},"capabilities":{"experimentalApi":true}}}"# + "\n"
        guard (try? inPipe.fileHandleForWriting.write(contentsOf: Data(initLine.utf8))) != nil else { return nil }

        var buffer = Data()
        var sentQuery = false
        let reader = outPipe.fileHandleForReading

        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !lineData.isEmpty,
                      let message = try? JSONDecoder().decode(RPCEnvelope.self, from: Data(lineData)),
                      let id = message.id else { continue }
                if id == 1 && !sentQuery {
                    sentQuery = true
                    let nextLines = #"{"jsonrpc":"2.0","method":"initialized"}"# + "\n"
                        + #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}"# + "\n"
                    try? inPipe.fileHandleForWriting.write(contentsOf: Data(nextLines.utf8))
                } else if id == 2 {
                    return rows(from: message.result)
                }
            }
        }
        return nil
    }

    private static func rows(from payload: RPCEnvelope.ResultPayload?) -> [UsageRow]? {
        guard let payload else { return nil }
        let buckets: [(key: String, snapshot: RPCEnvelope.Snapshot)]
        if let map = payload.rateLimitsByLimitId, !map.isEmpty {
            buckets = map.sorted { lhs, rhs in
                if lhs.key == "codex" { return true }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }.map { ($0.key, $0.value) }
        } else if let single = payload.rateLimits {
            buckets = [(single.limitId ?? "codex", single)]
        } else {
            return nil
        }

        var result: [UsageRow] = []
        for (key, snapshot) in buckets {
            let name = (snapshot.limitName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = (key == "codex" && name.isEmpty) ? nil : (name.isEmpty ? key : name)
            let windows = [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
                .compactMap { slot, win -> (String, RPCEnvelope.Window)? in win.map { (slot, $0) } }
                .sorted { ($0.1.windowDurationMins ?? .max) < ($1.1.windowDurationMins ?? .max) }
            for (slot, window) in windows {
                guard let used = window.usedPercent else { continue }
                let resetText = window.resetsAt.map {
                    isoPlain.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
                } ?? ""
                let windowName = windowLabel(minutes: window.windowDurationMins, hasPrefix: prefix != nil)
                let label = prefix.map { "\($0) · \(windowName)" } ?? windowName
                result.append(UsageRow(
                    id: "\(key)-\(slot)",
                    label: label,
                    percentUsed: (used * 10).rounded() / 10,
                    resetsAt: resetText
                ))
            }
        }
        return result
    }

    private static func windowLabel(minutes: Int?, hasPrefix: Bool) -> String {
        let suffix = hasPrefix ? "" : "额度"
        switch minutes {
        case 300: return "5 小时\(suffix)"
        case 1440: return "每天\(suffix)"
        case 10080: return "每周\(suffix)"
        case let m? where m > 0 && m % 1440 == 0: return "\(m / 1440) 天\(suffix)"
        case let m? where m > 0 && m % 60 == 0: return "\(m / 60) 小时\(suffix)"
        case let m? where m > 0: return "\(m) 分钟\(suffix)"
        default: return hasPrefix ? "用量" : "套餐额度"
        }
    }

    private static func findExecutable() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        for id in CodexFeed.bundleIDs {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex").path)
                candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex").path)
            }
        }
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".cargo/bin/codex").path,
        ])
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        for extDir in [".vscode/extensions", ".cursor/extensions", ".antigravity-ide/extensions"] {
            let root = home.appendingPathComponent(extDir)
            guard let items = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for item in items.sorted().reversed() where item.hasPrefix("openai.chatgpt-") {
                let binRoot = root.appendingPathComponent(item).appendingPathComponent("bin")
                guard let platforms = try? fm.contentsOfDirectory(atPath: binRoot.path) else { continue }
                for platform in platforms {
                    let bin = binRoot.appendingPathComponent(platform).appendingPathComponent("codex").path
                    if fm.isExecutableFile(atPath: bin) { return bin }
                }
            }
        }
        return nil
    }
}

// MARK: - Board

final class BoardModel: ObservableObject {
    @Published var claude: [Session] = []
    @Published var codex: [Session] = []
    @Published var antigravity: [Session] = []
    @Published var usage: [UsageWindow] = []
    @Published var usageAt: Date?
    @Published var codexUsage: [UsageRow] = []
    @Published var codexUsageAt: Date?
    @Published var antigravityUsage: [UsageRow] = []
    @Published var antigravityUsageAt: Date?
    @Published var claudeUpdatedAt: Date?
    @Published var hasActiveCodexSession = false
    @Published var now = Date()
    @Published var showClaude: Bool {
        didSet { UserDefaults.standard.set(showClaude, forKey: "showClaude") }
    }
    @Published var showCodex: Bool {
        didSet { UserDefaults.standard.set(showCodex, forKey: "showCodex") }
    }
    @Published var showAntigravity: Bool {
        didSet { UserDefaults.standard.set(showAntigravity, forKey: "showAntigravity") }
    }
    // Pinned: the dropdown stays up when another app comes forward or a row opens
    // something, and can be dragged anywhere.
    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: "isPinned") }
    }

    // Set by the status controller: the pointer entered (true) or left (false) a
    // session row, with the row's frame in the dropdown's top-left coordinates.
    var onHoverSession: ((Session, Bool, CGRect) -> Void)?

    // Set by the dropdown; the clock behind "35m ago" only ticks while it shows.
    var isShown = false
    let animator = IconAnimator()
    private let codexFeed = CodexFeed()
    private let codexQuota = CodexQuota()
    private let antigravityFeed = AntigravityFeed()
    private let antigravityQuota = AntigravityQuota()
    private var codexQuotaAskedAt = Date.distantPast
    private var quotaAskedAt = Date.distantPast
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        showClaude = defaults.object(forKey: "showClaude") as? Bool ?? true
        showCodex = defaults.object(forKey: "showCodex") as? Bool ?? true
        showAntigravity = defaults.object(forKey: "showAntigravity") as? Bool ?? true
        isPinned = defaults.bool(forKey: "isPinned")
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
        let threads = codexFeed.read()
        if threads != codex { codex = threads }
        if codexFeed.hasActiveSessionLock != hasActiveCodexSession {
            hasActiveCodexSession = codexFeed.hasActiveSessionLock
        }
        let conversations = antigravityFeed.read()
        if conversations != antigravity { antigravity = conversations }
        let interval: TimeInterval = isShown ? 15 : 60
        refreshCodexQuota(every: interval)
        refreshQuota(every: interval)
        animator.setSpinning(runningCount > 0)
    }

    private func refreshCodexQuota(every seconds: TimeInterval) {
        guard showCodex, Date().timeIntervalSince(codexQuotaAskedAt) >= seconds else { return }
        let isRunning = hasActiveCodexSession || NSWorkspace.shared.runningApplications.contains {
            CodexFeed.bundleIDs.contains($0.bundleIdentifier ?? "")
        }
        guard isRunning else { return }
        codexQuotaAskedAt = Date()
        codexQuota.fetch { [weak self] rows in
            guard let self, let rows else { return }
            if rows != self.codexUsage { self.codexUsage = rows }
            self.codexUsageAt = Date()
        }
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
        (showClaude ? claude : []) + (showCodex ? codex : []) + (showAntigravity ? antigravity : [])
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

    func hoverSession(_ session: Session, inside: Bool, frame: CGRect) {
        onHoverSession?(session, inside, frame)
    }

    // A row opened something: the dropdown gets out of the way unless it is pinned.
    private func dismissUnlessPinned() {
        if !isPinned { NotificationCenter.default.post(name: .closeDropdown, object: nil) }
    }

    func open(_ session: Session) {
        dismissUnlessPinned()
        switch session.source {
        case .claude:
            guard session.link.hasPrefix("claude://"), let url = URL(string: session.link) else { return }
            NSWorkspace.shared.open(url)
        case .codex:
            codexFeed.markSeen(session.id)
            codex = codexFeed.read()
            if session.link.hasPrefix("codex://"), let url = URL(string: session.link),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
            } else {
                openApp(CodexFeed.bundleIDs[0])
            }
        case .antigravity:
            // No link reaches one conversation; this brings up the Agent Manager.
            antigravityFeed.markSeen(session.id)
            antigravity = antigravityFeed.read()
            openApp(AntigravityFeed.bundleIDs[0])
        }
    }

    func openApp(_ bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        dismissUnlessPinned()
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
