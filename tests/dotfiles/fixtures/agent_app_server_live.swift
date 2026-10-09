import Foundation

/// Opt-in live test; not run by setup.sh. Uses a disposable directory and stricter test-only permissions.
@main struct LiveAppServerFixture {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply disposable working directory") }
        let client = AppServerClient()
        var active: String?, completed: [String: String] = [:], replies: [String] = []
        var callback: AppServerRequest?
        _ = client.observe(events: { method, params in
            if method == "turn/started" { active = params["turn"]["id"].string }
            if method == "turn/completed", let id = params["turn"]["id"].string { completed[id] = params["turn"]["status"].string; active = nil }
            if method == "item/completed", params["item"]["type"].string == "agentMessage", let text = params["item"]["text"].string { replies.append(text) }
        }, requests: { request in
            if request.method == "item/tool/call" { callback = request }
            else if request.method.hasSuffix("requestApproval") { try? client.respond(to: request, result: .object(["decision": .string("decline")])) }
        }, disconnected: {})
        let start = Date()
        try await client.connect()
        let created = try await client.request("thread/start", .object([
            "cwd": .string(CommandLine.arguments[1]), "historyMode": .string("paginated"),
            "sandbox": .string("read-only"), "approvalPolicy": .string("untrusted"), "approvalsReviewer": .string("user"),
            "dynamicTools": .array([.object(["type": .string("function"), "name": .string("acc_probe"), "description": .string("Return a harmless probe marker"),
                "inputSchema": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])])])
        ]))
        guard let thread = created["thread"]["id"].string else { fatalError("missing thread") }
        print("thread=\(thread) configured_model=\(created["model"].string ?? "unknown")")
        let turn = try await client.request("turn/start", .object(["threadId": .string(thread), "clientUserMessageId": .string(UUID().uuidString),
            "input": .array([.object(["type": .string("text"), "text": .string("Call acc_probe exactly once, then reply with its marker. Do not call other tools.")])])]))
        let firstID = turn["turn"]["id"].string!
        try await until { callback != nil }
        precondition(active == firstID)
        _ = try await client.request("turn/steer", .object(["threadId": .string(thread), "expectedTurnId": .string(firstID), "clientUserMessageId": .string(UUID().uuidString),
            "input": .array([.object(["type": .string("text"), "text": .string("Also include the exact word STEER_OK in your final response.")])])]))
        try client.respond(to: callback!, result: .object(["success": .bool(true), "contentItems": .array([.object(["type": .string("inputText"), "text": .string("NATIVE_CALLBACK_OK")])])]))
        try await until { completed[firstID] != nil }
        precondition(replies.joined().contains("NATIVE_CALLBACK_OK") && replies.joined().contains("STEER_OK"))
        print("PASS: native transport live dynamic callback and steering")
        client.stop()
        try await client.connect()
        _ = try await client.request("thread/resume", .object(["threadId": .string(thread), "excludeTurns": .bool(true)]))
        let page = try await client.request("thread/items/list", .object(["threadId": .string(thread), "limit": .number(50), "sortDirection": .string("desc")]))
        precondition(page["data"].array.contains { $0["item"]["text"].string?.contains("NATIVE_CALLBACK_OK") == true })
        let turns = try await client.request("thread/turns/list", .object(["threadId": .string(thread), "limit": .number(5), "itemsView": .string("notLoaded")]))
        precondition(turns["data"].array.contains { $0["id"].string == firstID })
        print("PASS: restart/resume and bounded native history pagination")
        let second = try await client.request("turn/start", .object(["threadId": .string(thread), "input": .array([.object(["type": .string("text"), "text": .string("Write a detailed explanation of how merge sort works, with five worked examples. Do not use tools.")])])]))
        let secondID = second["turn"]["id"].string!
        try await until { active == secondID || completed[secondID] != nil }
        precondition(completed[secondID] == nil, "turn finished before interrupt could be tested")
        _ = try await client.request("turn/interrupt", .object(["threadId": .string(thread), "turnId": .string(secondID)]))
        try await until { completed[secondID] != nil }
        precondition(completed[secondID] == "interrupted")
        client.stop()
        print("PASS: interruption after observed turn/started; elapsed=\(Date().timeIntervalSince(start))s")
    }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(180)
        while !condition() {
            guard Date() < deadline else { throw AppServerError.timeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
