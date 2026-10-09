import AppKit
import SwiftUI

@main struct WorkspaceChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func main() async throws {
        let root = WorktreeScanner.canonical(CommandLine.arguments[1])
        let fm = FileManager.default
        let repo = root + "/dev/repo", linked = root + "/dev/linked", external = root + "/external"
        let suite = "AgentWorkspace.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(startProviders: false, defaults: defaults, importPreferences: false, notificationsDefault: false, managesGit: false)
        check(!defaults.bool(forKey: "CodexSessions.notifications"), "notifications default off")
        check(!defaults.bool(forKey: "AgentControlCenter.importedCodexSessions"), "no legacy preference import")
        func snapshot(_ source: SessionSource, rows: [[String: Any]], children: [[String: Any]] = [], refreshIDs: [String] = []) throws -> ProviderSnapshot {
            try ProviderSnapshot.decode(JSONSerialization.data(withJSONObject: ["version": 1, "provider": source.executable,
                "health": "ok", "sessions": rows, "active_subagents": children, "refresh_ids": refreshIDs]), source: source)
        }
        func row(_ id: String, _ cwd: String, live: Bool = false, time: Int = 0, archived: Bool = false) -> [String: Any] {
            ["session_id": id, "transcript_path": root + "/" + id + ".jsonl", "cwd": cwd, "title": "Conversation " + id,
             "status": live ? "BUSY" : "CLOSED", "liveness": live ? "OPEN" : "CLOSED", "live_pid": 42,
             "git_branch": "feature", "last_activity": time, "archived": archived]
        }
        let codexRows = [row("live", repo + "/nested", live: true, time: 100), row("alias", root + "/alias/nested"),
                         row("external", external), row("missing", root + "/missing"), row("non-git", root),
                         row("missing-nested", repo + "/missing-subdirectory"), row("unknown", "-"),
                         row("archived", repo, time: 1000, archived: true)]
            + (1...24).map { row("history-\($0)", linked, time: $0) }
        let claudeRows = [row("live", linked, live: true, time: 99)]
        var child = row("child", repo + "/nested", live: true)
        child["root_session_id"] = "live"; child["thread_source"] = "subagent"
        var otherCheckout = row("other-checkout", external, live: true)
        otherCheckout["root_session_id"] = "live"; otherCheckout["thread_source"] = "subagent"
        store.applyProvider(try snapshot(.codex, rows: codexRows, children: [child, otherCheckout]), baseline: true)
        store.applyProvider(try snapshot(.claude, rows: claudeRows), baseline: true)
        let worktrees = WorktreeModel(autoRefresh: false, lookupPulls: { _ in PullRequestLookup() })
        var confirmations = 0
        let workspace = WorkspaceModel(sessions: store, worktrees: worktrees, defaults: defaults, start: false,
                                      confirmAgents: { confirmations += 1 })
        let begin = Date()
        worktrees.scan = { await WorktreeScanner.scan(projectRoot: root + "/dev", additionalPaths: [external, root + "/alias"], sessions: workspace.agentSessions, running: []) }
        worktrees.refresh()
        while worktrees.loading { try await Task.sleep(for: .milliseconds(10)) }
        check(workspace.groups.count == 2, "common Git directory deduplicates linked checkouts and aliases")
        check(worktrees.records.count == 3, "all worktrees and external repository discovered")
        check(workspace.worktreeFor(store.sessions.first { $0.id == "live" }!)?.path == repo, "nested cwd maps to checkout")
        check(workspace.worktreeFor(store.sessions.first { $0.id == "alias" }!)?.path == repo, "symlink maps to checkout")
        check(workspace.worktreeFor(store.sessions.first { $0.id == "claude:live" }!)?.path == linked, "provider-prefixed identity and linked checkout")
        check(workspace.worktreeFor(store.sessions.first { $0.id == "non-git" }!) == nil, "non-Git history remains unattached")
        check(workspace.worktreeFor(store.sessions.first { $0.id == "missing" }!) == nil, "missing-directory history remains unattached")
        check(workspace.worktreeFor(store.sessions.first { $0.id == "missing-nested" }!) == nil, "missing subdirectory is not guessed from its parent")
        check(workspace.worktreeFor(store.sessions.first { $0.id == "unknown" }!) == nil, "unknown cwd is not resolved relative to the app")
        check(workspace.live.count == 2, "both providers in Live")
        let primary = worktrees.records.first { $0.path == repo }!
        check(primary.agentCount == 1 && primary.sessions.first?.subagents.count == 1, "children in the same directory stay under their root")
        check(primary.sessions.first?.title == "Conversation live" && primary.sessions.first?.status == "BUSY", "worktree rows reuse streamed agent details")
        check(worktrees.records.first { $0.path == external }?.hasLiveAgent == true, "child in another checkout protects its own worktree")
        check(workspace.recent.count == 20 && workspace.recent.first?.id == "history-24", "Recent is latest 20 inactive non-archived sessions")
        check(worktrees.records.filter { $0.path == linked }.allSatisfy { !$0.safeToRemove && !$0.canRebase }, "Claude protects worktree")
        print(String(format: "PASS: workspace discovery and association (%.2fs)", Date().timeIntervalSince(begin)))

