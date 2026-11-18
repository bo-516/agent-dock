// What a session has been saying, for the hover preview: its latest prompts,
// thinking, tool steps, and replies. Each agent's own local files are read,
// read-only, only for the one session under the pointer; nothing is written.
//
// Claude: the desktop session file names the CLI session, whose transcript is
//   ~/.claude/projects/<dir>/<cliSessionId>.jsonl.
// Codex: ~/.codex/thread_history_<N>.sqlite (thread_items), else the rollout file.
// Antigravity: ~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl.

import Foundation
import SQLite3

enum PreviewKind: Equatable {
    case user
    case thinking
    case tools([String])
    case reply
}

struct PreviewEntry: Identifiable, Equatable {
    let id: String
    let kind: PreviewKind
    let text: String
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class TranscriptReader {
    private let queue = DispatchQueue(label: "agent-dock.transcripts")
    // Desktop session id -> its session file, and CLI session id -> its transcript.
    private var claudeSessionFiles: [String: URL] = [:]
    private var claudeTranscripts: [String: URL] = [:]
    private var claudeScannedAt = Date.distantPast

    // Reads on a background queue; calls back on the main queue.
    func load(_ session: Session, done: @escaping ([PreviewEntry]) -> Void) {
        queue.async {
            let entries = self.read(session)
            DispatchQueue.main.async { done(entries) }
        }
    }

    // Synchronous, for `AgentDock --print-preview`.
    func entriesNow(for session: Session) -> [PreviewEntry] {
        queue.sync { read(session) }
    }

    private func read(_ session: Session) -> [PreviewEntry] {
        let raw: [PreviewEntry]
        switch session.source {
        case .claude: raw = claude(session.id)
        case .codex: raw = codex(session.id)
        case .antigravity: raw = antigravity(session.id)
        }
        return Self.tidy(raw)
    }

    // MARK: Claude

    private func claude(_ id: String) -> [PreviewEntry] {
        guard let file = claudeSessionFile(id),
              let data = try? Data(contentsOf: file),
              let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let cli = (meta["cliSessionId"] as? String) ?? (meta["lastAssistantCliSessionId"] as? String) ?? ""
        if !cli.isEmpty, let transcript = claudeTranscript(cli) {
            let entries = Self.parseClaude(Self.objects(Self.tailLines(of: transcript, bytes: 768 * 1024)))
            if !entries.isEmpty { return entries }
        }
        // No transcript on disk: the desktop's own wrap-up of the last turn.
        if let wrap = meta["turnWrapUp"] as? [String: Any], let text = wrap["description"] as? String {
            return [PreviewEntry(id: "wrap", kind: .reply, text: text)]
        }
        if let summary = meta["postTurnSummary"] as? [String: Any], let text = summary["status_detail"] as? String {
            return [PreviewEntry(id: "summary", kind: .reply, text: text)]
        }
        return []
    }

    private func claudeSessionFile(_ id: String) -> URL? {
        if let hit = claudeSessionFiles[id] { return hit }
        // A new session: look again, at most every 10 seconds.
        guard Date().timeIntervalSince(claudeScannedAt) > 10 else { return nil }
        claudeScannedAt = Date()
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.pathExtension == "json" {
            claudeSessionFiles[url.deletingPathExtension().lastPathComponent] = url
        }
        return claudeSessionFiles[id]
    }

    private func claudeTranscript(_ cli: String) -> URL? {
        if let hit = claudeTranscripts[cli], FileManager.default.fileExists(atPath: hit.path) { return hit }
        let root = home.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        for dir in dirs {
            let url = root.appendingPathComponent(dir).appendingPathComponent("\(cli).jsonl")
            if FileManager.default.fileExists(atPath: url.path) {
                claudeTranscripts[cli] = url
                return url
            }
        }
        return nil
    }

    private static func parseClaude(_ lines: [[String: Any]]) -> [PreviewEntry] {
        var out: [PreviewEntry] = []
        for line in lines {
            guard let type = line["type"] as? String, type == "user" || type == "assistant",
                  line["isSidechain"] as? Bool != true, line["isMeta"] as? Bool != true,
                  let message = line["message"] as? [String: Any] else { continue }
            let uuid = (line["uuid"] as? String) ?? UUID().uuidString
            if let text = message["content"] as? String {
                if type == "user", !isMarkup(text) { out.append(PreviewEntry(id: uuid, kind: .user, text: text)) }
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { continue }
            for (index, block) in blocks.enumerated() {
                let id = "\(uuid)-\(index)"
                switch (type, block["type"] as? String) {
                case ("user", "text"):
                    if let text = block["text"] as? String, !isMarkup(text) {
                        out.append(PreviewEntry(id: id, kind: .user, text: text))
                    }
                case ("assistant", "thinking"):
                    if let text = block["thinking"] as? String {
                        out.append(PreviewEntry(id: id, kind: .thinking, text: text))
                    }
                case ("assistant", "tool_use"):
                    let name = (block["name"] as? String) ?? "tool"
                    out.append(PreviewEntry(id: id, kind: .tools([toolLabel(name, block["input"] as? [String: Any] ?? [:])]), text: ""))
                case ("assistant", "text"):
                    if let text = block["text"] as? String {
                        out.append(PreviewEntry(id: id, kind: .reply, text: text))
                    }
                default:
                    continue
                }
            }
        }
        return out
    }

    // MARK: Codex

    private func codex(_ id: String) -> [PreviewEntry] {
        if let path = CodexFeed.latestSQLite(prefix: "thread_history_") {
            let items = codexItems(at: path, thread: id)
            if !items.isEmpty { return items }
        }
        // Not paginated into thread history yet: the rollout file the thread names.
        guard let state = CodexFeed.latestSQLite(prefix: "state_"),
              let rollout = codexRolloutPath(at: state, thread: id) else { return [] }
        return Self.parseCodexRollout(Self.objects(Self.tailLines(of: URL(fileURLWithPath: rollout), bytes: 512 * 1024)))
    }

    // A WAL database with no -wal file opens read-only but fails on the first
    // read; the immutable open then reads the main file as it is.
    private func codexItems(at path: String, thread: String) -> [PreviewEntry] {
        for immutable in [false, true] {
            if let items = codexItems(at: path, thread: thread, immutable: immutable) { return items }
        }
        return []
    }

    private func codexItems(at path: String, thread: String, immutable: Bool) -> [PreviewEntry]? {
        var error: String?
        guard let db = CodexFeed.openReadOnly(path: path, immutable: immutable, errorOut: &error) else { return nil }
        defer { sqlite3_close(db) }
        let sql = "SELECT item_id, item_type, item_json FROM thread_items WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 40"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, thread, -1, sqliteTransient)

        var out: [PreviewEntry] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            let id = CodexFeed.text(statement, 0)
            let type = CodexFeed.text(statement, 1)
            guard let item = (try? JSONSerialization.jsonObject(with: Data(CodexFeed.text(statement, 2).utf8))) as? [String: Any],
                  let entry = Self.codexEntry(id: id, type: type, item: item) else { continue }
            out.append(entry)
        }
        return out.reversed()
    }

