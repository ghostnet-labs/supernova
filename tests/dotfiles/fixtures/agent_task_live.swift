import Foundation

/// Opt-in live check. Uses the existing CLI authentication, no production app data.
/// Run explicitly with a new disposable directory; normal repository tests do not invoke it.
@main struct TaskLiveFixture {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AgentDatabase(directory: directory.appendingPathComponent("state"))
        let memory = ProjectMemoryStore(database: database)
        let project = try await memory.attachProject(path: directory.path, name: "M5 disposable delegation probe")
        let context = ManagedConversationContext(projectID: project.id, name: project.name, cwd: directory.path)
        let parent = ManagedConversationStore(context: context, database: database)
        let coordinator = CoordinatorRegistry.attach(parent: parent)
        coordinator.allowResearch = true
        coordinator.allowImplementation = false
        await coordinator.load(); await parent.load()
        if ProcessInfo.processInfo.environment["ACC_LIVE_CLEANUP"] == "1" {
            try await parent.client.connect()
            for task in coordinator.tasks { if let id = task.nativeThreadID { _ = try await parent.client.request("thread/archive", .object(["threadId": .string(id)])) } }
            if let id = parent.threadID { _ = try await parent.client.request("thread/archive", .object(["threadId": .string(id)])) }
            await ManagedConversationRegistry.shutdown()
            print("Archived disposable probe threads")
            return
        }
        let instruction = "Delegate exactly two read-only tasks using acc_task_create. First objective: submit the text M5_ALPHA using acc_task_report; completion check outputContains M5_ALPHA. Second objective: submit M5_BETA using acc_task_report; completion check outputContains M5_BETA. Deliverables are those literal markers. No commands, file access, edits, web requests, other agents, or other tools are needed. After creating them, end your turn and wait for their results. When a result arrives, acknowledge that marker briefly without delegating more tasks."
        let start = Date()
        await parent.send(instruction)
        var success = false
        var failure = ""
        for index in 0..<3_600 {
            // A live probe never grants an incidental permission request.
            for request in parent.requests {
                if request.method.contains("requestApproval") { parent.respond(request, result: .object(["decision": .string("decline")])) }
            }
            for request in coordinator.requests {
                if request.method.contains("requestApproval") { await coordinator.respond(request, result: .object(["decision": .string("decline")])) }
            }
            if index % 100 == 0 {
                print("elapsed=\(Int(Date().timeIntervalSince(start)))s parent=\(parent.status) tasks=\(coordinator.tasks.map { $0.state.rawValue }.joined(separator: ",")) error=\(coordinator.error ?? parent.error ?? "none")")
            }
            await coordinator.deliverResults()
            let results = try await coordinator.store.deliveries()
            if coordinator.tasks.count == 2, coordinator.tasks.allSatisfy({ $0.state == .completed }), results.count == 2,
               results.allSatisfy({ $0.state == "Delivered" }), parent.canSend {
                let messages = parent.messages.filter { $0.role == "task" }
                guard messages.count == 2 else { failure = "Expected exactly two parent result messages."; break }
                let ids = Set(messages.map(\.id))
                guard ids.count == 2 else { failure = "Duplicate parent result identity."; break }
                await coordinator.deliverResults()
                guard parent.messages.filter({ $0.role == "task" }).count == 2 else { failure = "Repeated delivery duplicated a result."; break }
                success = true; break
            }
            if coordinator.tasks.contains(where: { [.failed, .unknown].contains($0.state) }) || parent.needsReconciliation { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let tasks = coordinator.tasks
        let results = try await coordinator.store.deliveries()
        let evidence: RPCValue = .object([
            "passed": .bool(success), "elapsedSeconds": .number(Date().timeIntervalSince(start)),
            "failure": .string(failure),
            "parentThreadID": parent.threadID.map(RPCValue.string) ?? .null,
            "tasks": .array(tasks.map { .object(["id": .string($0.id), "threadID": $0.nativeThreadID.map(RPCValue.string) ?? .null, "state": .string($0.state.rawValue), "result": .string($0.deliverable?.content ?? ""), "independentlyVerified": .bool($0.independentlyVerified)]) }),
            "deliveryCount": .number(Double(results.count)), "parentResultCount": .number(Double(parent.messages.filter { $0.role == "task" }.count)),
            "parentAssistantMessages": .array(parent.messages.filter { $0.role == "assistant" }.map { .string($0.text) }),
            "parentError": parent.error.map(RPCValue.string) ?? .null, "taskError": coordinator.error.map(RPCValue.string) ?? .null
        ])
        try JSONEncoder().encode(evidence).write(to: directory.appendingPathComponent("evidence.json"))
        for task in tasks { if let id = task.nativeThreadID { _ = try? await coordinator.client.request("thread/archive", .object(["threadId": .string(id)])) } }
        if let id = parent.threadID { _ = try? await parent.client.request("thread/archive", .object(["threadId": .string(id)])) }
        await ManagedConversationRegistry.shutdown()
        guard success else { throw AgentStorageError.invalid("Live delegation probe did not meet all checks. Inspect evidence.json.") }
        print("PASS: live coordinator created two separate child threads, validated both deliverables, and incorporated each result once using existing CLI authentication.")
    }
}
