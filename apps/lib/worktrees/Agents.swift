import Foundation
import SwiftUI

enum AgentKind: Hashable {
    case claude, codex

    /// The name Agent Control Center uses, which also picks the model logo.
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    var sessionsCommand: String { self == .claude ? "claude-sessions" : "codex-sessions" }
    /// Tests point this at a stub so they never read real sessions.
    var overrideVariable: String { self == .claude ? "WORKTREE_MANAGER_CLAUDE_SESSIONS_BIN" : "WORKTREE_MANAGER_SESSIONS_BIN" }

    var command: String? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env[overrideVariable], env["SETUP_DIR"].map { "\($0)/dotfiles/.bin/\(sessionsCommand)" },
                          "\(NSHomeDirectory())/dev/supernova/dotfiles/.bin/\(sessionsCommand)"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A Claude Code or Codex process running in a worktree; a live session names it by its process ID.
struct AgentProcess: Hashable {
    let pid: Int32
    let kind: AgentKind
}

/// A live Claude Code or Codex session as `claude-sessions` and `codex-sessions` report it, with the details Agent
/// Control Center's menu bar shows.
struct AgentSession: Identifiable, Hashable {
    let kind: AgentKind
    let sessionID: String
    let cwd: String
    var title = ""
    /// BUSY, WAITING, INTERRUPTED, IDLE, and so on, with when it entered that state.
    var status = "UNKNOWN"
    var statusSince: Date?
    var lastRequest = ""
    var model = ""
    var effort = ""
    var totalTokens: Int?
    var contextUsed: Int?
    var contextWindow: Int?
    var contextEstimated = false
    /// The process holding the session open: the agent itself, or the Codex app-server for a desktop or editor session.
    var pid: Int32?
    var rootID = ""
    var isSubagent = false
    var label = ""
    var subagents: [AgentSession] = []

    var id: String { "\(kind.name)-\(sessionID)" }

    /// One row of the shared session JSON; nil without a session ID or folder.
    init?(row: [String: Any], kind: AgentKind) {
        func string(_ key: String, _ fallback: String = "") -> String {
            guard let text = row[key] as? String, !text.isEmpty, text != "-" else { return fallback }
            return text
        }
        func number(_ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue ?? (row[key] as? String).flatMap(Double.init) }
        guard !string("session_id").isEmpty, !string("cwd").isEmpty else { return nil }
        (self.kind, sessionID, cwd) = (kind, string("session_id"), string("cwd"))
        lastRequest = string("last_user_request").oneLine(limit: 500)
        title = string("title", lastRequest.isEmpty ? "\(kind.name) session" : lastRequest).oneLine(limit: 180)
        // ACTIVE is codex-sessions' word for busy.
        status = string("status") == "ACTIVE" ? "BUSY" : string("status", "UNKNOWN")
        statusSince = number("state_started_at").map(Date.init(timeIntervalSince1970:))
        (model, effort) = (string("model"), string("reasoning_effort"))
        totalTokens = number("tokens_total").map(Int.init)
        contextUsed = number("context_used_tokens").map(Int.init)
        contextWindow = number("context_window_tokens").map(Int.init)
        contextEstimated = row["context_window_is_estimated"] as? Bool ?? false
        pid = number("live_pid").map { Int32($0) }
        rootID = string("root_session_id", sessionID)
        isSubagent = string("thread_source", "user") != "user" && rootID != sessionID
        label = string("table_detail", string("title", "Subagent")).oneLine(limit: 120)
    }
}

enum AgentSessions {
    /// Live sessions from both tools at once, each top-level one with its subagents. A tool that's missing, slow, or
    /// fails adds nothing; the processes the scan finds still protect its worktrees.
    static func load() -> [AgentSession] {
        let kinds: [AgentKind] = [.codex, .claude]
        var found = [[AgentSession]](repeating: [], count: kinds.count)
        found.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: kinds.count) { results[$0] = load(kinds[$0]) }
        }
        return attachingSubagents(Array(found.joined()))
    }

    static func load(_ kind: AgentKind) -> [AgentSession] {
        // The session JSON can exceed the pipe buffer, and a stalled tool must not stall the scan: reuse the runner
        // that drains before waiting, with a time limit.
        guard let command = kind.command,
              let output = try? GitTool.run(["--json", "--live", "--all", "--limit", "200"], executable: command,
                                            timeout: WorktreeScanner.liveAgentTimeout) else { return [] }
        return parse(output, kind: kind)
    }

    static func parse(_ output: String, kind: AgentKind) -> [AgentSession] {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap { AgentSession(row: $0, kind: kind) }
    }

    /// Subagents sit under the session that started them rather than counting as agents of their own.
    static func attachingSubagents(_ sessions: [AgentSession]) -> [AgentSession] {
        let children = Dictionary(grouping: sessions.filter(\.isSubagent)) { "\($0.kind.name)-\($0.rootID)" }
        return sessions.filter { !$0.isSubagent }.map { session in
            var session = session
            session.subagents = children[session.id] ?? []
            return session
        }
    }
}

/// One live agent under its worktree, with what Agent Control Center's menu bar shows: title, status and its age, and
/// subagents on one line, then the last request, then model, effort, tokens, and context. Everything sits next to what
/// it describes rather than at the row's far edge, and the worktree row already names the repository and branch.
struct AgentRow: View {
    let session: AgentSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("↳").font(.callout).foregroundStyle(.tertiary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail).help(session.title)
                    // The status's age keeps counting between refreshes.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        StatusPill(status: session.status, elapsed: StatusPill.elapsed(since: session.statusSince, until: context.date))
                    }
                    if !session.subagents.isEmpty { subagents }
                }
                if !session.lastRequest.isEmpty && session.lastRequest != session.title {
                    Text(session.lastRequest).font(.caption).lineLimit(1).truncationMode(.tail).help(session.lastRequest)
                }
                SessionMetadata(repository: session.cwd, branch: "", model: session.model, source: session.kind.name, effort: session.effort,
                                totalTokens: session.totalTokens, contextUsed: session.contextUsed, contextWindow: session.contextWindow,
                                contextEstimated: session.contextEstimated, showsLocation: false, contextBarWidth: 80)
            }
        }
    }

    private var subagents: some View {
        let running = session.subagents.filter { $0.status == "BUSY" }.count
        return Text("\(session.subagents.count) subagent\(session.subagents.count == 1 ? "" : "s")" + (running > 0 ? " · \(running) running" : ""))
            .font(.caption).foregroundStyle(.secondary).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .help(session.subagents.map { "\($0.label): \($0.status.capitalized)" }.joined(separator: "\n"))
    }
}