    private func codexRolloutPath(at path: String, thread: String) -> String? {
        for immutable in [false, true] {
            var error: String?
            guard let db = CodexFeed.openReadOnly(path: path, immutable: immutable, errorOut: &error) else { continue }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = ?", -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, thread, -1, sqliteTransient)
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { continue }
            let rollout = CodexFeed.text(statement, 0)
            return rollout.isEmpty ? nil : rollout
        }
        return nil
    }

    private static func codexEntry(id: String, type: String, item: [String: Any]) -> PreviewEntry? {
        switch type {
        case "userMessage":
            let text = strings(item["content"]).joined(separator: "\n")
            return text.isEmpty ? nil : PreviewEntry(id: id, kind: .user, text: myRequest(text))
        case "reasoning":
            var parts = strings(item["content"])
            if parts.isEmpty { parts = strings(item["summary"]) }
            let text = distinct(parts).joined(separator: "\n")
            return text.isEmpty ? nil : PreviewEntry(id: id, kind: .thinking, text: text)
        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return PreviewEntry(id: id, kind: .reply, text: text)
        case "commandExecution":
            return tool(id, "Bash", shortCommand(item["command"] as? String ?? ""))
        case "fileChange":
            let names = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            return tool(id, "Edit", names.joined(separator: ", "))
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            return tool(id, (item["tool"] as? String) ?? type, "")
        case "webSearch":
            return tool(id, "Search", item["query"] as? String ?? "")
        case "imageView", "imageGeneration":
            return tool(id, type == "imageView" ? "View image" : "Generate image", "")
        case "plan":
            return tool(id, "Plan", "")
        case "subAgentActivity":
            return tool(id, "Subagent", "")
        default:
            return nil
        }
    }

