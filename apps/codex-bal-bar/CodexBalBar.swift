// Codex Balance - a menu bar meter for Codex credit usage.
// Built, installed, and launched by dotfiles/.bin/codex-bal-bar.

import AppKit
import Charts
import Combine
import SwiftUI

// MARK: - Data

struct DailyUsage: Identifiable {
    let day: Date
    let tokens: Int
    var id: Date { day }
}

// One usage limit the account is metered against: a credit allowance on
// business-style plans, or a rolling time window (5-hour, weekly) on Plus/Pro.
struct LimitMeter: Identifiable {
    let id: String
    let title: String
    let remainingPercent: Int
    let resetsAt: Date?
    let detail: String

    // The app shows how much of each limit is used, so every figure and bar
    // grows toward the limit.
    var usedPercent: Int { min(100, max(0, 100 - remainingPercent)) }
    var usedFraction: Double { Double(usedPercent) / 100 }
}

private func headlineMeter(in meters: [LimitMeter]) -> LimitMeter? {
    meters.first(where: { $0.id == "five_hour" || $0.id == "primary" })
        ?? meters.min { $0.remainingPercent < $1.remainingPercent }
}

struct BalanceSnapshot {
    let meters: [LimitMeter]
    let creditBalance: String?
    let limitReached: String?
    let planName: String?
    let recentDays: [DailyUsage]
    let monthTokens: Int?
    let lifetimeTokens: Int?
    let streakDays: Int?
    let fetchedAt: Date

    // The limit closest to running out is the one that matters right now.
    var headline: LimitMeter? { headlineMeter(in: meters) }
}

struct FetchError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Codex sends credit values as decimal strings and token counts as numbers.
private func number(_ value: Any?) -> Double? {
    switch value {
    case let string as String: return Double(string)
    case let number as NSNumber: return number.doubleValue
    default: return nil
    }
}

private func timestamp(_ value: Any?) -> Date? {
    number(value).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
}

private func formatCredits(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...2)))
}

// Whole amounts drop their cents, as in "$500".
private func formatMoney(_ amount: Double, currency: String = "USD") -> String {
    amount.formatted(.currency(code: currency).precision(.fractionLength(amount == amount.rounded() ? 0 : 2)))
}

private func windowTitle(minutes: Double?, fallback: String) -> String {
    guard let minutes, minutes > 0 else { return fallback }
    let total = Int(minutes)
    switch total {
    case 10_080: return "Weekly limit"
    case 1_440: return "Daily limit"
    case _ where total % 1_440 == 0: return "\(total / 1_440)-day limit"
    case _ where total % 60 == 0: return "\(total / 60)-hour limit"
    default: return "\(total)-minute limit"
    }
}

private func displayPlanName(_ raw: String?) -> String? {
    guard let raw, raw != "unknown" else { return nil }
    if raw.hasPrefix("self_serve_business") { return "Business" }
    if raw.hasPrefix("enterprise") || raw == "ent26" { return "Enterprise" }
    let names = ["prolite": "Pro Lite", "promax": "Pro Max"]
    return names[raw] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
}

private func limitReachedText(_ raw: String?) -> String? {
    switch raw {
    case nil: return nil
    case "rate_limit_reached": return "Usage limit reached"
    case let type? where type.hasSuffix("credits_depleted"): return "Workspace credits used up"
    default: return "Workspace usage limit reached"
    }
}

extension BalanceSnapshot {
    static let chartDays = 30

