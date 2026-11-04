import Foundation

enum ProviderHealth: String { case ok, unavailable, error, loading }

struct ProviderSnapshot {
    let source: SessionSource
    let health: ProviderHealth
    let error: String?
    let sessions: [CodexSession]
    let subagents: [CodexSession]
    var refreshIDs: Set<String> = []
    var host = ""
    var endpoint: SessionEndpoint { SessionEndpoint(source: source, host: host) }

    static func decode(_ data: Data, source: SessionSource, registered: [SessionProject] = [], host: String = "", cache: URL? = nil, object supplied: [String: Any]? = nil) throws -> ProviderSnapshot {
        guard let object = try supplied ?? (JSONSerialization.jsonObject(with: data) as? [String: Any]),
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
            func identity(_ value: String) -> String {
                guard !value.isEmpty else { return "" }
                return host.isEmpty ? (source == .claude ? "claude:" + value : value) : "ssh:\(host):\(source.executable):\(value)"
            }
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
            let project = host.isEmpty ? resolver.resolve(cwd) : SessionProject(id: "ssh:\(host):\(cwd)", name: "\(host):\((cwd as NSString).lastPathComponent)", path: cwd)
            guard host.isEmpty || cache != nil else { throw ProviderError("Missing remote transcript cache") }
            var result = CodexSession(
                id: id, path: host.isEmpty ? URL(fileURLWithPath: path) : RemoteSessions.cacheURL(cache!, id: id), cwd: cwd, project: project,
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
            result.sshHost = host
            result.remoteSessionID = host.isEmpty ? "" : nativeID
            result.remoteTranscriptPath = host.isEmpty ? "" : path
            var queuedIDs: Set<String> = []
            result.queuedMessages = (row["queued_messages"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty,
                      let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      queuedIDs.insert(id).inserted else { return nil }
                return QueuedMessage(id: id, text: text, timestamp: ClaudeData.date(item["created_at"]),
                                     isPaused: item["is_paused"] as? Bool ?? false)
            }
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
                                refreshIDs: Set(object["refresh_ids"] as? [String] ?? []), host: host)
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
    private let host: String
    private let sshExecutable: URL
    private let cache = FileManager.default.temporaryDirectory.appendingPathComponent("agent-ssh-" + UUID().uuidString)
    private var cachedIdentities: [URL: String] = [:]
    private var cachedSizes: [URL: UInt64] = [:]
    private var cachedModified: [URL: String] = [:]
    private var reads: [String: (CodexSession, (Result<RemoteTranscriptUpdate, Error>) -> Void)] = [:]
    private var stderr = ""
    private let interval: Int
    private let queue = DispatchQueue(label: "AgentControlCenter.provider", qos: .utility)
    private let writer = DispatchQueue(label: "AgentControlCenter.provider.input", qos: .utility)
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

    init(source: SessionSource, interval: Int, host: String = "", sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")) {
        self.source = source; self.interval = interval; self.host = host; self.sshExecutable = sshExecutable
    }

    func start() { queue.async { self.registered = self.host.isEmpty ? CodexData.projectRoots() : []; self.launch() } }

    func refresh(requestID: String = "refresh") {
        queue.async {
            guard !self.stopped else { return }
            if var data = try? JSONSerialization.data(withJSONObject: ["command": "refresh", "request_id": requestID]) {
                data.append(10)
                self.write(data)
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            failReads("Session monitoring stopped")
            generation += 1
            if let process, process.isRunning {
                signal(process, SIGTERM)
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { signal(process, SIGKILL) }
                process.waitUntilExit()
            }
            try? input?.close()
            input = nil
            process = nil
            try? FileManager.default.removeItem(at: cache)
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
            var bootstrap: Data?
            if host.isEmpty {
                child.executableURL = try source.commandURL()
                child.arguments = ["--stream-json", "--interval", String(interval)]
            } else {
                guard try RemoteSessions.hosts(host) == [host] else { throw ProviderError("Invalid SSH host") }
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let remote = try RemoteSessions.bootstrap(source: source, interval: interval)
                bootstrap = remote.payload
                child.executableURL = sshExecutable
                child.arguments = RemoteSessions.arguments(host: host, command: remote.command)
            }
            child.standardInput = stdin
            child.standardOutput = output
            let errors = Pipe()
            stderr = ""
            child.standardError = errors
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                let message = String(decoding: data, as: UTF8.self)
                self?.queue.async { [weak self] in
                    guard let self, token == self.generation else { return }
                    self.stderr = String((self.stderr + message).suffix(2048))
                }
            }
            try child.run()
            process = child
            input = stdin.fileHandleForWriting
            // Blocking reads happen off the transport queue; stop and refresh remain responsive.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var pending = Data()
                var scanned = pending.startIndex
                // availableData is autoreleased and this loop never returns to GCD, so drain each read.
                while autoreleasepool(invoking: { () -> Bool in
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { return false }
                    pending.append(data)
                    if pending.count > 128 * 1024 * 1024 { child.terminate(); return false }
                    while let newline = pending[scanned...].firstIndex(of: 10) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        scanned = pending.startIndex
                        self?.queue.async { [weak self] in self?.receive(line, token: token) }
                    }
                    scanned = pending.endIndex
                    return true
                }) {}
                child.waitUntilExit()
                self?.queue.async { [weak self] in
                    guard let self, token == self.generation, !self.stopped else { return }
                    self.process = nil
                    self.input = nil
                    self.failed("\(self.source.command) exited (\(child.terminationStatus)). \(self.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            watch(token: token)
            if let bootstrap { write(bootstrap) }
        } catch { failed(error.localizedDescription) }
    }

    private func receive(_ data: Data, token: Int) {
        guard token == generation, !stopped else { return }
        do {
            let object = host.isEmpty ? nil : try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let reply = object, reply["type"] as? String == "transcript" {
                receiveTranscript(reply)
                return
            }
            let snapshot = try ProviderSnapshot.decode(data, source: source, registered: registered, host: host, cache: cache, object: object)
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
        failReads(message)
        baseline = true
        onFailure?(message)
        let delay = retry
        retry = min(30, retry * 2)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    func syncTranscript(_ session: CodexSession, complete: @escaping (Result<RemoteTranscriptUpdate, Error>) -> Void) {
        queue.async {
            guard !self.stopped, self.process?.isRunning == true, self.input != nil else {
                complete(.failure(ProviderError("\(self.host) is disconnected"))); return
            }
            let id = UUID().uuidString
            do {
                let handle = try? FileHandle(forReadingFrom: session.path)
                defer { try? handle?.close() }
                let offset = try handle?.seekToEnd() ?? 0
                try handle?.seek(toOffset: offset - min(offset, 64))
                let anchor = try handle?.read(upToCount: Int(min(offset, 64))) ?? Data()
                var data = try JSONSerialization.data(withJSONObject: ["command": "read_transcript", "request_id": id,
                    "session_id": session.nativeID, "offset": offset, "anchor": anchor.base64EncodedString(),
                    "file_identity": self.cachedIdentities[session.path] ?? "", "file_size": self.cachedSizes[session.path] ?? 0,
                    "file_modified_ns": self.cachedModified[session.path] ?? ""])
                data.append(10)
                self.reads[id] = (session, complete)
                self.write(data)
                self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                    self?.reads.removeValue(forKey: id)?.1(.failure(ProviderError("Remote transcript request timed out")))
                }
            } catch { self.reads.removeValue(forKey: id); complete(.failure(error)) }
        }
    }

    private func receiveTranscript(_ reply: [String: Any]) {
        guard let id = reply["request_id"] as? String, let (session, complete) = reads.removeValue(forKey: id) else { return }
        do {
            if let error = reply["error"] as? String { throw ProviderError(error) }
            guard let start = reply["offset"] as? NSNumber, start.int64Value >= 0,
                  let encoded = reply["data"] as? String, let data = Data(base64Encoded: encoded), data.count <= 4 * 1024 * 1024,
                  let identity = reply["file_identity"] as? String else { throw ProviderError("Invalid remote transcript response") }
            let offset = start.uint64Value
            if !FileManager.default.fileExists(atPath: session.path.path) {
                FileManager.default.createFile(atPath: session.path.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: session.path)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            guard offset == 0 || size == offset else { throw ProviderError("Remote transcript cache changed") }
            if offset == 0 { try handle.truncate(atOffset: 0) }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            cachedIdentities[session.path] = identity
            cachedSizes[session.path] = (reply["file_size"] as? NSNumber)?.uint64Value
            cachedModified[session.path] = reply["file_modified_ns"] as? String
            complete(.success(RemoteTranscriptUpdate(reset: offset == 0, hasMore: reply["has_more"] as? Bool == true)))
        } catch { complete(.failure(error)) }
    }

    private func failReads(_ message: String) {
        let pending = Array(reads.values)
        reads.removeAll()
        for (_, complete) in pending { complete(.failure(ProviderError(message))) }
    }

    private func write(_ data: Data) {
        guard let input else { return }
        let token = generation
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch {
                self?.queue.async { [weak self] in
                    guard let self, token == self.generation, !self.stopped else { return }
                    self.failReads(error.localizedDescription)
                    if let process = self.process { self.signal(process, SIGTERM) }
                }
            }
        }
    }
}

struct RemoteTranscriptUpdate { var reset = false; var hasMore = false }