    private static func parseCodexRollout(_ lines: [[String: Any]]) -> [PreviewEntry] {
        var out: [PreviewEntry] = []
        for (index, line) in lines.enumerated() {
            guard line["type"] as? String == "response_item", let payload = line["payload"] as? [String: Any] else { continue }
            let id = "r\(index)"
            switch payload["type"] as? String {
            case "message":
                let text = strings(payload["content"]).joined(separator: "\n")
                guard !text.isEmpty else { continue }
                if payload["role"] as? String == "user" {
                    if !isMarkup(text), !text.hasPrefix("# AGENTS.md") {
                        out.append(PreviewEntry(id: id, kind: .user, text: myRequest(text)))
                    }
                } else if payload["role"] as? String == "assistant" {
                    out.append(PreviewEntry(id: id, kind: .reply, text: text))
                }
            case "reasoning":
                let text = distinct(strings(payload["summary"])).joined(separator: "\n")
                if !text.isEmpty { out.append(PreviewEntry(id: id, kind: .thinking, text: text)) }
            case "function_call", "custom_tool_call":
                out.append(PreviewEntry(id: id, kind: .tools([(payload["name"] as? String) ?? "tool"]), text: ""))
            default:
                continue
            }
        }
        return out
    }

    // MARK: Antigravity

