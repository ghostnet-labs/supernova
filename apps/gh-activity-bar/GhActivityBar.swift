// GitHub Activity - a menu bar feed of locally cloned GitHub repositories.
// Built, installed, and launched by dotfiles/.bin/gh-activity-bar. The
// ghactivity shell function in dotfiles/functions/github.zsh uses the same
// event descriptions; keep that wording in step.

import AppKit
import Charts
import Combine
import SwiftUI

// MARK: - Data

struct LocalRepository {
    let name: String
    var checkouts: [URL]
}

enum LocalRepositories {
    static var root: String {
        let env = ProcessInfo.processInfo.environment
        return UserDefaults.standard.string(forKey: "repositoryRoot")
            ?? env["GH_ACTIVITY_BAR_ROOT"] ?? env["WORKTREE_MANAGER_ROOT"]
            ?? env["TW_PROJECT_ROOT"] ?? "\(NSHomeDirectory())/dev"
    }

    // Match Worktree Manager's immediate children of the project directory.
    // Reading origin works for normal clones, bare clones, and linked worktrees.
    static func scan(root: String) async throws -> [LocalRepository] {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let children = try fm.contentsOfDirectory(atPath: root).sorted()
            var hosts: [String: String] = [:]
            var repos: [String: LocalRepository] = [:]
            for child in children where !child.hasPrefix(".") {
                let path = "\(root)/\(child)"
                guard fm.fileExists(atPath: "\(path)/.git")
                    || (fm.fileExists(atPath: "\(path)/HEAD") && fm.fileExists(atPath: "\(path)/objects"))
                else { continue }
                guard let remote = output("/usr/bin/git", ["-C", path, "remote", "get-url", "origin"]),
                      let repo = name(remote: remote, resolveHost: { host in
                          if let cached = hosts[host] { return cached }
                          let resolved = output("/usr/bin/ssh", ["-G", host])?
                              .split(separator: "\n").first { $0.hasPrefix("hostname ") }
                              .map { String($0.dropFirst(9)) } ?? host
                          hosts[host] = resolved
                          return resolved
                      }) else { continue }
                repos[repo.lowercased(), default: LocalRepository(name: repo, checkouts: [])]
                    .checkouts.append(URL(fileURLWithPath: path, isDirectory: true))
            }
            return repos.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    static func name(remote: String, resolveHost: (String) -> String = { $0 }) -> String? {
        let host: String
        var path: String
        let ssh: Bool
        if remote.contains("://"), let url = URLComponents(string: remote), let hostname = url.host {
            guard ["https", "http", "ssh", "git"].contains(url.scheme ?? "") else { return nil }
            host = hostname
            path = url.path
            ssh = url.scheme == "ssh"
        } else {
            let parts = remote.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, !parts[0].contains("/") else { return nil }
            host = String(parts[0].split(separator: "@").last ?? "")
            path = String(parts[1])
            ssh = true
        }
        guard (ssh ? resolveHost(host) : host).lowercased() == "github.com" else { return nil }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        return path
    }

    private static func output(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && !result.isEmpty ? result : nil
    }
}

enum PullState: String {
    case open = "Open", draft = "Draft", merged = "Merged", closed = "Closed", queued = "Queued"

    var symbol: String {
        switch self {
        case .open: "git-pull-request"
        case .draft: "git-pull-request-draft"
        case .merged: "git-merge"
        case .closed: "git-pull-request-closed"
        case .queued: "git-merge-queue"
        }
    }

    // Transition actions are authoritative. Other events need explicit
    // fields: a closed payload without merged cannot distinguish a merge.
    static func recorded(action: String, pull: [String: Any]?) -> Self? {
        switch action {
        case "merged": return .merged
        case "converted_to_draft": return .draft
        case "ready_for_review": return .open
        case "enqueued": return .queued
        default: break
        }
        if pull?["merged"] as? Bool == true { return .merged }
        if action == "closed" || pull?["state"] as? String == "closed" {
            return pull?["merged"] as? Bool == false ? .closed : nil
        }
        if pull?["draft"] as? Bool == true { return .draft }
        if action == "opened" || action == "reopened" || pull?["state"] as? String == "open" {
            return pull?["draft"] as? Bool == false ? .open : nil
        }
        return nil
    }

    var color: Color {
        switch self {
        case .open: Color(light: 0x1F883D, dark: 0x238636)
        case .draft: Color(light: 0x59636E, dark: 0x656C76)
        case .merged: Color(light: 0x8250DF, dark: 0x8957E5)
        case .closed: Color(light: 0xCF222E, dark: 0xDA3633)
        case .queued: Color(light: 0x9A6700, dark: 0x9E6A03)
        }
    }
}

enum SymbolTone {
    case neutral, success, danger, done, attention

    var color: Color {
        switch self {
        case .neutral: Color(light: 0x59636E, dark: 0x9198A1)
        case .success: Color(light: 0x1A7F37, dark: 0x3FB950)
        case .danger: Color(light: 0xCF222E, dark: 0xF85149)
        case .done: Color(light: 0x8250DF, dark: 0xAB7DF8)
        case .attention: Color(light: 0x9A6700, dark: 0xD29922)
        }
    }
}

struct ActivityEvent: Identifiable {
    let id: String
    let type: String
    var actor: String
    var actorURL: URL
    var isBot: Bool
    var avatarURL: URL?
    let repo: String
    let createdAt: Date
    // What happened after the actor's name, such as "approved PR #12".
    let action: String
    // Event payloads no longer carry PR titles, so those arrive from a search
    // keyed by pullKey ("owner/repo#12", lower case) after the feed loads.
    var title: String?
    let pullKey: String?
    // The branch, tag, or fork shown beside the repo. Comments on a PR come
    // without branches and borrow them from the PR's other events.
    var ref: String?
    let refSymbol: String
    let url: URL
    let symbol: String
    var pullState: PullState? = nil
    var symbolTone: SymbolTone = .neutral
    var pullNumber: Int? = nil
    var mergeActorVerified = true
    var actorLabel: String { mergeActorVerified ? actor : "Merge actor unavailable" }

    var needsMergeActor: Bool { type == "PullRequestEvent" && pullState == .merged && !mergeActorVerified }

    mutating func apply(merger: MergeActor) {
        actor = merger.login
        actorURL = merger.url
        isBot = merger.isBot
        avatarURL = merger.avatarURL
        mergeActorVerified = true
    }

