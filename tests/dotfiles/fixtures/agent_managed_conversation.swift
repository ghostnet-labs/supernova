import Foundation

@main struct ManagedConversationFixture {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let database = try AgentDatabase(directory: directory)
        let client = AppServerClient()
        var writes: [RPCValue] = [], dropNextTurn = false, dropNextCreation = false, lastClientID = "", turnNumber = 0
        func emit(_ frame: RPCValue) { client.receive(try! JSONEncoder().encode(frame) + Data([10]), generation: client.generation) }
        func event(_ method: String, _ params: [String: RPCValue]) { emit(.object(["method": .string(method), "params": .object(params)])) }
        client.fixtureWrite = { bytes in
            let request = try JSONDecoder().decode(RPCValue.self, from: bytes); writes.append(request)
            guard let method = request["method"].string else { return }
            var result: RPCValue = .object([:])
            switch method {
            case "thread/start", "thread/resume":
                precondition(request["params"]["model"] == .null && request["params"]["approvalPolicy"] == .null, "configured defaults must survive")
                if method == "thread/start", dropNextCreation {
                    dropNextCreation = false
                    event("thread/started", ["thread": .object(["id": .string("owned")])])
                    client.receive(Data(), generation: client.generation)
                    return
                }
                result = .object(["thread": .object(["id": .string("owned")]), "model": .string("configured")])
            case "turn/start", "turn/steer":
                turnNumber += 1
                lastClientID = request["params"]["clientUserMessageId"].string!
                let nativeTurn = "turn-\(turnNumber)"
                event("turn/started", ["threadId": .string("owned"), "turn": .object(["id": .string(nativeTurn)])])
                if dropNextTurn { dropNextTurn = false; client.receive(Data(), generation: client.generation); return }
                result = .object(["turn": .object(["id": .string(nativeTurn)])])
            case "thread/turns/list":
                precondition(request["params"]["limit"] == .number(20))
                result = .object(["data": .array([.object(["id": .string("turn-\(turnNumber)"), "status": .string("completed")])])])
            case "thread/items/list":
                precondition(request["params"]["limit"] == .number(100))
                result = .object(["data": .array([.object(["turnId": .string("turn-\(turnNumber)"), "item": .object(["id": .string("native-user-item"), "clientId": .string(lastClientID), "type": .string("userMessage"), "content": .array([.object(["text": .string("ambiguous")])])])])])])
            default: break
            }
            if request["id"] != .null { emit(.object(["id": request["id"], "result": result])) }
        }
        let context = ManagedConversationContext(projectID: "project", name: "Fixture", cwd: directory.path, retrievedContext: ["untrusted evidence"])
        let store = ManagedConversationStore(context: context, database: database, client: client)
        var humanDispatches = 0
        store.onHumanDispatch = { _, _ in humanDispatches += 1 }
        await store.load()
        precondition(writes.isEmpty, "browsing saved conversation must not start a process")
        await store.send("hello")
        precondition(store.threadID == "owned" && store.activeTurnID == "turn-1" && humanDispatches == 1)
        precondition(writes.last?["params"]["additionalContext"]["project-memory"]["kind"].string == "untrusted")
        let snapshot = try await database.read { try $0.query("SELECT json FROM managed_records WHERE namespace='conversation'").first!["json"]! }
        precondition(snapshot.contains(lastClientID))
        event("item/agentMessage/delta", ["threadId": .string("other"), "turnId": .string("turn-1"), "itemId": .string("ignored"), "delta": .string("wrong thread")])
        event("item/agentMessage/delta", ["threadId": .string("owned"), "turnId": .string("turn-1"), "itemId": .string("reply"), "delta": .string("partial")])
        event("item/completed", ["threadId": .string("owned"), "turnId": .string("turn-1"), "item": .object(["id": .string("reply"), "type": .string("agentMessage"), "text": .string("final")])])
        event("item/agentMessage/delta", ["threadId": .string("owned"), "turnId": .string("turn-1"), "itemId": .string("reply"), "delta": .string("late")])
        event("item/completed", ["threadId": .string("owned"), "turnId": .string("turn-1"), "item": .object(["id": .string("reasoning"), "type": .string("reasoning"), "text": .string("not retained")])])
        precondition(store.messages.last?.text == "final" && store.messages.count == 2)
        let approval = RPCValue.object(["id": .number(7), "method": .string("item/commandExecution/requestApproval"), "params": .object(["threadId": .string("owned"), "turnId": .string("turn-1"), "availableDecisions": .array([.string("decline")])])])
        emit(approval); precondition(store.requests.count == 1)
        store.respond(store.requests[0], result: .object(["decision": .string("decline")]))
        precondition(store.requests.isEmpty && writes.last?["result"]["decision"].string == "decline")
        event("turn/completed", ["threadId": .string("owned"), "turn": .object(["id": .string("turn-1"), "status": .string("completed")])])
        precondition(store.canSend)
        let delivered = try await store.sendResult(resultID: "result-1", text: "task evidence")
        precondition(delivered && humanDispatches == 1 && store.currentInstruction == "hello")
        let resultClientID = lastClientID
        event("item/completed", ["threadId": .string("owned"), "turnId": .string("turn-2"), "item": .object(["id": .string("native-result-input"), "clientId": .string(resultClientID), "type": .string("userMessage"), "content": .array([.object(["text": .string("Synthetic result instruction")])])])])
        precondition(store.messages.last?.role == "task" && store.messages.last?.text == "task evidence", "provider echo must preserve the app-owned result text and role")
        precondition(writes.last?["params"]["additionalContext"]["task-result-result-1"]["kind"].string == "untrusted")
        let before = writes.count
        let duplicate = try await store.sendResult(resultID: "result-1", text: "task evidence")
        precondition(duplicate && writes.count == before, "result redelivery must not start a duplicate turn")
        event("turn/completed", ["threadId": .string("owned"), "turn": .object(["id": .string("turn-2"), "status": .string("completed")])])
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        store.updateContext(ManagedConversationContext(projectID: context.projectID, name: "Moved fixture", cwd: moved.path))
        dropNextTurn = true
        await store.send("ambiguous")
        precondition(writes.last?["params"]["cwd"].string == moved.path, "new turns must use the explicitly relinked directory")
        precondition(store.needsReconciliation && !store.canSend)
        let count = writes.count
        await store.send("must not retry")
        precondition(writes.count == count)
        await store.reconcile()
        precondition(!store.needsReconciliation && store.canSend)
        let resumed = ManagedConversationStore(context: context, database: database, client: AppServerClient())
        await resumed.load()
        precondition(resumed.threadID == "owned" && resumed.messages.last?.clientID == lastClientID)
        await store.newConversation()
        dropNextCreation = true
        await store.send("begin a new conversation")
        precondition(store.threadID == "owned" && store.needsReconciliation)
        await store.reconcile()
        precondition(!store.needsReconciliation && store.canSend, "thread/started evidence must recover a lost thread/start acknowledgement")
        await store.shutdown()
        precondition(!store.canSend && !store.canSteer, "quit must block new dispatch")
        do { _ = try await store.sendResult(resultID: "oversized", text: String(repeating: "x", count: 65_537)); preconditionFailure("oversized result was silently accepted") }
        catch AgentStorageError.invalid { }
        print("PASS: managed intent persistence, scope isolation, streaming final authority, hidden reasoning, approvals, result dedupe, ambiguous dispatch reconciliation, restart hydration")
    }
}
