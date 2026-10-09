import Foundation

enum ProviderHealth: String { case ok, unavailable, error, loading }

struct ProviderSnapshot {
    let source: SessionSource
    let health: ProviderHealth
    let error: String?
    let sessions: [CodexSession]
    let subagents: [CodexSession]
    var refreshIDs: Set<String> = []

    static func decode(_ data: Data, source: SessionSource, registered: [SessionProject] = []) throws -> ProviderSnapshot {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1, object["provider"] as? String == source.executable,
              let healthName = object["health"] as? String, let health = ProviderHealth(rawValue: healthName),
              let rows = object["sessions"] as? [[String: Any]],
              let children = object["active_subagents"] as? [[String: Any]] else {
            throw ProviderError("Invalid \(source.rawValue) snapshot")
        }
        var resolver = ProjectResolver(registered: registered)
        func session(_ row: [String: Any]) throws -> CodexSession {
            func string(_ key: String, _ fallback: String = "") -> String {
                guard let text = row[key] as? String, !text.isEmpty, text != "-" else { return fallback }
                return text
            }
            func number(_ key: String) -> Int? { (row[key] as? NSNumber)?.intValue }
            func date(_ key: String) -> Date { Date(timeIntervalSince1970: (row[key] as? NSNumber)?.doubleValue ?? 0) }
            func identity(_ value: String) -> String { source == .claude ? "claude:" + value : value }
            let nativeID = string("session_id"), path = string("transcript_path")
            guard !nativeID.isEmpty, !path.isEmpty else { throw ProviderError("Snapshot is missing session identity or transcript path") }
            let id = identity(nativeID), cwd = string("cwd", "-")
            var stats = SessionStats()
            stats.records = number("records") ?? 0
            stats.userTurns = number("user_turns") ?? 0
            stats.assistantMessages = number("assistant_messages") ?? 0
            stats.reasoningItems = number("reasoning_items") ?? 0
            stats.toolCalls = number("tool_calls") ?? 0
            stats.taskStarts = number("task_starts") ?? 0
            stats.taskCompletes = number("task_completes") ?? 0
            stats.abortedTurns = number("aborted_turns") ?? 0
            stats.totalTokens = number("tokens_total")
            stats.cachedTokens = number("tokens_cached")
            stats.outputTokens = number("tokens_output")
            stats.reasoningTokens = number("tokens_reasoning")
            stats.contextUsed = number("context_used_tokens")
            stats.contextWindow = number("context_window_tokens")
            stats.contextWindowIsEstimated = row["context_window_is_estimated"] as? Bool ?? false
            stats.fileBytes = number("file_bytes") ?? 0
            let live: LiveContext? = string("liveness") == "OPEN" ? LiveContext(
                pid: number("live_pid") ?? 0, tmuxSocket: string("tmux_socket"), tmuxPane: string("tmux_pane"),
                zellijSession: string("zellij_session"), zellijPane: string("zellij_pane_id")) : nil
            let title = string("title", string("last_user_request", "\(source.rawValue) session")).oneLine(limit: 180)
            var result = CodexSession(
                id: id, path: URL(fileURLWithPath: path), cwd: cwd, project: resolver.resolve(cwd),
                title: title, updatedAt: date("last_activity"), startedAt: date("started_at"), live: live,
                archived: row["archived"] as? Bool ?? false, model: string("model"), reasoning: string("reasoning_effort"),
                branch: string("git_branch"), commit: string("git_commit"), remote: string("git_remote"), cliVersion: string("cli_version"),
                lifecycle: string("status") == "ACTIVE" ? .busy : SessionLifecycle(rawValue: string("status")) ?? .unknown,
                lifecycleStartedAt: date("state_started_at"), lastRequest: string("last_user_request"), stats: stats, agents: [], source: source)
            result.clientType = string("client_type")
            result.rootID = identity(string("root_session_id", nativeID))
            result.parentID = identity(string("parent_thread_id", string("root_session_id", nativeID)))
            result.isSubagent = string("thread_source", "user") != "user" && result.rootID != id
            result.agentLabel = string("table_detail", "Subagent")
            result.fileIdentity = string("file_identity")
            result.fileModifiedNS = string("file_modified_ns", String(number("file_modified_ns") ?? 0))
            return result
        }
        let history = object["subagents"] as? [[String: Any]]
        guard object["subagents"] == nil || history != nil else { throw ProviderError("Invalid subagent history") }
        let subagents = try (history ?? children).map(session)
        var sessions = try rows.map(session)
        guard Set(sessions.map(\.id)).count == sessions.count,
              Set(subagents.map(\.id)).count == subagents.count else { throw ProviderError("Duplicate session identity") }
        for index in sessions.indices {
            sessions[index].agents = subagents.filter { $0.rootID == sessions[index].id }.map {
                AgentNode(id: $0.id, parentID: $0.parentID, nickname: $0.agentLabel, pathLabel: $0.agentLabel,
                          model: $0.model, startedAt: $0.startedAt, updatedAt: $0.updatedAt, active: $0.lifecycle == .busy, depth: 1,
                          status: $0.lifecycle.rawValue)
            }
        }
        return ProviderSnapshot(source: source, health: health, error: object["error"] as? String, sessions: sessions, subagents: subagents,
                                refreshIDs: Set(object["refresh_ids"] as? [String] ?? []))
    }
}