        workspace.navigate(.init(kind: .repository, key: repo))
        worktrees.selection = [linked]; worktrees.search = "feature"
        workspace.navigate(.init(kind: .worktree, key: linked))
        workspace.navigate(.init(kind: .conversation, key: "history-24"))
        workspace.back(); workspace.back()
        check(worktrees.selection == [linked] && worktrees.search == "feature", "Back restores repository selection and filter")
        let restored = try JSONDecoder().decode(WorkspacePage.self, from: defaults.data(forKey: "Workspace.page")!)
        check(restored == workspace.page, "last page persisted")
        store.handleDeepLink(URL(string: "agent-workspace://session/claude:live")!)
        check(workspace.page == .init(kind: .conversation, key: "claude:live"), "workspace URL opens provider conversation")
        store.handleDeepLink(URL(string: "agent-control-center://session/live")!)
        check(workspace.page.key == "claude:live", "existing app links not intercepted")
        store.togglePin("live")
        check(store.isPinned("live"), "session pin retained")

        try await store.confirmFreshAgents(timeout: 0.2) { request in
            store.applyProvider(try! snapshot(.codex, rows: codexRows, refreshIDs: [request]), baseline: false)
            store.applyProvider(try! snapshot(.claude, rows: claudeRows, refreshIDs: [request]), baseline: false)
        }
        do {
            try await store.confirmFreshAgents(timeout: 0.03) { _ in
                store.applyProvider(try! snapshot(.codex, rows: codexRows, refreshIDs: ["old-request"]), baseline: false)
            }
            check(false, "unrelated snapshot must not authorize mutation")
        } catch {}
        do {
            try await store.confirmFreshAgents(timeout: 0.1) { _ in store.providerFailed(.claude, message: "fixture failure") }
            check(false, "provider failure must not authorize mutation")
        } catch {}
        workspace.updateAssociations()
        check(worktrees.records.allSatisfy { !$0.safeToRemove && !$0.canRebase }, "unknown agent state protects worktrees")
        store.applyProvider(try snapshot(.claude, rows: [row("unknown-live", "-", live: true)]), baseline: true)
        workspace.updateAssociations()
        check(!workspace.agentsKnown, "unknown live cwd cannot authorize removal")
        do {
            _ = try await worktrees.validateWorktrees!([worktrees.records.first { $0.path == linked }!], true)
            check(false, "unknown live cwd must fail execution-time validation")
        } catch {}
        store.applyProvider(try snapshot(.claude, rows: []), baseline: true)
        workspace.updateAssociations()
        let candidate = worktrees.records.first { $0.path == linked }!
        check(candidate.safeToRemove, "clean inactive secondary is eligible")
        let fresh = try await worktrees.validateWorktrees!([candidate], true)
        check(fresh.count == 1 && confirmations == 2, "protected action requests fresh agents and Git")
        try "changed".write(toFile: linked + "/new-file", atomically: true, encoding: .utf8)
        do {
            _ = try await worktrees.validateWorktrees!([candidate], true)
            check(false, "dirty worktree after confirmation must block removal")
        } catch {}
        try fm.removeItem(atPath: linked + "/new-file")
        print("PASS: navigation, identity, preferences, fresh provider confirmation, and action revalidation")

