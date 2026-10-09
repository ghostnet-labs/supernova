// GitHub pull requests for Worktree Manager's worktrees and branches, looked up with the gh CLI's token.

import Foundation

enum PullRequestState: String, Sendable {
    case open = "Open", draft = "Draft", merged = "Merged", closed = "Closed"

    var isOpen: Bool { self == .open || self == .draft }
}

/// The rollup of the checks on a pull request's latest commit.
enum CheckState: Sendable {
    case success, failure, pending
}

enum ReviewState: Sendable {
    case approved, changesRequested, reviewRequired
}

struct PullRequestInfo: Hashable, Identifiable, Sendable {
    let number: Int
    let title: String
    let url: URL
    let state: PullRequestState
    let author: String
    /// Who merged it; nil unless merged.
    let mergedBy: String?
    let commits: Int
    /// The branch it merges into and the branch it comes from, such as main and feature-x.
    let baseRef: String
    let headRef: String
    let createdAt: Date
    let updatedAt: Date
    /// When it merged or closed; nil while open.
    let closedAt: Date?
    let additions: Int
    let deletions: Int
    /// Nil when the latest commit has no checks.
    let checks: CheckState?
    /// Nil when the repository doesn't require reviews and none was given.
    let review: ReviewState?
    /// The commit its branch pointed at last; for a merged one, the tip that merged.
    var headOid = ""

    var id: URL { url }
}

/// One repository's local branches, each mapped to its branch name on origin: `heads[local] = remote`.
struct PullRequestQuery: Sendable, Equatable {
    let repositoryRoot: String
    let heads: [String: String]
}

struct PullRequestLookup: Sendable {
    /// Each branch's most recent pull requests (at most `PullRequestClient.recentLimit`), newest first, keyed by
    /// `key(repositoryRoot:branch:)` with the local branch name. Branches without any are absent.
    var pulls: [String: [PullRequestInfo]] = [:]
    /// A short reason when some or all repositories couldn't be looked up; nil when every lookup succeeded.
    var error: String?

    /// The same form as `BranchRecord.id`.
    static func key(repositoryRoot: String, branch: String) -> String { repositoryRoot + "\u{0}" + branch }
}

enum PullRequestClient {
    static let recentLimit = 5
    /// The default branch, such as main, shows the newest pull requests into it rather than from it.
    static let defaultBranchLimit = 3
    /// Each head is its own pull request search, so larger repositories are split across requests.
    static let maxHeadsPerRequest = 50
    static let timeout: TimeInterval = 15
    static let signInMessage = "gh isn't signed in; run gh auth login"

    /// Looks up every query concurrently, off the main thread. Repositories whose origin isn't on github.com are skipped.
    static func lookup(_ queries: [PullRequestQuery]) async -> PullRequestLookup {
        let repositories = await resolve(queries)
        guard !repositories.isEmpty else { return PullRequestLookup() }
        guard let token = await offload({ tokens.current() }) else { return PullRequestLookup(error: signInMessage) }
        let results = await withTaskGroup(of: BatchResult.self) { group in
            for batch in batches(repositories) { group.addTask { await fetch(batch, token: token) } }
            return await group.reduce(into: [BatchResult]()) { $0.append($1) }
        }
        return merge(results)
    }

    // MARK: - Repositories

    struct Repository: Sendable {
        let root: String
        let owner: String
        let name: String
        /// Local branches by their branch name on origin; several local branches can share one.
        let branches: [String: [String]]
        /// origin's default branch, such as main, when a local branch tracks it.
        var defaultBranch: String? = nil
        var slug: String { "\(owner)/\(name)" }
    }

