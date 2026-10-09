import Foundation

enum ManagedTaskState: String, Codable, CaseIterable {
    case queued = "Queued", running = "Running", needsInput = "Needs input", paused = "Paused"
    case completed = "Completed", failed = "Failed", cancelled = "Cancelled", unknown = "Unknown"
    var terminal: Bool { [.completed, .failed, .cancelled].contains(self) }
}
enum ManagedTaskMode: String, Codable, CaseIterable { case research = "Read only", implementation = "Isolated writes" }
enum TaskCheckKind: String, Codable, CaseIterable { case outputContains, commandSucceeded, fileExists }
struct TaskCompletionCheck: Codable, Equatable, Identifiable {
    var id: String
    var description: String
    var kind: TaskCheckKind
    var target: String
}
struct TaskObservedEvidence: Codable, Equatable {
    var itemID: String
    var kind: String
    var detail: String
    var succeeded: Bool
}
struct TaskCheckResult: Codable, Equatable {
    var checkID: String
    var passed: Bool
    var evidence: String
}
struct TaskDeliverable: Codable, Equatable {
    var summary: String
    var content: String
    var files: [String]
    var checks: [TaskCheckResult]
    var submittedAt = Date()
}
struct TaskDispatch: Codable, Equatable {
    var id: String
    var phase: String = "Prepared"
    var nativeThreadID: String?
    var nativeTurnID: String?
    var instruction: String
    var createdAt = Date()
}
struct ManagedTaskRecord: Codable, Equatable, Identifiable {
    var schemaVersion = 1
    var id: String
    var projectID: String
    var parentThreadID: String
    var humanMessageID: String
    var humanInstruction: String
    var objective: String
    var expectedDeliverable: String
    var checks: [TaskCompletionCheck]
    var mode: ManagedTaskMode
    var provider = "Codex"
    var state: ManagedTaskState = .queued
    var cwd: String
    var baseCWD: String
    var managedWorktree = false
    var branch: String?
    var selectedWorktree = false
    var nativeThreadID: String?
    var nativeTurnID: String?
    var dispatch: TaskDispatch?
    var dispatchHistory: [TaskDispatch] = []
    var completedTurnIDs: [String] = []
    var continuationInstruction = ""
    var latestUpdate = "Waiting to dispatch"
    var lastAssistantText = ""
    var evidence: [TaskObservedEvidence] = []
    var deliverable: TaskDeliverable?
    var independentlyVerified = false
    var verificationEvidence = ""
    var recoveryRequired = false
    var cancellationRequested = false
    var createdAt = Date()
    var updatedAt = Date()
}
struct TaskToolCall: Codable {
    var key: String
    var arguments: String
    var response: RPCValue?
    var createdAt = Date()
}
struct TaskResultDelivery: Codable, Identifiable {
    var id: String // One durable result per task; replay cannot mint another delivery.
    var taskID: String
    var parentThreadID: String
    var state = "Queued"
    var messageID: String
    var turnID: String?
    var text: String
    var createdAt = Date()
}