    // Codex reports plain credits. CODEX_BAL_BAR_CREDIT_USD, the plan's price
    // per credit in US dollars, shows them as dollars instead.
    static let creditUSD = ProcessInfo.processInfo.environment["CODEX_BAL_BAR_CREDIT_USD"]
        .flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }

    // Builds a snapshot from the app server's account/read, account/rateLimits/read,
    // and account/usage/read replies, showing whichever limits the plan reports.
    init(account: [String: Any]?, rateLimits: [String: Any], usage: [String: Any]?, now: Date = Date(),
         creditUSD: Double? = BalanceSnapshot.creditUSD) throws {
        func amount(_ credits: Double) -> String {
            creditUSD.map { formatMoney(credits * $0) } ?? formatCredits(credits)
        }
        if let account {
            switch (account["account"] as? [String: Any])?["type"] as? String {
            case nil: throw FetchError("Not signed in to Codex. Run codex login in a terminal.")
            case "apiKey": throw FetchError("Codex is signed in with an API key. Usage limits are only reported for ChatGPT plans.")
            case "amazonBedrock": throw FetchError("Codex is using Amazon Bedrock. Usage limits are only reported for ChatGPT plans.")
            default: break
            }
        }

        let byLimitID = rateLimits["rateLimitsByLimitId"] as? [String: Any]
        let limits = byLimitID?["codex"] as? [String: Any] ?? rateLimits["rateLimits"] as? [String: Any] ?? [:]

        var meters: [LimitMeter] = []
        if let individual = limits["individualLimit"] as? [String: Any] {
            guard let limit = number(individual["limit"]), let used = number(individual["used"]), limit > 0 else {
                throw FetchError("Codex returned an invalid credit limit")
            }
            let remaining = number(individual["remainingPercent"]).map { Int($0.rounded()) }
                ?? Int((max(0, limit - used) * 100 / limit).rounded())
            meters.append(LimitMeter(id: "credits", title: "Credits", remainingPercent: remaining,
                                     resetsAt: timestamp(individual["resetsAt"]),
                                     detail: "\(amount(used)) of \(amount(limit)) used"))
        }
        for (key, fallback) in [("primary", "Short-term limit"), ("secondary", "Long-term limit")] {
            guard let window = limits[key] as? [String: Any], let usedPercent = number(window["usedPercent"]) else { continue }
            let used = min(100, max(0, Int(usedPercent.rounded())))
            meters.append(LimitMeter(id: key, title: windowTitle(minutes: number(window["windowDurationMins"]), fallback: fallback),
                                     remainingPercent: 100 - used, resetsAt: timestamp(window["resetsAt"]),
                                     detail: "\(used)% used"))
        }
        self.meters = meters

        let credits = limits["credits"] as? [String: Any]
        if credits?["unlimited"] as? Bool == true {
            creditBalance = "Unlimited"
        } else {
            creditBalance = number(credits?["balance"]).map(amount)
        }
        limitReached = limitReachedText(limits["rateLimitReachedType"] as? String)
        planName = BalanceSnapshot.planName(account: account, limits: limits)
        fetchedAt = now

        let summary = usage?["summary"] as? [String: Any]
        lifetimeTokens = number(summary?["lifetimeTokens"]).map { Int($0) }
        streakDays = number(summary?["currentStreakDays"]).map { Int($0) }

        guard let buckets = usage?["dailyUsageBuckets"] as? [Any] else {
            recentDays = []
            monthTokens = nil
            return
        }
        let calendar = Calendar.current
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        var tokensByDay: [Date: Int] = [:]
        for case let bucket as [String: Any] in buckets {
            guard let start = bucket["startDate"] as? String, let day = parser.date(from: start) else { continue }
            tokensByDay[calendar.startOfDay(for: day), default: 0] += Int(number(bucket["tokens"]) ?? 0)
        }
        let today = calendar.startOfDay(for: now)
        recentDays = (0..<Self.chartDays).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map {
                DailyUsage(day: $0, tokens: tokensByDay[$0] ?? 0)
            }
        }
        monthTokens = tokensByDay
            .filter { calendar.isDate($0.key, equalTo: now, toGranularity: .month) }
            .values.reduce(0, +)
    }

    private static func planName(account: [String: Any]?, limits: [String: Any]) -> String? {
        let accountPlan = (account?["account"] as? [String: Any])?["planType"] as? String
        return displayPlanName(accountPlan ?? limits["planType"] as? String)
    }
}

// MARK: - Claude plan limits

// Claude has no supported endpoint for plan limits, but Claude Code hands its
// status line the account's rate limits after each response. The
// claude-limits-capture hook saves them to this file for the app to read.
struct ClaudeSnapshot {
    let meters: [LimitMeter]
    let capturedAt: Date?

    var headline: LimitMeter? { headlineMeter(in: meters) }

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_BAL_BAR_CLAUDE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Codex Balance/claude-rate-limits.json")
    }

    // Returns nil until the status line hook has written the file at least once.
    static func load(from url: URL = fileURL, now: Date = Date()) -> ClaudeSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let limits = saved["rate_limits"] as? [String: Any] ?? [:]
        let titles = ["five_hour": "5-hour limit", "seven_day": "Weekly limit", "spend_limit": "Spend limit"]
        let order = ["five_hour", "seven_day", "spend_limit"]
        let keys = limits.keys.sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
        let meters: [LimitMeter] = keys.compactMap { key in
            guard let window = limits[key] as? [String: Any], let usedPercent = number(window["used_percentage"]) else { return nil }
            let title = titles[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized + " limit"
            let resetsAt = timestamp(window["resets_at"])
            // A window that reset after the last capture has no newer reading yet.
            if let resetsAt, resetsAt <= now {
                return LimitMeter(id: key, title: title, remainingPercent: 100, resetsAt: nil, detail: "Reset")
            }
            let used = max(0, Int(usedPercent.rounded()))
            return LimitMeter(id: key, title: title, remainingPercent: max(0, 100 - used), resetsAt: resetsAt,
                              detail: "\(used)% used")
        }
        return ClaudeSnapshot(meters: meters, capturedAt: timestamp(saved["captured_at"]))
    }
}