    /// owner and name when the remote is on github.com.
    static func slug(fromRemote remote: String, resolveHost: (String) -> String) -> (owner: String, name: String)? {
        guard let base = WorktreeActions.webBase(remote, resolveHost: resolveHost), let url = URL(string: base),
              url.host?.lowercased() == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private static func resolve(_ queries: [PullRequestQuery]) async -> [Repository] {
        await withTaskGroup(of: Repository?.self) { group in
            for query in queries where !query.heads.isEmpty {
                group.addTask {
                    await offload {
                        guard let remote = try? GitTool.run(["-C", query.repositoryRoot, "remote", "get-url", "origin"], timeout: 5),
                              let slug = slug(fromRemote: remote, resolveHost: hosts.resolve) else { return nil }
                        let base = (try? WorktreeActions.defaultBranch(query.repositoryRoot))
                            .map { $0.hasPrefix("origin/") ? String($0.dropFirst("origin/".count)) : $0 }
                        return Repository(root: query.repositoryRoot, owner: slug.owner, name: slug.name,
                                          branches: Dictionary(grouping: query.heads, by: \.value).mapValues { $0.map(\.key).sorted() },
                                          defaultBranch: base.flatMap { query.heads.values.contains($0) ? $0 : nil })
                    }
                }
            }
            return await group.reduce(into: [Repository]()) { if let repository = $1 { $0.append(repository) } }
        }
    }

    /// ssh -G answers for SSH host aliases such as github-work, kept for the app's lifetime.
    final class HostCache: @unchecked Sendable {
        private let lock = NSLock()
        private var hosts: [String: String] = [:]

        func resolve(_ alias: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            if let host = hosts[alias] { return host }
            let host = WorktreeActions.sshHostname(alias)
            hosts[alias] = host
            return host
        }
    }

    private static let hosts = HostCache()

    // MARK: - Token

    /// gh's token, read once and again only after GitHub rejects it.
    final class TokenCache: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?

        func current() -> String? {
            lock.lock()
            defer { lock.unlock() }
            if token == nil { token = PullRequestClient.readToken() }
            return token
        }

        /// Reads gh again after GitHub rejected `stale`; nil when gh still has that token or none.
        func refresh(replacing stale: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if token == stale { token = PullRequestClient.readToken() }
            return token == stale ? nil : token
        }
    }

    private static let tokens = TokenCache()

