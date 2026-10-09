import Foundation

@main struct AppServerFixture {
    @MainActor static func main() async throws {
        let client = AppServerClient()
        var sent: [RPCValue] = []
        client.fixtureWrite = { data in
            let value = try JSONDecoder().decode(RPCValue.self, from: data)
            sent.append(value)
            if value["method"].string == "initialize" {
                let response = RPCValue.object(["id": value["id"], "result": .object([:])])
                let bytes = try JSONEncoder().encode(response) + Data([10])
                client.receive(bytes.prefix(5), generation: client.generation)
                client.receive(bytes.dropFirst(5), generation: client.generation)
            }
        }
        var requests: [AppServerRequest] = [], events = 0
        _ = client.observe(events: { _, _ in events += 1 }, requests: { requests.append($0) }, disconnected: {})
        try await client.connect()
        precondition(client.isConnected)
        let generation = client.generation
        let request = RPCValue.object(["id": .number(8), "method": .string("item/fileChange/requestApproval"), "params": .object(["threadId": .string("own"), "turnId": .string("turn")])])
        let bytes = try JSONEncoder().encode(request) + Data([10])
        client.receive(bytes + bytes, generation: generation)
        precondition(requests.count == 1, "repeated pending request must not prompt twice")
        try client.respond(to: requests[0], result: .object(["decision": .string("decline")]))
        client.receive(bytes, generation: generation)
        precondition(requests.count == 1 && sent.last?["result"]["decision"].string == "decline")
        let first = Task { try await client.request("thread/read", .object([:])) }
        let second = Task { try await client.request("thread/read", .object([:])) }
        await Task.yield()
        let reads = sent.filter { $0["method"].string == "thread/read" }
        precondition(reads.count == 2)
        for (index, read) in reads.enumerated().reversed() {
            let reply = RPCValue.object(["id": read["id"], "result": .number(Double(index))])
            client.receive(try JSONEncoder().encode(reply) + Data([10]), generation: generation)
        }
        let results = try await [first.value, second.value]
        precondition(Set(results) == [.number(0), .number(1)], "out of order replies must route by id")
        do { _ = try await client.request("thread/shellCommand", .object([:])); fatalError("unrestricted endpoint allowed") } catch {}
        do { _ = try await client.request("thread/read", .object([:]), timeout: 0.01); fatalError("timeout missing") } catch AppServerError.timeout {} 
        client.stop()
        client.receive(bytes, generation: generation)
        precondition(requests.count == 1)
        do { try client.respond(to: requests[0], result: .object([:])); fatalError("stale approval allowed") } catch {}
        print("PASS: fragmented frames, out-of-order replies, duplicate requests, stale approvals, allowlist and timeout")
        if CommandLine.arguments.count > 1 {
            let blocked = AppServerClient()
            try await blocked.connect(executable: URL(fileURLWithPath: CommandLine.arguments[1]))
            let start = Date()
            do { _ = try await blocked.request("thread/read", .string(String(repeating: "x", count: 1_048_576)), timeout: 0.1); fatalError("blocked pipe did not timeout") }
            catch AppServerError.timeout {}
            precondition(Date().timeIntervalSince(start) < 2, "stdin writes blocked the main actor")
            blocked.stop()
            print("PASS: a non-reading child cannot block main-actor request timeout")
        }
    }
}