enum ClaudeCode {
    static var configDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }
}

// MARK: - Claude usage credits

// Claude Code's /usage screen reads usage credits, such as an Enterprise
// seat's monthly spend limit, from an undocumented endpoint with the Claude
// Code login. A reply without the expected fields adds no meter.
struct ClaudeAccount {
    let meters: [LimitMeter]
    let limitReached: String?
    let planName: String?
    let fetchedAt: Date

    init(usage: [String: Any], planName: String? = nil, now: Date = Date()) {
        var meters: [LimitMeter] = []
        var limitReached: String?
        if let extra = usage["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let limit = number(extra["monthly_limit"]), let used = number(extra["used_credits"]), limit > 0 {
            // Amounts are in minor units, such as cents.
            let scale = pow(10, number(extra["decimal_places"]) ?? 2)
            let currency = extra["currency"] as? String ?? "USD"
            func money(_ minor: Double) -> String { formatMoney(minor / scale, currency: currency) }
            // Round down so any spending shows below 100%. Claude Code resets
            // the monthly limit on the 1st, local time.
            meters.append(LimitMeter(id: "credits", title: "Credits",
                                     remainingPercent: Int((max(0, limit - used) * 100 / limit).rounded(.down)),
                                     resetsAt: Calendar.current.dateInterval(of: .month, for: now)?.end,
                                     detail: "\(money(used)) of \(money(limit)) used"))
            if extra["spend_limit_reached"] as? Bool == true { limitReached = "Credits used up" }
        }
        self.meters = meters
        self.limitReached = limitReached
        self.planName = planName
        fetchedAt = now
    }
}

enum ClaudeAccountClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Login {
        let accessToken: String
        let planName: String?
    }

    private static let notSignedIn = FetchError("Not signed in to a Claude plan. Run claude, then /login, in a terminal.")

    // Claude Code keeps its login in the keychain on macOS and in
    // .credentials.json elsewhere.
    static func readLogin() throws -> Login {
        guard let data = keychainCredentials()
            ?? (try? Data(contentsOf: ClaudeCode.configDirectory.appending(path: ".credentials.json")))
        else { throw notSignedIn }
        return try login(from: data)
    }

    static func login(from data: Data, now: Date = Date()) throws -> Login {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = saved["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { throw notSignedIn }
        // Only Claude Code may refresh its token: a refresh here would replace
        // the login Claude Code holds and sign it out.
        if let expiresAt = number(oauth["expiresAt"]), Date(timeIntervalSince1970: expiresAt / 1000) <= now {
            throw FetchError("Claude Code's login has expired. Use Claude Code to renew it.")
        }
        return Login(accessToken: token, planName: displayPlanName(oauth["subscriptionType"] as? String))
    }

    // Claude Code writes this item with the security tool, which the item
    // therefore trusts, so reading it the same way never prompts.
    private static func keychainCredentials() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func fetch(timeout: TimeInterval = 15) async throws -> ClaudeAccount {
        let login = try readLogin()
        var request = URLRequest(url: usageURL, timeoutInterval: timeout)
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw FetchError("Claude rejected Claude Code's login. Use Claude Code to renew it.")
        }
        guard status == 200, let usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError("Claude usage request failed (HTTP \(status))")
        }
        return ClaudeAccount(usage: usage, planName: login.planName)
    }
}

// MARK: - Claude Code token usage

// Claude Code logs each response's token counts in its session transcripts
// and deletes transcripts after cleanupPeriodDays (30 by default). The app
// saves every day it has counted so deleted transcripts still count, and
// Claude Code's /stats totals cover the days before that.
struct ClaudeUsage {
    let recentDays: [DailyUsage]
    let monthTokens: Int
    let lifetimeTokens: Int
    let streakDays: Int
    let scannedAt: Date
}

// Only one scan runs at a time (BalanceModel.isRefreshingClaude).
final class ClaudeUsageLog: @unchecked Sendable {
    typealias Response = (day: String, tokens: Int)

    private struct FileTotals {
        let modified: Date
        let size: Int
        let responses: [String: Response]
    }

    private let root: URL
    private let historyURL: URL
    private let statsURL: URL
    private var cache: [URL: FileTotals] = [:]
    private let days: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(root: URL = ClaudeCode.configDirectory.appending(path: "projects"),
         historyURL: URL = ClaudeSnapshot.fileURL.deletingLastPathComponent().appending(path: "claude-daily-tokens.json"),
         statsURL: URL = ClaudeCode.configDirectory.appending(path: "stats-cache.json")) {
        self.root = root
        self.historyURL = historyURL
        self.statsURL = statsURL
    }

