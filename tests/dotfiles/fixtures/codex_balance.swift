import Foundation

@main struct BalanceChecks {
    static func main() async throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { print("FAIL: " + message); exit(1) }
        }
        let account: [String: Any] = ["account": ["type": "chatgpt", "planType": "pro"]]
        let limits: [String: Any] = ["rateLimitsByLimitId": ["codex": [
            "primary": ["usedPercent": 23.4, "windowDurationMins": 300, "resetsAt": 2_000_000_000],
            "secondary": ["usedPercent": 101, "windowDurationMins": 10_080]]]]
        let snapshot = try BalanceSnapshot(account: account, rateLimits: limits, usage: nil)
        check(snapshot.meters.map(\.remainingPercent) == [77, 0], "round and clamp rolling limits")
        check(snapshot.headline?.id == "primary" && snapshot.planName == "Pro", "choose primary meter and plan")
        do {
            _ = try BalanceSnapshot(account: ["account": ["type": "apiKey"]], rateLimits: [:], usage: nil)
            check(false, "API key accounts must report unavailable plan limits")
        } catch {}
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
        let fake = scratch.appendingPathComponent("codex fixture")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request.get('id') == 1:
                result = {}
            elif request.get('id') == 2:
                result = {'rateLimits': {'primary': {'usedPercent': 40, 'windowDurationMins': 300}}}
            elif request.get('id') == 3:
                print(json.dumps({'id': 3, 'error': {'code': -32601, 'message': 'unknown method'}}), flush=True)
                continue
            elif request.get('id') == 4:
                result = {'account': {'type': 'chatgpt', 'planType': 'pro'}}
            else:
                continue
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        setenv("CODEX_BIN", fake.path, 1)
        let fetched = try await CodexClient.fetch(timeout: .seconds(3))
        check(fetched.headline?.remainingPercent == 60 && fetched.lifetimeTokens == nil, "optional usage failure must not hide available rate limits")
        let claude = scratch.appendingPathComponent("claude.json")
        try Data(#"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":100},"seven_day":{"used_percentage":101,"resets_at":2000}},"captured_at":50}"#.utf8).write(to: claude)
        let captured = ClaudeSnapshot.load(from: claude, now: Date(timeIntervalSince1970: 200))!
        check(captured.meters.map(\.remainingPercent) == [100, 0], "handle expired Claude windows and overuse")
        try Data("invalid".utf8).write(to: claude)
        check(ClaudeSnapshot.load(from: claude) == nil, "invalid captures are unavailable, not a crash")
        print("PASS: Codex Balance RPC, optional usage errors, account types, limit windows, and Claude capture decoding")
    }
}
