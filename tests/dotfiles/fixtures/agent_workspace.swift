import AppKit
import Observation
import SwiftUI
import os

@main struct WorkspaceChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { print("FAIL: \(message)"); exit(1) }
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        // Keep SwiftUI layout and accessibility updates on AppKit's event loop.
        NSApp.run()
    }
    @MainActor static func runChecks() async throws {
        let root = WorktreeScanner.canonical(CommandLine.arguments[1])
        let fm = FileManager.default
        let repo = root + "/dev/repo", linked = root + "/dev/linked", external = root + "/external"
        let suite = "AgentWorkspace.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(WorkspaceThemes.all.count == 10 && Set(WorkspaceThemes.all.map(\.id)).count == 10, "ten distinct theme choices")
        check(WorkspaceThemes.all.allSatisfy { $0.scheme == .dark }, "all named presets are dark")
        for (retired, replacement) in [("github-light", "github-dark"), ("solarized-light", "obsidian")] {
            defaults.set(retired, forKey: WorkspaceThemes.preferenceKey)
            WorkspaceThemes.restore(defaults: defaults)
            check(AppTheme.shared.palette?.id == replacement, "retired light theme migrates to a dark theme")
            check(defaults.string(forKey: WorkspaceThemes.preferenceKey) == replacement, "theme migration persisted")
        }
        defaults.removeObject(forKey: WorkspaceThemes.preferenceKey)
        WorkspaceThemes.restore(defaults: defaults)
        check(AppTheme.shared.palette == nil, "new installs follow system appearance")
        for palette in WorkspaceThemes.all {
            let invalidated = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = AppTheme.background } onChange: { invalidated.withLock { $0 = true } }
            WorkspaceThemes.select(palette, defaults: defaults)
            check(invalidated.withLock { $0 }, "theme changes invalidate existing color consumers")
            check(defaults.string(forKey: WorkspaceThemes.preferenceKey) == palette.id, "selection saved")
            AppTheme.shared.palette = nil
            WorkspaceThemes.restore(defaults: defaults)
            check(AppTheme.shared.palette?.id == palette.id, "selection restored on launch")
            func luminance(_ color: Color) -> Double {
                let color = NSColor(color).usingColorSpace(.sRGB)!
                let components = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
                let channels = components.map { value -> Double in
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
            }
            for background in [palette.background, palette.surface] {
                let a = luminance(palette.foreground), b = luminance(background)
                let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                check((4.5...9).contains(contrast), "soft but readable text on \(palette.name) surfaces")
            }
            let syntax = palette.syntax
            for color in [syntax.keyword, syntax.string, syntax.number, syntax.typeName, syntax.function, syntax.comment] {
                let a = luminance(color), b = luminance(palette.surface)
                check((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5, "readable syntax in \(palette.name)")
            }
        }
        defaults.set("removed-theme", forKey: WorkspaceThemes.preferenceKey)
        WorkspaceThemes.restore(defaults: defaults)
        check(AppTheme.shared.palette == nil, "unknown saved theme safely follows system")
        WorkspaceThemes.select(nil, defaults: defaults)
        check(defaults.object(forKey: WorkspaceThemes.preferenceKey) == nil, "System clears saved override")
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let color = NSColor(AppTheme.foreground).usingColorSpace(.sRGB)!
            check((0.65...0.75).contains(color.redComponent), "System dark text uses a muted gray")
        }
        print("PASS: theme persistence, fallback, live observation, and text contrast for ten palettes")
        AppFont.shared.selection = WorkspaceFont.monospaced.rawValue
        for font in WorkspaceFont.allCases {
            let invalidated = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = AppFont.shared.selection } onChange: { invalidated.withLock { $0 = true } }
            WorkspaceThemes.selectFont(font, defaults: defaults)
            check(invalidated.withLock { $0 }, "font changes invalidate mounted views")
            AppFont.shared.selection = "System"
            AppFont.shared.family = nil
            WorkspaceThemes.restore(defaults: defaults)
            check(WorkspaceThemes.font == font, "font selection survives relaunch")
            if font == .github { check(AppFont.shared.family == font.postscriptName, "bundled GitHub font loads") }
            if let family = AppFont.shared.family {
                check(NSFont(name: family, size: 13) != nil, "selected custom font exists")
                print("PASS: \(font.rawValue) uses \(family)")
            }
            WorkspaceThemes.select(WorkspaceThemes.all[0], defaults: defaults)
            check(WorkspaceThemes.font == font, "changing theme preserves font")
        }
        defaults.set("missing-font", forKey: WorkspaceThemes.fontPreferenceKey)
        WorkspaceThemes.restore(defaults: defaults)
        check(WorkspaceThemes.font == .system, "unknown font falls back to system")
        WorkspaceThemes.selectFont(.system, defaults: defaults)
        check(defaults.object(forKey: WorkspaceThemes.fontPreferenceKey) == nil, "System resets saved font")
        WorkspaceThemes.select(nil, defaults: defaults)
        print("PASS: independent font persistence, reset, fallback, and live observation")
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
        check(workspace.forwardStack.count == 2, "Back keeps forward history")
        workspace.forward()
        check(workspace.page == .init(kind: .worktree, key: linked), "Forward returns to worktree")
        workspace.forward()
        check(workspace.page == .init(kind: .conversation, key: "history-24"), "Forward returns to conversation")
        check(store.selection == "history-24" && workspace.forwardStack.isEmpty, "Forward selects the conversation and exhausts history")
        workspace.back(); workspace.back()
        check(worktrees.selection == [linked] && worktrees.search == "feature", "round-trip navigation keeps repository state")
        workspace.navigate(workspace.page)
        check(workspace.forwardStack.count == 2, "selecting current page keeps forward history")
        let restored = try JSONDecoder().decode(WorkspacePage.self, from: defaults.data(forKey: "Workspace.page")!)
        check(restored == workspace.page, "last page persisted")
        store.handleDeepLink(URL(string: "agent-workspace://session/claude:live")!)
        check(workspace.page == .init(kind: .conversation, key: "claude:live"), "workspace URL opens provider conversation")
        check(workspace.forwardStack.isEmpty, "new navigation clears obsolete forward history")
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

        let localAgents = workspace.agentSessions.count
        let remoteData = try JSONSerialization.data(withJSONObject: ["version": 1, "provider": "codex", "health": "ok",
            "sessions": [row("live", repo, live: true)], "active_subagents": []])
        let remoteSnapshot = try ProviderSnapshot.decode(remoteData, source: .codex, host: "fixture-host", cache: URL(fileURLWithPath: root))
        store.applyProvider(remoteSnapshot, baseline: true)
        workspace.updateAssociations()
        check(workspace.worktreeFor(remoteSnapshot.sessions[0]) == nil, "identical remote cwd cannot attach to a local worktree")
        check(workspace.agentSessions.count == localAgents, "remote agents do not change local worktree protection")
        let locallyKnown = workspace.agentsKnown
        store.providerFailed(.codex, message: "offline", host: "fixture-host")
        check(workspace.agentsKnown == locallyKnown, "remote outage cannot block local Git actions")
        workspace.search = "fixture-host"
        check(workspace.matches(remoteSnapshot.sessions[0]), "workspace search includes SSH host")
        workspace.search = ""
        print("PASS: remote host search and local worktree isolation")

        for outcome in ["found", "missing", "unavailable", "removed"] {
            let restoreSuite = suite + ".Restore." + outcome
            let restoreDefaults = UserDefaults(suiteName: restoreSuite)!
            defer { restoreDefaults.removePersistentDomain(forName: restoreSuite) }
            let savedPage = WorkspacePage(kind: .conversation, key: remoteSnapshot.sessions[0].id)
            restoreDefaults.set(try JSONEncoder().encode(savedPage), forKey: "Workspace.page")
            let restoring = SessionStore(startProviders: false, defaults: restoreDefaults, importPreferences: false,
                                         notificationsDefault: false, managesGit: false, enableSSH: true)
            restoring.configureSSH("fixture-host slow-host")
            let restoredWorktrees = WorktreeModel(autoRefresh: false, lookupPulls: { _ in PullRequestLookup() })
            let restoredWorkspace = WorkspaceModel(sessions: restoring, worktrees: restoredWorktrees,
                                                   defaults: restoreDefaults, start: false)
            restoring.applyProvider(try snapshot(.codex, rows: []), baseline: true)
            restoring.applyProvider(try snapshot(.claude, rows: []), baseline: true)
            restoredWorktrees.onScan?()
            try await Task.sleep(for: .milliseconds(200))
            check(!restoring.isLoadingSessions, "remote discovery does not block local readiness")
            check(restoredWorkspace.page == savedPage, "local discovery preserves the pending remote page")
            restoring.providerFailed(.codex, message: "temporary outage", host: "fixture-host")
            try await Task.sleep(for: .milliseconds(200))
            check(restoredWorkspace.page == savedPage, "connection failure preserves the page while retrying")
            switch outcome {
            case "found": restoring.applyProvider(remoteSnapshot, baseline: true)
            case "missing", "unavailable":
                restoring.applyProvider(ProviderSnapshot(source: .codex, health: outcome == "missing" ? .ok : .unavailable,
                    error: nil, sessions: [], subagents: [], host: "fixture-host"), baseline: true)
            default: restoring.configureSSH("slow-host")
            }
            try await Task.sleep(for: .milliseconds(200))
            let expected = outcome == "found" ? savedPage : .home
            check(restoredWorkspace.page == expected, "remote restoration resolves after \(outcome)")
            let persisted = try JSONDecoder().decode(WorkspacePage.self, from: restoreDefaults.data(forKey: "Workspace.page")!)
            check(persisted == expected, "persisted page follows the resolved remote result")
            if outcome == "found" {
                check(restoring.selection == savedPage.key, "recovered remote conversation is selected")
            }
            restoredWorkspace.navigate(.init(kind: .conversation, key: "missing-local"))
            restoredWorktrees.onScan?()
            check(restoredWorkspace.page == .home, "an unrelated pending SSH host does not retain a missing local page")
            restoring.stop()
        }
        print("PASS: remote page restoration waits for its host, survives errors, and resolves missing or removed history")

        if CommandLine.arguments.contains("--render") {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            func detailed(_ row: [String: Any], model: String) -> [String: Any] {
                row.merging(["model": model, "reasoning_effort": "high", "tokens_total": 125000,
                             "context_used_tokens": 50000, "context_window_tokens": 200000,
                             "last_user_request": "Restore the session details", "state_started_at": Date().timeIntervalSince1970 - 120]) { _, new in new }
            }
            let idle = detailed(row("idle", repo, live: true), model: "gpt-5-codex").merging(["status": "IDLE"]) { _, new in new }
            store.applyProvider(try snapshot(.codex, rows: codexRows.map { detailed($0, model: "gpt-5-codex") } + [idle],
                                             children: [child, otherCheckout]), baseline: true)
            store.applyProvider(try snapshot(.claude, rows: claudeRows.map {
                detailed($0, model: "claude-sonnet-4").merging(["status": "WAITING"]) { _, new in new }
            }), baseline: true)
            // Capture the view directly: native window capture respects alphaValue,
            // which stays zero so these checks never display a window or take focus.
            func captureWindow(_ window: NSWindow, name: String) async throws {
                let controller = window.contentViewController!
                let view = controller.view
                let frame = view.frame
                window.contentViewController = nil
                defer { window.contentViewController = controller }
                view.frame = frame
                try await Task.sleep(for: .milliseconds(100))
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: root + "/" + name + ".png"))
            }
            func element(_ object: Any, id: String) -> AnyObject? {
                let accessible = object as AnyObject
                if accessible.accessibilityIdentifier?() == id { return accessible }
                for child in accessible.accessibilityChildren?() ?? [] {
                    if let found = element(child, id: id) { return found }
                }
                if let view = object as? NSView {
                    for child in view.subviews {
                        if let found = element(child, id: id) { return found }
                    }
                }
                return nil
            }
            func accessibleText(_ object: AnyObject) -> String {
                let node = object as? NSObject
                let value = node?.responds(to: NSSelectorFromString("accessibilityValue")) == true
                    ? node?.value(forKey: "accessibilityValue") as? String : nil
                let values = [object.accessibilityLabel?() ?? "", value ?? ""]
                return (values + (object.accessibilityChildren?() ?? []).map { accessibleText($0 as AnyObject) }).joined(separator: " ")
            }
            // Use real transcript rendering to compare prose, inline code, links, and fenced code.
            let sample = """
            Commands and paths are easy to find within the conversation.

            - Run `ghactivity --no-bots --json` to refresh the report.
            - The cache lives in `~/.cache/ghactivity`. **Your settings stay saved.**

            See [the repository](https://github.com/ghostnet-labs/supernova) for details.

            ```swift
            // Refresh the selected repository
            let repository = "setup"
            if changes.count > 0 {
                refresh(repository, limit: 20)
            }
            ```
            """
            var transcript = try JSONSerialization.data(withJSONObject: ["type": "response_item",
                "timestamp": "2026-10-21T18:00:00Z", "payload": ["type": "message", "role": "assistant",
                "phase": "final", "content": [["type": "output_text", "text": sample]]]])
            transcript.append(0x0A)
            try transcript.write(to: URL(fileURLWithPath: root + "/live.jsonl"))
            for path in [repo, linked] {
                try Data("fixture".utf8).write(to: URL(fileURLWithPath: path + "/sidebar-detail-fixture"))
            }
            workspace.navigate(.init(kind: .conversation, key: "live"))
            workspace.setVisible(true)
            store.refresh(full: true)
            while store.isLoadingTranscript || worktrees.loading { try await Task.sleep(for: .milliseconds(10)) }
            check(store.messages.count == 1, "the rendering fixture loads its sample transcript")
            for (appearance, width) in [(NSAppearance.Name.aqua, 1320.0), (.darkAqua, 1040.0)] {
                let controller = NSHostingController(rootView: WorkspaceView(model: workspace).defaultAppStorage(defaults))
                let view = controller.view
                view.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.contentViewController = controller
                WorkspaceWindowChrome.configure(window)
                window.setContentSize(NSSize(width: width, height: 820))
                window.alphaValue = 0; window.ignoresMouseEvents = true // never shown to the person logged in
                window.center()
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(400))
                view.layoutSubtreeIfNeeded()
                try await captureWindow(window, name: "workspace-\(appearance.rawValue)")
                for (id, title, status) in [("live", "Conversation live", "Busy"), ("claude:live", "Conversation live", "Waiting"),
                                           ("idle", "Conversation idle", "Idle"),
                                           ("history-24", "Conversation history-24", ""),
                                           (remoteSnapshot.sessions[0].id, "Conversation live", "Stale")] {
                    guard let row = element(window.contentView!.superview!, id: "workspace.session.\(id)") else {
                        check(false, "find sidebar session \(id)"); return
                    }
                    let text = accessibleText(row)
                    check(text.contains(title) && (status.isEmpty || text.contains(status)), "sidebar shows title and current status: \(text)")
                    check(text.contains("2m") == (!status.isEmpty && status != "Stale"),
                          "live badges show time in the current state; stale and recent rows omit it")
                    for detail in ["Restore the session details", "feature", "untracked", "gpt-5-codex", "claude-sonnet-4",
                                   "high", "tokens", "percent left", "Closed"] {
                        check(!text.contains(detail), "sidebar omits metadata: \(detail)")
                    }
                    let height = row.accessibilityFrame?().height ?? 0
                    check((20...32).contains(height), "sidebar session fits a single compact row")
                }
                print("PASS: compact sidebar titles, Busy/Idle/Waiting elapsed time, quiet Recent rows, and stale status")
                window.orderOut(nil)
            }
            // Reuse a mounted workspace so snapshots exercise live theme changes.
            let themed = NSHostingController(rootView: WorkspaceView(model: workspace).defaultAppStorage(defaults))
            let themedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 640),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            themedWindow.contentViewController = themed
            WorkspaceWindowChrome.configure(themedWindow)
            themedWindow.setContentSize(NSSize(width: 1040, height: 640))
            themedWindow.center()
            themedWindow.alphaValue = 0; themedWindow.ignoresMouseEvents = true
            themedWindow.orderFront(nil)
            let page = workspace.page
            for palette in WorkspaceThemes.all {
                let start = Date()
                WorkspaceThemes.select(palette, defaults: defaults)
                check(workspace.page == page, "theme switching preserves navigation")
                check(NSApp.appearance?.name == (palette.scheme == .dark ? .darkAqua : .aqua), "native controls follow theme")
                try await Task.sleep(for: .milliseconds(120))
                themed.view.layoutSubtreeIfNeeded()
                try await captureWindow(themedWindow, name: "theme-\(palette.id)")
                let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: root + "/theme-\(palette.id).png")))!
                func rgb(at x: Int) -> [CGFloat] {
                    let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                    return [color.redComponent, color.greenComponent, color.blueComponent]
                }
                // Compare rendered pane margins, allowing for display color-profile rounding.
                let gains = zip(rgb(at: bitmap.pixelsWide - 8), rgb(at: 8)).map { $0 / $1 }
                check(gains.allSatisfy { (1.02...1.2).contains($0) }, "\(palette.name) conversation is a slightly lighter sidebar hue: \(gains)")
                print(String(format: "PASS: rendered %@ in %.2fs (includes 120ms settle)", palette.name, Date().timeIntervalSince(start)))
            }
            for font in WorkspaceFont.allCases {
                WorkspaceThemes.selectFont(font, defaults: defaults)
                check(workspace.page == page, "font switching preserves navigation")
                let narrow = NSHostingController(rootView: MarkdownMessage("`iiii`").fontDesign(font.design))
                let wide = NSHostingController(rootView: MarkdownMessage("`WWWW`").fontDesign(font.design))
                let proposed = NSSize(width: 500, height: 100)
                let narrowWidth = narrow.sizeThatFits(in: proposed).width
                let wideWidth = wide.sizeThatFits(in: proposed).width
                check(narrowWidth < 100 && abs(narrowWidth - wideWidth) < 0.5, "inline code stays monospaced with \(font.rawValue)")
                try await Task.sleep(for: .milliseconds(120))
                themed.view.layoutSubtreeIfNeeded()
                try await captureWindow(themedWindow, name: "font-\(font.rawValue)")
            }
            WorkspaceThemes.selectFont(.system, defaults: defaults)
            WorkspaceThemes.select(WorkspaceThemes.all.first { $0.id == "obsidian" }, defaults: defaults)
            for (name, collapsed, mode, width) in [("collapsed", true, "Sessions", 1040.0),
                                                  ("repositories", false, "Repositories", 1320.0),
                                                  ("compact-sidebar", false, "Sessions", 1040.0)] {
                defaults.set(collapsed, forKey: "Workspace.sidebarCollapsed")
                defaults.set(mode, forKey: "Workspace.sidebarMode")
                defaults.set(260, forKey: "Workspace.sidebarWidth")
                themedWindow.setContentSize(NSSize(width: width, height: 640))
                themedWindow.center()
                try await Task.sleep(for: .milliseconds(400))
                themed.view.layoutSubtreeIfNeeded()
                check(workspace.page == page, "sidebar layout preserves conversation")
                try await captureWindow(themedWindow, name: "sidebar-\(name)")
            }
            try await Task.sleep(for: .milliseconds(200))
            let windowFrame = themedWindow.contentView!.superview!
            func press(_ id: String) {
                check(element(windowFrame, id: id)?.accessibilityPerformPress?() == true, "press \(id)")
            }
            // Exercise mounted controls without showing a window or taking focus.
            let recentBackStack = workspace.backStack, recentForwardStack = workspace.forwardStack
            let recentSelection = store.selection
            for expanded in [false, true] {
                press("workspace.sidebar.recent")
                try await Task.sleep(for: .milliseconds(200))
                check(defaults.bool(forKey: "Workspace.recentExpanded") == expanded, "Recent label toggles disclosure to \(expanded): \(String(describing: defaults.object(forKey: "Workspace.recentExpanded")))")
                check(workspace.page == page && store.selection == recentSelection,
                      "Recent disclosure preserves the selected conversation")
                check(workspace.backStack == recentBackStack && workspace.forwardStack == recentForwardStack,
                      "Recent disclosure leaves navigation history unchanged")
            }
            press("workspace.session.history-24")
            try await Task.sleep(for: .milliseconds(100))
            check(workspace.page == .init(kind: .conversation, key: "history-24"), "Recent session row opens its conversation")
            press("workspace.navigation.back")
            try await Task.sleep(for: .milliseconds(100))
            check(workspace.page == page, "Back returns directly to the conversation after opening a Recent session")
            print("PASS: Recent disclosure preserves the conversation and history; session rows still navigate")
            press("workspace.sidebar.mode.repositories")
            try await Task.sleep(for: .milliseconds(100))
            check(defaults.string(forKey: "Workspace.sidebarMode") == "Repositories", "mode control switches sidebar content")
            press("workspace.sidebar.toggle")
            try await Task.sleep(for: .milliseconds(400))
            check(defaults.bool(forKey: "Workspace.sidebarCollapsed"), "sidebar control collapses sidebar")
            press("workspace.sidebar.toggle")
            try await Task.sleep(for: .milliseconds(400))
            check(!defaults.bool(forKey: "Workspace.sidebarCollapsed"), "sidebar control reopens sidebar")
            press("workspace.navigation.back")
            try await Task.sleep(for: .milliseconds(80))
            check(workspace.page != page, "Back button opens the preceding page")
            press("workspace.navigation.forward")
            try await Task.sleep(for: .milliseconds(80))
            check(workspace.page == page, "Forward button restores the conversation")
            press("workspace.sidebar.toggle")
            try await Task.sleep(for: .milliseconds(400))
            check(defaults.bool(forKey: "Workspace.sidebarCollapsed"), "collapse button persists state")
            check(element(windowFrame, id: "workspace.sidebar.themes") != nil, "Appearance remains accessible when collapsed")
            press("workspace.navigation.search")
            try await Task.sleep(for: .milliseconds(400))
            check(!defaults.bool(forKey: "Workspace.sidebarCollapsed"), "Search expands the sidebar")
            check(element(windowFrame, id: "workspace.search.field") != nil, "Search reveals its field")
            check(workspace.page == page, "search and collapse preserve the conversation")
            try await captureWindow(themedWindow, name: "sidebar-search")
            print("PASS: Back, Forward, sidebar collapse/reopen, search, and accessibility activation without focus")
            // Exercise an actual parsed response, including grouped activity and lazy tool details.
            let styleRecords: [(String, [String: Any])] = [
                ("event_msg", ["type": "task_started", "turn_id": "style"]),
                ("response_item", ["type": "message", "role": "user", "content": [["type": "input_text",
                    "text": "Make the conversation easier to read, with quieter activity and colors that follow my theme."]]]),
                ("response_item", ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text",
                    "text": "I’ll check `WorkspaceViews.swift` and adjust the conversation layout. Your theme and font choices will stay in place."]]]),
                ("response_item", ["type": "function_call", "call_id": "style-one", "name": "exec_command", "arguments": "{\"cmd\":\"swift test\"}"]),
                ("response_item", ["type": "function_call_output", "call_id": "style-one", "output": "All conversation checks passed."]),
                ("response_item", ["type": "function_call", "call_id": "style-two", "name": "exec_command", "arguments": "{\"cmd\":\"git diff --check\"}"]),
                ("response_item", ["type": "function_call_output", "call_id": "style-two", "output": "No whitespace errors."]),
                ("response_item", ["type": "message", "role": "assistant", "phase": "final", "content": [["type": "output_text", "text": """
                    The conversation now has more room to breathe. User messages sit in rounded bubbles, and assistant replies flow directly on the page.

                    - Inline code like `theme.background` stays easy to find.
                    - Tool activity expands when you want the details.
                    - [Links](https://github.com/ghostnet-labs/supernova) and syntax colors follow your theme.

                    ```swift
                    let background = theme.background
                    conversation.apply(background)
                    ```
                    """]]]),
                ("event_msg", ["type": "task_complete", "turn_id": "style", "duration_ms": 136000])
            ]
            var styleData = Data()
            var openStyleData = Data()
            for (index, record) in styleRecords.enumerated() {
                if index == styleRecords.count - 1 { openStyleData = styleData }
                styleData.append(try JSONSerialization.data(withJSONObject: ["type": record.0, "payload": record.1,
                    "timestamp": Date(timeIntervalSince1970: 1792612800 + Double(index * 17)).ISO8601Format()]))
                styleData.append(0x0A)
            }
            try styleData.write(to: URL(fileURLWithPath: root + "/style.jsonl"))
            store.applyProvider(try snapshot(.codex, rows: [row("style", repo)]), baseline: true)
            workspace.navigate(.init(kind: .conversation, key: "style"))
            defaults.set("Sessions", forKey: "Workspace.sidebarMode")
            themedWindow.setContentSize(NSSize(width: 1120, height: 940))
            WorkspaceThemes.select(WorkspaceThemes.all.first { $0.id == "github-dark" }, defaults: defaults)
            try await Task.sleep(for: .milliseconds(400))
            let responseText = accessibleText(windowFrame)
            check(responseText.contains("Worked for 2m 16s") && !responseText.contains("Final response"),
                  "response duration replaces repeated assistant headings")
            try await captureWindow(themedWindow, name: "conversation-style")
            let firstTool = store.activity.first { $0.kind == .tool }!
            press("activity-group-\(firstTool.id)")
            try await Task.sleep(for: .milliseconds(150))
            press("timeline-event-\(firstTool.id)")
            try await Task.sleep(for: .milliseconds(300))
            check(accessibleText(windowFrame).contains("All conversation checks passed."), "compact activity still opens the original tool output")
            try await captureWindow(themedWindow, name: "conversation-tool-details")
            press("activity-group-\(firstTool.id)")
            themedWindow.setContentSize(NSSize(width: 900, height: 720))
            WorkspaceThemes.select(WorkspaceThemes.all.first { $0.id == "tokyo-night" }, defaults: defaults)
            try await Task.sleep(for: .milliseconds(200))
            try await captureWindow(themedWindow, name: "conversation-narrow")
            check(store.messages.count == 3, "conversation styling preserves the parsed messages")
            try openStyleData.write(to: URL(fileURLWithPath: root + "/style-open.jsonl"))
            var openRow = row("style-open", repo, live: true)
            store.applyProvider(try snapshot(.codex, rows: [openRow]), baseline: true)
            workspace.navigate(.init(kind: .conversation, key: "style-open"))
            try await Task.sleep(for: .milliseconds(300))
            check(accessibleText(windowFrame).contains("Working for"), "busy response shows live elapsed time")
            openRow["status"] = "IDLE"
            store.applyProvider(try snapshot(.codex, rows: [openRow]), baseline: true)
            try await Task.sleep(for: .milliseconds(150))
            check(!accessibleText(windowFrame).contains("Working for"), "idle sessions cannot keep an unfinished response clock running")
            print("PASS: response duration, open assistant prose, compact activity disclosure, and lazy tool output")
            for source in [SessionSource.codex, .claude] {
                var queuedRow = detailed(row("live", repo, live: true), model: "fixture")
                queuedRow["queued_messages"] = [
                    ["id": "next", "text": "After this finishes, check the sidebar at a narrow width.\nKeep the current conversation selected."],
                    ["id": "later", "text": "Then review `config.swift` and summarize the changes.", "is_paused": true]
                ]
                store.applyProvider(try snapshot(source, rows: [queuedRow]), baseline: true)
                let queuedPage = WorkspacePage(kind: .conversation, key: source == .codex ? "live" : "claude:live")
                workspace.navigate(queuedPage)
                try await Task.sleep(for: .milliseconds(400))
                guard let queue = element(windowFrame, id: "conversation.queued-messages") else {
                    check(false, "queued messages are visible for \(source.rawValue)"); return
                }
                let text = accessibleText(queue)
                try await captureWindow(themedWindow, name: "queue-\(source.executable)")
                check(text.contains("Queued messages") && text.contains("narrow width") && text.contains("Paused"),
                      "pending text and paused status appear in the conversation: \(text)")
                queuedRow["queued_messages"] = []
                store.applyProvider(try snapshot(source, rows: [queuedRow]), baseline: true)
                try await Task.sleep(for: .milliseconds(150))
                check(element(windowFrame, id: "conversation.queued-messages") == nil && workspace.page == queuedPage,
                      "clearing the queue updates the pane without changing the conversation")
            }
            print("PASS: Codex and Claude queued messages render and clear without transcript changes")
            WorkspaceThemes.selectFont(.chatgpt, defaults: defaults)
            let picker = NSHostingController(rootView: WorkspaceThemePicker())
            let pickerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 550),
                                        styleMask: [.titled], backing: .buffered, defer: false)
            pickerWindow.contentViewController = picker
            pickerWindow.setContentSize(picker.sizeThatFits(in: NSSize(width: 420, height: 640)))
            pickerWindow.alphaValue = 0; pickerWindow.ignoresMouseEvents = true
            pickerWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(120))
            picker.view.layoutSubtreeIfNeeded()
            check(picker.view.bounds.height <= 640, "theme picker fits smallest supported window")
            if let bitmap = picker.view.bitmapImageRepForCachingDisplay(in: picker.view.bounds) {
                picker.view.cacheDisplay(in: picker.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root + "/theme-picker.png"))
            }
            pickerWindow.orderOut(nil)
            themedWindow.orderOut(nil)
            WorkspaceThemes.selectFont(.system, defaults: defaults)
            WorkspaceThemes.select(nil, defaults: defaults)
            let settingsStore = SessionStore(startProviders: false, defaults: defaults, enableSSH: true)
            settingsStore.configureSSH("fixture-host")
            settingsStore.applyProvider(remoteSnapshot, baseline: true)
            settingsStore.applyProvider(ProviderSnapshot(source: .claude, health: .unavailable, error: nil,
                sessions: [], subagents: [], host: "fixture-host"), baseline: true)
            let settings = NSHostingController(rootView: SettingsView(store: settingsStore))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = settings
            window.setContentSize(NSSize(width: 520, height: 720))
            window.alphaValue = 0; window.ignoresMouseEvents = true
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            settings.view.layoutSubtreeIfNeeded()
            if let bitmap = settings.view.bitmapImageRepForCachingDisplay(in: settings.view.bounds) {
                settings.view.cacheDisplay(in: settings.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: root + "/ssh-settings.png"))
            }
            window.orderOut(nil)
            settingsStore.stop()
        }
        store.stop()
        print("PASS: Agent Workspace")
    }
}