    var repoName: String { repo.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repo }
    var typeName: String { type.hasSuffix("Event") ? String(type.dropLast(5)) : type }
    var headline: String { action + (title.map { ": \(Self.untagged($0))" } ?? "") }
    var titleAction: String {
        guard title != nil, let pullNumber else { return action }
        if type == "PullRequest" { return "" }
        return action.replacingOccurrences(of: "PR #\(pullNumber)", with: "PR")
            .trimmingCharacters(in: .whitespaces)
    }
    var badgeAction: String {
        guard let pullState else { return titleAction }
        let verb = action.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let repeatsState: Bool
        switch pullState {
        case .merged: repeatsState = ["merged", "closed"].contains(verb)
        case .open: repeatsState = ["opened", "reopened", "ready_for_review", "dequeued"].contains(verb)
        case .draft: repeatsState = ["opened", "converted_to_draft"].contains(verb)
        case .closed: repeatsState = verb == "closed"
        case .queued: repeatsState = verb == "enqueued"
        }
        guard type == "PullRequest" || (type == "PullRequestEvent" && repeatsState) else { return titleAction }
        // Keep the number visible when a historical event has no title.
        return title == nil ? pullNumber.map { "#\($0)" } ?? "" : ""
    }

    // "[https://bugs.example.com/123][fix] Restore X" reads as "Restore X"; the full
    // title stays in the row's tooltip.
    static func untagged(_ title: String) -> String {
        let text = title.replacingOccurrences(of: #"^(\s*\[[^\]]*\])+[\s:-]*"#, with: "", options: .regularExpression)
        return text.isEmpty ? title : text
    }
}

struct FetchError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct MergeActor {
    let login: String
    let url: URL
    let avatarURL: URL?
    let isBot: Bool

    init?(json: [String: Any]) {
        guard let login = json["login"] as? String, !login.isEmpty,
              let url = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        self.login = clean(login)
        self.url = url
        avatarURL = (json["avatar_url"] as? String).flatMap(URL.init(string:))
        isBot = login.hasSuffix("[bot]") || json["type"] as? String == "Bot"
    }

    static func verified(fromPR data: Data, eventDate: Date) -> Self? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["merged"] as? Bool == true,
              let date = (json["merged_at"] as? String).flatMap({ try? Date($0, strategy: .iso8601) }),
              abs(date.timeIntervalSince(eventDate)) < 2,
              let actor = json["merged_by"] as? [String: Any] else { return nil }
        return Self(json: actor)
    }
}

private func clean(_ text: String) -> String {
    text.split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
}

struct OpenPullRequest: Identifiable {
    let event: ActivityEvent
    var id: String { event.id }

    init?(json: [String: Any]) {
        guard json["state"] as? String == "open", json["pull_request"] is [String: Any],
              let number = json["number"] as? Int, let title = json["title"] as? String,
              let api = json["repository_url"] as? String,
              let url = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let updated = (json["updated_at"] as? String).flatMap({ try? Date($0, strategy: .iso8601) })
        else { return nil }
        let repo = api.split(separator: "/").suffix(2).joined(separator: "/")
        let user = json["user"] as? [String: Any] ?? [:]
        let actor = user["login"] as? String ?? "?"
        let draft = json["draft"] as? Bool ?? false
        event = ActivityEvent(
            id: "\(repo)#\(number)".lowercased(), type: "PullRequest", actor: actor,
            actorURL: (user["html_url"] as? String).flatMap(URL.init(string:)) ?? url,
            isBot: actor.hasSuffix("[bot]"),
            avatarURL: (user["avatar_url"] as? String).flatMap(URL.init(string:)),
            repo: repo, createdAt: updated, action: "PR #\(number)",
            title: clean(title), pullKey: nil, ref: nil, refSymbol: "git-branch",
            url: url, symbol: draft ? "git-pull-request-draft" : "git-pull-request",
            pullState: draft ? .draft : .open, pullNumber: number)
    }
}

struct PullSearchResult {
    let pulls: [OpenPullRequest]
    let total: Int
    let incomplete: Bool
    var warnings: [String] = []

    init(pulls: [OpenPullRequest], total: Int, incomplete: Bool, warnings: [String] = []) {
        self.pulls = pulls
        self.total = total
        self.incomplete = incomplete
        self.warnings = warnings
    }

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]], let total = json["total_count"] as? Int
        else { throw FetchError("GitHub sent an unexpected PR search response") }
        pulls = items.compactMap(OpenPullRequest.init(json:))
        self.total = total
        incomplete = json["incomplete_results"] as? Bool ?? false
    }
}

extension ActivityEvent {
    // Mirrors ghactivity's describe() so the app and the terminal read alike.
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, let type = json["type"] as? String,
              let created = (json["created_at"] as? String).flatMap({ try? Date($0, strategy: .iso8601) })
        else { return nil }
        let actor = json["actor"] as? [String: Any] ?? [:]
        let login = actor["login"] as? String ?? "?"
        let repo = (json["repo"] as? [String: Any])?["name"] as? String ?? "?"
        let payload = json["payload"] as? [String: Any] ?? [:]
        let verb = payload["action"] as? String ?? ""
        let pullRequest = payload["pull_request"] as? [String: Any]
        let issue = payload["issue"] as? [String: Any]
        let repoURL = "https://github.com/\(repo)"
        // PR payloads still name their branches.
        let branches = ((pullRequest?["head"] as? [String: Any])?["ref"] as? String).flatMap { head in
            ((pullRequest?["base"] as? [String: Any])?["ref"] as? String).map { "\(head) → \($0)" }
        }