    func scan(now: Date = Date()) -> ClaudeUsage? {
        var history = savedHistory()
        var changed = false
        // A day's count only grows, so a smaller one means its transcripts are gone.
        for (day, tokens) in transcriptTokensByDay() where tokens > history[day] ?? 0 {
            history[day] = tokens
            changed = true
        }
        if changed { save(history) }
        let stats = statsTotals()
        guard !history.isEmpty || stats != nil else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let recentDays = (0..<BalanceSnapshot.chartDays).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map {
                DailyUsage(day: $0, tokens: history[days.string(from: $0)] ?? 0)
            }
        }
        let monthStart = days.string(from: calendar.dateInterval(of: .month, for: now)?.start ?? today)
        // /stats totals already include every day through its last computed date.
        let lifetime = (stats?.tokens ?? 0) + history.filter { $0.key > stats?.through ?? "" }.values.reduce(0, +)

        var active = Set(history.filter { $0.value > 0 }.keys)
        if let stats { active.formUnion(stats.activeDays) }
        // Like a streak shown during the day, one not yet extended today still counts.
        var day = active.contains(days.string(from: today)) ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var streak = 0
        while active.contains(days.string(from: day)), let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            streak += 1
            day = previous
        }
        return ClaudeUsage(recentDays: recentDays, monthTokens: history.filter { $0.key >= monthStart }.values.reduce(0, +),
                           lifetimeTokens: lifetime, streakDays: streak, scannedAt: now)
    }

    // Re-reads only the transcripts that changed since the last scan.
    private func transcriptTokensByDay() -> [String: Int] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [:] }
        var scanned: [URL: FileTotals] = [:]
        var responses: [String: Response] = [:]
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            let size = values.fileSize ?? 0
            let totals = cache[url].flatMap { $0.modified == modified && $0.size == size ? $0 : nil }
                ?? FileTotals(modified: modified, size: size, responses: read(url))
            scanned[url] = totals
            responses.merge(totals.responses) { kept, _ in kept }
        }
        cache = scanned
        var tokensByDay: [String: Int] = [:]
        for response in responses.values {
            tokensByDay[response.day, default: 0] += response.tokens
        }
        return tokensByDay
    }

    // Claude Code writes a streamed response several times, so responses are
    // keyed by message and request ID and the last copy wins.
    private func read(_ url: URL) -> [String: Response] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        let marker = Data(#""usage""#.utf8)
        let stamps = ISO8601DateFormatter()
        stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var responses: [String: Response] = [:]
        for line in data.split(separator: 0x0A) where line.range(of: marker) != nil {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let stamp = entry["timestamp"] as? String, let time = stamps.date(from: stamp) else { continue }
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                .reduce(0) { $0 + Int(number(usage[$1]) ?? 0) }
            let key = "\(message["id"] as? String ?? stamp)|\(entry["requestId"] as? String ?? "")"
            responses[key] = (days.string(from: time), tokens)
        }
        return responses
    }

    private func savedHistory() -> [String: Int] {
        guard let data = try? Data(contentsOf: historyURL),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return saved.compactMapValues { number($0).map { Int($0) } }
    }

    private func save(_ history: [String: Int]) {
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: history, options: .sortedKeys) {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    // Claude Code's /stats saves totals through lastComputedDate, including
    // days whose transcripts are gone. It only updates when /stats runs.
    private func statsTotals() -> (through: String, tokens: Int, activeDays: Set<String>)? {
        guard let data = try? Data(contentsOf: statsURL),
              let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let through = stats["lastComputedDate"] as? String,
              let models = stats["modelUsage"] as? [String: Any] else { return nil }
        let fields = ["inputTokens", "outputTokens", "cacheReadInputTokens", "cacheCreationInputTokens"]
        let tokens = models.values.reduce(0) { total, usage in
            total + fields.reduce(0) { $0 + Int(number((usage as? [String: Any])?[$1]) ?? 0) }
        }
        let activeDays = (stats["dailyActivity"] as? [[String: Any]] ?? []).compactMap { day in
            (number(day["messageCount"]) ?? 0) > 0 ? day["date"] as? String : nil
        }
        return (through, tokens, Set(activeDays))
    }
}

// MARK: - Codex app server client

