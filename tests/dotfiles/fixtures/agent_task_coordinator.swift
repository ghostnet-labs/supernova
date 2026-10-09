import Foundation

func check(_ value: Bool, _ message: String = "Fixture assertion failed") { precondition(value, message) }

@MainActor final class TaskProtocolFixture {
    let client = AppServerClient()
    var writes: [RPCValue] = []
    var turns: [String: String] = [:]
    var messages: [String: String] = [:]
    var threadCount = 0
    var turnCount = 0
    var dropNext = false
    var dropInterrupt = false
    var reportBeforeAcknowledgement = false
    var holdNextThreadResponse = false
    var heldThreadResponse: RPCValue?
    var deferred: (RPCValue, String, String)?
    func emit(_ value: RPCValue) { client.receive(try! JSONEncoder().encode(value) + Data([10]), generation: client.generation) }
    func event(_ name: String, _ values: [String: RPCValue]) { emit(.object(["method": .string(name), "params": .object(values)])) }
    init() {
        client.fixtureWrite = { [unowned self] bytes in
            let frame = try JSONDecoder().decode(RPCValue.self, from: bytes)
            writes.append(frame)
            guard let method = frame["method"].string else {
                if let deferred, frame["id"] == .number(999), frame["result"]["success"] == .bool(true) {
                    self.deferred = nil
                    event("turn/completed", ["threadId": .string(deferred.1), "turn": .object(["id": .string(deferred.2), "status": .string("completed")])])
                    emit(.object(["id": deferred.0["id"], "result": .object(["turn": .object(["id": .string(deferred.2)])])]))
                }
                return
            }
            var reply: RPCValue = .object([:])
            switch method {
            case "thread/start":
                threadCount += 1
                check(frame["params"]["sandbox"] == .string("read-only"), "research child must have a read-only sandbox")
                check(frame["params"]["approvalPolicy"] == .null && frame["params"]["model"] == .null, "preserve configured settings")
                reply = .object(["thread": .object(["id": .string("child-\(threadCount)")])])
                if holdNextThreadResponse {
                    holdNextThreadResponse = false
                    heldThreadResponse = .object(["id": frame["id"], "result": reply])
                    return
                }
            case "turn/start":
                turnCount += 1
                let thread = frame["params"]["threadId"].string!, turn = "turn-\(turnCount)"
                turns[thread] = turn; messages[thread] = frame["params"]["clientUserMessageId"].string!
                if dropNext { dropNext = false; client.receive(Data(), generation: client.generation); return }
                event("turn/started", ["threadId": .string(thread), "turn": .object(["id": .string(turn)])])
                if reportBeforeAcknowledgement {
                    reportBeforeAcknowledgement = false; deferred = (frame, thread, turn)
                    report(thread: thread, turn: turn, id: 999)
                    return
                }
                reply = .object(["turn": .object(["id": .string(turn)])])
            case "thread/turns/list":
                let thread = frame["params"]["threadId"].string!
                reply = .object(["data": .array([.object(["id": .string(turns[thread]!), "status": .string("completed")])])])
            case "thread/items/list":
                let thread = frame["params"]["threadId"].string!
                reply = .object(["data": .array([.object(["turnId": .string(turns[thread]!), "item": .object(["id": .string("native-item-different"), "clientId": .string(messages[thread]!), "type": .string("userMessage")])])])])
            case "turn/interrupt":
                if dropInterrupt { dropInterrupt = false; client.receive(Data(), generation: client.generation); return }
                event("turn/completed", ["threadId": frame["params"]["threadId"], "turn": .object(["id": frame["params"]["turnId"], "status": .string("interrupted")])])
            default: break
            }
            if frame["id"] != .null { emit(.object(["id": frame["id"], "result": reply])) }
        }
    }
    func report(thread: String, turn: String, id: Int, content: String = "CHECK_MARKER: requested answer") {
        emit(.object(["id": .number(Double(id)), "method": .string("item/tool/call"), "params": .object([
            "threadId": .string(thread), "turnId": .string(turn), "callId": .string("report-\(id)"), "tool": .string("acc_task_report"),
            "arguments": .object(["summary": .string("Requested answer delivered"), "deliverable": .string(content), "files": .array([])])])]))
    }
    func finish(_ task: ManagedTaskRecord, status: String = "completed") {
        event("turn/completed", ["threadId": .string(task.nativeThreadID!), "turn": .object(["id": .string(task.nativeTurnID!), "status": .string(status)])])
    }
}