        var action: String
        var title: String?
        var pullKey: String?
        var pullNumber: Int?
        var ref: String?
        var refSymbol = "git-branch"
        var link = repoURL
        var symbol: String
        var pullState: PullState?
        var symbolTone = SymbolTone.neutral
        switch type {
        case "PushEvent":
            var branch = payload["ref"] as? String ?? ""
            if branch.hasPrefix("refs/heads/") { branch.removeFirst("refs/heads/".count) }
            action = "pushed"
            ref = branch
            if let head = payload["head"] as? String { link = "\(repoURL)/commit/\(head)" }
            symbol = "repo-push"
        case "PullRequestEvent", "PullRequestReviewEvent", "PullRequestReviewCommentEvent":
            let number = (payload["number"] ?? pullRequest?["number"]) as? Int
            pullNumber = number
            let label = "PR #\(number.map(String.init) ?? "?")"
            // Use the state recorded in this event, never a later search's
            // current state. Older payloads can omit state and draft fields.
            pullState = PullState.recorded(action: type == "PullRequestEvent" ? verb : "", pull: pullRequest)
            switch type {
            case "PullRequestEvent":
                action = "\(verb) \(label)"
                symbol = pullState?.symbol ?? "git-pull-request"
            case "PullRequestReviewEvent":
                let state = (payload["review"] as? [String: Any])?["state"] as? String
                action = (state == "approved" ? "approved" : state == "changes_requested" ? "requested changes on" : "reviewed")
                    + " \(label)"
                symbol = state == "approved" ? "check" : state == "changes_requested" ? "x" : "comment"
                symbolTone = state == "approved" ? .success : state == "changes_requested" ? .danger : .neutral
            default:
                action = "commented on \(label)"
                symbol = "comment"
            }
            title = pullRequest?["title"] as? String
            ref = branches
            if let number {
                link = "\(repoURL)/pull/\(number)"
                pullKey = "\(repo)#\(number)".lowercased()
            }
        case "IssuesEvent", "IssueCommentEvent":
            let number = (issue?["number"] as? Int).map(String.init) ?? "?"
            if type == "IssuesEvent" {
                action = "\(verb) issue #\(number)"
                symbol = "issue-opened"
                if ["opened", "reopened"].contains(verb) || issue?["state"] as? String == "open" {
                    symbolTone = .success
                }
                if verb == "reopened" { symbol = "issue-reopened" }
                if verb == "closed" || issue?["state"] as? String == "closed" {
                    symbolTone = issue?["state_reason"] as? String == "not_planned" ? .neutral : .done
                    symbol = symbolTone == .done ? "issue-closed" : "skip"
                }
            } else {
                let onPR = issue?["pull_request"] != nil
                action = "commented on \(onPR ? "PR" : "issue") #\(number)"
                symbol = "comment"
                if onPR {
                    pullKey = "\(repo)#\(number)".lowercased()
                    pullNumber = Int(number)
                }
            }
            title = issue?["title"] as? String
            if let html = issue?["html_url"] as? String { link = html }
        case "CreateEvent", "DeleteEvent":
            let refType = payload["ref_type"] as? String ?? ""
            action = "\(type == "CreateEvent" ? "created" : "deleted") \(refType)"
            ref = payload["ref"] as? String
            if refType == "tag" { refSymbol = "tag" }
            if type == "CreateEvent", let ref {
                link = refType == "tag" ? "\(repoURL)/releases/tag/\(ref)" : refType == "branch" ? "\(repoURL)/tree/\(ref)" : repoURL
            }
            symbol = refType == "tag" ? "tag" : refType == "branch" ? "git-branch"
                : type == "DeleteEvent" ? "trash" : "repo"
        case "ReleaseEvent":
            let release = payload["release"] as? [String: Any]
            action = "\(verb) release"
            ref = release?["tag_name"] as? String
            refSymbol = "tag"
            if let html = release?["html_url"] as? String { link = html }
            symbol = "tag"
        case "ForkEvent":
            let fork = (payload["forkee"] as? [String: Any])?["full_name"] as? String ?? "?"
            action = "forked"
            ref = fork
            refSymbol = "repo-forked"
            link = "https://github.com/\(fork)"
            symbol = "repo-forked"
        case "WatchEvent":
            action = "starred"
            symbol = "star"
        case "MemberEvent":
            action = "\(verb) member \((payload["member"] as? [String: Any])?["login"] as? String ?? "?")"
            symbol = "person"
        case "PublicEvent":
            action = "made public"
            symbol = "globe"
        case "GollumEvent":
            action = "edited wiki"
            link = "\(repoURL)/wiki"
            symbol = "book"
        case "CommitCommentEvent":
            let comment = payload["comment"] as? [String: Any]
            action = "commented on commit \(String((comment?["commit_id"] as? String ?? "").prefix(7)))"
            if let html = comment?["html_url"] as? String { link = html }
            symbol = "comment"
        default:
            action = type.hasSuffix("Event") ? String(type.dropLast(5)) : type
            symbol = "dot"
        }

        // Apps log in as "name[bot]"; their profile pages live under /apps.
        let isBot = login.hasSuffix("[bot]")
        let display = clean(actor["display_login"] as? String ?? login)
        self.init(
            id: id, type: type, actor: display,
            actorURL: URL(string: isBot ? "https://github.com/apps/\(display)" : "https://github.com/\(login)")
                ?? URL(string: "https://github.com")!,
            isBot: isBot,
            avatarURL: (actor["avatar_url"] as? String).flatMap { URL(string: $0 + ($0.contains("?") ? "&" : "?") + "s=48") },
            repo: repo, createdAt: created, action: clean(action), title: title.map(clean), pullKey: pullKey,
            ref: ref.map(clean), refSymbol: refSymbol,
            url: URL(string: link) ?? URL(string: repoURL) ?? URL(string: "https://github.com")!,
            symbol: symbol, pullState: pullState, symbolTone: symbolTone, pullNumber: pullNumber)
        if type == "PullRequestEvent", pullState == .merged {
            mergeActorVerified = false
            if let json = pullRequest?["merged_by"] as? [String: Any], let merger = MergeActor(json: json) {
                apply(merger: merger)
            }
        }
    }
}

// MARK: - GitHub client

private struct RateLimited: LocalizedError {
    let resetsAt: Date?
    var authenticated = false
    var primary = true

    var message: String {
        "GitHub's \(authenticated ? "login" : "anonymous") requests are paused"
            + (resetsAt.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
    }

    var errorDescription: String? { message }
}

struct RepositoryFeed {
    // Retain each repo's page so filtering can show quieter repositories
    // even when busier repos occupy all 50 rows in the combined feed.
    let repositoryEvents: [ActivityEvent]
    let failures: [String: String]
    var events: [ActivityEvent] { GitHubClient.latest(repositoryEvents) }
}

struct RepositorySelection: Equatable {
    // nil includes newly discovered clones; an empty set selects none.
    private(set) var names: Set<String>?
    var saved: [String]? { names?.sorted() }

    init(saved: [String]? = nil) { names = saved.map { Set($0.map { $0.lowercased() }) } }

    func includes(_ repo: String) -> Bool { names?.contains(repo.lowercased()) ?? true }

    mutating func set(_ repo: String, included: Bool, available: [String]) {
        var selected = names ?? Set(available.map { $0.lowercased() })
        if included { selected.insert(repo.lowercased()) }
        else { selected.remove(repo.lowercased()) }
        names = selected
    }
}

final class GitHubRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Renamed repositories redirect to /repositories/ID. URLSession drops
        // Authorization on that hop; retain it only within GitHub's HTTPS API.
        guard request.url?.scheme == "https", request.url?.host == "api.github.com",
              request.url?.port == nil || request.url?.port == 443 else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
                            forHTTPHeaderField: "Authorization")
        completionHandler(redirected)
    }
}