    /// The app's PATH is minimal, so also look where Homebrew installs gh.
    static func readToken() -> String? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        guard let gh = (path + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]).first(where: FileManager.default.isExecutableFile(atPath:)),
              let token = try? GitTool.run(["auth", "token"], executable: gh, timeout: 5), !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Requests

    struct Batch: Sendable {
        struct Part: Sendable {
            let repository: Repository
            /// Branch names on origin.
            let heads: [String]
            /// The default branch, set on the part whose heads include it, to also look up pull requests into it.
            var base: String? = nil
        }
        let parts: [Part]
    }

    /// One request per repository, split at `maxHeadsPerRequest`; the requests run concurrently.
    static func batches(_ repositories: [Repository]) -> [Batch] {
        repositories.flatMap { repository in
            let heads = repository.branches.keys.sorted()
            return stride(from: 0, to: heads.count, by: maxHeadsPerRequest).map { start in
                let chunk = Array(heads[start..<min(start + maxHeadsPerRequest, heads.count)])
                let base = repository.defaultBranch.flatMap { chunk.contains($0) ? $0 : nil }
                return Batch(parts: [.init(repository: repository, heads: chunk, base: base)])
            }
        }
    }

    private static let fields = "number title url state isDraft isCrossRepository createdAt updatedAt closedAt mergedAt "
        + "additions deletions reviewDecision baseRefName headRefName headRefOid headRepositoryOwner { login } author { login } mergedBy { login } "
        + "commits(last: 1) { totalCount nodes { commit { statusCheckRollup { state } } } }"

    /// Names travel as GraphQL variables, so no branch name can change the query.
    static func body(_ batch: Batch) -> Data {
        var declarations: [String] = [], selections: [String] = [], variables: [String: String] = [:]
        for (r, part) in batch.parts.enumerated() {
            declarations += ["$o\(r): String!", "$n\(r): String!"]
            variables["o\(r)"] = part.repository.owner
            variables["n\(r)"] = part.repository.name
            var pulls = part.heads.enumerated().map { h, head in
                declarations.append("$r\(r)h\(h): String!")
                variables["r\(r)h\(h)"] = head
                return "h\(h): pullRequests(headRefName: $r\(r)h\(h), first: \(recentLimit), "
                    + "orderBy: {field: CREATED_AT, direction: DESC}) { ...pulls }"
            }
            if let base = part.base {
                declarations.append("$r\(r)b: String!")
                variables["r\(r)b"] = base
                pulls.append("base: pullRequests(baseRefName: $r\(r)b, first: \(defaultBranchLimit), "
                    + "orderBy: {field: CREATED_AT, direction: DESC}) { ...pulls }")
            }
            selections.append("r\(r): repository(owner: $o\(r), name: $n\(r)) { \(pulls.joined(separator: " ")) }")
        }
        let query = "query(\(declarations.joined(separator: ", "))) { viewer { login } \(selections.joined(separator: " ")) } "
            + "fragment pulls on PullRequestConnection { nodes { \(fields) } }"
        return (try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])) ?? Data()
    }

    struct Response: Sendable {
        let status: Int
        let data: Data
        let remaining: String?
        let reset: String?
    }

    private static func post(_ body: Data, token: String) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return Response(status: http?.statusCode ?? 0, data: data, remaining: http?.value(forHTTPHeaderField: "x-ratelimit-remaining"),
                        reset: http?.value(forHTTPHeaderField: "x-ratelimit-reset"))
    }

    struct BatchResult: Sendable {
        var pulls: [String: [PullRequestInfo]] = [:]
        var errors: [String] = []
    }

    private static func fetch(_ batch: Batch, token: String) async -> BatchResult {
        do {
            let body = body(batch)
            var response = try await post(body, token: token)
            // gh may have replaced a revoked or expired token since it was read.
            if response.status == 401, let fresh = await offload({ tokens.refresh(replacing: token) }) {
                response = try await post(body, token: fresh)
            }
            guard response.status == 200 else { return BatchResult(errors: [message(response)]) }
            return parse(response.data, batch: batch)
        } catch {
            return BatchResult(errors: [message(error)])
        }
    }

    // MARK: - Diffs

    /// The REST address of a pull request's diff, from its page (https://github.com/owner/repo/pull/123).
    static func diffURL(for pull: PullRequestInfo) -> URL? {
        let parts = pull.url.path.split(separator: "/")
        guard pull.url.host?.lowercased() == "github.com", parts.count == 4, parts[2] == "pull" else { return nil }
        return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/pulls/\(parts[3])")
    }

    /// A pull request's changes as a unified diff, the text `gh pr diff` prints.
    static func diff(_ pull: PullRequestInfo) async throws -> String {
        guard let url = diffURL(for: pull) else { throw WorktreeError("\(pull.url.absoluteString) isn't a GitHub pull request") }
        guard let token = await offload({ tokens.current() }) else { throw WorktreeError(signInMessage) }
        func get(_ token: String) async throws -> Response {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github.diff", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            return Response(status: http?.statusCode ?? 0, data: data, remaining: http?.value(forHTTPHeaderField: "x-ratelimit-remaining"),
                            reset: http?.value(forHTTPHeaderField: "x-ratelimit-reset"))
        }
        do {
            var response = try await get(token)
            if response.status == 401, let fresh = await offload({ tokens.refresh(replacing: token) }) { response = try await get(fresh) }
            guard response.status == 200 else { throw WorktreeError(diffMessage(response)) }
            return String(decoding: response.data, as: UTF8.self)
        } catch let error as URLError {
            throw WorktreeError(message(error))
        }
    }

    static func diffMessage(_ response: Response) -> String {
        switch response.status {
        case 406: return "GitHub won't send a diff this large; open the pull request on GitHub instead"
        case 404: return "The signed-in gh account can't see this pull request"
        default: return message(response)
        }
    }

    // MARK: - Responses

    /// Keeps every repository that answered; a repository GitHub can't show adds an error instead.
    static func parse(_ data: Data, batch: Batch) -> BatchResult {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return BatchResult(errors: ["GitHub sent an unreadable response"])
        }
        let root = json["data"] as? [String: Any] ?? [:]
        let login = (root["viewer"] as? [String: Any])?["login"] as? String
        let dates = ISO8601DateFormatter()
        var result = BatchResult()
        for (r, part) in batch.parts.enumerated() {
            guard let repository = root["r\(r)"] as? [String: Any] else { continue }
            for (h, head) in part.heads.enumerated() {
                let nodes = (repository["h\(h)"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
                let pulls = nodes.compactMap { pull($0, dates: dates) }.sorted { $0.createdAt > $1.createdAt }.prefix(recentLimit)
                guard !pulls.isEmpty else { continue }
                for branch in part.repository.branches[head] ?? [] {
                    result.pulls[PullRequestLookup.key(repositoryRoot: part.repository.root, branch: branch)] = Array(pulls)
                }
            }
            // Pull requests into the default branch join any from it; the newest few are kept.
            if let base = part.base {
                let nodes = (repository["base"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
                let into = nodes.compactMap { pull($0, dates: dates, forks: true) }
                for branch in part.repository.branches[base] ?? [] {
                    let key = PullRequestLookup.key(repositoryRoot: part.repository.root, branch: branch)
                    var seen = Set<URL>()
                    let pulls = ((result.pulls[key] ?? []) + into).filter { seen.insert($0.url).inserted }
                    result.pulls[key] = pulls.isEmpty ? nil : Array(pulls.sorted { $0.createdAt > $1.createdAt }.prefix(defaultBranchLimit))
                }
            }
        }
        for error in json["errors"] as? [[String: Any]] ?? [] {
            let alias = (error["path"] as? [Any])?.first as? String
            let part = alias.flatMap { $0.hasPrefix("r") ? Int($0.dropFirst()) : nil }
                .flatMap { batch.parts.indices.contains($0) ? batch.parts[$0] : nil }
            let text = error["message"] as? String ?? "unknown error"
            switch (error["type"] as? String, part) {
            case ("RATE_LIMITED", _): result.errors.append(rateLimited(reset: nil))
            case ("NOT_FOUND", let part?): result.errors.append("No access to \(part.repository.slug)" + (login.map { " as \($0)" } ?? ""))
            case (_, let part?): result.errors.append("\(part.repository.slug): \(text)")
            default: result.errors.append("GitHub: \(text)")
            }
        }
        return result
    }

    /// `forks` keeps pull requests from forks, which only make sense when matching the branch they merge into:
    /// a fork's branch can share a local branch's name without being that branch.
    private static func pull(_ node: [String: Any], dates: ISO8601DateFormatter, forks: Bool = false) -> PullRequestInfo? {
        let fork = node["isCrossRepository"] as? Bool == true
        guard forks || !fork,
              let number = node["number"] as? Int, let title = node["title"] as? String,
              let url = (node["url"] as? String).flatMap(URL.init(string:)),
              let created = (node["createdAt"] as? String).flatMap(dates.date(from:)),
              let updated = (node["updatedAt"] as? String).flatMap(dates.date(from:)) else { return nil }
        let state: PullRequestState
        switch node["state"] as? String {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        case "OPEN": state = node["isDraft"] as? Bool == true ? .draft : .open
        default: return nil
        }
        let commits = node["commits"] as? [String: Any]
        let commit = (commits?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any]
        let checks: CheckState? = switch (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        case "PENDING", "EXPECTED": .pending
        default: nil
        }
        let review: ReviewState? = switch node["reviewDecision"] as? String {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: nil
        }
        let closed = ((node["mergedAt"] as? String) ?? (node["closedAt"] as? String)).flatMap(dates.date(from:))
        return PullRequestInfo(number: number, title: title, url: url, state: state,
                               author: (node["author"] as? [String: Any])?["login"] as? String ?? "ghost",
                               mergedBy: (node["mergedBy"] as? [String: Any])?["login"] as? String,
                               commits: commits?["totalCount"] as? Int ?? 0,
                               baseRef: node["baseRefName"] as? String ?? "", headRef: head(node, fork: fork),
                               createdAt: created, updatedAt: updated, closedAt: closed,
                               additions: node["additions"] as? Int ?? 0, deletions: node["deletions"] as? Int ?? 0,
                               checks: checks, review: review, headOid: node["headRefOid"] as? String ?? "")
    }

    /// The branch a pull request comes from; GitHub writes a fork's as owner:branch.
    private static func head(_ node: [String: Any], fork: Bool) -> String {
        let name = node["headRefName"] as? String ?? ""
        guard fork, let owner = (node["headRepositoryOwner"] as? [String: Any])?["login"] as? String else { return name }
        return "\(owner):\(name)"
    }

    static func message(_ response: Response) -> String {
        if response.status == 401 { return "GitHub rejected the gh token; run gh auth login" }
        let limited = response.remaining == "0" || String(decoding: response.data, as: UTF8.self).lowercased().contains("rate limit")
        if [403, 429].contains(response.status) && limited { return rateLimited(reset: response.reset) }
        return "GitHub returned HTTP \(response.status)"
    }

    private static func message(_ error: Error) -> String {
        if (error as? URLError)?.code == .timedOut { return "GitHub didn't answer within \(Int(timeout)) s" }
        return "Couldn't reach GitHub: \(error.localizedDescription)"
    }

    private static func rateLimited(reset: String?) -> String {
        guard let reset = reset.flatMap(Double.init) else { return "GitHub rate limit reached; try again later" }
        return "GitHub rate limit reached until \(Date(timeIntervalSince1970: reset).formatted(date: .omitted, time: .shortened))"
    }

    static func merge(_ results: [BatchResult]) -> PullRequestLookup {
        var lookup = PullRequestLookup(), errors: [String] = []
        for result in results {
            lookup.pulls.merge(result.pulls) { $1 }
            errors += result.errors.filter { !errors.contains($0) }
        }
        lookup.error = errors.isEmpty ? nil : errors.joined(separator: "; ")
        return lookup
    }

    private static func offload<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }
}