enum CodexClient {
    static func locateCodex() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = environment["CODEX_BIN"], !override.isEmpty { candidates.append(override) }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(NSHomeDirectory())/.local/bin/codex"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw FetchError("codex is not installed or not in PATH (set CODEX_BIN)")
        }
        return URL(fileURLWithPath: path)
    }

    // Asks one short-lived `codex app-server` for the account rate limits and
    // daily usage, mirroring the requests made by the codex_bal shell helper.
    static func fetch(timeout: Duration = .seconds(15)) async throws -> BalanceSnapshot {
        let process = Process()
        process.executableURL = try locateCodex()
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let started = ContinuousClock.now

        let watchdog = Task {
            try await Task.sleep(for: timeout)
            process.terminate()
        }
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message.merging(["jsonrpc": "2.0"]) { a, _ in a })
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }

        try send(["id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": "codex_bal_bar", "version": "1.0.0"]]])

        // Replies by request id: 2 = rate limits, 3 = token usage, 4 = account.
        var replies: [Int: [String: Any]] = [:]
        for try await line in output.fileHandleForReading.bytes.lines {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = message["id"] as? Int else { continue }
            if id == 1 {
                if let error = errorMessage(message) { throw FetchError(error) }
                try send(["method": "initialized", "params": [String: Any]()])
                try send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
                try send(["id": 3, "method": "account/usage/read", "params": NSNull()])
                try send(["id": 4, "method": "account/read", "params": ["refreshToken": false]])
                continue
            }
            guard (2...4).contains(id) else { continue }
            replies[id] = message
            guard let rateLimits = replies[2], let usage = replies[3], let account = replies[4] else { continue }

            // Check the login type first so an API-key login gets a clear
            // message rather than whatever error the rate-limit read returned.
            let accountResult = account["result"] as? [String: Any]
            if let error = errorMessage(rateLimits) {
                _ = try BalanceSnapshot(account: accountResult, rateLimits: [:], usage: nil)
                throw FetchError(error)
            }
            return try BalanceSnapshot(account: accountResult,
                                       rateLimits: rateLimits["result"] as? [String: Any] ?? [:],
                                       usage: usage["result"] as? [String: Any])
        }
        // Output can close before the process is reaped, so terminationReason
        // may not be readable yet; elapsed time tells a timeout from an exit.
        throw FetchError(ContinuousClock.now - started >= timeout
            ? "Timed out reading Codex rate limits"
            : "Codex app server exited before returning rate limits")
    }

    private static func errorMessage(_ reply: [String: Any]) -> String? {
        reply["error"].map { ($0 as? [String: Any])?["message"] as? String ?? "Codex request failed" }
    }
}

// MARK: - Model

@MainActor
final class BalanceModel: ObservableObject {
    @Published private(set) var snapshot: BalanceSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var claude: ClaudeSnapshot?
    @Published private(set) var claudeAccount: ClaudeAccount?
    @Published private(set) var claudeUsage: ClaudeUsage?
    @Published private(set) var claudeError: String?
    @Published private(set) var isRefreshingClaude = false
    private let claudeLog = ClaudeUsageLog()
    private var timer: Timer?
    private var claudeTimer: Timer?
    private var claudeFileDate: Date?
    private var wakeObserver: NSObjectProtocol?

    init() {
        let configured = ProcessInfo.processInfo.environment["CODEX_BAL_BAR_INTERVAL"].flatMap(TimeInterval.init)
        let interval = max(60, configured ?? 300)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = interval / 10
        // The Claude file is local and tiny, so check it often to keep the
        // menu bar close to what Claude Code last reported.
        claudeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadClaude() }
        }
        claudeTimer?.tolerance = 5
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // Claude's plan limits from the status line, usage credits from the
    // account, and token history from its logs, in Codex's snapshot shape so
    // both tabs show the same things the same way.
    var claudeSnapshot: BalanceSnapshot? {
        guard let fetchedAt = claudeAccount?.fetchedAt ?? claudeUsage?.scannedAt ?? claude?.capturedAt else { return nil }
        return BalanceSnapshot(meters: (claude?.meters ?? []) + (claudeAccount?.meters ?? []), creditBalance: nil,
                               limitReached: claudeAccount?.limitReached, planName: claudeAccount?.planName,
                               recentDays: claudeUsage?.recentDays ?? [], monthTokens: claudeUsage?.monthTokens,
                               lifetimeTokens: claudeUsage?.lifetimeTokens, streakDays: claudeUsage?.streakDays,
                               fetchedAt: fetchedAt)
    }

    func refreshIfStale() {
        if let snapshot, Date().timeIntervalSince(snapshot.fetchedAt) < 60 { return }
        refresh()
    }

    // Re-reads the Claude file when it changes, or with force to re-evaluate
    // reset times even when Claude Code has not written anything new.
    func reloadClaude(force: Bool = false) {
        let url = ClaudeSnapshot.fileURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || modified != claudeFileDate || claude?.meters.contains(where: { ($0.resetsAt ?? .distantFuture) <= Date() }) == true
        else { return }
        claudeFileDate = modified
        claude = ClaudeSnapshot.load(from: url)
    }

    // As with Codex, a failed fetch keeps the last reading and shows why.
    private func refreshClaude() {
        guard !isRefreshingClaude else { return }
        isRefreshingClaude = true
        let log = claudeLog
        Task {
            let scan = Task.detached(priority: .utility) { log.scan() }
            do {
                claudeAccount = try await ClaudeAccountClient.fetch()
                claudeError = nil
            } catch {
                claudeError = error.localizedDescription
            }
            claudeUsage = await scan.value
            isRefreshingClaude = false
        }
    }

    func refresh() {
        reloadClaude(force: true)
        refreshClaude()
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            do {
                snapshot = try await CodexClient.fetch()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isRefreshing = false
        }
    }
}

