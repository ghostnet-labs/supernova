import AppKit
import Foundation

@main struct StoreChecks {
    @MainActor static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { print("FAIL: \(message)"); exit(1) }
        }
        let suite = "AgentControlCenter.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "CodexSessions.notificationSound")
        SessionStore.migratePreferences(defaults, legacy: ["CodexSessions.pinned": ["root", "claude:root"], "CodexSessions.notificationSound": true,
            "CodexSessions.verboseTranscript": true, "CodexSessions.notifications": true])
        check(!defaults.bool(forKey: "CodexSessions.notificationSound"), "preserve explicit destination preferences")
        check(defaults.bool(forKey: "CodexSessions.verboseTranscript"), "import verbosity")
        SessionStore.migratePreferences(defaults, legacy: ["CodexSessions.verboseTranscript": false])
        check(defaults.bool(forKey: "CodexSessions.verboseTranscript"), "migration runs once")
        func snapshot(_ status: String, source: SessionSource = .codex, title: String = "Saved title", clientType: String = "CLI") throws -> ProviderSnapshot {
            let row: [String: Any] = ["session_id": "root", "transcript_path": "/tmp/absent-agent-fixture.jsonl", "cwd": "/tmp", "title": title,
                "client_type": clientType, "thread_source": "user", "root_session_id": "root", "status": status, "liveness": status == "CLOSED" ? "CLOSED" : "OPEN",
                "last_activity": 10, "started_at": 1, "state_started_at": 5, "file_bytes": 23, "file_identity": "a",
                "context_used_tokens": 300, "context_window_tokens": 1000, "context_window_is_estimated": true, "live_pid": 42]
            let child: [String: Any] = ["session_id": "child", "root_session_id": "root", "parent_thread_id": "root", "thread_source": "subagent",
                "transcript_path": "/tmp/child", "cwd": "/tmp", "status": "BUSY", "liveness": "OPEN", "table_detail": "Reviewer"]
            return try ProviderSnapshot.decode(JSONSerialization.data(withJSONObject: ["version": 1, "provider": source.executable,
                "health": "ok", "sessions": [row], "active_subagents": [child]]), source: source)
        }
        let store = SessionStore(startProviders: false, defaults: defaults)
        defer { store.stop() }
        var opens = 0, notifications: [String] = []
        store.onOpenWindow = { opens += 1 }
        store.onNotify = { _, title in notifications.append(title) }
        store.handleDeepLink(URL(string: "codex-sessions://session/claude:root")!)
        store.applyProvider(try snapshot("BUSY"), baseline: true)
        store.applyProvider(try snapshot("WAITING", source: .claude), baseline: true)
        check(store.selection == "claude:root" && opens == 1, "queue legacy deep-link selection until discovery")
        check(store.messages.isEmpty, "quiet discovery never parses a transcript")
        check(store.isPinned("root") && store.isPinned("claude:root"), "preserve provider identities and pins")
        check(store.selected?.stats.contextPercent == 30 && store.selected?.stats.contextWindowIsEstimated == true, "provider context metadata reaches browser")
        check(store.children(of: store.selected!).first?.id == "claude:child", "same provider hierarchy for popover")
        check(store.selected?.agents.first?.id == "claude:child", "same provider hierarchy for browser")
        check(notifications.isEmpty, "initial snapshots are silent")
        store.applyProvider(try snapshot("WAITING"), baseline: false)
        store.applyProvider(try snapshot("WAITING"), baseline: false)
        check(notifications.count == 1, "one waiting notification")
        store.applyProvider(try snapshot("BUSY"), baseline: false)
        store.providerFailed(.codex, message: "fixture failure")
        check(store.sessions.first { $0.id == "root" }?.lifecycle == .busy, "retain last good status during failure")
        check(store.sessions.first { $0.id == "root" }?.stale == true, "mark failed provider stale")
        store.applyProvider(try snapshot("CLOSED"), baseline: true)
        check(notifications.count == 1, "reconnection baseline is silent")
        store.applyProvider(try snapshot("BUSY"), baseline: false)
        store.applyProvider(try snapshot("CLOSED"), baseline: false)
        check(notifications.count == 2, "busy to closed finishes once")
        store.applyProvider(try snapshot("INTERRUPTED"), baseline: false)
        check(notifications.count == 3, "interruption notification")
        check(store.selection == "claude:root", "reordering preserves selection")
        store.handleDeepLink(URL(string: "agent-control-center://session/root")!)
        check(store.selection == "root" && opens == 2, "new links focus the same window")
        store.handleDeepLink(URL(string: "agent-control-center://open")!)
        check(opens == 2 && store.selection == "root", "open command preserves session selection")
        check(store.selected?.deepLink?.scheme == "agent-control-center", "new links use unified scheme")
        store.applyProvider(try snapshot("WAITING", title: "Provider rename"), baseline: false)
        check(store.selected?.title == "Provider rename", "provider titles remain authoritative")
        // A pasted log stays whole for search and Copy Last Request, but rows and the title get one capped line.
        let pasted: [String: Any] = ["session_id": "pasted", "transcript_path": "/tmp/absent-agent-fixture.jsonl", "cwd": "/tmp",
                                     "last_user_request": "\n\nfirst line\n" + String(repeating: "log ", count: 2_000)]
        let long = try ProviderSnapshot.decode(JSONSerialization.data(withJSONObject: ["version": 1, "provider": "codex", "health": "ok",
            "sessions": [pasted], "active_subagents": []]), source: .codex).sessions[0]
        check(long.lastRequest.count > 8_000 && long.requestLine.count == 500 && long.requestLine.hasPrefix("first line log")
              && long.title.count == 180 && !long.title.contains("\n"), "long requests show as one capped line")
        store.applyProvider(try snapshot("WAITING", clientType: "APP"), baseline: true)
        store.jump(store.sessions.first { $0.id == "root" }!)
        check(store.selection == "root" && opens == 3, "desktop click opens conversation without a terminal")
        store.jump(store.children(of: store.selected!).first!)
        check(store.selection == "root" && opens == 4, "desktop subagent click opens root conversation")
        for bad in ["garbage", "{\"version\":2}", "{\"version\":1,\"provider\":\"wrong\"}"] {
            do { _ = try ProviderSnapshot.decode(Data(bad.utf8), source: .codex); check(false, "reject malformed protocol") } catch {}
        }
        print("PASS: shared store, identity, links, selection, metadata, preferences, notifications, and stale recovery")

        let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
        let backend = scratch.appendingPathComponent("provider.py")
        let attempts = scratch.appendingPathComponent("attempts")
        let script = """
        #!/usr/bin/env python3
        import json,os,pathlib,sys,time
        os.setpgid(0,0) if os.getpgrp()!=os.getpid() else None
        path=pathlib.Path(\(String(reflecting: attempts.path)))
        count=int(path.read_text())+1 if path.exists() else 1
        path.write_text(str(count))
        def emit(ids=[]):
            print(json.dumps({'version':1,'provider':'codex','health':'ok','sessions':[],'active_subagents':[],'refresh_ids':ids}),flush=True)
        emit()
        if count==1:
            print('malformed',flush=True)
            time.sleep(30)
        for line in sys.stdin:
            emit([json.loads(line).get('request_id','refresh')])
        """
        try script.write(to: backend, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backend.path)
        setenv("AGENT_CONTROL_SESSIONS_BIN", backend.path, 1)
        let client = ProviderClient(source: .codex, interval: 2)
        let lock = NSLock()
        var baselines: [Bool] = [], failures = 0, refreshed = false
        client.onSnapshot = { snapshot, baseline in
            lock.lock(); defer { lock.unlock() }
            baselines.append(baseline)
            refreshed = refreshed || snapshot.refreshIDs.contains("manual")
        }
        client.onFailure = { _ in lock.lock(); failures += 1; lock.unlock() }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                lock.lock(); let done = condition(); lock.unlock()
                if done { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return false
        }
        client.start()
        check(wait { baselines.count >= 2 && failures > 0 }, "restart malformed provider")
        check(baselines.prefix(2).allSatisfy { $0 }, "restarted provider establishes a baseline")
        client.refresh(requestID: "manual")
        check(wait { refreshed }, "manual refresh round-trip")
        client.stop()
        let count = try String(contentsOf: attempts, encoding: .utf8)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let stoppedCount = try String(contentsOf: attempts, encoding: .utf8)
        check(count == stoppedCount, "stopping cancels restarts")
        print("PASS: provider framing, restart baseline, manual refresh, and shutdown")
    }
}
