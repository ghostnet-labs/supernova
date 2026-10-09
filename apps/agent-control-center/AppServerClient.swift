import Foundation

/// Lossless JSON values keep experimental protocol fields intact, including approval choices.
enum RPCValue: Codable, Hashable, Sendable {
    case object([String: RPCValue]), array([RPCValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([RPCValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: RPCValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> RPCValue { if case .object(let value) = self { return value[key] ?? .null }; return .null }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var array: [RPCValue] { if case .array(let value) = self { return value }; return [] }
    var object: [String: RPCValue] { if case .object(let value) = self { return value }; return [:] }
    var text: String { guard let data = try? JSONEncoder().encode(self) else { return "null" }; return String(decoding: data, as: UTF8.self) }
}

struct AppServerRequest: Identifiable, Hashable {
    let generation: UUID
    let requestID: RPCValue
    let method: String
    let params: RPCValue
    var id: String { generation.uuidString + ":" + requestID.text }
    var threadID: String? { params["threadId"].string }
    var turnID: String? { params["turnId"].string }
}

enum AppServerError: LocalizedError {
    case unavailable(String), protocolError(String), remote(RPCValue), disconnected, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable(let text), .protocolError(let text): return text
        case .remote(let value): return value["message"].string ?? value.text
        case .disconnected: return "The Codex connection ended. The outcome may be unknown; reconcile before sending again."
        case .timeout: return "Codex did not acknowledge this request in time. Reconcile before sending again."
        }
    }
}

/// Installed protocol 0.160.1 adapter. Requests are explicitly allowlisted; no direct execution endpoints.
@MainActor final class AppServerClient {
    static let protocolVersion = "codex-app-server-0.160.1"
    static let maximumFrameBytes = 8 * 1_024 * 1_024
    static let allowedMethods: Set<String> = ["initialize", "thread/start", "thread/resume", "thread/read", "thread/list", "thread/turns/list", "thread/items/list", "thread/archive", "turn/start", "turn/steer", "turn/interrupt"]
    private(set) var generation = UUID()
    private(set) var isConnected = false
    private(set) var diagnostic = ""
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var pending: [String: CheckedContinuation<RPCValue, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var serverRequests: [String: AppServerRequest] = [:]
    private var responses: [String: RPCValue] = [:]
    private var answeredRequests: [String: AppServerRequest] = [:]
    private var responseOrder: [String] = []
    private let writeQueue = DispatchQueue(label: "local.agent-control-center.codex-stdin")
    private var queuedWriteBytes = 0
    private var observers: [UUID: (String, RPCValue) -> Void] = [:]
    private var requestObservers: [UUID: (AppServerRequest) -> Void] = [:]
    private var disconnectObservers: [UUID: () -> Void] = [:]
    /// A fixture writer bypasses Process while exercising the same framing and routing.
    var fixtureWrite: ((Data) throws -> Void)?

    @discardableResult func observe(events: @escaping (String, RPCValue) -> Void,
                                     requests: @escaping (AppServerRequest) -> Void,
                                     disconnected: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = events; requestObservers[id] = requests; disconnectObservers[id] = disconnected
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil; requestObservers[id] = nil; disconnectObservers[id] = nil }

    static func executableURL() throws -> URL {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw AppServerError.unavailable("Codex CLI is unavailable. Install it and sign in using the CLI, then reconnect.")
    }

    func connect(executable: URL? = nil) async throws {
        if isConnected { return }
        guard process == nil else { throw AppServerError.unavailable("Codex is still connecting.") }
        generation = UUID(); buffer.removeAll(); responses.removeAll(); answeredRequests.removeAll(); responseOrder.removeAll(); diagnostic = ""
        if fixtureWrite == nil {
            let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            child.executableURL = try executable ?? Self.executableURL()
            child.arguments = ["app-server", "--listen", "stdio://"]
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
            input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
            // A stopped peer must fail the background write, never deliver SIGPIPE to the GUI.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let current = generation
            output?.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                let delivered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { self?.receive(bytes, generation: current); delivered.signal() }
                delivered.wait() // Backpressure: at most one stdout chunk waits for the UI reducer.
            }
            errors?.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                let delivered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    defer { delivered.signal() }
                    guard let self, self.generation == current else { return }
                    self.diagnostic = String((self.diagnostic + String(decoding: bytes, as: UTF8.self)).suffix(8_192))
                }
                delivered.wait()
            }
            child.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.connectionEnded(generation: current) } }
            process = child
            do { try child.run() } catch { connectionEnded(generation: current); throw error }
        }
        do {
            _ = try await request("initialize", .object([
                "clientInfo": .object(["name": .string("agent_control_center"), "title": .string("Agent Control Center"), "version": .string("1")]),
                "capabilities": .object(["experimentalApi": .bool(true)])
            ]))
            try write(.object(["method": .string("initialized")]))
            isConnected = true
        } catch { stop(); throw error }
    }

    func request(_ method: String, _ params: RPCValue, timeout: TimeInterval = 30) async throws -> RPCValue {
        guard Self.allowedMethods.contains(method) else { throw AppServerError.protocolError("Unsupported App Server method: \(method)") }
        guard input != nil || fixtureWrite != nil else { throw AppServerError.disconnected }
        guard pending.count < 128 else { throw AppServerError.protocolError("Too many pending Codex requests.") }
        sequence += 1
        let id = String(sequence)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000)) } catch { return }
                self?.finish(id, .failure(AppServerError.timeout))
            }
            do { try write(.object(["id": .string(id), "method": .string(method), "params": params])) }
            catch { finish(id, .failure(error)) }
        }
    }

    /// Generation and exact server request identity prevent a stale approval from answering a new process.
    func respond(to request: AppServerRequest, result: RPCValue) throws {
        guard request.generation == generation, serverRequests[request.id] == request else {
            throw AppServerError.protocolError("This Codex request is no longer pending.")
        }
        let response = RPCValue.object(["id": request.requestID, "result": result])
        try write(response)
        serverRequests[request.id] = nil
        responses[request.id] = response; responseOrder.append(request.id)
        answeredRequests[request.id] = request
        if responseOrder.count > 512 { let oldest = responseOrder.removeFirst(); responses[oldest] = nil; answeredRequests[oldest] = nil }
    }

    func receive(_ bytes: Data, generation current: UUID) {
        guard current == generation else { return }
        guard !bytes.isEmpty else { connectionEnded(generation: current); return }
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 10) {
            let frame = buffer[..<end]; buffer.removeSubrange(...end)
            guard frame.count <= Self.maximumFrameBytes else { failProtocol("A Codex frame exceeded the 8 MiB limit."); return }
            if frame.isEmpty { continue }
            do { route(try JSONDecoder().decode(RPCValue.self, from: frame)) }
            catch { failProtocol("Codex sent invalid JSON."); return }
        }
        if buffer.count > Self.maximumFrameBytes { failProtocol("A Codex frame exceeded the 8 MiB limit.") }
    }

    private func route(_ frame: RPCValue) {
        if let method = frame["method"].string {
            if frame["id"] != .null {
                let request = AppServerRequest(generation: generation, requestID: frame["id"], method: method, params: frame["params"])
                if let prior = responses[request.id] {
                    guard answeredRequests[request.id] == request else { failProtocol("Codex reused a request ID with different contents."); return }
                    try? write(prior); return
                }
                if let pending = serverRequests[request.id] {
                    if pending != request { failProtocol("Codex changed a pending request's contents.") }
                    return
                }
                guard serverRequests.count < 128 else { failProtocol("Too many pending server requests."); return }
                serverRequests[request.id] = request
                for callback in Array(requestObservers.values) { callback(request) }
            } else {
                if method == "serverRequest/resolved" {
                    let key = generation.uuidString + ":" + frame["params"]["requestId"].text
                    serverRequests[key] = nil
                }
                for callback in Array(observers.values) { callback(method, frame["params"]) }
            }
        } else if let id = frame["id"].string {
            if frame["error"] != .null { finish(id, .failure(AppServerError.remote(frame["error"]))) }
            else { finish(id, .success(frame["result"])) }
        }
    }
    private func finish(_ id: String, _ result: Result<RPCValue, Error>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func write(_ value: RPCValue) throws {
        var bytes = try JSONEncoder().encode(value)
        guard bytes.count <= Self.maximumFrameBytes else { throw AppServerError.protocolError("The request exceeds the 8 MiB limit.") }
        bytes.append(10)
        if let fixtureWrite { try fixtureWrite(bytes) }
        else if let input {
            guard queuedWriteBytes + bytes.count <= 16 * 1_024 * 1_024 else { throw AppServerError.protocolError("Codex input queue is full.") }
            queuedWriteBytes += bytes.count
            let current = generation, payload = bytes
            writeQueue.async { [weak self] in
                do {
                    try input.write(contentsOf: payload)
                    DispatchQueue.main.async { guard let self, self.generation == current else { return }; self.queuedWriteBytes -= payload.count }
                } catch {
                    DispatchQueue.main.async { guard let self, self.generation == current else { return }; self.diagnostic = error.localizedDescription; self.connectionEnded(generation: current) }
                }
            }
        }
        else { throw AppServerError.disconnected }
    }
    private func failProtocol(_ message: String) { diagnostic = message; stop() }
    func stop() {
        let child = process
        connectionEnded(generation: generation)
        if child?.isRunning == true {
            child?.terminate()
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        }
    }
    private func connectionEnded(generation current: UUID) {
        guard current == generation else { return }
        let child = process
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; process = nil; isConnected = false
        buffer.removeAll(); serverRequests.removeAll(); queuedWriteBytes = 0
        for id in Array(pending.keys) { finish(id, .failure(AppServerError.disconnected)) }
        generation = UUID()
        if child?.isRunning == true { child?.terminate() }
        for callback in Array(disconnectObservers.values) { callback() }
    }
}