// MARK: - Styling

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
                           green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

enum Palette {
    static let accent = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let warning = Color(light: 0xFAB219, dark: 0xFAB219)
    static let critical = Color(light: 0xD03B3B, dark: 0xD03B3B)
}

enum Severity {
    case normal, low, critical

    init(remainingPercent: Int) {
        switch remainingPercent {
        case ...10: self = .critical
        case ...25: self = .low
        default: self = .normal
        }
    }

    var color: Color {
        switch self {
        case .normal: return Palette.accent
        case .low: return Palette.warning
        case .critical: return Palette.critical
        }
    }

    var label: (text: String, symbol: String)? {
        switch self {
        case .normal: return nil
        case .low: return ("Running low", "exclamationmark.triangle.fill")
        case .critical: return ("Almost out", "exclamationmark.octagon.fill")
        }
    }
}

func relativeTime(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: date, relativeTo: now)
}

func compactTokens(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
}

// MARK: - Menu bar label

enum Logo {
    static let size = NSSize(width: 16, height: 16)

    // The Codex app's own menu bar template, when it is installed; the asset
    // is read from that app at runtime rather than copied into this repo.
    static let codex: NSImage = {
        // Other OpenAI apps can claim a Codex bundle ID without shipping the
        // icon, so use the first app that actually has it.
        let image = ["com.openai.codex", "com.openai.codex.beta"].lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .compactMap { Bundle(url: $0)?.image(forResource: "codexTemplate") }
            .first
        if let image {
            image.size = size
            image.isTemplate = true
            return image
        }
        return drawnCodex
    }()

    // Fallback: a rounded tile with a ">_" prompt knocked out of it.
    static let drawnCodex = template { rect in
        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 5, yRadius: 5).fill()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        let prompt = NSBezierPath()
        prompt.lineWidth = 1.6
        prompt.lineCapStyle = .round
        prompt.lineJoinStyle = .round
        prompt.move(to: NSPoint(x: 4.5, y: 10.5))
        prompt.line(to: NSPoint(x: 7, y: 8))
        prompt.line(to: NSPoint(x: 4.5, y: 5.5))
        prompt.move(to: NSPoint(x: 8.5, y: 5.5))
        prompt.line(to: NSPoint(x: 11.5, y: 5.5))
        prompt.stroke()
    }

    // Claude's spark: rounded rays of alternating length around the center.
    static let claude = template { rect in
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let rays = NSBezierPath()
        rays.lineWidth = 1.7
        rays.lineCapStyle = .round
        for index in 0..<12 {
            let angle: Double = (Double(index) * 30 + 8) * .pi / 180
            let outer: Double = index.isMultiple(of: 2) ? 7.0 : 5.6
            let x = center.x + CGFloat(outer * cos(angle))
            let y = center.y + CGFloat(outer * sin(angle))
            rays.move(to: center)
            rays.line(to: NSPoint(x: x, y: y))
        }
        rays.stroke()
    }

    private static func template(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// Draws "[Codex] 62%  [Claude] 80%" as one template image so macOS tints the
// logos and text together for light and dark menu bars.
func menuBarImage(_ parts: [(logo: NSImage, text: String)]) -> NSImage {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.black]
    let texts = parts.map { NSAttributedString(string: $0.text, attributes: attributes) }
    let logoGap: CGFloat = 4
    let partGap: CGFloat = 9
    let height: CGFloat = 18
    let width = zip(parts, texts).reduce(CGFloat(0)) { $0 + $1.0.logo.size.width + logoGap + ceil($1.1.size().width) }
        + partGap * CGFloat(max(0, parts.count - 1))
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        var x: CGFloat = 0
        for (part, text) in zip(parts, texts) {
            let logoSize = part.logo.size
            part.logo.draw(in: NSRect(x: x, y: (height - logoSize.height) / 2, width: logoSize.width, height: logoSize.height))
            x += logoSize.width + logoGap
            let textSize = text.size()
            text.draw(at: NSPoint(x: x, y: (height - textSize.height) / 2))
            x += ceil(textSize.width) + partGap
        }
        return true
    }
    image.isTemplate = true
    return image
}

// Codex first, then Claude when it has reported a plan limit or usage credits.
@MainActor
func menuBarImage(model: BalanceModel) -> NSImage {
    let codex = model.snapshot?.headline.map { "\($0.usedPercent)%" } ?? "--"
    let claude = model.claudeSnapshot?.headline.map { "\($0.usedPercent)%" }
    var parts = [(logo: Logo.codex, text: codex)]
    if let claude { parts.append((logo: Logo.claude, text: claude)) }
    return menuBarImage(parts)
}