struct ProviderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension SessionSource {
    var command: String { executable + "-sessions" }
    var overrideVariable: String { Self.environmentPrefix + (self == .codex ? "_SESSIONS_BIN" : "_CLAUDE_SESSIONS_BIN") }

    func commandURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env[overrideVariable], Shell.executable(command),
                          env["SETUP_DIR"].map { $0 + "/dotfiles/.bin/" + command },
                          NSHomeDirectory() + "/dev/supernova/dotfiles/.bin/" + command].compactMap { $0 }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ProviderError("\(command) is unavailable")
        }
        return URL(fileURLWithPath: path)
    }
}

/// One owned, persistent child per provider. All transport state lives on this queue.
final class ProviderClient: @unchecked Sendable {
    private let source: SessionSource
    private let interval: Int
    private let queue = DispatchQueue(label: "AgentControlCenter.provider", qos: .utility)
    private var process: Process?
    private var input: FileHandle?
    private var stopped = false
    private var generation = 0
    private var retry: TimeInterval = 1
    private var baseline = true
    private var receivedAt = Date()
    private var registered: [SessionProject] = []
    var onSnapshot: ((ProviderSnapshot, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    init(source: SessionSource, interval: Int) { self.source = source; self.interval = interval }

    func start() { queue.async { self.registered = CodexData.projectRoots(); self.launch() } }

    func refresh(requestID: String = "refresh") {
        queue.async {
            guard !self.stopped else { return }
            if var data = try? JSONSerialization.data(withJSONObject: ["command": "refresh", "request_id": requestID]) {
                data.append(10)
                try? self.input?.write(contentsOf: data)
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            generation += 1
            try? input?.close()
            input = nil
            if let process, process.isRunning {
                signal(process, SIGTERM)
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { signal(process, SIGKILL) }
                process.waitUntilExit()
            }
            process = nil
        }
    }

    private func signal(_ process: Process, _ value: Int32) {
        let pid = process.processIdentifier
        kill(getpgid(pid) == pid ? -pid : pid, value)
    }

    private func launch() {
        guard !stopped else { return }
        generation += 1
        let token = generation
        baseline = true
        receivedAt = Date()
        let child = Process(), output = Pipe(), stdin = Pipe()
        do {
            child.executableURL = try source.commandURL()
            child.arguments = ["--stream-json", "--interval", String(interval)]
            child.standardInput = stdin
            child.standardOutput = output
            child.standardError = FileHandle.standardError
            try child.run()
            process = child
            input = stdin.fileHandleForWriting
            // Blocking reads happen off the transport queue; stop and refresh remain responsive.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var pending = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    if pending.count > 128 * 1024 * 1024 { child.terminate(); break }
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        self?.queue.async { [weak self] in self?.receive(line, token: token) }
                    }
                }
                child.waitUntilExit()
                self?.queue.async { [weak self] in
                    guard let self, token == self.generation, !self.stopped else { return }
                    self.process = nil
                    self.input = nil
                    self.failed("\(self.source.command) exited (\(child.terminationStatus))")
                }
            }
            watch(token: token)
        } catch { failed(error.localizedDescription) }
    }

    private func receive(_ data: Data, token: Int) {
        guard token == generation, !stopped else { return }
        do {
            let snapshot = try ProviderSnapshot.decode(data, source: source, registered: registered)
            receivedAt = Date()
            let isBaseline = baseline
            baseline = snapshot.health != .ok
            retry = 1
            onSnapshot?(snapshot, isBaseline)
        } catch {
            baseline = true
            onFailure?(error.localizedDescription)
            if let process { signal(process, SIGTERM) }
        }
    }

    private func watch(token: Int) {
        queue.asyncAfter(deadline: .now() + Double(interval) + 30) { [weak self] in
            guard let self, token == self.generation, !self.stopped else { return }
            if Date().timeIntervalSince(self.receivedAt) > Double(self.interval) + 30 {
                self.onFailure?("\(self.source.command) stopped responding")
                self.baseline = true
                if let process = self.process { self.signal(process, SIGKILL) }
            } else { self.watch(token: token) }
        }
    }

    private func failed(_ message: String) {
        guard !stopped else { return }
        baseline = true
        onFailure?(message)
        let delay = retry
        retry = min(30, retry * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }
}
