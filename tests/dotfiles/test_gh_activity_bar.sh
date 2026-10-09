#!/usr/bin/env bash
# setup-test: GitHub Activity menu bar app
# Offline checks for the gh-activity-bar command and the app's event parsing.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMAND="$REPO_DIR/dotfiles/.bin/gh-activity-bar"
APP_SOURCE="$REPO_DIR/apps/gh-activity-bar/GhActivityBar.swift"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gh-activity-bar-test.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

help_output="$("$COMMAND" --help)" || fail_test "--help failed"
remaining="$help_output"
for section in "Usage:" "Description:" "Options:" "Examples:" "Environment:"; do
  [[ "$remaining" == *"$section"* ]] || fail_test "help is missing or misorders $section"
  remaining="${remaining#*"$section"}"
done

expect_usage_error() {
  local expected="$1" output status=0
  shift
  output="$("$COMMAND" "$@" 2>&1)" || status=$?
  [[ "$status" == 2 ]] || fail_test "gh-activity-bar $* returned $status"
  assert_contains "$output" "$expected"
}
expect_usage_error "unknown option: --unknown" --unknown
expect_usage_error "--root needs a directory" --root
expect_usage_error "clone directory not found:" --root "$TMP_ROOT/missing"
expect_usage_error "unknown option: --org" --org
expect_usage_error "Usage:" --install --start

# The app is macOS only; Linux Swift cannot typecheck AppKit code, and
# gh-activity-bar refuses to run off macOS.
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf '[SKIP] app checks need macOS and swiftc\n'
  exit 0
fi

# Build the app's code without its @main entry point, plus a small driver that
# prints how it reads fixture events, so the parsing is checked offline.
# Match the installed release build: the repository task-group regression
# only reproduces with optimization enabled.
sed '/^@main$/d' "$APP_SOURCE" >"$TMP_ROOT/App.swift"
printf '%s\n' 'import AppKit