// MARK: - Panel

enum Service: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case claude = "Claude"

    var id: Self { self }
}

private struct PanelSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct BalancePanel: View {
    @ObservedObject var model: BalanceModel
    let onSizeChange: () -> Void
    @AppStorage("selectedService") private var service: Service = .codex
    @State private var swipeMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 260, maxWidth: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PanelSizePreferenceKey.self, value: geometry.size)
            }
        }
        .onPreferenceChange(PanelSizePreferenceKey.self) { _ in onSizeChange() }
        .onChange(of: service) { _, _ in onSizeChange() }
        .background { tabShortcuts }
        .onAppear {
            model.refreshIfStale()
            installSwipeMonitor()
        }
        .onDisappear(perform: removeSwipeMonitor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Service", selection: $service) {
                ForEach(Service.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let plan = shown.snapshot?.planName {
                Text(plan)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            if shown.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
                    .accessibilityLabel("Refresh")
                    .keyboardShortcut("r")
            }
        }
    }

    // Both tabs render one snapshot shape, so they always look alike.
    private var shown: (snapshot: BalanceSnapshot?, error: String?, isRefreshing: Bool) {
        switch service {
        case .codex: return (model.snapshot, model.errorMessage, model.isRefreshing)
        case .claude: return (model.claudeSnapshot, model.claudeError, model.isRefreshingClaude)
        }
    }

    @ViewBuilder private var content: some View {
        let shown = shown
        if let snapshot = shown.snapshot {
            // Re-render each minute so short reset countdowns stay current.
            TimelineView(.everyMinute) { context in
                BalanceSummary(snapshot: snapshot, now: context.date)
            }
            if snapshot.monthTokens != nil {
                Divider()
                UsageChart(days: snapshot.recentDays)
                StatRow(snapshot: snapshot)
            }
        } else if shown.error == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        }
        if let error = shown.error {
            Label {
                Text(error).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
            }
            .font(.callout)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let text = freshness(now: context.date) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                ForEach(Service.allCases) { page in
                    Circle()
                        .fill(page == service ? Color.primary : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 6)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
    }

    private func freshness(now: Date) -> String? {
        shown.snapshot.map { "Updated \(relativeTime($0.fetchedAt, now: max(now, $0.fetchedAt)))" }
    }

    // ⌘1 / ⌘2 jump straight to a tab.
    private var tabShortcuts: some View {
        ZStack {
            Button("Codex") { service = .codex }.keyboardShortcut("1")
            Button("Claude") { service = .claude }.keyboardShortcut("2")
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // A horizontal two-finger trackpad swipe flips tabs like pages: fingers
    // moving left reveal the next tab. One switch per gesture.
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        var travel: CGFloat = 0
        var switched = false
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return event }
            if event.phase.contains(.began) {
                travel = 0
                switched = false
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            travel += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            if !switched, abs(travel) > 40 {
                let pages = Service.allCases
                let index = pages.firstIndex(of: service) ?? 0
                let target = travel < 0 ? min(index + 1, pages.count - 1) : max(index - 1, 0)
                switched = true
                withAnimation(.easeInOut(duration: 0.15)) { service = pages[target] }
            }
            return nil
        }
    }

    private func removeSwipeMonitor() {
        if let swipeMonitor { NSEvent.removeMonitor(swipeMonitor) }
        swipeMonitor = nil
    }
}

func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
    Label {
        Text(text)
    } icon: {
        Image(systemName: symbol).foregroundStyle(color)
    }
    .font(.caption.weight(.medium))
}

// The tightest limit as a hero figure, then one row per limit.
struct LimitsSummary: View {
    let meters: [LimitMeter]
    let limitReached: String?
    let now: Date

    var body: some View {
        if let headline = headlineMeter(in: meters) {
            let severity = Severity(remainingPercent: headline.remainingPercent)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(headline.usedPercent)%").font(.system(size: 48, weight: .semibold))
                    Text("used").font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    if let limitReached {
                        statusLabel(limitReached, symbol: "xmark.octagon.fill", color: Palette.critical)
                    } else if let label = severity.label {
                        statusLabel(label.text, symbol: label.symbol, color: severity.color)
                    }
                }
                ForEach(meters) { meter in
                    MeterRow(meter: meter, now: now)
                }
            }
        }
    }
}