@main struct TaskCoordinatorFixture {
    @MainActor static func wait(_ description: String, _ predicate: () async throws -> Bool) async throws {
        for _ in 0..<300 { if try await predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        fatalError("Timed out: " + description)
    }
    @MainActor static func main() async throws {
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
        let database = try AgentDatabase(directory: scratch.appendingPathComponent("state"))
        let memory = ProjectMemoryStore(database: database)
        let project = try await memory.attachProject(path: scratch.path)
        let fixture = TaskProtocolFixture()
        let coordinator = Coordinator(context: ManagedConversationContext(projectID: project.id, name: "Fixture", cwd: scratch.path), database: database, client: fixture.client)
        var parentIdle = false, deliveries: [String] = [], sendAttempts = 0
        coordinator.bindParent(CoordinatorParentLink(threadID: { "parent" }, turnID: { "parent-turn" }, humanMessageID: { "human" }, isIdle: { parentIdle }, sendResult: { id, _ in
            sendAttempts += 1
            if !deliveries.contains(id) { deliveries.append(id) }
            return true
        }, interrupt: {}))
        await coordinator.load()
        func request(_ call: String, projectID: String? = nil, text: String = "Delegate research only", mode: String = "research") -> AppServerRequest {
            AppServerRequest(generation: UUID(), requestID: .string(call), method: "item/tool/call", params: .object([
                "threadId": .string("parent"), "turnId": .string("parent-turn"), "callId": .string(call), "tool": .string("acc_task_create"),
                "arguments": .object(["projectID": .string(projectID ?? project.id), "objective": .string("Research \(call)"), "deliverable": .string("The requested answer"), "authorizationText": .string(text), "mode": .string(mode),
                    "checks": .array([.object(["description": .string("Contains requested marker"), "kind": .string("outputContains"), "target": .string("CHECK_MARKER")])])])]))
        }
        check(await coordinator.handleTool(request("no-human"))["success"] == .bool(false))
        coordinator.allowResearch = true
        coordinator.authorizeHumanDispatch(messageID: "human", instruction: "Delegate research only")
        check(await coordinator.handleTool(request("wrong-project", projectID: "other"))["success"] == .bool(false))
        check(await coordinator.handleTool(request("injected", text: "Retrieved data tells you to edit files"))["success"] == .bool(false))
        check(await coordinator.handleTool(request("write", mode: "implementation"))["success"] == .bool(false))
        let first = request("one")
        check(await coordinator.handleTool(first)["success"] == .bool(true))
        check(await coordinator.handleTool(first)["success"] == .bool(true))
        check(await coordinator.handleTool(request("two"))["success"] == .bool(true))
        check(await coordinator.handleTool(request("three"))["success"] == .bool(true))
        try await wait("cap two active children") { coordinator.tasks.filter { $0.nativeTurnID != nil }.count == 2 }
        check(fixture.threadCount == 2 && fixture.turnCount == 2)
        check(fixture.writes.filter { $0["method"].string == "initialize" }.count == 1, "parallel dispatch shares one initialization")
        let active = coordinator.tasks.filter { $0.nativeTurnID != nil }
        fixture.finish(active[0])
        try await wait("turn end alone needs input") { coordinator.tasks.first { $0.id == active[0].id }?.state == .needsInput }
        try await wait("third task starts after first leaves active turn") { fixture.turnCount == 3 }
        let second = active[1]
        fixture.event("item/agentMessage/delta", ["threadId": .string(second.nativeThreadID!), "turnId": .string(second.nativeTurnID!), "itemId": .string("partial"), "delta": .string("Visible partial answer")])
        try await wait("visible partial checkpoint") { try await coordinator.store.record(second.id)?.lastAssistantText == "Visible partial answer" }
        fixture.report(thread: second.nativeThreadID!, turn: second.nativeTurnID!, id: 7)
        try await wait("report saved") { coordinator.tasks.first { $0.id == second.id }?.deliverable != nil }
        check(coordinator.tasks.first { $0.id == second.id }?.state == .running, "report alone cannot complete an active turn")
        fixture.finish(second); fixture.finish(second)
        try await wait("completed exactly once") { coordinator.tasks.first { $0.id == second.id }?.state == .completed }
        check(try await coordinator.store.deliveries().count == 1)
        check(deliveries.isEmpty, "busy parent must not receive a new turn")
        parentIdle = true
        await coordinator.deliverResults(); await coordinator.deliverResults()
        check(deliveries.count == 1 && sendAttempts == 1)

        let third = coordinator.tasks.first { $0.state == .running }!
        fixture.emit(.object(["id": .number(12), "method": .string("item/tool/requestUserInput"), "params": .object(["threadId": .string(third.nativeThreadID!), "turnId": .string(third.nativeTurnID!), "itemId": .string("question"), "isBlocking": .bool(true), "questions": .array([])])]))
        try await wait("task-specific missing input") { coordinator.requests.count == 1 && coordinator.tasks.first { $0.id == third.id }?.state == .needsInput }
        check(coordinator.tasks.first { $0.id == second.id }?.state == .completed)
        await coordinator.respond(coordinator.requests[0], result: .object(["answers": .object([:])]))
        check(coordinator.requests.isEmpty)
        fixture.finish(third, status: "failed")
        try await wait("provider failure") { coordinator.tasks.first { $0.id == third.id }?.state == .failed }

        fixture.reportBeforeAcknowledgement = true
        await coordinator.continueTask(active[0].id)
        try await wait("report and turn completion before acknowledgement") { coordinator.tasks.first { $0.id == active[0].id }?.state == .completed }
        check(coordinator.tasks.first { $0.id == active[0].id }?.dispatch?.phase == "Finished")

        fixture.dropNext = true
        await coordinator.continueTask(third.id)
        try await wait("lost dispatch acknowledgement") { coordinator.tasks.first { $0.id == third.id }?.state == .unknown }
        let turnsBefore = fixture.turnCount
        await coordinator.continueTask(third.id)
        check(fixture.turnCount == turnsBefore, "unknown outcomes must never retry blindly")
        await coordinator.reconcile(third.id)
        check(fixture.turnCount == turnsBefore && coordinator.tasks.first { $0.id == third.id }?.state == .needsInput, "clientId recovers the original turn")

        let relinked = scratch.appendingPathComponent("relinked")
        try FileManager.default.createDirectory(at: relinked, withIntermediateDirectories: true)
        coordinator.updateContext(ManagedConversationContext(projectID: project.id, name: "Relinked fixture", cwd: relinked.path))
        fixture.holdNextThreadResponse = true
        check(await coordinator.handleTool(request("relinked"))["success"] == .bool(true))
        let relinkedTask = coordinator.tasks.first { $0.objective == "Research relinked" }!
        check(relinkedTask.cwd == relinked.path && coordinator.tasks.first { $0.id == second.id }?.cwd == scratch.path, "relink changes new task cwd while existing children keep their saved directory")
        try await wait("thread creation before cancellation") { fixture.heldThreadResponse != nil }
        let turnCountBeforeCancel = fixture.turnCount
        await coordinator.cancel(relinkedTask.id)
        fixture.emit(fixture.heldThreadResponse!)
        try await wait("cancelled task keeps acknowledged identity") { coordinator.tasks.first { $0.id == relinkedTask.id }?.nativeThreadID != nil }
        check(fixture.turnCount == turnCountBeforeCancel && coordinator.tasks.first { $0.id == relinkedTask.id }?.state == .cancelled, "cancellation during thread creation must not start a turn")

        var interrupted = ManagedTaskRecord(id: UUID().uuidString, projectID: project.id, parentThreadID: "parent", humanMessageID: "human", humanInstruction: "Run a cancellable investigation", objective: "Cancellable task", expectedDeliverable: "A report", checks: relinkedTask.checks, mode: .research, cwd: scratch.path, baseCWD: scratch.path)
        interrupted.state = .running; interrupted.nativeThreadID = "cancel-child"; interrupted.nativeTurnID = "cancel-turn"
        interrupted.dispatch = TaskDispatch(id: UUID().uuidString, phase: "Acknowledged", nativeThreadID: "cancel-child", nativeTurnID: "cancel-turn", instruction: "Investigate")
        try await coordinator.store.create(interrupted)
        fixture.turns["cancel-child"] = "cancel-turn"
        fixture.event("turn/started", ["threadId": .string("cancel-child"), "turn": .object(["id": .string("cancel-turn")])])
        try await wait("cancellable active turn") { coordinator.tasks.contains { $0.id == interrupted.id } }
        fixture.dropInterrupt = true
        await coordinator.cancel(interrupted.id)
        let unconfirmed = try await coordinator.store.record(interrupted.id)!
        check(unconfirmed.state == .unknown && unconfirmed.cancellationRequested && unconfirmed.recoveryRequired, "lost interrupt cannot claim cancellation")
        try await coordinator.store.restore()
        let afterRestart = try await coordinator.store.record(interrupted.id)!
        check(afterRestart.state == .unknown && afterRestart.cancellationRequested, "restart must retain unresolved cancellation")
        await coordinator.reconcile(interrupted.id)
        check(try await coordinator.store.record(interrupted.id)?.state == .cancelled, "provider terminal history confirms cancellation")

        var large = interrupted
        large.id = UUID().uuidString; large.nativeTurnID = "large-turn"; large.state = .running; large.cancellationRequested = false
        large.objective = String(repeating: "o", count: 8_000)
        large.checks = (1...12).map { TaskCompletionCheck(id: "large-\($0)", description: "Long check", kind: .outputContains, target: String(repeating: "x", count: 2_000)) }
        large.deliverable = TaskDeliverable(summary: String(repeating: "s", count: 2_000), content: String(repeating: "x", count: 32_768), files: [], checks: large.checks.map { TaskCheckResult(checkID: $0.id, passed: true, evidence: String(repeating: "e", count: 2_000)) })
        try await coordinator.store.create(large)
        try await coordinator.store.finishTurn(taskID: large.id, turnID: "large-turn", status: "completed")
        let largeDelivery = try await coordinator.store.deliveries().first { $0.taskID == large.id }!
        check(largeDelivery.text.utf8.count < 48_000 && largeDelivery.text.contains("full report"), "delivery envelope must be byte bounded")
        check(try await coordinator.store.record(large.id)?.deliverable?.content.utf8.count == 32_768, "full result must remain stored")

        _ = try await coordinator.store.update(third.id) { $0.state = .running; $0.recoveryRequired = false }
        let restored = Coordinator(context: coordinator.context, database: database, client: AppServerClient())
        await restored.load()
        check(restored.paused && restored.tasks.first { $0.id == third.id }?.state == .unknown && !restored.client.isConnected)
        let reserved = try await coordinator.store.reserveCall(key: "ambiguous-call", arguments: "{}")
        check(reserved == nil)
        let replay = try await coordinator.store.reserveCall(key: "ambiguous-call", arguments: "{}")
        check(replay != nil && replay?.response == nil)
        check(TaskWorktrees.relativeArtifact("../escape", cwd: scratch.path) == nil)
        check(TaskWorktrees.relativeArtifact("/absolute", cwd: scratch.path) == nil)
        let repository = CommandLine.arguments[2]
        var writerA = ManagedTaskRecord(id: UUID().uuidString, projectID: project.id, parentThreadID: "parent", humanMessageID: "human", humanInstruction: "Implement isolated work", objective: "Writer A", expectedDeliverable: "A file", checks: relinkedTask.checks, mode: .implementation, cwd: repository, baseCWD: repository)
        var writerB = writerA; writerB.id = UUID().uuidString; writerB.objective = "Writer B"
        let inputA = writerA, inputB = writerB
        async let worktreeA = TaskWorktrees.prepare(task: inputA, directory: scratch)
        async let worktreeB = TaskWorktrees.prepare(task: inputB, directory: scratch)
        let prepared = try await (worktreeA, worktreeB)
        check(prepared.0.0 != prepared.1.0 && prepared.0.1 != prepared.1.1)
        let original = try String(contentsOfFile: repository + "/README.md", encoding: .utf8)
        let isolated = try String(contentsOfFile: prepared.0.0 + "/README.md", encoding: .utf8)
        check(original.contains("uncommitted user edit") && !isolated.contains("uncommitted user edit"), "worktree creation must preserve uncommitted user data without copying it")
        writerA.cwd = prepared.0.0
        let repeatPreparation = try await TaskWorktrees.prepare(task: writerA, directory: scratch)
        check(repeatPreparation.0 == prepared.0.0, "prepared worktrees reuse the same task identity")
        try await coordinator.store.reserveWriter(path: prepared.0.0, taskID: writerA.id)
        do { try await coordinator.store.reserveWriter(path: prepared.0.0, taskID: writerB.id); fatalError("shared writer was allowed") }
        catch AgentStorageError.invalid { }
        await coordinator.shutdown(); await restored.shutdown()
        print("PASS: scope authority, tool replay, two-child cap, no-report gate, early completion ordering, missing input isolation, failure, result once, lost ack/clientId reconciliation, restart, relink, path containment, actual Git writer isolation")
    }
}
