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
        check(snapshot.meters.map(\.remainingPercent) == [77, 0] && snapshot.meters.map(\.usedPercent) == [23, 100],
              "round and clamp rolling limits, shown as the share used")
        check(snapshot.headline?.id == "primary" && snapshot.planName == "Pro", "choose primary meter and plan")
        let credit: [String: Any] = ["rateLimits": ["individualLimit": ["limit": "1000", "used": "250.5"]]]
        let plain = try BalanceSnapshot(account: account, rateLimits: credit, usage: nil, creditUSD: nil)
        let priced = try BalanceSnapshot(account: account, rateLimits: credit, usage: nil, creditUSD: 0.5)
        check(plain.meters.first?.detail.contains("$") == false && priced.meters.first?.detail.contains("$") == true
              && priced.meters.first?.detail.contains("125.25") == true && priced.meters.first?.detail.contains("500") == true,
              "show Codex credits as dollars only with a price per credit")
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
        check(fetched.headline?.remainingPercent == 60 && fetched.monthTokens == nil, "optional usage failure must not hide available rate limits")
        let windows = ClaudeAccount(usage: [
            "five_hour": ["utilization": 42.4, "resets_at": "2030-01-01T05:00:00.123Z"],
            "seven_day": ["utilization": 101, "resets_at": "2030-01-07T00:00:00Z"],
            "seven_day_opus": NSNull(), "extra_usage": ["is_enabled": false]])
        check(windows.meters.map(\.id) == ["five_hour", "seven_day"] && windows.meters.map(\.usedPercent) == [42, 100]
              && windows.meters.allSatisfy { $0.resetsAt != nil },
              "decode Claude plan windows with either ISO 8601 form")
        for (status, body, expected) in [(401, "{}", "rejected"), (500, "{}", "HTTP 500"), (200, "not json", "HTTP 200")] {
            do {
                _ = try ClaudeAccountClient.account(status: status, data: Data(body.utf8), planName: nil)
                check(false, "HTTP \(status) with \(body) must fail")
            } catch {
                check(error.localizedDescription.contains(expected), "explain HTTP \(status) from the Claude usage endpoint")
            }
        }
        let replied = try ClaudeAccountClient.account(
            status: 200, data: Data(#"{"five_hour":{"utilization":10,"resets_at":null}}"#.utf8), planName: "Max")
        check(replied.meters.map(\.usedPercent) == [10] && replied.planName == "Max", "read a successful Claude usage reply")

        let credits = ClaudeAccount(usage: ["extra_usage": [
            "is_enabled": true, "monthly_limit": 50_000, "used_credits": 1234.0, "currency": "USD", "decimal_places": 2]])
        check(credits.meters.map(\.remainingPercent) == [97] && credits.meters[0].title == "Credits"
              && credits.meters[0].detail.contains("12.34") && credits.limitReached == nil
              && credits.meters[0].resetsAt == Calendar.current.dateInterval(of: .month, for: Date())?.end,
              "decode Claude usage credits from minor units with a monthly reset")
        let spent = ClaudeAccount(usage: ["extra_usage": [
            "is_enabled": true, "monthly_limit": 100, "used_credits": 120, "spend_limit_reached": true]])
        check(spent.meters.map(\.remainingPercent) == [0] && spent.limitReached != nil, "report a reached Claude spend limit")
        check(ClaudeAccount(usage: ["extra_usage": ["is_enabled": false, "monthly_limit": 100, "used_credits": 1]]).meters.isEmpty,
              "disabled Claude usage credits add no meter")
        do {
            _ = try ClaudeAccountClient.login(from: Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":1000}}"#.utf8))
            check(false, "an expired Claude Code login must not be used")
        } catch is ClaudeAccountClient.ExpiredLogin {}
        let login = try ClaudeAccountClient.login(
            from: Data(#"{"claudeAiOauth":{"accessToken":"t","expiresAt":4102444800000,"subscriptionType":"enterprise"}}"#.utf8))
        check(login.planName == "Enterprise", "read the Claude plan from the login")

        let projects = scratch.appendingPathComponent("projects")
        let subagents = projects.appendingPathComponent("demo/session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let stamps = ISO8601DateFormatter()
        stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func response(_ id: String, _ output: Int, at time: Date = Date()) -> String {
            #"{"type":"assistant","timestamp":"\#(stamps.string(from: time))","requestId":"req_\#(id)","message":{"id":"msg_\#(id)","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":\#(output)}}}"#
        }
        let user = #"{"type":"user","timestamp":"\#(stamps.string(from: Date()))","message":{"content":"usage"}}"#
        let old = response("old", 1, at: Date().addingTimeInterval(-60 * 86_400))
        try [response("a", 10), response("a", 40), user, old].joined(separator: "\n")
            .write(to: projects.appendingPathComponent("demo/session.jsonl"), atomically: true, encoding: .utf8)
        try response("b", 5).write(to: subagents.appendingPathComponent("agent.jsonl"), atomically: true, encoding: .utf8)
        // Saved days from deleted transcripts, and /stats activity two days ago.
        let calendar = Calendar.current
        let dayKeys = DateFormatter()
        dayKeys.locale = Locale(identifier: "en_US_POSIX")
        dayKeys.dateFormat = "yyyy-MM-dd"
        func day(_ offset: Int) -> String { dayKeys.string(from: calendar.date(byAdding: .day, value: offset, to: Date())!) }
        let history = scratch.appendingPathComponent("support/claude-daily-tokens.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"\#(day(-10))":1000,"\#(day(-1))":50}"#.utf8).write(to: history)
        let stats = scratch.appendingPathComponent("stats-cache.json")
        try Data(#"{"dailyActivity":[{"date":"\#(day(-2))","messageCount":3},{"date":"\#(day(-4))","messageCount":0}]}"#.utf8)
            .write(to: stats)
        let monthStart = dayKeys.string(from: calendar.dateInterval(of: .month, for: Date())!.start)
        let month = [(-10, 1000), (-1, 50), (0, 165)].filter { day($0.0) >= monthStart }.reduce(0) { $0 + $1.1 }
        let log = ClaudeUsageLog(root: projects, historyURL: history, statsURL: stats)
        for pass in ["first", "cached"] {
            let usage = log.scan()
            check(usage?.recentDays.count == BalanceSnapshot.chartDays && usage?.recentDays.last?.tokens == 165
                  && usage?.monthTokens == month && usage?.streakDays == 3,
                  "\(pass) Claude scan counts each streamed response once, adds saved days, and extends the streak with /stats activity")
        }
        try FileManager.default.removeItem(at: projects)
        let saved = ClaudeUsageLog(root: projects, historyURL: history, statsURL: stats).scan()
        check(saved?.recentDays.last?.tokens == 165 && saved?.monthTokens == month,
              "saved Claude days still count after Claude Code deletes their transcripts")
        print("PASS: Codex Balance RPC, optional usage errors, account types, limit windows, Claude plan windows and credits, and token logs")
    }
}