    private func antigravity(_ id: String) -> [PreviewEntry] {
        let url = home.appendingPathComponent(".gemini/antigravity/brain/\(id)/.system_generated/logs/transcript.jsonl")
        var out: [PreviewEntry] = []
        for line in Self.objects(Self.tailLines(of: url, bytes: 512 * 1024)) {
            let step = (line["step_index"] as? Int).map(String.init) ?? UUID().uuidString
            switch line["type"] as? String {
            case "USER_INPUT":
                guard let content = line["content"] as? String else { continue }
                if let start = content.range(of: "<USER_REQUEST>"),
                   let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex) {
                    out.append(PreviewEntry(id: step, kind: .user, text: String(content[start.upperBound..<end.lowerBound])))
                } else if line["source"] as? String == "USER_EXPLICIT" {
                    out.append(PreviewEntry(id: step, kind: .user, text: content))
                }
            case "PLANNER_RESPONSE":
                if let thinking = line["thinking"] as? String, !thinking.isEmpty {
                    out.append(PreviewEntry(id: "\(step)-t", kind: .thinking, text: thinking))
                }
                let calls = (line["tool_calls"] as? [[String: Any]] ?? []).map { call -> String in
                    let args = (call["args"] as? [String: Any] ?? [:]).mapValues { Self.unquote(String(describing: $0)) }
                    return Self.antigravityToolLabel((call["name"] as? String) ?? "tool", args)
                }
                if !calls.isEmpty { out.append(PreviewEntry(id: "\(step)-c", kind: .tools(calls), text: "")) }
                if let content = line["content"] as? String, !content.isEmpty {
                    out.append(PreviewEntry(id: "\(step)-r", kind: .reply, text: content))
                }
            default:
                continue
            }
        }
        return out
    }

    private static func antigravityToolLabel(_ name: String, _ args: [String: String]) -> String {
        if let summary = args["toolSummary"], !summary.isEmpty { return "\(name) · \(summary)" }
        for key in ["Path", "AbsolutePath", "TargetFile", "DirectoryPath"] {
            if let path = args[key], !path.isEmpty { return "\(name) · \(URL(fileURLWithPath: path).lastPathComponent)" }
        }
        if let command = args["CommandLine"], !command.isEmpty { return "\(name) · \(shortCommand(command))" }
        for key in ["Query", "query", "Url", "url"] {
            if let value = args[key], !value.isEmpty { return "\(name) · \(value)" }
        }
        return name
    }

    // MARK: Shared

    // Merges neighbouring tool steps, trims each text, keeps the last 12 entries.
    static func tidy(_ list: [PreviewEntry]) -> [PreviewEntry] {
        var out: [PreviewEntry] = []
        for entry in list {
            switch entry.kind {
            case .tools(let names):
                let names = names.map { clip($0, 52) }.filter { !$0.isEmpty }
                guard !names.isEmpty else { continue }
                if let last = out.last, case .tools(let earlier) = last.kind {
                    out[out.count - 1] = PreviewEntry(id: last.id, kind: .tools(earlier + names), text: "")
                } else {
                    out.append(PreviewEntry(id: entry.id, kind: .tools(names), text: ""))
                }
            case .thinking:
                let text = clean(entry.text)
                if !text.isEmpty { out.append(PreviewEntry(id: entry.id, kind: .thinking, text: clipLines(text, 600, keepEnd: true))) }
            case .user:
                let text = clean(entry.text)
                if !text.isEmpty { out.append(PreviewEntry(id: entry.id, kind: .user, text: clipLines(text, 1200))) }
            case .reply:
                let text = clean(entry.text)
                if !text.isEmpty { out.append(PreviewEntry(id: entry.id, kind: .reply, text: clipLines(text, 4000))) }
            }
        }
        return out.suffix(12).map { entry in
            guard case .tools(let names) = entry.kind, names.count > 4 else { return entry }
            return PreviewEntry(id: entry.id, kind: .tools(["+\(names.count - 4)"] + names.suffix(4)), text: "")
        }
    }

    static func tailLines(of url: URL, bytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // The first line of a tail read starts mid-record.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { String(data: Data($0), encoding: .utf8) }
    }

    static func objects(_ lines: [String]) -> [[String: Any]] {
        lines.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    private static func tool(_ id: String, _ name: String, _ detail: String) -> PreviewEntry {
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return PreviewEntry(id: id, kind: .tools([detail.isEmpty ? name : "\(name) · \(detail)"]), text: "")
    }

    private static func toolLabel(_ name: String, _ input: [String: Any]) -> String {
        let short = name.hasPrefix("mcp__") ? (name.components(separatedBy: "__").last ?? name) : name
        if let command = input["command"] as? String { return "\(short) · \(shortCommand(command))" }
        for key in ["file_path", "path", "notebook_path"] {
            if let path = input[key] as? String { return "\(short) · \(URL(fileURLWithPath: path).lastPathComponent)" }
        }
        for key in ["pattern", "query", "url", "description"] {
            if let value = input[key] as? String, !value.isEmpty { return "\(short) · \(value)" }
        }
        return short
    }

    private static func strings(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["text"] as? String) }
    }

    // Codex often repeats a reasoning summary line; each shows once.
    private static func distinct(_ parts: [String]) -> [String] {
        var seen: Set<String> = []
        return parts.compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    // Codex Desktop wraps the prompt after "## My request:" when files are attached.
    private static func myRequest(_ text: String) -> String {
        guard let marker = text.range(of: "## My request:") else { return text }
        return String(text[marker.upperBound...])
    }

    // Harness-injected user text: reminders, command echoes, environment blocks.
    private static func isMarkup(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<")
    }

    private static func shortCommand(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["/bin/bash -lc ", "/bin/zsh -lc ", "bash -lc ", "zsh -lc "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        if let first = text.first, first == "\"" || first == "'" { text.removeFirst() }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    // Antigravity stores each tool argument JSON-encoded ("\"List files\"").
    private static func unquote(_ text: String) -> String {
        guard text.hasPrefix("\""),
              let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) as? String
        else { return text }
        return value
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<system-reminder>[\\s\\S]*?</system-reminder>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clip(_ text: String, _ limit: Int, keepEnd: Bool = false) -> String {
        guard text.count > limit else { return text }
        return keepEnd ? "…" + String(text.suffix(limit)) : String(text.prefix(limit)) + "…"
    }

    // Cuts at whole lines, so markdown is never left half open: the start of
    // the text (a reply) or its end (thinking), marked with a line of "…".
    static func clipLines(_ text: String, _ limit: Int, keepEnd: Bool = false) -> String {
        guard text.count > limit else { return text }
        var lines = text.components(separatedBy: "\n")
        if keepEnd { lines.reverse() }
        var kept: [String] = []
        var count = 0
        for line in lines {
            if count + line.count + 1 > limit { break }
            kept.append(line)
            count += line.count + 1
        }
        // One line longer than the limit: cut inside it, closing what it opened.
        if kept.isEmpty, let first = lines.first {
            kept = [balanced(keepEnd ? String(first.suffix(limit)) : String(first.prefix(limit)))]
        }
        if keepEnd { return "…\n" + kept.reversed().joined(separator: "\n") }
        return kept.joined(separator: "\n") + "\n…"
    }

    // Drops a dangling ** or ` left by a cut.
    private static func balanced(_ text: String) -> String {
        var out = text
        if out.components(separatedBy: "**").count % 2 == 0, let last = out.range(of: "**", options: .backwards) {
            out.removeSubrange(last)
        }
        if out.filter({ $0 == "`" }).count % 2 == 1, let last = out.range(of: "`", options: .backwards) {
            out.removeSubrange(last)
        }
        return out
    }
}