final class EventPages: URLProtocol {
    typealias Reply = (status: Int, headers: [String: String], data: Data)
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var requests: [URLRequest] = []
    static var count: Int { lock.withLock { requests.count } }
    static var anonymousCount: Int {
        lock.withLock { requests.filter { $0.value(forHTTPHeaderField: "Authorization") == nil }.count }
    }
    static func stub(_ handler: @escaping (URLRequest) -> Reply) {
        lock.withLock { self.handler = handler; requests = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { Self.requests.append(request); return Self.handler?(request) }
        if let reply { finish(reply); return }
        preconditionFailure("Unexpected network request: \(request.url!)")
    }
    private func finish(_ reply: Reply) {
        let finalURL = reply.headers["Test-Redirect"].flatMap(URL.init(string:)) ?? request.url!
        let response = HTTPURLResponse(url: finalURL, statusCode: reply.status, httpVersion: nil,
                                       headerFields: reply.headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: reply.data)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct Check {
    static func main() async throws {
        URLProtocol.registerClass(EventPages.self)
        defer { URLProtocol.unregisterClass(EventPages.self) }
        try await checkRepositories()
        try await checkFeeds()
        try await checkPolling()
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let array = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        // PR titles come from a search, and PR comments borrow branches, as the app fills them.
        let titles = GitHubClient.titles(fromSearch: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        print("titles:" + titles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
        let parsed = array.map(ActivityEvent.init(json:))
        var filled = ActivityModel.filled(parsed.compactMap { $0 }, titles: titles).makeIterator()
        for json in parsed {
            guard json != nil, let event = filled.next() else { print("unparsed"); continue }
            let symbols = [event.symbol, event.refSymbol, "repo"]
                .allSatisfy { Octicons.image($0) != nil } ? "symbols" : "missing-symbol"
            print([event.actor, event.repoName, event.headline, event.ref ?? "-", event.url.absoluteString,
                   event.actorURL.absoluteString, event.isBot ? "bot" : "person", symbols].joined(separator: "|"))
        }
        for title in ["[https://bugs.example.com/1][fix] Restore X", "[None][feat]: Add Y", "[only]", "Plain [not a prefix]"] {
            print("untagged:\(title)=\(ActivityEvent.untagged(title))")
        }
        // The PR tab must include drafts and exclude closed PRs and issues.
        func searchPull(_ number: Int, draft: Bool) -> [String: Any] {
            ["state": "open", "pull_request": [:], "number": number, "draft": draft,
             "title": "[fix] Retry uploads", "repository_url": "https://api.github.com/repos/acme/rocket",
             "html_url": "https://github.com/acme/rocket/pull/\(number)",
             "updated_at": "2026-10-04T12:00:00Z", "user": ["login": "alice"]]
        }
        var closed = searchPull(3, draft: false)
        closed["state"] = "closed"
        var issue = searchPull(4, draft: false)
        issue.removeValue(forKey: "pull_request")
        let search = try JSONSerialization.data(withJSONObject: ["total_count": 2, "incomplete_results": true,
            "items": [searchPull(1, draft: false), searchPull(2, draft: true), closed, issue]])
        let pulls = try PullSearchResult(data: search)
        precondition(pulls.total == 2 && pulls.incomplete && pulls.pulls.count == 2)
        precondition(pulls.pulls.map { $0.event.pullState } == [.open, .draft])
        precondition(pulls.pulls.map { $0.event.pullNumber } == [1, 2])
        precondition(pulls.pulls.allSatisfy { $0.event.badgeAction.isEmpty })
        precondition(OpenPullRequest(json: [:]) == nil)
        // Historical states must not be guessed from incomplete event data.
        for (action, pull, expected) in [
            ("opened", ["draft": false], PullState.open),
            ("opened", ["draft": true], .draft),
            ("closed", ["merged": true], .merged),
            ("closed", ["merged": false], .closed),
            ("merged", [:], .merged),
            ("converted_to_draft", ["draft": false], .draft),
            ("ready_for_review", ["draft": true], .open),
            ("enqueued", [:], .queued)
        ] {
            precondition(PullState.recorded(action: action, pull: pull) == expected)
            precondition(Octicons.image(expected.symbol)?.size == NSSize(width: 16, height: 16))
        }
        precondition(PullState.recorded(action: "opened", pull: nil) == nil)
        precondition(PullState.recorded(action: "closed", pull: [:]) == nil)
        precondition(PullState.recorded(action: "labeled", pull: nil) == nil)
        // Exercise actual event mapping as well as the status resolver.
        func fixture(_ type: String, _ payload: [String: Any]) -> ActivityEvent {
            ActivityEvent(json: ["id": "fixture", "type": type, "created_at": "2026-10-04T12:00:00Z",
                "actor": ["login": "alice"], "repo": ["name": "acme/rocket"], "payload": payload])!
        }
        for (type, payload, icon, tone) in [
            ("PushEvent", [:], "repo-push", SymbolTone.neutral),
            ("ForkEvent", [:], "repo-forked", .neutral),
            ("CreateEvent", ["ref_type": "branch"], "git-branch", .neutral),
            ("DeleteEvent", ["ref_type": "tag"], "tag", .neutral),
            ("ReleaseEvent", ["action": "published"], "tag", .neutral),
            ("WatchEvent", [:], "star", .neutral),
            ("PullRequestReviewEvent", ["review": ["state": "approved"]], "check", .success),
            ("PullRequestReviewEvent", ["review": ["state": "changes_requested"]], "x", .danger),
            ("IssuesEvent", ["action": "reopened"], "issue-reopened", .success),
            ("IssuesEvent", ["action": "closed"], "issue-closed", .done),
            ("IssuesEvent", ["action": "closed", "issue": ["state_reason": "not_planned"]], "skip", .neutral)
        ] {
            let event = fixture(type, payload)
            precondition(event.symbol == icon && event.symbolTone == tone)
            precondition(Octicons.image(icon) != nil)
        }
        // Regression: protobufs PR #3 credits its author in the org event,
        // but the PR record and timeline credit github-actions[bot].
        var merge = fixture("PullRequestEvent", ["action": "merged", "number": 3])
        precondition(merge.actor == "alice" && merge.actorLabel == "Merge actor unavailable")
        let pr = Data(#"{"merged":true,"merged_at":"2026-10-04T12:00:00Z","merged_by":{"login":"github-actions[bot]","type":"Bot","html_url":"https://github.com/apps/github-actions","avatar_url":"https://avatars.githubusercontent.com/in/15368?v=4"}}"#.utf8)
        let merger = MergeActor.verified(fromPR: pr, eventDate: merge.createdAt)!
        merge.apply(merger: merger)
        precondition(merge.actorLabel == "github-actions[bot]" && merge.isBot && merge.mergeActorVerified)
        precondition(merge.actorURL.absoluteString == "https://github.com/apps/github-actions")
        precondition(merge.avatarURL?.absoluteString == "https://avatars.githubusercontent.com/in/15368?v=4")
        precondition(MergeActor.verified(fromPR: pr, eventDate: merge.createdAt.addingTimeInterval(60)) == nil)
        precondition(MergeActor.verified(fromPR: Data("{}".utf8), eventDate: merge.createdAt) == nil)
        precondition(fixture("PullRequestEvent", ["action": "opened"]).actorLabel == "alice")
        precondition(fixture("PullRequestEvent", ["action": "merged"]).pullState == .merged)
        precondition(fixture("PullRequestEvent", ["action": "closed"]).pullState == nil)
        // Each gesture is a list of (phase, finger dx, dy) scroll events.
        let gestures: [(String, [(NSEvent.Phase, CGFloat, CGFloat)])] = [
            ("left", [(.began, -5, 0), (.changed, -20, 2), (.changed, -20, 1), (.changed, -30, 0)]),
            ("right", [(.began, 10, 0), (.changed, 35, -3)]),
            ("vertical", [(.began, 0, 10), (.changed, -5, 40)]),
            ("diagonal", [(.began, -25, 15), (.changed, -20, 10)]),
            ("short", [(.began, -10, 0), (.changed, -20, 0), (.ended, -30, 0)]),
            ("momentum", [([], -80, 0)]),
        ]
        for (name, events) in gestures {
            var tracker = SwipeTracker()
            let tabs = events.compactMap { tracker.track(phase: $0.0, fingerDX: $0.1, dy: $0.2)?.rawValue }
            print("swipe:\(name)=\(tabs.joined(separator: ","))")
        }
    }
}

func checkRepositories() async throws {
    for remote in ["https://github.com/acme/rocket.git", "git@github.com:acme/rocket.git",
                   "ssh://git@github.com/acme/rocket", "https://github.com/acme/rocket/"] {
        precondition(LocalRepositories.name(remote: remote) == "acme/rocket")
    }
    precondition(LocalRepositories.name(remote: "git@work:acme/rocket.git", resolveHost: { _ in "github.com" }) == "acme/rocket")
    for remote in ["git@gitlab.com:acme/rocket.git", "/tmp/rocket", "file:///tmp/repo",
                   "https://github.com/acme", "https://github.com/acme/repo/extra", "https://github.com.evil/acme/repo"] {
        precondition(LocalRepositories.name(remote: remote) == nil)
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Git fixture failed: \(arguments)")
    }
    let clone = root.appendingPathComponent("clone with spaces").path
    try git(["init", clone])
    try git(["-C", clone, "remote", "add", "origin", "git@github.com:acme/rocket.git"])
    try git(["-C", clone, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "commit.gpgsign=false",
             "commit", "--allow-empty", "-m", "fixture"])
    try git(["-C", clone, "worktree", "add", "-b", "fixture", root.appendingPathComponent("worktree").path])
    let duplicate = root.appendingPathComponent("duplicate").path
    try git(["init", duplicate])
    try git(["-C", duplicate, "remote", "add", "origin", "https://github.com/ACME/ROCKET.git"])
    let bare = root.appendingPathComponent("bare.git").path
    try git(["init", "--bare", bare])
    try git(["-C", bare, "remote", "add", "origin", "https://github.com/acme/bare.git"])
    let other = root.appendingPathComponent("other").path
    try git(["init", other])
    try git(["-C", other, "remote", "add", "origin", "git@gitlab.com:acme/unrelated.git"])
    let nested = root.appendingPathComponent("folder/nested").path
    try git(["init", nested])
    try git(["-C", nested, "remote", "add", "origin", "https://github.com/acme/not-direct.git"])
    let repositories = try await LocalRepositories.scan(root: root.path)
    let repos = repositories.map { $0.name.lowercased() }
    precondition(repos == ["acme/bare", "acme/rocket"], "Deduplicate clones and worktrees: \(repos)")
    let rocket = repositories.first { $0.name.lowercased() == "acme/rocket" }!
    precondition(Set(rocket.checkouts.map(\.path)) == Set([clone, duplicate, root.appendingPathComponent("worktree").path]),
                 "Finder must retain every checkout, including spaces and linked worktrees")
    precondition(repositories.first { $0.name == "acme/bare" }?.checkouts.map(\.path) == [bare])
    try FileManager.default.removeItem(atPath: bare)
    let rescanned = try await LocalRepositories.scan(root: root.path)
    precondition(rescanned.count == 1, "Deleted clones must leave the feed scope")
    try await checkBackgroundPulls(root: root.path)
    do { _ = try await LocalRepositories.scan(root: root.appendingPathComponent("missing").path); preconditionFailure() }
    catch { /* An unreadable root is an error, not a successful empty scan. */ }
}

@MainActor
func checkBackgroundPulls(root: String) async throws {
    let suite = "gh-activity-background-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    func stub(number: Int, feedStatus: Int = 200) {
        EventPages.stub { request in
            if request.url!.path.hasSuffix("/events") {
                return (feedStatus, [:], Data((feedStatus == 200 ? "[]" : "{}").utf8))
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(request.url!.path == "/search/issues")
            precondition(query.first { $0.name == "q" }!.value!.contains("is:open"))
            let item: [String: Any] = ["state": "open", "pull_request": [:], "number": number,
                "title": "Background PR", "repository_url": "https://api.github.com/repos/acme/rocket",
                "html_url": "https://github.com/acme/rocket/pull/\(number)", "updated_at": "2026-10-04T12:00:00Z"]
            return (200, [:], try! JSONSerialization.data(withJSONObject: ["total_count": 1, "items": [item]]))
        }
    }
    func settled(_ model: ActivityModel) async throws {
        for _ in 0..<500 {
            if !model.isRefreshing && !model.isRefreshingPulls { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Background refresh did not finish")
    }
    var now = Date()
    stub(number: 1)
    // Construct only the model: no panel or PR tab is ever opened.
    let model = ActivityModel(repositoryRoot: root, defaults: defaults,
                              client: GitHubClient(token: { _ in nil }), now: { now })
    try await settled(model)
    precondition(model.pullsFetchedAt != nil && model.pulls.map { $0.event.pullNumber } == [1])
    precondition(EventPages.count == 2, "Startup must load both activity and PRs")
    model.refresh()
    precondition(EventPages.count == 2, "Opening the panel must respect the shared cooldown")
    now = now.addingTimeInterval(899)
    model.refresh()
    precondition(EventPages.count == 2)
    now = now.addingTimeInterval(1)
    stub(number: 2)
    model.refresh()
    try await settled(model)
    precondition(model.pulls.map { $0.event.pullNumber } == [2] && EventPages.count == 2,
                 "The next background cycle must refresh PRs without selecting a tab")
    now = now.addingTimeInterval(900)
    stub(number: 3, feedStatus: 500)
    model.refresh()
    try await settled(model)
    precondition(model.errorMessage != nil && model.pullsError == nil)
    precondition(model.pulls.map { $0.event.pullNumber } == [3] && EventPages.count == 2,
                 "A failed activity feed must not prevent the PR refresh")
}

@MainActor
func checkFeeds() async throws {
    // Keep credentials on GitHub rename redirects, never on another origin.
    var original = URLRequest(url: URL(string: "https://api.github.com/repos/acme/old/events")!)
    original.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
    let task = URLSession.shared.dataTask(with: original)
    defer { task.cancel() }
    let response = HTTPURLResponse(url: original.url!, statusCode: 301, httpVersion: nil, headerFields: [:])!
    let redirect = GitHubRedirects()
    for target in ["https://api.github.com/repositories/1/events", "https://outside.example/events", "http://api.github.com/events"] {
        redirect.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: target)!)) { result in
                if target.hasPrefix("https://api.github.com/") {
                    precondition(result?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
                } else { precondition(result == nil) }
            }
    }
    func data(_ ids: [Int], repo: String) -> Data {
        let events: [[String: Any]] = ids.map { id in
            ["id": String(id), "type": "PushEvent", "actor": ["login": "alice"],
             "repo": ["name": repo], "payload": [:],
             "created_at": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(id))) ]
        }
        return try! JSONSerialization.data(withJSONObject: events)
    }
    EventPages.stub { request in
        let url = request.url!
        precondition(url.path.hasPrefix("/repos/") && url.path.hasSuffix("/events"))
        precondition(url.query == "per_page=50")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let repo = url.path.split(separator: "/").dropFirst().prefix(2).joined(separator: "/")
        if repo == "acme/missing" { return (404, [:], Data("{}".utf8)) }
        if ["acme/empty", "acme/quiet"].contains(repo) { return (200, [:], Data("[]".utf8)) }
        if request.value(forHTTPHeaderField: "If-None-Match") == "fixture-etag" { return (304, [:], Data()) }
        let ids = repo == "acme/rocket" ? Array(1...50) : Array(26...75) + [75]
        return (200, ["ETag": "fixture-etag"], data(ids, repo: repo))
    }
    let client = GitHubClient(token: { _ in "fixture" })
    // Five distinct repos exercise a full batch and its trailing batch.
    let repos = ["acme/rocket", "acme/website", "acme/missing", "acme/empty", "acme/quiet", "acme/rocket"]
    let result = try await client.fetch(repos: repos)
    precondition(result.events.map(\.id) == (26...75).reversed().map(String.init), "Sort and cap the combined feed at 50")
    precondition(Array(result.failures.keys) == ["acme/missing"])
    precondition(EventPages.count == 5, "One request per unique repository")
    // Filter before the 50-row cap: a quiet repo must retain its full page.
    let available = ["acme/rocket", "acme/website"]
    var selection = RepositorySelection()
    precondition(selection.saved == nil && selection.includes("acme/new-clone"))
    selection.set("ACME/WEBSITE", included: false, available: available)
    precondition(selection.includes("ACME/ROCKET") && !selection.includes("acme/website"))
    precondition(!selection.includes("acme/new-clone"), "A custom selection only includes chosen repos")
    let quiet = GitHubClient.latest(result.repositoryEvents, selection: selection)
    precondition(quiet.map(\.id) == (1...50).reversed().map(String.init), "Filtering must retain older events from selected repos")
    precondition(quiet.allSatisfy { $0.repo == "acme/rocket" })
    let restored = RepositorySelection(saved: selection.saved)
    precondition(restored == selection && restored.includes("acme/rocket"))
    selection.set("acme/website", included: true, available: available)
    precondition(selection.includes("acme/rocket") && selection.includes("acme/website"), "Support multiple selected repositories")
    precondition(GitHubClient.latest(result.repositoryEvents, selection: selection).map(\.id) == result.events.map(\.id))
    selection = RepositorySelection(saved: [])
    precondition(GitHubClient.latest(result.repositoryEvents, selection: selection).isEmpty)
    precondition(RepositorySelection(saved: selection.saved).saved == [], "Persist none separately from all")
    selection = RepositorySelection()
    precondition(selection.saved == nil && selection.includes("acme/new-clone"))
    precondition(EventPages.count == 5, "Changing selections must not fetch from GitHub")
    let cached = try await client.fetch(repos: repos)
    precondition(cached.events.map(\.id) == result.events.map(\.id), "ETag responses must retain rows")
    let empty = try await client.fetch(repos: ["acme/empty"])
    precondition(empty.events.isEmpty && empty.failures.isEmpty, "Empty feeds do not imply an SSO failure")
    let before = EventPages.count
    let none = try await client.fetch(repos: [])
    precondition(none.events.isEmpty && EventPages.count == before)

    // A differently named repo in a response must never escape the clone scope.
    EventPages.stub { _ in (200, [:], data([99], repo: "outside/uncloned")) }
    let filtered = try await client.fetch(repos: ["acme/rocket"])
    precondition(filtered.events.isEmpty)

    EventPages.stub { _ in
        (200, ["Test-Redirect": "https://api.github.com/repositories/1/events?per_page=50"],
         data([100], repo: "acme/renamed"))
    }
    let renamed = try await client.fetch(repos: ["acme/old"])
    precondition(renamed.events.first?.repo == "acme/renamed")
    precondition(client.canonicalRepositories(["acme/old", "acme/renamed"]) == ["acme/renamed"])
    let renamedSelection = RepositorySelection(saved: client.canonicalRepositories(["ACME/OLD"]))
    precondition(renamedSelection.includes("acme/renamed"), "Keep a selected repo after a GitHub rename")

    EventPages.stub { request in
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let search = query.first { $0.name == "q" }!.value!
        precondition(search.contains("repo:acme/rocket") && !search.contains("org:") && !search.contains("is:public"))
        let page = query.first { $0.name == "page" }!.value!
        let number = page == "1" ? 1 : 2
        let item: [String: Any] = ["state": "open", "pull_request": [:], "number": number, "draft": number == 2,
            "title": "Fixture", "repository_url": "https://api.github.com/repos/acme/rocket",
            "html_url": "https://github.com/acme/rocket/pull/\(number)", "updated_at": "2026-10-04T12:00:00Z"]
        return (200, [:], try! JSONSerialization.data(withJSONObject: ["total_count": 101, "items": [item]]))
    }
    let pulls = try await client.openPulls(repos: ["acme/rocket"])
    precondition(pulls.pulls.count == 2 && pulls.incomplete && EventPages.count == 2)
    precondition(Set(pulls.pulls.map { $0.event.pullState }) == [.open, .draft])

    // Personal and active-account quotas must remain independent.
    EventPages.stub { request in
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer personal" {
            return (200, [:], Data("[]".utf8))
        }
        return (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000060"], Data("{}".utf8))
    }
    let accounts = GitHubClient(now: { Date(timeIntervalSince1970: 1_700_000_000) },
        token: { user in user == "alice" ? "personal" : user == nil ? "work" : nil })
    let mixed = try await accounts.fetch(repos: ["acme/rocket", "alice/private"])
    precondition(Array(mixed.failures.keys) == ["acme/rocket"] && EventPages.count == 2)
    _ = try await accounts.fetch(repos: ["alice/private"])
    precondition(EventPages.count == 3)
}

@MainActor
func checkPolling() async throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var cooldown = RefreshCooldown()
    precondition(cooldown.begin(at: start))
    precondition(!cooldown.begin(at: start.addingTimeInterval(899)))
    precondition(cooldown.begin(at: start.addingTimeInterval(900)))
    cooldown.reset()
    precondition(cooldown.begin(at: start.addingTimeInterval(901)))

    func paused(_ client: GitHubClient) async {
        do { _ = try await client.fetch(repos: ["acme/rocket"]); preconditionFailure("Expected rate limit") }
        catch { precondition(error.localizedDescription.contains("paused")) }
    }
    var now = start
    let exhausted = ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000060"]
    EventPages.stub { _ in (403, exhausted, Data("{}".utf8)) }
    let core = GitHubClient(now: { now }, token: { _ in nil })
    await paused(core)
    let firstCount = EventPages.count
    await paused(core)
    precondition(EventPages.count == firstCount, "Core requests must pause until reset")
    _ = await core.pullTitles(repos: ["acme/rocket"])
    precondition(EventPages.count == firstCount + 1, "Search has a separate primary quota")
    now = start.addingTimeInterval(61)
    await paused(core)
    precondition(EventPages.count > firstCount + 1, "Core requests must resume after reset")

    now = start
    EventPages.stub { _ in (200, exhausted, Data("{\"items\":[]}".utf8)) }
    let lastAllowed = GitHubClient(now: { now }, token: { _ in nil })
    _ = await lastAllowed.pullTitles(repos: ["acme/rocket"])
    _ = await lastAllowed.pullTitles(repos: ["acme/rocket"])
    precondition(EventPages.count == 1, "A successful response can exhaust the quota")

    EventPages.stub { _ in (429, ["Retry-After": "120"], Data("{}".utf8)) }
    let secondary = GitHubClient(now: { now }, token: { _ in "fixture" })
    _ = await secondary.pullTitles(repos: ["acme/rocket"])
    _ = await secondary.pullTitles(repos: ["acme/rocket"])
    await paused(secondary)
    precondition(EventPages.count == 1, "Secondary limits pause core and search requests")
    now = start.addingTimeInterval(121)
    _ = await secondary.pullTitles(repos: ["acme/rocket"])
    precondition(EventPages.count == 2, "Honor Retry-After before retrying")

    now = start
    EventPages.stub { _ in (429, [:], Data("{}".utf8)) }
    let repeated = GitHubClient(now: { now }, token: { _ in nil })
    _ = await repeated.pullTitles(repos: ["acme/rocket"])
    now = start.addingTimeInterval(60)
    _ = await repeated.pullTitles(repos: ["acme/rocket"])
    now = start.addingTimeInterval(179)
    _ = await repeated.pullTitles(repos: ["acme/rocket"])
    precondition(EventPages.count == 2, "Repeated secondary limits increase the delay")
    now = start.addingTimeInterval(180)
    _ = await repeated.pullTitles(repos: ["acme/rocket"])
    precondition(EventPages.count == 3)

    EventPages.stub { _ in (200, [:], Data(#"{"merged":true,"merged_at":"2026-10-04T12:00:00Z","merged_by":{"login":"alice","html_url":"https://github.com/alice"}}"#.utf8)) }
    let merges = (1...8).map { number in
        ActivityEvent(json: ["id": String(number), "type": "PullRequestEvent", "created_at": "2026-10-04T12:00:00Z",
            "actor": ["login": "alice"], "repo": ["name": "acme/rocket"],
            "payload": ["action": "merged", "number": number]])!
    }
    let client = GitHubClient(token: { _ in nil })
    let firstMergers = await client.verifiedMergers(for: merges)
    precondition(firstMergers.count == 4 && EventPages.count == 4)
    let nextMergers = await client.verifiedMergers(for: merges)
    precondition(nextMergers.count == 8 && EventPages.count == 8)
    _ = await client.verifiedMergers(for: merges)
    precondition(EventPages.count == 8, "Cached mergers need no new requests")
}' >"$TMP_ROOT/Check.swift"
printf '%s\n' '[
  {"id":"1","type":"PushEvent","created_at":"2026-10-02T10:00:00Z","actor":{"login":"alice","display_login":"alice"},"repo":{"name":"acme/rocket"},"payload":{"ref":"refs/heads/main","head":"abc123"}},
  {"id":"2","type":"PullRequestEvent","created_at":"2026-10-02T12:00:00Z","actor":{"login":"bob"},"repo":{"name":"acme/rocket"},"payload":{"action":"opened","number":7,"pull_request":{"number":7,"head":{"ref":"fix/upload-retry"},"base":{"ref":"main"}}}},
  {"id":"3","type":"IssueCommentEvent","created_at":"2026-10-02T11:00:00Z","actor":{"login":"helper[bot]","display_login":"helper"},"repo":{"name":"acme/website"},"payload":{"issue":{"number":3,"title":"Broken\tlink","pull_request":{},"html_url":"https://github.com/acme/website/pull/3"}}},
  {"id":"4","type":"PullRequestReviewEvent","created_at":"2026-10-01T09:00:00Z","actor":{"login":"bob"},"repo":{"name":"acme/rocket"},"payload":{"review":{"state":"approved"},"pull_request":{"number":7}}},
  {"id":"5","type":"CreateEvent","created_at":"2026-10-01T08:00:00Z","actor":{"login":"alice"},"repo":{"name":"acme/rocket"},"payload":{"ref_type":"tag","ref":"v1.0"}},
  {"id":"6","type":"ReleaseEvent","created_at":"2026-10-01T07:30:00Z","actor":{"login":"alice"},"repo":{"name":"acme/rocket"},"payload":{"action":"published","release":{"tag_name":"v1.0","html_url":"https://github.com/acme/rocket/releases/tag/v1.0"}}},
  {"id":"7","type":"ForkEvent","created_at":"2026-10-01T07:20:00Z","actor":{"login":"erin"},"repo":{"name":"acme/rocket"},"payload":{"forkee":{"full_name":"erin/rocket"}}},
  {"id":"8","type":"WatchEvent","created_at":"2026-10-01T07:00:00Z","actor":{"login":"dave"},"repo":{"name":"acme/website"},"payload":{"action":"started"}},
  {"id":"9","type":"IssuesEvent","created_at":"2026-10-01T06:30:00Z","actor":{"login":"carol"},"repo":{"name":"acme/website"},"payload":{"action":"closed","issue":{"number":4,"title":"Typo","html_url":"https://github.com/acme/website/issues/4"}}},
  {"id":"11","type":"IssueCommentEvent","created_at":"2026-10-02T12:30:00Z","actor":{"login":"carol"},"repo":{"name":"acme/rocket"},"payload":{"issue":{"number":7,"title":"Retry failed uploads","pull_request":{},"html_url":"https://github.com/acme/rocket/pull/7"}}},
  {"id":"10","type":"SponsorshipEvent","created_at":"2026-10-01T06:00:00Z","actor":{"login":"erin"},"repo":{"name":"acme/rocket"},"payload":{}},
  {"type":"PushEvent"}
]' >"$TMP_ROOT/events.json"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -o "$TMP_ROOT/check-gh-activity-bar" "$TMP_ROOT/App.swift" "$REPO_DIR/apps/lib/octicons/Octicons.swift" "$TMP_ROOT/Check.swift" 2>"$TMP_ROOT/build.log" ||
  fail_test "GitHub Activity app does not build: $(cat "$TMP_ROOT/build.log")"
# Repository case differs on purpose: search and events name repos alike, but keys ignore case.
printf '%s\n' '{"total_count":3,"items":[
  {"number":7,"title":"[BUG-12][fix] Retry\tfailed uploads","repository_url":"https://api.github.com/repos/Acme/Rocket"},
  {"number":9,"title":"Unrelated","repository_url":"https://api.github.com/repos/acme/website"},
  {"title":"No number","repository_url":"https://api.github.com/repos/acme/rocket"}
]}' >"$TMP_ROOT/search.json"
parsed="$("$TMP_ROOT/check-gh-activity-bar" "$TMP_ROOT/events.json" "$TMP_ROOT/search.json")" || fail_test "event parsing check failed"

expected="titles:acme/rocket#7=[BUG-12][fix] Retry failed uploads,acme/website#9=Unrelated
alice|rocket|pushed|main|https://github.com/acme/rocket/commit/abc123|https://github.com/alice|person|symbols
bob|rocket|opened PR #7: Retry failed uploads|fix/upload-retry → main|https://github.com/acme/rocket/pull/7|https://github.com/bob|person|symbols
helper|website|commented on PR #3: Broken link|-|https://github.com/acme/website/pull/3|https://github.com/apps/helper|bot|symbols
bob|rocket|approved PR #7: Retry failed uploads|fix/upload-retry → main|https://github.com/acme/rocket/pull/7|https://github.com/bob|person|symbols
alice|rocket|created tag|v1.0|https://github.com/acme/rocket/releases/tag/v1.0|https://github.com/alice|person|symbols
alice|rocket|published release|v1.0|https://github.com/acme/rocket/releases/tag/v1.0|https://github.com/alice|person|symbols
erin|rocket|forked|erin/rocket|https://github.com/erin/rocket|https://github.com/erin|person|symbols
dave|website|starred|-|https://github.com/acme/website|https://github.com/dave|person|symbols
carol|website|closed issue #4: Typo|-|https://github.com/acme/website/issues/4|https://github.com/carol|person|symbols
carol|rocket|commented on PR #7: Retry failed uploads|fix/upload-retry → main|https://github.com/acme/rocket/pull/7|https://github.com/carol|person|symbols
erin|rocket|Sponsorship|-|https://github.com/acme/rocket|https://github.com/erin|person|symbols
unparsed
untagged:[https://bugs.example.com/1][fix] Restore X=Restore X
untagged:[None][feat]: Add Y=Add Y
untagged:[only]=[only]
untagged:Plain [not a prefix]=Plain [not a prefix]
swipe:left=Summary
swipe:right=Feed
swipe:vertical=
swipe:diagonal=
swipe:short=
swipe:momentum="
[[ "$parsed" == "$expected" ]] || fail_test "event parsing differs:
$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$parsed"))"

printf '[PASS] GitHub Activity app checks\n'