        for client in ["CLI", "APP"] {
            var parent = row("claude-parent", linked, live: true)
            parent["client_type"] = client
            var active = row("child", linked, live: true)
            active["root_session_id"] = "claude-parent"; active["thread_source"] = "subagent"
            active["table_detail"] = "Explore"
            var finished = row("finished", linked)
            finished["root_session_id"] = "claude-parent"; finished["thread_source"] = "subagent"
            finished["table_detail"] = "Reviewer"
            func claudeSnapshot(_ rows: [[String: Any]], _ active: [[String: Any]], _ history: [[String: Any]]) throws -> ProviderSnapshot {
                try ProviderSnapshot.decode(JSONSerialization.data(withJSONObject: ["version": 1, "provider": "claude", "health": "ok",
                    "sessions": rows, "active_subagents": active, "subagents": history]), source: .claude)
            }
            store.applyProvider(try claudeSnapshot([parent], [active], [active, finished]), baseline: true)
            let session = store.sessions.first { $0.id == "claude:claude-parent" }!
            check(store.children(of: session).map(\.id) == ["claude:child", "claude:finished"], "\(client) hierarchy retains finished Claude children")
            check(session.agents.first { $0.id == "claude:finished" }?.status == "CLOSED", "\(client) conversation shows finished status")
            check(workspace.agentSessions.first { $0.sessionID == "claude-parent" }?.subagents.map(\.sessionID) == ["child"],
                  "\(client) completed children do not count as live agents")
            parent["status"] = "CLOSED"; parent["liveness"] = "CLOSED"
            active["status"] = "CLOSED"; active["liveness"] = "CLOSED"
            store.applyProvider(try claudeSnapshot([parent], [], [active, finished]), baseline: true)
            check(store.children(of: store.sessions.first { $0.id == session.id }!).count == 2, "\(client) closed parent retains its children")
            check(workspace.agentSessions.allSatisfy { $0.kind != .claude }, "\(client) history never protects a worktree as a running agent")
        }
        store.applyProvider(try snapshot(.claude, rows: claudeRows), baseline: true)
        print("PASS: Claude desktop and CLI child history, provider identity, status, and live-agent accounting")

        let creation = WorkspaceCreation()
        let created = root + "/created"
        let request = CreateRequest(repositoryRoot: repo)
        let first = await creation.submit(request: request, branch: "new-work", path: created, createBranch: true, agent: .codex,
            launch: { _, _ in throw WorktreeError("agent unavailable") })
        check(!first && creation.createdPath == created && fm.fileExists(atPath: created), "failed launch retains created worktree")
        let retry = await creation.submit(request: request, branch: "new-work", path: created, createBranch: true, agent: .codex,
            create: { _, _, _, _ in throw WorktreeError("must not create twice") }, launch: { _, _ in })
        check(retry, "retry launches without recreating")
        let noLaunch = WorkspaceCreation()
        let noCreate = await noLaunch.submit(request: request, branch: "bad", path: root + "/bad", createBranch: true, agent: .codex,
            create: { _, _, _, _ in throw WorktreeError("fixture creation failure") }, launch: { _, _ in fatalError("launch after failed create") })
        check(!noCreate && noLaunch.createdPath == nil, "creation failure never launches an agent")
        print("PASS: create, launch failure, retry, and creation failure")

        if CommandLine.arguments.contains("--render") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            for (appearance, width) in [(NSAppearance.Name.aqua, 1320.0), (.darkAqua, 1040.0)] {
                workspace.navigate(.init(kind: .worktree, key: linked))
                let controller = NSHostingController(rootView: WorkspaceView(model: workspace))
                let view = controller.view
                view.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.contentViewController = controller
                window.setContentSize(NSSize(width: width, height: 820))
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root + "/workspace-\(appearance.rawValue).png"))
                }
                window.orderOut(nil)
            }
        }
        store.stop()
        print("PASS: Agent Workspace")
    }
}
