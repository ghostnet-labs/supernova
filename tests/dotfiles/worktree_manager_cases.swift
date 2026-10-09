import Foundation

@main
struct WorktreeManagerCases {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw WorktreeError(message) }
    }

    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw WorktreeError(message)
    }

    static func main() async throws {
        let fm = FileManager.default
        guard let root = ProcessInfo.processInfo.environment["WORKTREE_MANAGER_ROOT"] else {
            throw WorktreeError("fixture root missing")
        }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let repo = root + "/repo", linked = root + "/repo-linked"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws -> String { try GitTool.run(["-C", repo] + args) }
        _ = try git("init", "-b", "main")
        _ = try git("config", "user.name", "Fixture")
        _ = try git("config", "user.email", "fixture@example.invalid")
        _ = try git("config", "commit.gpgsign", "false")
        _ = try git("config", "core.hooksPath", "/dev/null")
        try "base\n".write(toFile: repo + "/file", atomically: true, encoding: .utf8)
        _ = try git("add", ".")
        _ = try git("commit", "-m", "base")
        let base = try git("rev-parse", "HEAD")
        _ = try git("remote", "add", "origin", "https://example.invalid/fixture.git")
        _ = try git("update-ref", "refs/remotes/origin/main", base)
        _ = try git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        _ = try git("branch", "feature")
        _ = try git("branch", "merged")
        _ = try git("worktree", "add", "-b", "linked", linked)

        // More than a pipe buffer on both streams must not deadlock agent discovery.
        let helper = root + "/sessions"
        let json = try JSONSerialization.data(withJSONObject: [["cwd": repo, "session_id": "live", "padding": String(repeating: "x", count: 200_000)]])
        let script = "#!/bin/sh\ncat <<'LOG' >&2\n" + String(repeating: "x", count: 200_000)
            + "\nLOG\ncat <<'JSON'\n" + String(decoding: json, as: UTF8.self) + "\nJSON\n"
        try script.write(toFile: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        // Claude Code sessions come from a stub that prints whatever a case writes beside it, so no real session leaks in.
        let claudeStub = root + "/claude-sessions"
        try "#!/bin/sh\ncat \"$WORKTREE_MANAGER_ROOT/claude-sessions.json\" 2>/dev/null || echo '[]'\n"
            .write(toFile: claudeStub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeStub)
        let start = Date()
        let scan = await WorktreeScanner.scan()
        try check(scan.records.count == 2, "linked worktrees should not duplicate a repository")
        try check(scan.records.first?.hasLiveAgent == true, "large session JSON lost agent protection")
        try check(scan.records.first?.safeToRemove == false, "primary worktree must remain protected")
        try check(scan.records.first?.badgeHelp == "Agents running there: 1 Codex.", "a badge's tooltip must explain that badge")
        print(String(format: "PASS: large-output scan (%.2fs)", Date().timeIntervalSince(start)))
        guard let feature = scan.branches[repo]?.first(where: { $0.name == "feature" }),
              let merged = scan.branches[repo]?.first(where: { $0.name == "merged" }) else {
            throw WorktreeError("fixture branches missing")
        }

        let prepared = try RemovalPlan.prepare(SelectionActions(branches: [feature])).branches[0]
        _ = try git("switch", "feature")
        try "unmerged\n".write(toFile: repo + "/file", atomically: true, encoding: .utf8)
        _ = try git("commit", "-am", "unmerged")
        _ = try git("switch", "main")
        try rejects("stale confirmation deleted new commits") { _ = try WorktreeActions.deleteBranch(prepared) }
        try check((try? git("show-ref", "--verify", "refs/heads/feature")) != nil, "changed branch was removed")
        let safe = try RemovalPlan.prepare(SelectionActions(branches: [merged])).branches[0]
        _ = try WorktreeActions.deleteBranch(safe)
        try check((try? git("show-ref", "--verify", "refs/heads/merged")) == nil, "merged branch was not removed")

        _ = try git("branch", "gone", "feature")
        _ = try git("config", "branch.gone.remote", "origin")
        _ = try git("config", "branch.gone.merge", "refs/heads/gone")
        let next = await WorktreeScanner.scan()
        guard let gone = next.branches[repo]?.first(where: { $0.name == "gone" }) else { throw WorktreeError("gone branch missing") }
        // An upstream deleted on origin proves nothing: the pull request may have closed unmerged, or work went unpushed.
        try check(gone.gone && !gone.canDelete, "a deleted upstream alone must not make a branch deletable")
        try check(try RemovalPlan.prepare(SelectionActions(branches: [gone])).branches.isEmpty, "Remove must skip an unproven branch")
        func pullRequest(_ number: Int, head: String, state: PullRequestState = .merged, base: String = "main") -> PullRequestInfo {
            PullRequestInfo(number: number, title: "Fixture", url: URL(string: "https://github.com/acme/repo/pull/\(number)")!,
                            state: state, author: "fixture", mergedBy: nil, commits: 1, baseRef: base, headRef: "gone",
                            createdAt: Date(), updatedAt: Date(), closedAt: nil, additions: 1, deletions: 1, checks: nil, review: nil,
                            headOid: head)
        }
        try check(gone.proven(by: [pullRequest(6, head: base)]).mergedPull == nil, "a pull request that merged another tip proves nothing")
        try check(gone.proven(by: [pullRequest(6, head: gone.head, state: .closed)]).mergedPull == nil, "a closed pull request proves nothing")
        try check(gone.proven(by: [pullRequest(6, head: gone.head, base: "release")]).mergedPull == nil,
                  "a pull request into another branch doesn't put the work on the default branch")
        let proven = gone.proven(by: [pullRequest(6, head: base), pullRequest(7, head: gone.head)])
        try check(proven.mergedPull == 7 && proven.canDelete, "a merged pull request with this exact tip proves the work merged")
        try rejects("unconfirmed branch removal was allowed") { _ = try WorktreeActions.deleteBranch(proven) }
        let gonePlan = try RemovalPlan.prepare(SelectionActions(branches: [proven]))
        try check(gonePlan.branches[0].unmergedCommits == 1, "commits under new IDs must be counted accurately")
        try check(gonePlan.message.contains("pull request #7 merged this exact tip into main"), "confirmation must name the proof: \(gonePlan.message)")
        _ = try git("update-ref", "refs/heads/gone", try git("commit-tree", "-p", gone.head, "-m", "unpushed", "\(gone.head)^{tree}"))
        try rejects("a commit after the merged tip was deleted") { _ = try WorktreeActions.deleteBranch(gonePlan.branches[0]) }
        _ = try git("update-ref", "refs/heads/gone", gone.head)
        _ = try WorktreeActions.deleteBranch(gonePlan.branches[0])

        // A rebase merge copies each commit under a new ID; an identical change on the default branch proves it landed.
        // A merge commit has no such twin, so a branch with one stays protected.
        let change = try git("rev-parse", "refs/heads/feature^{tree}")
        let original = try git("commit-tree", "-p", base, "-m", "landed", change)
        let mixed = try git("commit-tree", "-p", original, "-p", base, "-m", "merge main", change)
        _ = try git("update-ref", "refs/remotes/origin/main", try git("commit-tree", "-p", base, "-m", "landed, rebased", change))
        for (name, tip) in [("landed", original), ("mixed", mixed)] {
            _ = try git("update-ref", "refs/heads/\(name)", tip)
            _ = try git("config", "branch.\(name).remote", "origin")
            _ = try git("config", "branch.\(name).merge", "refs/heads/\(name)")
        }
        let rebased = await WorktreeScanner.scan().branches[repo] ?? []
        guard let landed = rebased.first(where: { $0.name == "landed" }), let merge = rebased.first(where: { $0.name == "mixed" }) else {
            throw WorktreeError("rebase-merged fixture branches missing")
        }
        try check(landed.gone && !landed.merged && landed.mergedByPatch && landed.canDelete, "identical changes on main prove a rebase merge")
        try check(merge.gone && !merge.mergedByPatch && !merge.canDelete, "a merge commit has no twin, so it must not count as merged")
        let landedPlan = try RemovalPlan.prepare(SelectionActions(branches: [landed]))
        try check(landedPlan.message.contains("each of its 1 commit has an identical change on main"), "confirmation: \(landedPlan.message)")
        _ = try WorktreeActions.deleteBranch(landedPlan.branches[0])
        _ = try git("update-ref", "-d", "refs/heads/mixed")
        _ = try git("update-ref", "refs/remotes/origin/main", base)

        let unknown = BranchRecord(repositoryRoot: repo, name: "main", head: base, upstream: "origin/main", gone: true,
                                   ahead: 0, behind: 0, lastCommit: Date(), base: nil, merged: false)
        try check(!unknown.canDelete, "unknown default branch must not allow force deletion")
        let main = BranchRecord(repositoryRoot: repo, name: "main", head: base, upstream: "origin/main", gone: true,
                                ahead: 0, behind: 0, lastCommit: Date(), base: "origin/main", merged: true)
        try check(!main.canDelete, "default branch must not allow force deletion")
        try fm.removeItem(atPath: linked)
        let missing = await WorktreeScanner.scan()
        try check(missing.records.first(where: { $0.path == linked })?.safeToRemove == false,
                  "failed status must not classify a missing worktree as clean")
        try check(missing.records.first(where: { $0.path == linked })?.badge?.text == "MISSING",
                  "a worktree whose folder is gone must say so rather than look clean")
        print("PASS: branch removal validates the tip, default, upstream, and confirmation")

        try check(PullRequestLookup.key(repositoryRoot: repo, branch: "feature") == feature.id, "pull request keys must match branch IDs")
        // The fixture's origin isn't on github.com, and the second repository doesn't exist: no gh, no network.
        let skipped = await PullRequestClient.lookup([PullRequestQuery(repositoryRoot: repo, heads: ["main": "main"]),
                                                      PullRequestQuery(repositoryRoot: root + "/missing", heads: ["main": "main"])])
        try check(skipped.pulls.isEmpty && skipped.error == nil, "repositories not on github.com must be skipped without asking gh")
        try pullRequestCases()
        try pullRequestWordingCases()
        try pullRequestSelectionCases(repo: repo)
        try worktreeBadgeCases()
        print("PASS: pull request parsing, request bodies, batching, and GitHub slugs")
        try await checkPullRequestWiring(repo: repo)
        try await gitCountsCases(root: root)
        try await removalSafetyCases(root: root)
    }

    /// Remove deletes a worktree only when nothing in it would be lost, and looks again right before deleting.
    static func removalSafetyCases(root: String) async throws {
        let fm = FileManager.default, repo = root + "/safety"
        let paths = ["caches", "env", "hidden", "late", "detached", "parked", "lost", "agent"].map { "\(repo)-\($0)" }
        let agentBin = root + "/agent-bin/claude/versions/9.9.9"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { for path in paths + [repo, root + "/agent-bin"] { try? fm.removeItem(atPath: path) } }
        @discardableResult func git(_ path: String, _ args: String...) throws -> String { try GitTool.run(["-C", path] + args) }
        func write(_ text: String, _ path: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        try git(repo, "init", "-b", "main")
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"),
                             ("core.hooksPath", "/dev/null")] { try git(repo, "config", key, value) }
        try write(".env\n__pycache__/\n", repo + "/.gitignore")
        try git(repo, "add", "."); try git(repo, "commit", "-m", "base")
        for path in paths.prefix(4) + [paths[7]] { try git(repo, "worktree", "add", "-b", (path as NSString).lastPathComponent, path) }
        // Detached worktrees: one with a commit no branch has, one at main's tip, and one with a lost commit and no folder.
        for path in paths[4...6] { try git(repo, "worktree", "add", "--detach", path) }
        for path in [paths[4], paths[6]] { try write("work\n", path + "/work"); try git(path, "add", "work"); try git(path, "commit", "-m", "work") }
        let lost = try git(paths[6], "rev-parse", "HEAD")
        try fm.removeItem(atPath: paths[6])
        // Only a cache is ignored; a .env is not a cache; the repository's config hides an untracked file.
        try fm.createDirectory(atPath: paths[0] + "/__pycache__", withIntermediateDirectories: true)
        try write("cache\n", paths[0] + "/__pycache__/module.pyc")
        try write("TOKEN=secret\n", paths[1] + "/.env")
        try write("notes\n", paths[2] + "/notes.txt")
        try git(repo, "config", "status.showUntrackedFiles", "no")

        let records = await WorktreeScanner.scan().records.filter { $0.repository == "safety" }
        func record(_ name: String) throws -> WorktreeRecord {
            guard let record = records.first(where: { $0.name == "safety-\(name)" }) else { throw WorktreeError("safety-\(name) was not scanned") }
            return record
        }
        let caches = try record("caches"), env = try record("env"), hidden = try record("hidden"), late = try record("late")
        let detached = try record("detached"), parked = try record("parked")
        try check(detached.unbranched && !detached.safeToRemove && detached.badge?.text == "COMMITS ON NO BRANCH",
                  "a commit only a detached HEAD has must protect its worktree: \(detached.badgeHelp)")
        try check(!parked.unbranched && parked.safeToRemove, "a detached HEAD a branch contains is safe to remove: \(parked.badgeHelp)")
        try rejects("Prune dropped the only reference to a missing worktree's commit") {
            _ = try WorktreeActions.prune(repositoryRoot: repo)
        }
        try check(try git(repo, "worktree", "list").contains(paths[6]), "a refused Prune must keep the missing worktree")
        try git(repo, "branch", "kept", lost)
        _ = try WorktreeActions.prune(repositoryRoot: repo)
        try check(!(try git(repo, "worktree", "list").contains(paths[6])), "Prune must clear a missing worktree once its commits are kept")
        try check(caches.safeToRemove && caches.ignoredFiles.isEmpty, "caches alone must not protect a worktree: \(caches.badgeHelp)")
        try check(env.ignoredFiles == [".env"] && !env.safeToRemove && env.badge?.text == "IGNORED FILES"
                  && env.badgeHelp.contains(".env"), "an ignored .env must protect its worktree and be named: \(env.badgeHelp)")
        try check(hidden.dirty && hidden.untracked == 1 && !hidden.safeToRemove,
                  "status.showUntrackedFiles=no must not hide untracked files: \(hidden.badgeHelp)")
        try check(late.safeToRemove, "a clean worktree is safe to remove: \(late.badgeHelp)")

        // Each is checked again right before deleting, so a file added after the scan is never lost.
        try write("written after the scan\n", late.path + "/later.txt")
        try rejects("Remove deleted a file written after the scan") { _ = try WorktreeActions.remove(late) }
        try rejects("Remove deleted an untracked file the repository's config hides") { _ = try WorktreeActions.remove(hidden) }
        try check(fm.fileExists(atPath: late.path + "/later.txt") && fm.fileExists(atPath: hidden.path + "/notes.txt"),
                  "protected worktrees must keep their files")
        _ = try WorktreeActions.remove(caches)
        try check(!fm.fileExists(atPath: caches.path), "a worktree holding only caches was not removed")

        // Claude Code's native build runs as its version number; the session list doesn't know it, but its folder does.
        func agent(_ path: String, _ arguments: [String] = []) -> AgentKind? { WorktreeScanner.agentKind(path, arguments: { arguments }) }
        try check(agent("/Users/me/.local/share/claude/versions/2.1.292") == .claude && agent("/opt/homebrew/bin/codex") == .codex
                  && agent("/usr/bin/python3") == nil && agent("/opt/claude-helper") == nil, "agent executables were misread")
        // The app-server hosts sessions the session list reports; its folder is wherever it started.
        try check(agent("/Users/me/.codex/packages/app-server-daemon/bin/codex", ["app-server", "--listen", "unix://"]) == nil,
                  "codex app-server must not count as an agent")
        // Sessions name their process: a terminal session and its process count once, a desktop Codex session names
        // the app-server and counts as a session, and a process no session names still counts.
        func session(_ id: String, _ kind: AgentKind, pid: Int) -> AgentSession {
            AgentSession(row: ["session_id": id, "cwd": repo + "-mixed", "live_pid": pid], kind: kind)!
        }
        let mixed = WorktreeRecord(repository: "safety", repositoryRoot: repo, path: repo + "-mixed", branch: "mixed", head: "-", dirty: false,
                                   ahead: 0, behind: 0, hasUpstream: false, locked: false,
                                   sessions: [session("terminal", .codex, pid: 100), session("desktop", .codex, pid: 999), session("claude", .claude, pid: 200)],
                                   agentProcesses: [AgentProcess(pid: 100, kind: .codex), AgentProcess(pid: 200, kind: .claude),
                                                    AgentProcess(pid: 300, kind: .claude)])
        try check(mixed.agentCount == 4 && mixed.unlistedProcesses == [AgentProcess(pid: 300, kind: .claude)] && mixed.badge?.text == "4 AGENTS LIVE"
                  && mixed.badgeHelp == "Agents running there: 2 Claude Code, 2 Codex.", "agents were miscounted: \(mixed.agentCount), \(mixed.badgeHelp)")
        try check(RepositoryGroup(root: repo, name: "safety", records: [mixed, mixed]).liveAgentCount == 8,
                  "a repository header must add up its worktrees' agents")

        // Rows decode as Agent Control Center shows them, and subagents sit under the session that started them.
        let rows = """
            [{"session_id": "root", "cwd": "/w", "title": "Fix it", "status": "ACTIVE", "state_started_at": 1791403257.5,
              "last_user_request": "please", "model": "gpt-6", "reasoning_effort": "xhigh", "tokens_total": 9352254,
              "context_used_tokens": 184190, "context_window_tokens": 258400, "context_window_is_estimated": true,
              "live_pid": 98644, "thread_source": "user", "root_session_id": "root"},
             {"session_id": "child", "cwd": "/w", "status": "WAITING", "thread_source": "guardian_review", "root_session_id": "root",
              "table_detail": "Guardian review"},
             {"session_id": "-", "cwd": "/w"}]
            """
        let parsed = AgentSessions.attachingSubagents(AgentSessions.parse(rows, kind: .codex))
        guard parsed.count == 1, let top = parsed.first else { throw WorktreeError("sessions parsed as \(parsed.map(\.sessionID))") }
        try check((top.status, top.title, top.lastRequest, top.model, top.effort) == ("BUSY", "Fix it", "please", "gpt-6", "xhigh")
                  && top.statusSince == Date(timeIntervalSince1970: 1791403257.5) && top.totalTokens == 9352254 && top.contextUsed == 184190
                  && top.contextWindow == 258400 && top.contextEstimated && top.pid == 98644, "session details were misread: \(top)")
        try check(top.subagents.map(\.label) == ["Guardian review"] && top.subagents.first?.status == "WAITING",
                  "a subagent must sit under its session: \(top.subagents)")
        // A pasted log becomes one capped line; with no title, the title falls back to it, capped shorter.
        let pasted = "\n\n  first line\n" + String(repeating: "log ", count: 2_000)
        guard let long = AgentSession(row: ["session_id": "long", "cwd": "/w", "last_user_request": pasted], kind: .claude) else {
            throw WorktreeError("a session with a long request was dropped")
        }
        try check(long.lastRequest.hasPrefix("first line log") && long.lastRequest.count == 500 && long.lastRequest.hasSuffix("…")
                  && !long.lastRequest.contains("\n") && long.title.count == 180, "long requests must be one capped line: \(long.lastRequest.count)")
        let agent = try record("agent")
        try check(agent.safeToRemove, "a clean worktree with no agent is safe to remove: \(agent.badgeHelp)")
        try fm.createDirectory(atPath: (agentBin as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/bin/sleep", toPath: agentBin)
        // A copied system binary must be signed again before macOS lets it run.
        _ = try GitTool.run(["--force", "--sign", "-", agentBin], executable: "/usr/bin/codesign")
        let fake = Process()
        fake.executableURL = URL(fileURLWithPath: agentBin)
        fake.arguments = ["60"]
        fake.currentDirectoryURL = URL(fileURLWithPath: agent.path + "/")
        try fake.run()
        defer { fake.terminate() }
        try check(WorktreeScanner.arguments(fake.processIdentifier) == ["60"], "process arguments were misread")
        try rejects("Remove deleted a worktree an agent started in after the scan") { _ = try WorktreeActions.remove(agent) }
        let live = await WorktreeScanner.scan().records.first { $0.path == agent.path }
        try check(live?.hasLiveAgent == true && live?.badge?.text == "AGENT LIVE" && live?.canJump == false,
                  "a running Claude Code process must protect its worktree without a session to jump to")
        let second = Process()
        (second.executableURL, second.arguments, second.currentDirectoryURL) = (fake.executableURL, ["60"], fake.currentDirectoryURL)
        try second.run()
        defer { second.terminate() }
        let both = await WorktreeScanner.scan().records.first { $0.path == agent.path }
        // Once claude-sessions names the first process, its details show and the other still counts.
        let named = ["session_id": "claude-live", "cwd": agent.path, "title": "Agent fixture", "status": "WAITING",
                     "model": "claude-opus-5-5", "live_pid": Int(fake.processIdentifier)] as [String: Any]
        try JSONSerialization.data(withJSONObject: [named]).write(to: URL(fileURLWithPath: root + "/claude-sessions.json"))
        defer { try? fm.removeItem(atPath: root + "/claude-sessions.json") }
        let listed = await WorktreeScanner.scan().records.first { $0.path == agent.path }
        try check(listed?.sessions.map(\.title) == ["Agent fixture"] && listed?.unlistedProcesses.count == 1 && listed?.agentCount == 2
                  && listed?.canJump == true, "a listed Claude Code session must show its details and count once")
        try check(both?.badge?.text == "2 AGENTS LIVE" && both?.badgeHelp == "Agents running there: 2 Claude Code.",
                  "two agents in one worktree must both show: \(both?.badge?.text ?? "no badge"), \(both?.badgeHelp ?? "")")
        print("PASS: Remove and Prune keep changes, hidden untracked files, ignored files that aren't caches, commits on no branch, "
              + "and worktrees an agent is running in")
    }

    /// Each worktree shows its changed files from git status, and each worktree or branch the stashes made on it.
    static func gitCountsCases(root: String) async throws {
        let fm = FileManager.default, repo = root + "/counts", linked = root + "/counts-linked"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: linked); try? fm.removeItem(atPath: repo) }
        func git(_ path: String, _ args: String...) throws { _ = try GitTool.run(["-C", path] + args) }
        func write(_ text: String, _ path: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        try git(repo, "init", "-b", "main")
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false"),
                             ("core.hooksPath", "/dev/null")] { try git(repo, "config", key, value) }
        for name in ["a", "b", "c"] { try write("\(name)\n", "\(repo)/\(name)") }
        try git(repo, "add", "."); try git(repo, "commit", "-m", "base")
        // A branch with no worktree and two stashes, one with a message.
        try git(repo, "switch", "-c", "parked")
        try write("parked\n", repo + "/a"); try git(repo, "stash")
        try write("kept\n", repo + "/a"); try git(repo, "stash", "push", "-m", "kept")
        try git(repo, "switch", "main")
        // The primary worktree: one stash, one staged change, two unstaged changes, and one untracked file.
        try write("stashed\n", repo + "/a"); try git(repo, "stash")
        try write("staged\n", repo + "/a"); try git(repo, "add", "a")
        try write("changed\n", repo + "/b"); try write("changed\n", repo + "/c"); try write("new\n", repo + "/new")
        // A linked worktree with one untracked file and no stashes.
        try git(repo, "worktree", "add", "-b", "side", linked)
        try write("new\n", linked + "/side-new")

        let scan = await WorktreeScanner.scan()
        let records = scan.records.filter { $0.repository == "counts" }
        guard let primary = records.first(where: \.isPrimary), let side = records.first(where: { !$0.isPrimary }),
              let parked = scan.branches[primary.repositoryRoot]?.first(where: { $0.name == "parked" }) else {
            throw WorktreeError("the counts fixture's worktrees and branch were not scanned")
        }
        try check((primary.staged, primary.unstaged, primary.untracked, primary.conflicted) == (1, 2, 1, 0) && primary.dirty,
                  "primary counts: +\(primary.staged) !\(primary.unstaged) ?\(primary.untracked)")
        try check((side.staged, side.unstaged, side.untracked) == (0, 0, 1) && side.dirty && !side.safeToRemove,
                  "a worktree with only an untracked file is dirty and protected")
        try check(primary.changes.stashes == 1 && side.changes.stashes == 0 && parked.changes.stashes == 2,
                  "each stash counts on the branch it was made on: main *\(primary.stashes), side *\(side.stashes), parked *\(parked.stashes)")
        print("PASS: worktrees and branches show their own git status counts and stashes")
    }

    /// Each worktree shows one state badge, the most important one, so the row never says the same thing twice.
    static func worktreeBadgeCases() throws {
        func record(primary: Bool = false, dirty: Bool = false, locked: Bool = false, agent: Bool = false,
                    missing: Bool = false, unreadable: Bool = false) -> WorktreeRecord {
            WorktreeRecord(repository: "repo", repositoryRoot: "/dev/repo", path: primary ? "/dev/repo" : "/dev/repo-x", branch: "x", head: "-",
                           dirty: dirty, ahead: 0, behind: 0, hasUpstream: true, locked: locked, missing: missing, unreadable: unreadable,
                           sessions: agent ? [AgentSession(row: ["session_id": "session", "cwd": "/dev/repo-x"], kind: .codex)!] : [])
        }
        let cases: [(WorktreeRecord, String?)] = [
            (record(dirty: true, locked: true, missing: true), "MISSING"),
            (record(dirty: true, agent: true, unreadable: true), "NO STATUS"),
            (record(dirty: true, locked: true, agent: true), "AGENT LIVE"),
            (record(dirty: true, locked: true), "LOCKED"),
            (record(locked: true), "LOCKED"),
            (record(), "SAFE TO REMOVE"),
            // Uncommitted changes show as counts, so they need no badge of their own.
            (record(dirty: true), nil),
            (record(primary: true), nil)
        ]
        for (record, expected) in cases {
            try check(record.badge?.text == expected, "badge was \(record.badge?.text ?? "none"), expected \(expected ?? "none")")
        }
        // Merged or gone branches wait behind the merged-branches line; the default branch never does.
        func branch(_ name: String, merged: Bool = false, gone: Bool = false) -> BranchRecord {
            BranchRecord(repositoryRoot: "/dev/repo", name: name, head: "-", upstream: "origin/\(name)", gone: gone, ahead: 0, behind: 0,
                         lastCommit: Date(), base: "origin/main", merged: merged)
        }
        try check(branch("done", merged: true).finished && branch("pr-merged", gone: true).finished, "merged and gone branches are finished")
        try check(!branch("wip").finished && !branch("main", merged: true).finished, "active work and the default branch stay visible")
        print("PASS: each worktree shows its one most important state")
    }

    /// A selected pull request offers its diff, its repository's actions, and a worktree for its branch.
    static func pullRequestSelectionCases(repo: String) throws {
        func pull(_ number: Int, head: String, host: String = "github.com") -> PullRequestInfo {
            PullRequestInfo(number: number, title: "Fixture \(number)", url: URL(string: "https://\(host)/acme/rocket/pull/\(number)")!,
                            state: .open, author: "alice", mergedBy: nil, commits: 1, baseRef: "main", headRef: head,
                            createdAt: Date(), updatedAt: Date(), closedAt: nil, additions: 1, deletions: 0, checks: nil, review: nil)
        }
        let alone = SelectionActions(pulls: [PullSelection(pull: pull(412, head: "feature/retry"), repositoryRoot: repo)])
        try check(alone.repositories == [repo] && alone.count == 1, "a pull request's repository gets Fetch, Prune, and Pin")
        guard case .pull(let shown)? = alone.diff else { throw WorktreeError("one pull request alone must offer its diff") }
        try check(shown.number == 412, "the diff must be the selected pull request's")
        let parent = (repo as NSString).deletingLastPathComponent
        try check(alone.newWorktree?.branch == "feature/retry" && alone.newWorktree?.path == parent + "/repo-feature-retry",
                  "New Worktree must offer the pull request's branch beside the repository: \(String(describing: alone.newWorktree))")
        let fork = SelectionActions(pulls: [PullSelection(pull: pull(9, head: "forker:patch-1"), repositoryRoot: repo)])
        try check(fork.newWorktree?.branch == "", "a fork's branch isn't on origin, so New Worktree starts empty")
        let two = SelectionActions(pulls: [PullSelection(pull: pull(1, head: "a"), repositoryRoot: repo),
                                           PullSelection(pull: pull(2, head: "b"), repositoryRoot: repo)])
        try check(two.diff == nil && two.newWorktree?.branch == "", "two pull requests have no single diff or branch")

        try check(PullRequestClient.diffURL(for: pull(412, head: "x"))?.absoluteString == "https://api.github.com/repos/acme/rocket/pulls/412",
                  "the diff comes from the pull request's REST address")
        try check(PullRequestClient.diffURL(for: pull(412, head: "x", host: "gitlab.example.com")) == nil, "only GitHub pull requests have a diff")
        func message(_ status: Int) -> String { PullRequestClient.diffMessage(.init(status: status, data: Data(), remaining: nil, reset: nil)) }
        try check(message(406).contains("too large") || message(406).contains("this large"), "a diff GitHub refuses as too large says so")
        try check(message(404).contains("can't see"), "a pull request the account can't see says so")
        print("PASS: selected pull requests offer their diff, repository actions, and a worktree for their branch")
    }

    /// The line under each pull request's title reads like the top of its GitHub page.
    static func pullRequestWordingCases() throws {
        let dates = ISO8601DateFormatter(), now = dates.date(from: "2026-10-04T12:00:00Z")!
        func pull(_ state: PullRequestState, commits: Int, mergedBy: String? = nil, closed: String? = nil) -> PullRequestInfo {
            PullRequestInfo(number: 121, title: "Map OSFP failures", url: URL(string: "https://github.com/acme/repo/pull/121")!,
                            state: state, author: "octo-dev", mergedBy: mergedBy, commits: commits, baseRef: "main",
                            headRef: "octo/fix-flaky-test", createdAt: now, updatedAt: now, closedAt: closed.flatMap(dates.date(from:)),
                            additions: 1, deletions: 0, checks: nil, review: nil)
        }
        // Noon UTC stays the same calendar day in every time zone the tests run in.
        let cases: [(PullRequestInfo, String)] = [
            (pull(.merged, commits: 3, mergedBy: "review-lead", closed: "2026-07-02T12:00:00Z"),
             "review-lead merged 3 commits into main from octo/fix-flaky-test on 07/02/2026"),
            (pull(.merged, commits: 1, closed: "2025-07-02T12:00:00Z"), "ghost merged 1 commit into main from octo/fix-flaky-test on 07/02/2025"),
            (pull(.merged, commits: 2, mergedBy: "alice", closed: "2026-10-04T10:00:00Z"),
             "alice merged 2 commits into main from octo/fix-flaky-test on 10/04/2026"),
            (pull(.open, commits: 1), "octo-dev wants to merge 1 commit into main from octo/fix-flaky-test · opened 10/04/2026"),
            (pull(.draft, commits: 4), "octo-dev wants to merge 4 commits into main from octo/fix-flaky-test · opened 10/04/2026"),
            (pull(.closed, commits: 2, closed: "2026-09-01T12:00:00Z"), "octo-dev wants to merge 2 commits into main from octo/fix-flaky-test · closed 09/01/2026")
        ]
        for (pull, expected) in cases {
            try check(pull.sentence == expected, "expected \"\(expected)\", got \"\(pull.sentence)\"")
            // A merged pull request names its merger, so the author follows the number; other states lead with the author.
            try check(pull.reference == (pull.state == .merged ? "#121 by octo-dev" : "#121"), "reference was \(pull.reference)")
        }
        print("PASS: pull request lines read like GitHub's")
    }

    /// GitHub pull request lookups without the network: responses, request bodies, batches, slugs, and messages.
    static func pullRequestCases() throws {
        typealias Client = PullRequestClient
        let rocket = Client.Repository(root: "/dev/rocket", owner: "acme", name: "rocket",
                                       branches: ["feature": ["feature"], "shared": ["shared-a", "shared-b"]])
        let secret = Client.Repository(root: "/dev/secret", owner: "acme", name: "secret", branches: ["main": ["main"]])
        let batch = Client.Batch(parts: [.init(repository: rocket, heads: ["feature", "shared"]),
                                         .init(repository: secret, heads: ["main"])])
        func pull(_ number: Int, _ state: String, created: String, draft: Bool = false, cross: Bool = false, checks: String? = nil,
                  review: String? = nil, author: String? = "alice", merged: String? = nil, closed: String? = nil) -> [String: Any] {
            let rollup: Any = checks.map { ["state": $0] } ?? NSNull()
            return ["number": number, "title": "PR \(number)", "url": "https://github.com/acme/rocket/pull/\(number)", "state": state,
                    "isDraft": draft, "isCrossRepository": cross, "createdAt": created, "updatedAt": created,
                    "closedAt": closed ?? NSNull(), "mergedAt": merged ?? NSNull(), "additions": number * 10, "deletions": number,
                    "reviewDecision": review ?? NSNull(), "author": author.map { ["login": $0] } ?? NSNull(),
                    "mergedBy": merged == nil ? NSNull() : ["login": "merger"], "baseRefName": "main", "headRefName": "feature",
                    "headRefOid": "oid\(number)",
                    "commits": ["totalCount": number, "nodes": [["commit": ["statusCheckRollup": rollup]]]]]
        }
        let feature = [
            pull(5, "OPEN", created: "2026-10-04T00:00:00Z", cross: true, checks: "SUCCESS"),
            pull(1, "OPEN", created: "2026-10-01T00:00:00Z", checks: "SUCCESS", review: "APPROVED"),
            pull(3, "MERGED", created: "2026-09-01T00:00:00Z", checks: "FAILURE", review: "CHANGES_REQUESTED",
                 merged: "2026-09-02T00:00:00Z", closed: "2026-09-02T00:00:00Z"),
            pull(2, "OPEN", created: "2026-10-03T00:00:00Z", draft: true, checks: "PENDING", review: "REVIEW_REQUIRED"),
            pull(4, "CLOSED", created: "2026-08-01T00:00:00Z", checks: "ERROR", author: nil, closed: "2026-08-02T00:00:00Z")
        ]
        let shared = (6...11).map { pull($0, "MERGED", created: "2026-07-\(String(format: "%02d", $0))T00:00:00Z",
                                         checks: $0 == 6 ? "EXPECTED" : $0 == 7 ? nil : "SUCCESS", merged: "2026-07-20T00:00:00Z") }
        let response = try JSONSerialization.data(withJSONObject: [
            "data": ["viewer": ["login": "fixture-user"], "r0": ["h0": ["nodes": feature], "h1": ["nodes": shared]], "r1": NSNull()],
            "errors": [["type": "NOT_FOUND", "path": ["r1"], "message": "Could not resolve to a Repository with the name 'acme/secret'."]]
        ])
        let result = Client.parse(response, batch: batch)
        let pulls = result.pulls[PullRequestLookup.key(repositoryRoot: "/dev/rocket", branch: "feature")] ?? []
        try check(pulls.map(\.number) == [2, 1, 3, 4], "pull requests must be newest first without cross-repository ones")
        try check(pulls.map(\.state) == [.draft, .open, .merged, .closed], "states were mapped wrong")
        try check(pulls.map(\.checks) == [.pending, .success, .failure, .failure], "check rollups were mapped wrong")
        try check(pulls.map(\.review) == [.reviewRequired, .approved, .changesRequested, nil], "review decisions were mapped wrong")
        try check(pulls[3].author == "ghost" && pulls[1].author == "alice", "a deleted author must show as ghost")
        try check(pulls[1].closedAt == nil && pulls[2].closedAt == ISO8601DateFormatter().date(from: "2026-09-02T00:00:00Z"),
                  "closedAt must be the merge or close time, and nil while open")
        try check(pulls[1].additions == 10 && pulls[1].deletions == 1, "diff size was lost")
        try check(pulls[2].mergedBy == "merger" && pulls[1].mergedBy == nil, "the merger must be read, and only for merged pull requests")
        try check(pulls[2].commits == 3 && pulls[2].baseRef == "main" && pulls[2].headRef == "feature", "commit count and branches were lost")
        try check(pulls[2].headOid == "oid3", "the merged tip proves a branch's work merged, so it must be read")
        let a = result.pulls[PullRequestLookup.key(repositoryRoot: "/dev/rocket", branch: "shared-a")]
        let b = result.pulls[PullRequestLookup.key(repositoryRoot: "/dev/rocket", branch: "shared-b")]
        try check(a != nil && a == b, "a head shared by two local branches must land under both")
        try check(a?.map(\.number) == [11, 10, 9, 8, 7], "only the five most recent pull requests are kept")
        try check(a?.last?.checks == nil, "a commit without checks must have nil checks")
        try check(result.pulls.count == 3, "an unreadable repository must add no rows")
        try check(result.errors == ["No access to acme/secret as fixture-user"], "partial errors must name the repository: \(result.errors)")
        let expected = Client.parse(try JSONSerialization.data(withJSONObject: [
            "data": ["r0": ["h1": ["nodes": [pull(6, "OPEN", created: "2026-07-06T00:00:00Z", checks: "EXPECTED")]]]],
            "errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded"], ["message": "Something broke"]]
        ]), batch: batch)
        try check(expected.pulls.count == 2 && expected.pulls.values.allSatisfy { $0.first?.checks == .pending }, "EXPECTED checks are pending")
        try check(expected.errors == ["GitHub rate limit reached; try again later", "GitHub: Something broke"],
                  "rate limits and other errors need distinct messages: \(expected.errors)")
        try check(Client.parse(Data("<html>".utf8), batch: batch).errors == ["GitHub sent an unreadable response"], "bad JSON must not crash")
        let merged = Client.merge([result, Client.BatchResult(errors: ["No access to acme/secret as fixture-user", "x"])])
        try check(merged.error == "No access to acme/secret as fixture-user; x" && merged.pulls.count == 3, "merge must dedupe errors")

        // Branch names travel as variables, so quotes, backslashes, and braces can't change the query.
        let tricky = "we\"ird\\branch} {"
        let body = Client.body(.init(parts: [.init(repository: .init(root: "/dev/x", owner: "acme", name: "x", branches: [tricky: ["local"]]),
                                                   heads: [tricky])]))
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let query = json?["query"] as? String ?? "", variables = json?["variables"] as? [String: String] ?? [:]
        try check(!query.contains("we\"ird") && !query.contains("branch}") && !query.contains("acme"), "names must not be in the query text")
        try check(variables == ["o0": "acme", "n0": "x", "r0h0": tricky], "names must travel as variables: \(variables)")
        try check(query.contains("$r0h0: String!") && query.contains("headRefName: $r0h0") && query.contains("first: 5,"),
                  "each head needs its own variable and the recent limit")

        // One request per repository, split so no request exceeds the head limit.
        let big = Client.Repository(root: "/dev/big", owner: "acme", name: "big",
                                    branches: Dictionary(uniqueKeysWithValues: (0..<120).map { ("b\($0)", ["b\($0)"]) }))
        let planned = Client.batches([big, rocket])
        try check(planned.count == 4 && planned.allSatisfy { $0.parts.count == 1 }, "each repository gets its own requests")
        try check(planned.allSatisfy { $0.parts[0].heads.count <= Client.maxHeadsPerRequest }, "a request exceeded the head limit")
        let heads = planned.flatMap { batch in batch.parts.flatMap { part in part.heads.map { "\(part.repository.name)/\($0)" } } }
        try check(heads.count == 122 && Set(heads).count == 122, "every head must be looked up exactly once")

        // The default branch also lists the newest pull requests into it, forks included, merged with any from it.
        try check(planned.allSatisfy { $0.parts[0].base == nil }, "only a repository whose default branch is local looks up pull requests into it")
        let home = Client.Repository(root: "/dev/home", owner: "acme", name: "home", branches: ["main": ["main"], "feature": ["feature"]],
                                     defaultBranch: "main")
        let homeBatch = Client.batches([home])[0]
        try check(homeBatch.parts[0].heads == ["feature", "main"] && homeBatch.parts[0].base == "main", "the default branch's part must ask for pull requests into it")
        let bigHome = Client.Repository(root: "/dev/big-home", owner: "acme", name: "big-home", branches: Dictionary(uniqueKeysWithValues:
            (0..<120).map { ("b\($0)", ["b\($0)"]) } + [("main", ["main"])]), defaultBranch: "main")
        let bases = Client.batches([bigHome]).map(\.parts[0]).filter { $0.base != nil }
        try check(bases.count == 1 && bases[0].heads.contains("main"), "pull requests into the default branch are asked for once, beside its head")
        let homeJSON = try JSONSerialization.jsonObject(with: Client.body(homeBatch)) as? [String: Any]
        let homeQuery = homeJSON?["query"] as? String ?? "", homeVariables = homeJSON?["variables"] as? [String: String] ?? [:]
        try check(homeQuery.contains("$r0b: String!") && homeQuery.contains("base: pullRequests(baseRefName: $r0b, first: 3,")
                  && homeVariables["r0b"] == "main", "the default branch must travel as a variable with its limit")
        var fork = pull(43, "OPEN", created: "2026-10-03T00:00:00Z", cross: true)
        fork["headRepositoryOwner"] = ["login": "forker"]
        let homeResult = Client.parse(try JSONSerialization.data(withJSONObject: ["data": ["r0": [
            "h0": ["nodes": [pull(30, "OPEN", created: "2026-09-30T00:00:00Z")]],
            "h1": ["nodes": [pull(10, "MERGED", created: "2025-01-01T00:00:00Z", merged: "2025-01-02T00:00:00Z")]],
            "base": ["nodes": [pull(44, "OPEN", created: "2026-10-04T00:00:00Z"), fork,
                               pull(42, "MERGED", created: "2026-10-02T00:00:00Z", merged: "2026-10-02T12:00:00Z"),
                               pull(41, "CLOSED", created: "2026-10-01T00:00:00Z", closed: "2026-10-01T12:00:00Z")]]
        ]]]), batch: homeBatch)
        let mainPulls = homeResult.pulls[PullRequestLookup.key(repositoryRoot: "/dev/home", branch: "main")] ?? []
        try check(mainPulls.map(\.number) == [44, 43, 42], "the default branch keeps its three newest pull requests: \(mainPulls.map(\.number))")
        try check(mainPulls[1].headRef == "forker:feature", "a fork's branch reads owner:branch, as on GitHub")
        try check(homeResult.pulls[PullRequestLookup.key(repositoryRoot: "/dev/home", branch: "feature")]?.map(\.number) == [30],
                  "other branches keep only the pull requests from them")

        let alias: (String) -> String = { $0 == "github-work" ? "github.com" : $0 }
        let remotes: [(String, String?)] = [
            ("https://github.com/octo/dotfiles.git", "octo/dotfiles"),
            ("git@github-work:example-org/service.git", "example-org/service"),
            ("ssh://git@github-work/example-org/infra.git", "example-org/infra"),
            ("git@GitHub.com:Acme/Rocket", "Acme/Rocket"),
            ("git@gitlab.example.com:team/repo.git", nil),
            ("https://github.com/acme", nil),
            ("/srv/git/repo.git", nil)
        ]
        for (remote, expected) in remotes {
            let slug = Client.slug(fromRemote: remote, resolveHost: alias).map { "\($0.owner)/\($0.name)" }
            try check(slug == expected, "slug for \(remote) was \(slug ?? "nil")")
        }

        func message(_ status: Int, _ body: String = "", remaining: String? = nil, reset: String? = nil) -> String {
            Client.message(.init(status: status, data: Data(body.utf8), remaining: remaining, reset: reset))
        }
        try check(message(401) == "GitHub rejected the gh token; run gh auth login", "401 must ask for gh auth login")
        try check(message(403, #"{"message":"API rate limit exceeded"}"#, remaining: "0", reset: "1790000000")
                    .hasPrefix("GitHub rate limit reached until "), "rate limits need a distinct message")
        try check(message(429, "You have exceeded a secondary rate limit") == "GitHub rate limit reached; try again later",
                  "secondary rate limits need a distinct message")
        try check(message(403, #"{"message":"Forbidden"}"#) == "GitHub returned HTTP 403" && message(502) == "GitHub returned HTTP 502",
                  "other failures report their status")
    }

    /// Records each lookup's queries.
    actor PullStub {
        private(set) var calls: [[PullRequestQuery]] = []
        func record(_ queries: [PullRequestQuery]) -> Int { calls.append(queries); return calls.count - 1 }
    }

    /// A delay that ignores cancellation, so a superseded lookup still delivers its result late.
    static func pause(_ seconds: Double) async {
        await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() } }
    }

    /// Pull request lookups get one query per repository, with each branch's name on origin, and their results
    /// are keyed like the rows that show them. A lookup that a newer scan superseded never replaces its results.
    @MainActor static func checkPullRequestWiring(repo: String) async throws {
        func git(_ args: String...) throws -> String { try GitTool.run(["-C", repo] + args) }
        let root = (repo as NSString).deletingLastPathComponent
        _ = try git("remote", "add", "upstream", "https://example.invalid/upstream.git")
        _ = try git("branch", "renamed", "main")
        _ = try git("config", "branch.renamed.remote", "origin")
        _ = try git("config", "branch.renamed.merge", "refs/heads/feature/renamed-on-origin")
        _ = try git("branch", "elsewhere", "main")
        _ = try git("config", "branch.elsewhere.remote", "upstream")
        _ = try git("config", "branch.elsewhere.merge", "refs/heads/elsewhere-upstream")
        _ = try git("worktree", "add", "-b", "tracked", root + "/repo-tracked", "main")
        _ = try git("config", "branch.tracked.remote", "origin")
        _ = try git("config", "branch.tracked.merge", "refs/heads/tracked-on-origin")
        _ = try git("worktree", "add", "--detach", root + "/repo-detached", "main")

        func pull(_ number: Int) -> PullRequestInfo {
            PullRequestInfo(number: number, title: "Fixture \(number)", url: URL(string: "https://github.com/acme/repo/pull/\(number)")!,
                            state: .open, author: "fixture", mergedBy: nil, commits: 1, baseRef: "main", headRef: "feature",
                            createdAt: Date(), updatedAt: Date(), closedAt: nil,
                            additions: 1, deletions: 1, checks: nil, review: nil)
        }
        let renamedKey = PullRequestLookup.key(repositoryRoot: repo, branch: "renamed")
        let trackedKey = PullRequestLookup.key(repositoryRoot: repo, branch: "tracked")
        let stale = PullRequestLookup(pulls: [renamedKey: [pull(1)]], error: "stale")
        let fresh = PullRequestLookup(pulls: [renamedKey: [pull(2)], trackedKey: [pull(3)]], error: "partial")
        let stub = PullStub()
        let model = WorktreeModel { queries in
            guard await stub.record(queries) == 0 else { return fresh }
            // The first lookup answers only after the newer one started and had time to publish.
            while await stub.calls.count < 2 { await pause(0.05) }
            await pause(0.5)
            return stale
        }
        func waitUntil(_ message: String, _ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while !(await condition()) {
                guard Date() < deadline else { throw WorktreeError(message) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await waitUntil("the first lookup never started") { await stub.calls.count == 1 }
        model.refresh()
        try await waitUntil("the second lookup never finished") { await stub.calls.count == 2 && !model.loadingPulls }
        // Give the superseded lookup time to finish; its result must be dropped.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let queries = await stub.calls[1]
        try check(queries.count == 1 && queries[0].repositoryRoot == repo, "each repository should get one query")
        let heads = queries[0].heads
        try check(heads["renamed"] == "feature/renamed-on-origin", "a branch should be looked up by its name on origin")
        try check(heads["tracked"] == "tracked-on-origin", "a worktree should be looked up by its upstream's name")
        try check(heads["elsewhere"] == "elsewhere", "an upstream on another remote should fall back to the local name")
        try check(heads["main"] == "main", "a branch without an upstream should use its local name")
        try check(heads["detached"] == nil, "detached worktrees have no pull requests")
        let renamed = model.branches[repo]?.first { $0.name == "renamed" }
        try check(renamed.flatMap { model.pulls[$0.id] }?.map(\.number) == [2], "a stale lookup replaced newer pull requests")
        let tracked = model.records.first { $0.branch == "tracked" }
        try check(tracked?.upstream == "origin/tracked-on-origin", "the scan should record a worktree's upstream")
        try check(tracked.flatMap { model.pulls[PullRequestLookup.key(repositoryRoot: $0.repositoryRoot, branch: $0.branch)] }?.map(\.number) == [3],
                  "a worktree's pull requests should be keyed by its repository and branch")
        try check(model.pullsError == "partial" && !model.loadingPulls, "the newest lookup's error should be shown")
        // Pull requests are selectable rows: a listed one stays selected across a refresh, and one that's gone doesn't.
        let selectedPull = ListRow.pull(pull(2), key: renamedKey).id
        model.selection = [selectedPull, "pull:gone"]
        model.refresh()
        try await waitUntil("the refresh's lookup never finished") { await stub.calls.count == 3 && !model.loading && !model.loadingPulls }
        try check(model.selection == [selectedPull], "selection after refresh: \(model.selection)")
        // Rows pick these Octicons by name, and a missing name would silently draw a dot.
        for symbol in [PullRequestState.open, .draft, .merged, .closed].map(\.symbol) + [CheckState.success, .failure, .pending].map(\.symbol) {
            try check(Octicons.image(symbol) != nil, "missing Octicon \(symbol)")
        }
        print("PASS: pull request lookups use origin's branch names and ignore stale results")
    }
}