struct BalanceSummary: View {
    let snapshot: BalanceSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.meters.isEmpty {
                Text("No usage limits reported for this plan")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let reached = snapshot.limitReached {
                    statusLabel(reached, symbol: "xmark.octagon.fill", color: Palette.critical)
                }
            } else {
                LimitsSummary(meters: snapshot.meters, limitReached: snapshot.limitReached, now: now)
            }
            if let balance = snapshot.creditBalance {
                HStack {
                    Text("Credit balance")
                    Spacer()
                    Text(balance).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}


struct MeterRow: View {
    let meter: LimitMeter
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.title).font(.subheadline.weight(.medium))
                Spacer()
                Text(meter.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Meter(fraction: meter.usedFraction, color: Severity(remainingPercent: meter.remainingPercent).color)
                .accessibilityElement()
                .accessibilityLabel("\(meter.title) used")
                .accessibilityValue("\(meter.usedPercent) percent")
            if let resetsAt = meter.resetsAt {
                Text(resetText(resetsAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(resetsAt.formatted(date: .complete, time: .shortened))
            }
        }
    }

    // Short windows count down in hours and minutes; long ones show a date.
    private func resetText(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "Reset pending" }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            let minutes = max(1, seconds % 3_600 / 60)
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
        }
        let days = Int((Double(seconds) / 86_400).rounded(.up))
        return "Resets \(date.formatted(.dateTime.month(.abbreviated).day())) · \(days) \(days == 1 ? "day" : "days")"
    }
}

struct Meter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.22))
                if fraction > 0 {
                    Capsule().fill(color).frame(width: max(geometry.size.height, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: 8)
    }
}

struct UsageChart: View {
    let days: [DailyUsage]
    @State private var hovered: Date?

    // Weekly ticks from the oldest day, skipping any too close to the trailing
    // edge for its label to fit.
    private var axisDays: [Date] {
        days.indices.filter { $0 % 7 == 0 && $0 < days.count - 3 }.map { days[$0].day }
    }

    private var readout: String {
        if let hovered, let day = days.first(where: { $0.day == hovered }) {
            return "\(day.day.formatted(.dateTime.month(.abbreviated).day())) · \(compactTokens(day.tokens)) tokens"
        }
        return "\(compactTokens(days.reduce(0) { $0 + $1.tokens })) total"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily tokens, last \(BalanceSnapshot.chartDays) days").font(.subheadline.weight(.medium))
                Spacer()
                Text(readout).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Chart(days) { day in
                BarMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.tokens), width: .ratio(0.75))
                    .cornerRadius(2)
                    .foregroundStyle(Palette.accent.opacity(hovered == nil || hovered == day.day ? 1 : 0.35))
                    .accessibilityLabel(day.day.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(day.tokens) tokens")
            }
            .chartXAxis {
                AxisMarks(values: axisDays) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) { Text(compactTokens(tokens)) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let date: Date? = proxy.value(atX: location.x - geometry[plot].origin.x)
                                hovered = date.map { Calendar.current.startOfDay(for: $0) }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 110)
        }
    }
}

struct StatRow: View {
    let snapshot: BalanceSnapshot

    var body: some View {
        HStack(alignment: .top) {
            stat("This month", snapshot.monthTokens.map(compactTokens))
            Spacer()
            stat("Lifetime", snapshot.lifetimeTokens.map(compactTokens))
            Spacer()
            stat("Streak", snapshot.streakDays.map { "\($0) \($0 == 1 ? "day" : "days")" })
        }
    }

    private func stat(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "n/a").font(.title3.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - App

@MainActor
final class CodexBalanceDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = BalanceModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    private var hostingController: NSHostingController<BalancePanel>?
    private var modelUpdates: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = menuBarImage(model: model)
        item.button?.toolTip = "Codex and Claude usage"
        item.button?.setAccessibilityLabel("Codex and Claude usage")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 320, height: 240)
        let hostingController = NSHostingController(rootView: BalancePanel(model: model) { [weak self] in
            self?.resizePopover()
        })
        hostingController.sizingOptions = .preferredContentSize
        self.hostingController = hostingController
        popover.contentViewController = hostingController

        modelUpdates = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // A menu bar-only app is never active on its own, and a transient
            // popover only closes on outside clicks while its app is active.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Clicks in other apps never reach this one, so watch for them too.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover.performClose(nil) }
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    private func resizePopover() {
        guard let hostingController else { return }
        let ideal = hostingController.preferredContentSize
        guard ideal.width > 0, ideal.height > 0 else { return }
        let width = ceil(min(440, max(260, ideal.width)))
        let height = ceil(ideal.height)
        guard abs(popover.contentSize.width - width) > 1 || abs(popover.contentSize.height - height) > 1 else { return }
        popover.contentSize = NSSize(width: width, height: height)
    }

    private func updateStatusItem() {
        statusItem?.button?.image = menuBarImage(model: model)
    }
}

@main
struct CodexBalanceApp: App {
    @NSApplicationDelegateAdaptor(CodexBalanceDelegate.self) private var delegate

    init() {
        // A codex process that exits early closes its stdin; make writes to it
        // throw instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