// Use the saved gh login for private clones and the larger authenticated quota.
// A personal repository can use its owner's saved account without switching gh.
@MainActor
final class GitHubClient {
    static let pageSize = 100
    nonisolated static let eventLimit = 50
    private var cache: [String: (etag: String, events: [ActivityEvent])] = [:]
    private var mergers: [String: MergeActor] = [:]
    private var retryAfter: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]
    private let now: () -> Date
    private let token: (String?) async -> String?
    private var credentials: [String: (loaded: Date, token: String?)] = [:]
    private var renamed: [String: String] = [:]

    init(now: @escaping () -> Date = Date.init,
         token: @escaping (String?) async -> String? = GitHubClient.ghToken) {
        self.now = now
        self.token = token
    }

    // Core and search quotas are separate, as are anonymous and login quotas.
    // Check every request so page fetches and optional lookups share backoff.
    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let authenticated = authorization != nil
        let resource = request.url!.path.hasPrefix("/search/") ? "search" : "core"
        let key = "\(authorization.map { String($0.hashValue) } ?? "anonymous") \(resource)"
        for scope in ["secondary", key] {
            if let until = retryAfter[scope], until > now() {
                throw RateLimited(resetsAt: until, authenticated: authenticated, primary: scope != "secondary")
            }
        }
        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request, delegate: GitHubRedirects())
        } catch {
            throw FetchError("Could not reach GitHub: \(error.localizedDescription)")
        }
        guard let http = result.1 as? HTTPURLResponse else { throw FetchError("GitHub sent an invalid response") }
        let exhausted = http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
        let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let message = [403, 429].contains(http.statusCode)
            ? ((try? JSONSerialization.jsonObject(with: result.0) as? [String: Any])?["message"] as? String ?? "")
            : ""
        let limited = [403, 429].contains(http.statusCode)
            && (exhausted || retry != nil || http.statusCode == 429 || message.localizedCaseInsensitiveContains("rate limit"))
        if exhausted || limited {
            let scope = exhausted ? key : "secondary"
            let reset = exhausted ? http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) : nil
            let delay = min((backoff[scope] ?? 30) * 2, 3_600)
            let until = max(reset.map { Date(timeIntervalSince1970: $0 + 1) } ?? .distantPast,
                            now().addingTimeInterval(retry.map { $0 + 1 } ?? (reset == nil ? delay : 1)))
            retryAfter[scope] = max(retryAfter[scope] ?? .distantPast, until)
            backoff[scope] = delay
            if limited { throw RateLimited(resetsAt: retryAfter[scope], authenticated: authenticated, primary: exhausted) }
        } else if (200...399).contains(http.statusCode) {
            backoff[key] = nil
            backoff["secondary"] = nil
        }
        return (result.0, http)
    }

    private func credential(user: String?) async -> String? {
        let key = user ?? "active"
        if let cached = credentials[key], now().timeIntervalSince(cached.loaded) < 900 { return cached.token }
        let value = await token(user)
        credentials[key] = (now(), value)
        return value
    }

    private func request(url: URL, repo: String) async -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let owner = repo.split(separator: "/").first.map(String.init)
        let personal = await credential(user: owner)
        let value = personal != nil ? personal : await credential(user: nil)
        if let value {
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // GitHub events can credit the PR author for an automated
    // merge. Only the PR record's merged_by is authoritative for this row.
    // Cache by event ID (immutable), with four concurrent requests and at
    // most four lookups per refresh. Later refreshes continue uncached rows.
    func verifiedMergers(for events: [ActivityEvent]) async -> [String: MergeActor] {
        let pending = Array(events.filter { $0.needsMergeActor && mergers[$0.id] == nil }.prefix(4))
        let tasks = pending.map { event in
            Task { @MainActor in (event.id, await self.fetchMerger(for: event)) }
        }
        for task in tasks {
            let (id, actor) = await task.value
            if let actor { mergers[id] = actor }
        }
        let ids = Set(events.map(\.id))
        mergers = mergers.filter { ids.contains($0.key) }
        return mergers
    }

    private func fetchMerger(for event: ActivityEvent) async -> MergeActor? {
        guard let number = event.pullNumber,
              let url = URL(string: "https://api.github.com/repos/\(event.repo)/pulls/\(number)") else { return nil }
        let request = await request(url: url, repo: event.repo)
        guard let result = try? await data(for: request), result.1.statusCode == 200 else { return nil }
        return MergeActor.verified(fromPR: result.0, eventDate: event.createdAt)
    }

    // Bound concurrency across repositories; each feed needs only its newest 50.
    func fetch(repos: [String]) async throws -> RepositoryFeed {
        let repos = canonicalRepositories(repos)
        var events: [ActivityEvent] = []
        var failures: [String: String] = [:]
        for start in stride(from: 0, to: repos.count, by: 4) {
            // Resolve credentials before spawning requests, once per account.
            var requests: [(String, URLRequest)] = []
            for repo in repos[start..<min(start + 4, repos.count)] {
                let url = URL(string: "https://api.github.com/repos/\(repo)/events?per_page=\(Self.eventLimit)")!
                requests.append((repo, await request(url: url, repo: repo)))
            }
            // Keep explicit task handles alive until every request in this batch
            // finishes. Task-group completion crashes in the optimized build.
            let tasks = requests.map { repo, request in
                Task { @MainActor () -> (String, Result<[ActivityEvent], Error>) in
                    do { return (repo, .success(try await self.page(request, repo: repo))) }
                    catch { return (repo, .failure(error)) }
                }
            }
            for task in tasks {
                let (repo, result) = await task.value
                switch result {
                case .success(let fetched): events += fetched
                case .failure(let error): failures[repo] = error.localizedDescription
                }
            }
        }
        if !repos.isEmpty, failures.count == repos.count {
            throw FetchError(failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        }
        return RepositoryFeed(repositoryEvents: events, failures: failures)
    }

    func canonicalRepositories(_ repos: [String]) -> [String] {
        var unique: [String: String] = [:]
        for repo in repos {
            let name = renamed[repo.lowercased()] ?? repo
            unique[name.lowercased()] = name
        }
        return unique.values.sorted()
    }

    nonisolated static func latest(_ events: [ActivityEvent], selection: RepositorySelection = RepositorySelection()) -> [ActivityEvent] {
        var seen = Set<String>()
        return Array(events.filter { selection.includes($0.repo) }.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }.filter { seen.insert($0.id).inserted }.prefix(eventLimit))
    }

    private func page(_ original: URLRequest, repo: String) async throws -> [ActivityEvent] {
        let key = "\(original.value(forHTTPHeaderField: "Authorization")?.hashValue ?? 0) \(original.url!)"
        var request = original
        if let etag = cache[key]?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await data(for: request)
        switch http.statusCode {
        case 200:
            guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw FetchError("GitHub sent an unexpected response")
            }
            let parsed = array.compactMap(ActivityEvent.init(json:))
            var canonical = repo
            if http.url?.host == "api.github.com", http.url?.path.hasPrefix("/repositories/") == true,
               let name = parsed.first?.repo, Set(parsed.map(\.repo)).count == 1 {
                canonical = name
                renamed[repo.lowercased()] = name
            }
            let events = parsed.filter { $0.repo.caseInsensitiveCompare(canonical) == .orderedSame }
            if let etag = http.value(forHTTPHeaderField: "ETag") { cache[key] = (etag, events) }
            else { cache[key] = nil }
            return events
        case 304:
            return cache[key]?.events ?? []
        default:
            throw responseError(data, http)
        }
    }

    private func responseError(_ data: Data, _ http: HTTPURLResponse) -> FetchError {
        if http.statusCode == 404 { return FetchError("Not found or inaccessible with the saved gh login") }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        return FetchError("GitHub returned HTTP \(http.statusCode)" + (message.map { ": \($0)" } ?? ""))
    }

    // One repo qualifier per search keeps every tab within the discovered set,
    // includes private PRs, and avoids GitHub's query-length limit.
    func openPulls(repos: [String]) async throws -> PullSearchResult {
        var pulls: [OpenPullRequest] = []
        var total = 0
        var incomplete = false
        var failures: [String] = []
        let repos = canonicalRepositories(repos)
        for repo in repos {
            do {
                let result = try await openPulls(repo: repo)
                pulls += result.pulls
                total += result.total
                incomplete = incomplete || result.incomplete
            } catch { failures.append("\(repo): \(error.localizedDescription)") }
        }
        if !repos.isEmpty, failures.count == repos.count { throw FetchError(failures.joined(separator: "\n")) }
        let sorted = pulls.sorted { $0.event.createdAt > $1.event.createdAt }
        return PullSearchResult(pulls: sorted, total: total, incomplete: incomplete, warnings: failures)
    }

    private func openPulls(repo: String) async throws -> PullSearchResult {
        var pulls: [OpenPullRequest] = []
        var total = 0
        var incomplete = false
        for page in 1...10 {
            let url = URL(string: "https://api.github.com/search/issues?q=repo:\(repo)+is:pr+is:open&sort=updated&order=desc&per_page=100&page=\(page)")!
            let request = await request(url: url, repo: repo)
            let (data, http) = try await data(for: request)
            guard http.statusCode == 200 else { throw responseError(data, http) }
            let result = try PullSearchResult(data: data)
            pulls += result.pulls.filter { $0.event.repo.caseInsensitiveCompare(repo) == .orderedSame }
            total = result.total
            incomplete = incomplete || result.incomplete
            if page * Self.pageSize >= min(total, 1_000) { break }
        }
        var seen = Set<String>()
        pulls = pulls.filter { seen.insert($0.id).inserted }
        return PullSearchResult(pulls: pulls, total: total, incomplete: incomplete || pulls.count < total)
    }

    func pullTitles(repos: [String]) async -> [String: String] {
        var titles: [String: String] = [:]
        for repo in repos {
            let url = URL(string: "https://api.github.com/search/issues?q=repo:\(repo)+is:pr&sort=updated&order=desc&per_page=100")!
            let request = await request(url: url, repo: repo)
            guard let (data, response) = try? await data(for: request), response.statusCode == 200 else { continue }
            titles.merge(Self.titles(fromSearch: data)) { _, new in new }
        }
        return titles
    }

    // Keys match ActivityEvent.pullKey: "owner/repo#12" in lower case.
    nonisolated static func titles(fromSearch data: Data) -> [String: String] {
        let items = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]] ?? []
        var titles: [String: String] = [:]
        for item in items {
            guard let number = item["number"] as? Int, let title = item["title"] as? String,
                  let api = item["repository_url"] as? String else { continue }
            let repo = api.split(separator: "/").suffix(2).joined(separator: "/")
            titles["\(repo)#\(number)".lowercased()] = clean(title)
        }
        return titles
    }

    // The login agent's PATH is minimal, so look where Homebrew installs gh.
    nonisolated static func ghToken(user: String? = nil) async -> String? {
        await Task.detached {
            let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
            guard let gh = (path + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"])
                .first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token", "--hostname", "github.com"] + (user.map { ["--user", $0] } ?? [])
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && !token.isEmpty ? token : nil
        }.value
    }
}