/// Task state and side-effect intents share the app's serialized SQLite connection.
/// A reserved tool call or dispatch is never repeated automatically after an unknown outcome.
actor TaskStore {
    let database: AgentDatabase
    let projectID: String
    init(database: AgentDatabase, projectID: String) { self.database = database; self.projectID = projectID }
    private var namespace: String { "tasks.v1:" + projectID }
    private var callsNamespace: String { "task-calls.v1:" + projectID }
    private var deliveriesNamespace: String { "task-deliveries.v1:" + projectID }

    func records() async throws -> [ManagedTaskRecord] {
        let namespace = namespace
        return try await database.read { db in
            try db.query("SELECT json FROM managed_records WHERE namespace=?", [namespace]).map {
                let record = try Self.decode(ManagedTaskRecord.self, $0["json"]!)
                guard record.schemaVersion == 1 else { throw AgentStorageError.invalid("These tasks require a newer Agent Control Center.") }
                return record
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    func record(_ id: String) async throws -> ManagedTaskRecord? {
        let namespace = namespace
        return try await database.read { db in try Self.get(ManagedTaskRecord.self, db, namespace, id) }
    }
    func create(_ task: ManagedTaskRecord) async throws {
        guard task.projectID == projectID, UUID(uuidString: task.id) != nil,
              !task.objective.isEmpty, !task.expectedDeliverable.isEmpty, !task.checks.isEmpty else {
            throw AgentStorageError.invalid("A task needs an objective, a deliverable, and completion checks in this project.")
        }
        let namespace = namespace
        try await database.transaction { db in
            guard try Self.get(ManagedTaskRecord.self, db, namespace, task.id) == nil else { return }
            try Self.put(task, db, namespace, task.id)
        }
    }
    func reserveWriter(path: String, taskID: String) async throws {
        let path = MemoryRepositoryIdentity.canonical(path)
        try await database.transaction { db in
            let owner = try Self.get(String.self, db, "task-writers.v1", path)
            guard owner == nil || owner == taskID else { throw AgentStorageError.invalid("This checkout belongs to a different managed writer. Select a separate worktree.") }
            try Self.put(taskID, db, "task-writers.v1", path)
        }
    }
    @discardableResult func update(_ id: String, _ body: (inout ManagedTaskRecord) throws -> Void) async throws -> ManagedTaskRecord {
        let namespace = namespace
        return try await database.transaction { db in
            guard var task = try Self.get(ManagedTaskRecord.self, db, namespace, id) else { throw AgentStorageError.invalid("Task no longer exists.") }
            try body(&task); task.updatedAt = Date()
            try Self.put(task, db, namespace, id)
            return task
        }
    }
    /// Restart is a checkpoint, never an implicit permission to continue execution.
    func restore() async throws {
        let namespace = namespace
        try await database.transaction { db in
            for row in try db.query("SELECT key,json FROM managed_records WHERE namespace=?", [namespace]) {
                var task = try Self.decode(ManagedTaskRecord.self, row["json"]!)
                guard !task.state.terminal else { continue }
                task.recoveryRequired = true
                if task.state == .running || task.state == .unknown || task.cancellationRequested || task.dispatch?.phase == "Starting turn" || task.dispatch?.phase == "Creating thread" {
                    task.state = .unknown; task.latestUpdate = "Execution stopped or disconnected. Reconcile before continuing."
                } else { task.state = .paused; task.latestUpdate = "Saved task. Continue explicitly when ready." }
                try Self.put(task, db, namespace, task.id)
            }
        }
    }
    /// Returns an existing call when replayed; nil means this invocation now owns the reservation.
    func reserveCall(key: String, arguments: String) async throws -> TaskToolCall? {
        let namespace = callsNamespace
        return try await database.transaction { db in
            if let old = try Self.get(TaskToolCall.self, db, namespace, key) {
                guard old.arguments == arguments else { throw AgentStorageError.invalid("A repeated tool call changed its arguments.") }
                return old
            }
            try Self.put(TaskToolCall(key: key, arguments: arguments), db, namespace, key)
            return nil
        }
    }
    func finishCall(key: String, response: RPCValue) async throws {
        let namespace = callsNamespace
        try await database.transaction { db in
            guard var call = try Self.get(TaskToolCall.self, db, namespace, key) else { throw AgentStorageError.invalid("The tool call was not reserved.") }
            call.response = response; try Self.put(call, db, namespace, key)
        }
    }
    func finishTurn(taskID: String, turnID: String, status: String) async throws {
        let namespace = namespace, deliveries = deliveriesNamespace
        try await database.transaction { db in
            guard var task = try Self.get(ManagedTaskRecord.self, db, namespace, taskID), task.nativeTurnID == turnID,
                  !task.completedTurnIDs.contains(turnID) else { return }
            task.completedTurnIDs.append(turnID)
            if task.cancellationRequested, ["completed", "failed", "interrupted"].contains(status) {
                task.state = .cancelled; task.recoveryRequired = false; task.dispatch?.phase = "Finished"
                task.latestUpdate = "Cancellation confirmed: provider turn stopped"
                try Self.put(task, db, namespace, taskID); return
            }
            if task.state.terminal { try Self.put(task, db, namespace, taskID); return }
            task.dispatch?.phase = "Finished"
            task.recoveryRequired = false
            if status == "completed", let report = task.deliverable,
               !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               task.checks.allSatisfy({ check in report.checks.contains { $0.checkID == check.id && $0.passed && !$0.evidence.isEmpty } }) {
                task.state = .completed; task.latestUpdate = report.summary
                let id = task.id + ":result-v1"
                if try Self.get(TaskResultDelivery.self, db, deliveries, id) == nil {
                    let checks = report.checks.map { "\($0.checkID): \($0.evidence)" }.joined(separator: "\n")
                    let text = "Task \(task.id): \(task.objective)\n\(report.summary)\n\n\(report.content)\n\nCompletion evidence:\n\(checks)\nIndependent verification: not performed.\nWorking directory: \(task.cwd)"
                    let delivery = TaskResultDelivery(id: id, taskID: task.id, parentThreadID: task.parentThreadID, messageID: UUID().uuidString.lowercased(), text: Self.deliveryText(text, taskID: task.id))
                    try Self.put(delivery, db, deliveries, id)
                }
            } else if status == "failed" {
                task.state = .failed; task.latestUpdate = "Provider failed. Inspect the saved result and continue explicitly."
            } else if status == "interrupted" {
                if task.state != .cancelled { task.state = .paused; task.latestUpdate = "Interrupted. Saved context can be continued." }
            } else if status == "completed" {
                task.state = .needsInput; task.latestUpdate = "The turn ended without a deliverable and passing completion evidence. Review or continue."
            } else { task.state = .unknown; task.recoveryRequired = true; task.latestUpdate = "Unrecognized provider outcome. Reconcile before continuing." }
            task.updatedAt = Date(); try Self.put(task, db, namespace, taskID)
        }
    }
    func deliveries() async throws -> [TaskResultDelivery] {
        let namespace = deliveriesNamespace
        return try await database.read { db in try db.query("SELECT json FROM managed_records WHERE namespace=? ORDER BY key", [namespace]).map { try Self.decode(TaskResultDelivery.self, $0["json"]!) } }
    }
    func updateDelivery(_ id: String, state: String, turnID: String? = nil) async throws {
        let namespace = deliveriesNamespace
        try await database.transaction { db in
            guard var delivery = try Self.get(TaskResultDelivery.self, db, namespace, id) else { return }
            delivery.state = state; delivery.turnID = turnID ?? delivery.turnID
            try Self.put(delivery, db, namespace, id)
        }
    }
    static func deliveryText(_ text: String, taskID: String) -> String {
        guard text.utf8.count > 48_000 else { return text }
        var excerpt = String(decoding: Data(text.utf8).prefix(47_000), as: UTF8.self)
        while excerpt.utf8.count > 47_000 { excerpt.removeLast() }
        return excerpt + "\n\nDelivery excerpt truncated. The full report and evidence remain saved in this project's Tasks tab, task \(taskID)."
    }
    private static func get<T: Decodable>(_ type: T.Type, _ db: SQLiteConnection, _ namespace: String, _ key: String) throws -> T? {
        guard let json = try db.query("SELECT json FROM managed_records WHERE namespace=? AND key=?", [namespace, key]).first?["json"] else { return nil }
        return try decode(type, json)
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try JSONDecoder().decode(type, from: Data(value.utf8)) }
    private static func put<T: Encodable>(_ value: T, _ db: SQLiteConnection, _ namespace: String, _ key: String) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute("INSERT INTO managed_records(namespace,key,json) VALUES(?,?,?) ON CONFLICT(namespace,key) DO UPDATE SET json=excluded.json", [namespace, key, json])
    }
}