// MARK: - Model

struct RefreshCooldown {
    let interval: TimeInterval
    private(set) var nextAttempt = Date.distantPast

    init(interval: TimeInterval = 900) { self.interval = interval }

    mutating func begin(at now: Date = Date()) -> Bool {
        guard now >= nextAttempt else { return false }
        nextAttempt = now.addingTimeInterval(interval)
        return true
    }

    mutating func reset() { nextAttempt = .distantPast }
}

@MainActor
final class ActivityModel: ObservableObject {
    let repositoryRoot: String
    @Published private(set) var repos: [String] = []
    @Published private var localRepositories: [LocalRepository] = []
    @Published private var repositoryEvents: [ActivityEvent] = []
    @Published var repositorySelection: RepositorySelection {
        didSet {
            let key = "repositorySelection:\(repositoryRoot)"
            if let saved = repositorySelection.saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var pulls: [OpenPullRequest] = []
    @Published private(set) var pullsFetchedAt: Date?
    @Published private(set) var pullsError: String?
    @Published private(set) var pullsNotice: String?
    @Published private(set) var isRefreshingPulls = false
    @Published private(set) var lastSeen: Date?
    @Published var hideBots: Bool {
        didSet { defaults.set(hideBots, forKey: "hideBots") }
    }

    private let defaults: UserDefaults
    private let client: GitHubClient
    private let now: () -> Date
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var feedCooldown = RefreshCooldown()
    private var titles: [String: String] = [:]
    private var discoveredRepos: [String] = []

    init(repositoryRoot: String = LocalRepositories.root, defaults: UserDefaults = .standard,
         client: GitHubClient? = nil, now: @escaping () -> Date = Date.init) {
        self.repositoryRoot = repositoryRoot
        self.defaults = defaults
        self.client = client ?? GitHubClient()
        self.now = now
        let environment = ProcessInfo.processInfo.environment
        repositorySelection = RepositorySelection(saved: defaults.stringArray(forKey: "repositorySelection:\(repositoryRoot)"))
        hideBots = defaults.bool(forKey: "hideBots")
        lastSeen = (defaults.dictionary(forKey: "clonedLastSeen")?[repositoryRoot] as? Double)
            .map(Date.init(timeIntervalSince1970:))

        let configured = environment["GH_ACTIVITY_BAR_INTERVAL"].flatMap(TimeInterval.init)
        let interval = max(60, configured ?? 900)
        feedCooldown = RefreshCooldown(interval: interval)
        refresh()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var visibleEvents: [ActivityEvent] { hideBots ? events.filter { !$0.isBot } : events }
    var events: [ActivityEvent] { GitHubClient.latest(repositoryEvents, selection: repositorySelection) }
    var selectedPulls: [ActivityEvent] { pulls.map(\.event).filter { repositorySelection.includes($0.repo) } }
    var visiblePulls: [ActivityEvent] { selectedPulls.filter { !hideBots || !$0.isBot } }
    var selectedRepoCount: Int { repos.filter(repositorySelection.includes).count }
    var refreshMinutes: Int { Int(feedCooldown.interval / 60) }

    func checkoutURLs(for repo: String) -> [URL] {
        let checkouts = localRepositories.filter {
            client.canonicalRepositories([$0.name]).first?.caseInsensitiveCompare(repo) == .orderedSame
        }.flatMap(\.checkouts)
        return Array(Set(checkouts)).sorted { $0.path < $1.path }
    }

    private func refreshPulls() {
        guard !repos.isEmpty, !isRefreshingPulls else { return }
        isRefreshingPulls = true
        let requested = repos
        Task {
            do {
                let result = try await client.openPulls(repos: requested)
                if requested == repos {
                    pulls = result.pulls
                    pullsFetchedAt = Date()
                    pullsError = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
                    pullsNotice = result.incomplete
                        ? "Showing \(result.pulls.count) of \(result.total) PRs; GitHub search results are incomplete."
                        : nil
                }
            } catch {
                if requested == repos { pullsError = error.localizedDescription }
            }
            isRefreshingPulls = false
            if requested != repos { refreshPulls() }
        }
    }

    var newCount: Int {
        guard let lastSeen else { return 0 }
        return visibleEvents.lazy.filter { $0.createdAt > lastSeen }.count
    }

    func refresh() {
        guard !isRefreshing, feedCooldown.begin(at: now()) else { return }
        timer?.invalidate()
        isRefreshing = true
        Task {
            do {
                localRepositories = try await LocalRepositories.scan(root: repositoryRoot)
                let found = localRepositories.map(\.name)
                if found != discoveredRepos {
                    discoveredRepos = found
                    repos = client.canonicalRepositories(found)
                    let allowed = Set(repos.map { $0.lowercased() })
                    repositoryEvents.removeAll { !allowed.contains($0.repo.lowercased()) }
                    pulls.removeAll { !allowed.contains($0.event.repo.lowercased()) }
                    pullsFetchedAt = nil
                    pullsError = nil
                    pullsNotice = nil
                }
                let result = try await client.fetch(repos: repos)
                let canonical = client.canonicalRepositories(found)
                if canonical != repos {
                    repos = canonical
                }
                if let selected = repositorySelection.saved {
                    let canonicalSelection = RepositorySelection(saved: client.canonicalRepositories(selected))
                    if canonicalSelection != repositorySelection { repositorySelection = canonicalSelection }
                }
                refreshPulls()
                // Keep previously fetched rows for temporarily unavailable repos.
                let unavailable = Set(result.failures.keys.map { $0.lowercased() })
                let retained = repositoryEvents.filter { unavailable.contains($0.repo.lowercased()) }
                repositoryEvents = Self.filled(result.repositoryEvents + retained, titles: titles)
                fetchedAt = Date()
                errorMessage = result.failures.isEmpty ? nil : result.failures.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                if lastSeen == nil { markSeen() }
                let titleRepos = Set(repositoryEvents.filter { $0.pullKey != nil && $0.title == nil }.map(\.repo)).sorted()
                async let searched = client.pullTitles(repos: titleRepos)
                let mergers = await client.verifiedMergers(for: events)
                let keys = Set(repositoryEvents.compactMap(\.pullKey))
                titles = titles.merging(await searched) { $1 }.filter { keys.contains($0.key) }
                repositoryEvents = Self.filled(repositoryEvents, titles: titles).map { event in
                    var event = event
                    if event.needsMergeActor, let merger = mergers[event.id] { event.apply(merger: merger) }
                    return event
                }
            } catch {
                errorMessage = error.localizedDescription
                refreshPulls()
            }
            isRefreshing = false
            // Schedule from this cycle's start, not from a repeating timer that
            // can fire before the cooldown expires and skip an entire interval.
            let delay = max(1, feedCooldown.nextAttempt.timeIntervalSince(now()))
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer?.tolerance = min(delay / 10, 30)
        }
    }

    func markSeen() {
        guard let newest = events.first?.createdAt, newest > (lastSeen ?? .distantPast) else { return }
        lastSeen = newest
        var seen = defaults.dictionary(forKey: "clonedLastSeen") as? [String: Double] ?? [:]
        seen[repositoryRoot] = newest.timeIntervalSince1970
        defaults.set(seen, forKey: "clonedLastSeen")
    }

    // Gives PR events their searched titles, and comments on a PR, which
    // arrive without branches, the branches of the PR's other events.
    nonisolated static func filled(_ events: [ActivityEvent], titles: [String: String]) -> [ActivityEvent] {
        var branches: [String: String] = [:]
        for event in events {
            if let key = event.pullKey, let ref = event.ref { branches[key] = ref }
        }
        return events.map { event in
            guard let key = event.pullKey else { return event }
            var event = event
            if event.title == nil { event.title = titles[key] }
            if event.ref == nil { event.ref = branches[key] }
            return event
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
}

func relativeTime(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: date, relativeTo: now)
}

// "now", "42m", "5h", "3d": short enough for a feed row.
func shortAge(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    switch seconds {
    case ..<60: return "now"
    case ..<3_600: return "\(seconds / 60)m"
    case ..<86_400: return "\(seconds / 3_600)h"
    default: return "\(seconds / 86_400)d"
    }
}

// MARK: - Menu bar label

// Draws "[pulse] GitHub +12" as one template image so macOS tints it for light
// and dark menu bars. The count is events newer than the last panel visit.
@MainActor
func menuBarImage(model: ActivityModel) -> NSImage {
    let logo = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
    let count = model.newCount
    let label = "GitHub" + (count > 0 ? " +\(count)" : "")
    let text = NSAttributedString(string: label, attributes: [
        .font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.black,
    ])
    let gap: CGFloat = 4
    let height: CGFloat = 18
    let textSize = text.size()
    let width = logo.size.width + gap + ceil(textSize.width)
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        logo.draw(in: NSRect(x: 0, y: (height - logo.size.height) / 2, width: logo.size.width, height: logo.size.height))
        text.draw(at: NSPoint(x: logo.size.width + gap, y: (height - textSize.height) / 2))
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Panel

enum Tab: String, CaseIterable, Identifiable {
    case feed = "Feed"
    case summary = "Summary"
    case pulls = "PRs"

    var id: Self { self }
}

struct ActivityPanel: View {
    @ObservedObject var model: ActivityModel
    @AppStorage("selectedTab") private var tab: Tab = .feed
    @State private var showsRepositoryFilter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if tab != .pulls, let error = model.errorMessage, !model.events.isEmpty {
                errorLabel(error)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 420, height: 560)
        .background { tabShortcuts }
        .background(SwipeMonitor { direction in
            let tabs = Tab.allCases
            let index = tabs.firstIndex(of: tab) ?? 0
            tab = tabs[min(max(index + (direction == .summary ? 1 : -1), 0), tabs.count - 1)]
        })
        .onAppear { model.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                Menu {
                    Text(model.repositoryRoot)
                    Divider()
                    ForEach(model.repos, id: \.self) { repo in
                        Menu(repo) {
                            Button("Open in GitHub", systemImage: "arrow.up.right.square") {
                                NSWorkspace.shared.open(URL(string: "https://github.com/\(repo)")!)
                            }
                            Button("Reveal in Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting(model.checkoutURLs(for: repo))
                            }
                        }
                    }
                    Divider()
                    Button("Open clone folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: model.repositoryRoot))
                    }
                } label: {
                    Text("\(model.repos.count) cloned repos")
                }
                .menuStyle(.borderlessButton)
                .help("Following GitHub origins cloned in \(model.repositoryRoot)")
                Spacer()
                repositoryFilter
                if tab == .pulls ? model.isRefreshingPulls : model.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 16)
                } else {
                    Button {
                        model.refresh()
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Check for updates at most once every \(model.refreshMinutes) minutes")
                        .accessibilityLabel("Refresh")
                        .keyboardShortcut("r")
                        .frame(width: 16)
                }
            }
        }
    }

    private var repositoryFilter: some View {
        Button { showsRepositoryFilter.toggle() } label: {
            HStack(spacing: 4) {
                Label(model.selectedRepoCount == model.repos.count ? "All repos" : "\(model.selectedRepoCount) of \(model.repos.count) repos",
                      systemImage: "line.3.horizontal.decrease.circle")
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .disabled(model.repos.isEmpty)
        .accessibilityLabel("Filter repositories")
        .help("Select which repositories to show in Feed, Summary, and PRs")
        .popover(isPresented: $showsRepositoryFilter, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Repositories").font(.headline)
                    Spacer()
                    Button("Done") { showsRepositoryFilter = false }
                }
                HStack {
                    Button("Select All") { model.repositorySelection = RepositorySelection() }
                    Button("Clear All") { model.repositorySelection = RepositorySelection(saved: []) }
                }
                .buttonStyle(.link)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.repos, id: \.self) { repo in
                            Toggle(repo, isOn: Binding(
                                get: { model.repositorySelection.includes(repo) },
                                set: { model.repositorySelection.set(repo, included: $0, available: model.repos) }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(model.repos.count) * 28, 280))
            }
            .padding(12)
            .frame(width: 340)
        }
    }

    @ViewBuilder private var content: some View {
        let events = model.visibleEvents
        if model.repos.isEmpty, let error = model.errorMessage {
            errorLabel(error)
        } else if model.repos.isEmpty, model.isRefreshing {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else if model.repos.isEmpty {
            message("No cloned GitHub repositories",
                    detail: "Looking for GitHub origins directly inside \(model.repositoryRoot).")
        } else if model.selectedRepoCount == 0 {
            message("No repositories selected", detail: "Choose one or more repositories from the filter above.")
        } else if tab == .pulls {
            pullContent
        } else if events.isEmpty, let error = model.errorMessage {
            errorLabel(error)
        } else if model.fetchedAt == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else if events.isEmpty {
            message(model.events.isEmpty ? "No recent activity" : "Only bot activity",
                    detail: model.events.isEmpty
                        ? "No recent events are available for the selected repositories."
                        : "Turn off Hide bots to see the \(model.events.count) bot events.")
        } else {
            TimelineView(.everyMinute) { context in
                switch tab {
                case .feed:
                    FeedList(events: events, lastSeen: model.lastSeen, now: context.date)
                case .summary:
                    SummaryView(events: events, now: context.date)
                case .pulls:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder private var pullContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.pullsError { errorLabel(error) }
            if let notice = model.pullsNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            if model.pullsFetchedAt == nil {
                if model.pullsError == nil { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
            } else if model.visiblePulls.isEmpty {
                message(model.selectedPulls.isEmpty ? "No open PRs" : "Only bot PRs",
                        detail: model.selectedPulls.isEmpty
                            ? "The selected repositories have no open pull requests, including drafts."
                            : "Turn off Hide bots to see open PRs authored by bots.")
            } else {
                Text("\(model.visiblePulls.count) open PRs · includes drafts")
                    .font(.caption).foregroundStyle(.secondary)
                TimelineView(.everyMinute) { context in
                    FeedList(events: model.visiblePulls, lastSeen: nil, now: context.date)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("Hide bots", isOn: $model.hideBots)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let fetchedAt = tab == .pulls ? model.pullsFetchedAt : model.fetchedAt {
                    Text("Updated \(relativeTime(fetchedAt, now: max(context.date, fetchedAt)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorLabel(_ error: String) -> some View {
        Label {
            Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
        }
        .font(.callout)
    }

    // ⌘1 / ⌘2 / ⌘3 jump straight to a tab.
    private var tabShortcuts: some View {
        ZStack {
            Button("Feed") { tab = .feed }.keyboardShortcut("1")
            Button("Summary") { tab = .summary }.keyboardShortcut("2")
            Button("PRs") { tab = .pulls }.keyboardShortcut("3")
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// A two-finger trackpad swipe switches tabs the way Safari swipes between
// pages: fingers left advance a tab, fingers right go back. A gesture
// switches at most once, and one that starts out vertical is left to scroll.
struct SwipeTracker {
    static let distance: CGFloat = 40
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var decided = false

    // fingerDX is positive when the fingers move right.
    mutating func track(phase: NSEvent.Phase, fingerDX: CGFloat, dy deltaY: CGFloat) -> Tab? {
        if phase == .began {
            (dx, dy, decided) = (0, 0, false)
        } else if phase != .changed {
            return nil // ended, cancelled, momentum, or a mouse wheel
        }
        guard !decided else { return nil }
        dx += fingerDX
        dy += deltaY
        guard max(abs(dx), abs(dy)) >= Self.distance else { return nil }
        decided = true
        return abs(dx) > 2 * abs(dy) ? (dx < 0 ? .summary : .feed) : nil
    }
}

struct SwipeMonitor: NSViewRepresentable {
    let onSwipe: (Tab) -> Void

    func makeNSView(context: Context) -> SwipeMonitorView { SwipeMonitorView() }
    func updateNSView(_ view: SwipeMonitorView, context: Context) { view.onSwipe = onSwipe }
}

// Observe scrolling and outside-field clicks without consuming either event.
final class SwipeMonitorView: NSView {
    var onSwipe: ((Tab) -> Void)?
    private var tracker = SwipeTracker()
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = window == nil ? nil : NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.window === window else { return }
        if event.type == .leftMouseDown {
            if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
               let field = editor.delegate as? NSTextField,
               !field.convert(field.bounds, to: nil).contains(event.locationInWindow) {
                window?.makeFirstResponder(nil)
            }
            return
        }
        guard event.hasPreciseScrollingDeltas else { return }
        // With natural scrolling the delta already follows the fingers.
        let fingerDX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if let tab = tracker.track(phase: event.phase, fingerDX: fingerDX, dy: event.scrollingDeltaY) {
            onSwipe?(tab)
        }
    }
}

struct FeedList: View {
    let events: [ActivityEvent]
    let lastSeen: Date?
    let now: Date

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(events) { event in
                    EventRow(event: event, isNew: lastSeen.map { event.createdAt > $0 } ?? false, now: now)
                }
            }
        }
        .scrollIndicators(.automatic)
    }
}

// GitHub Primer's small StateLabel: white Octicon and text in a colored pill.
struct PullStateBadge: View {
    let state: PullState

    var body: some View {
        HStack(spacing: 4) {
            Octicons.swiftUIImage(state.symbol).frame(width: 16, height: 16)
            Text(state.rawValue)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.color, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.rawValue) pull request")
    }
}

struct EventRow: View {
    let event: ActivityEvent
    let isNew: Bool
    let now: Date
    @State private var hovering = false

    private var titleText: Text {
        let title = Text(ActivityEvent.untagged(event.title ?? ""))
        guard let number = event.pullNumber else { return title }
        return title + Text(" #\(number)").foregroundStyle(SymbolTone.neutral.color)
    }

    private var headlineText: Text {
        let action = Text(event.actorLabel).fontWeight(.semibold) + Text(" \(event.titleAction)")
        return event.title == nil ? action : action + Text(": ") + titleText
    }

    var body: some View {
        Button { NSWorkspace.shared.open(event.url) } label: {
            HStack(alignment: .top, spacing: 9) {
                AsyncImage(url: event.mergeActorVerified ? event.avatarURL : nil) { image in
                    image.resizable()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 22, height: 22)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    if let state = event.pullState {
                        HStack(spacing: 6) {
                            PullStateBadge(state: state)
                            if event.symbolTone != .neutral {
                                Octicons.swiftUIImage(event.symbol).foregroundStyle(event.symbolTone.color)
                            }
                            Text([event.badgeAction, event.actorLabel].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if event.title != nil {
                            titleText
                                .font(.callout).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("\(Text(Octicons.swiftUIImage(event.symbol)).foregroundStyle(event.symbolTone.color)) \(headlineText)")
                        .font(.callout)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    // The repo keeps its whole name; a long branch gives way in the middle.
                    HStack(spacing: 10) {
                        Text("\(Octicons.swiftUIImage("repo")) \(event.repoName)")
                            .layoutPriority(1)
                        if let ref = event.ref {
                            Text("\(Octicons.swiftUIImage(event.refSymbol)) \(ref)")
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(SymbolTone.neutral.color)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    if isNew {
                        Circle().fill(Palette.accent).frame(width: 7, height: 7).accessibilityLabel("New")
                    }
                    Text(shortAge(event.createdAt, now: now)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help((event.title.map { "\($0)\n" } ?? "")
            + "\(event.createdAt.formatted(date: .abbreviated, time: .shortened)) · open on GitHub")
    }
}

struct SummaryView: View {
    let events: [ActivityEvent]
    let now: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let oldest = events.last?.createdAt {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(events.count)").font(.system(size: 40, weight: .semibold)).monospacedDigit()
                            Text("recent events").font(.title3).foregroundStyle(.secondary)
                        }
                        Text("Since \(oldest.formatted(date: .abbreviated, time: .shortened)), \(relativeTime(oldest, now: now))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ActivityChart(events: events)
                RankList(title: "Repositories", rows: ranked(events.map { ($0.repoName, URL(string: "https://github.com/\($0.repo)")) }))
                RankList(title: "People", rows: ranked(events.map { ($0.actorLabel, $0.mergeActorVerified ? $0.actorURL : nil) }))
                RankList(title: "Event types", rows: ranked(events.map { ($0.typeName, nil) }))
            }
            .padding(.trailing, 4)
        }
    }

    private func ranked(_ items: [(String, URL?)]) -> [RankList.Row] {
        var counts: [String: (count: Int, url: URL?)] = [:]
        for (name, url) in items { counts[name, default: (0, url)].count += 1 }
        return counts.map { RankList.Row(name: $0.key, count: $0.value.count, url: $0.value.url) }
            .sorted { ($1.count, $0.name) < ($0.count, $1.name) }
            .prefix(5).map { $0 }
    }
}

struct ActivityChart: View {
    let unit: Calendar.Component
    let buckets: [(start: Date, count: Int)]

    // The feed can carry a stray event from weeks back, so the newest 95%
    // set the time span: hourly bars for a busy org's few hours, daily or
    // weekly for a quiet org whose events reach back weeks.
    init(events: [ActivityEvent]) {
        let charted = events.prefix(max(1, Int((Double(events.count) * 0.95).rounded(.up))))
        let span = charted.first.map { $0.createdAt.timeIntervalSince(charted.last!.createdAt) } ?? 0
        unit = span <= 2 * 86_400 ? .hour : span <= 45 * 86_400 ? .day : .weekOfYear
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for event in charted {
            if let start = calendar.dateInterval(of: unit, for: event.createdAt)?.start { counts[start, default: 0] += 1 }
        }
        buckets = counts.map { ($0.key, $0.value) }.sorted { $0.start < $1.start }
    }

    var body: some View {
        let unitName = unit == .hour ? "hour" : unit == .day ? "day" : "week"
        VStack(alignment: .leading, spacing: 6) {
            Text("Events per \(unitName)").font(.subheadline.weight(.medium))
            Chart(buckets, id: \.start) { bucket in
                BarMark(x: .value("Time", bucket.start, unit: unit), y: .value("Events", bucket.count))
                    .cornerRadius(2)
                    .foregroundStyle(Palette.accent)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                }
            }
            .frame(height: 90)
        }
    }
}

struct RankList: View {
    struct Row: Identifiable {
        let name: String
        let count: Int
        let url: URL?
        var id: String { name }
    }

    let title: String
    let rows: [Row]

    var body: some View {
        let top = max(1, rows.first?.count ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    if let url = row.url {
                        Link(row.name, destination: url).foregroundStyle(.primary)
                    } else {
                        Text(row.name)
                    }
                    Spacer(minLength: 8)
                    Text("\(row.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
                .lineLimit(1)
                .background(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(Palette.accent.opacity(0.14))
                            .frame(width: geometry.size.width * CGFloat(row.count) / CGFloat(top))
                    }
                    .padding(.horizontal, -4)
                }
            }
        }
    }
}

// MARK: - App

@MainActor
final class ActivityDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = ActivityModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    private var modelUpdates: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = menuBarImage(model: model)
        item.button?.toolTip = "GitHub activity from cloned repositories"
        item.button?.setAccessibilityLabel("GitHub activity from cloned repositories")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(rootView: ActivityPanel(model: model))

        modelUpdates = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Activate the menu bar app so keyboard shortcuts reach the panel.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            popover.contentViewController?.view.window?.makeFirstResponder(nil)
            // Clicks in other apps, such as another menu bar item, never reach
            // this one, so the transient popover would stay open without this.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover.performClose(nil) }
            }
        }
    }

    // New-event dots stay visible while the panel is open and clear on close.
    func popoverDidClose(_ notification: Notification) {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        model.markSeen()
    }

    private func updateStatusItem() {
        statusItem?.button?.image = menuBarImage(model: model)
    }
}

@main
struct GitHubActivityApp: App {
    @NSApplicationDelegateAdaptor(ActivityDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
