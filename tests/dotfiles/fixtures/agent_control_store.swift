import AppKit
import Foundation

@main struct StoreChecks {
    @MainActor static func main() throws {
        signal(SIGPIPE, SIG_IGN)
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
        func snapshot(_ status: String, source: SessionSource = .codex, title: String = "Saved title", clientType: String = "CLI",
                      queued: [[String: Any]] = []) throws -> ProviderSnapshot {
            let row: [String: Any] = ["session_id": "root", "transcript_path": "/tmp/absent-agent-fixture.jsonl", "cwd": "/tmp", "title": title,
                "client_type": clientType, "thread_source": "user", "root_session_id": "root", "status": status, "liveness": status == "CLOSED" ? "CLOSED" : "OPEN",
                "last_activity": 10, "started_at": 1, "state_started_at": 5, "file_bytes": 23, "file_identity": "a",
                "context_used_tokens": 300, "context_window_tokens": 1000, "context_window_is_estimated": true, "live_pid": 42,
                "queued_messages": queued]
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
        store.applyProvider(try snapshot("BUSY"), baseline: false)
        store.applyProvider(try snapshot("IDLE"), baseline: false)
        store.applyProvider(try snapshot("IDLE"), baseline: false)
        check(notifications.count == 4, "busy to idle finishes once")
        check(!store.sessions.first { $0.id == "root" }!.lifecycle.isAttention, "idle does not need attention")
        check(store.selection == "claude:root", "reordering preserves selection")
        store.handleDeepLink(URL(string: "agent-control-center://session/root")!)
        check(store.selection == "root" && opens == 2, "new links focus the same window")
        store.handleDeepLink(URL(string: "agent-control-center://open")!)
        check(opens == 2 && store.selection == "root", "open command preserves session selection")
        check(store.selected?.deepLink?.scheme == "agent-control-center", "new links use unified scheme")
        store.applyProvider(try snapshot("WAITING", title: "Provider rename"), baseline: false)
        check(store.selected?.title == "Provider rename", "provider titles remain authoritative")
        for source in [SessionSource.codex, .claude] {
            let queued: [[String: Any]] = [["id": "one", "text": "Follow up\nwith details", "created_at": 1791201600000],
                                          ["id": "two", "text": "Another request", "created_at": "2026-10-05T12:00:00Z", "is_paused": true]]
            store.applyProvider(try snapshot("BUSY", source: source, queued: queued), baseline: true)
            let id = source == .codex ? "root" : "claude:root"
            let session = store.sessions.first { $0.id == id }!
            check(session.queuedMessages.map(\.text) == ["Follow up\nwith details", "Another request"], "queued text preserves order and newlines")
            check(session.queuedMessages[0].timestamp == session.queuedMessages[1].timestamp && session.queuedMessages[1].isPaused,
                  "both timestamp formats and paused status decode")
            store.applyProvider(try snapshot("BUSY", source: source), baseline: true)
            check(store.sessions.first { $0.id == id }!.queuedMessages.isEmpty, "queue clears without a transcript or status change")
        }
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
        func wait(seconds: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
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

        // The real in-memory bootstrap and reader run behind a local SSH transport
        // fixture. No configured host, credentials, or user's history is touched.
        func checkThrowing(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            let value = try condition(); check(value, message)
        }
        let repo = CommandLine.arguments[2]
        setenv("XDG_CACHE_HOME", scratch.appendingPathComponent("cache").path, 1)
        setenv("AGENT_CONTROL_SESSIONS_BIN", repo + "/dotfiles/.bin/codex-sessions", 1)
        let fakeSSH = scratch.appendingPathComponent("ssh.py")
        let sshPID = scratch.appendingPathComponent("ssh.pid")
        try """
        #!/usr/bin/env python3
        import os, pathlib, sys
        assert '-oBatchMode=yes' in sys.argv and '-oStrictHostKeyChecking=yes' in sys.argv
        assert sys.argv[-2] == 'fixture-host' and sys.argv[-3] == '--'
        pathlib.Path(\(String(reflecting: sshPID.path))).write_text(str(os.getpid()))
        os.execv('/bin/sh', ['sh', '-c', sys.argv[-1]])
        """.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        let remoteDirectory = CodexData.home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        let remoteFile = remoteDirectory.appendingPathComponent("rollout-fixture.jsonl")
        let uuid = UUID().uuidString.lowercased()
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": uuid, "thread_source": "user", "cwd": scratch.path, "timestamp": "2026-10-21T12:00:00Z"]],
            ["type": "event_msg", "timestamp": "2026-10-21T12:00:01Z", "payload": ["type": "user_message", "message": "remote transcript"]]
        ]
        var bytes = Data()
        for record in records { bytes.append(try JSONSerialization.data(withJSONObject: record)); bytes.append(10) }
        try bytes.write(to: remoteFile)
        let remote = ProviderClient(source: .codex, interval: 2, host: "fixture-host", sshExecutable: fakeSSH)
        var remoteSnapshot: ProviderSnapshot?, remoteFailures = 0, remoteBaselines = 0
        remote.onSnapshot = { value, baseline in
            print("SSH fixture snapshot: \(value.health.rawValue), \(value.sessions.count) sessions, \(value.error ?? "no error")")
            lock.lock(); defer { lock.unlock() }
            if value.health == .ok { remoteSnapshot = value; if baseline { remoteBaselines += 1 } }
        }
        remote.onFailure = { message in print("SSH fixture: \(message)"); lock.lock(); remoteFailures += 1; lock.unlock() }
        remote.start()
        check(wait { remoteSnapshot?.sessions.count == 1 }, "remote bootstrap discovers history without a remote checkout")
        lock.lock(); let firstRemote = remoteSnapshot!; lock.unlock()
        let row = firstRemote.sessions[0]
        check(row.nativeID == uuid && row.id == "ssh:fixture-host:codex:\(uuid)", "remote identity retains native resume ID")
        check(row.sshHost == "fixture-host" && URL(fileURLWithPath: row.remoteTranscriptPath).resolvingSymlinksInPath() == remoteFile.resolvingSymlinksInPath() && row.path != remoteFile,
              "remote paths never become local transcript paths")
        check(!FileManager.default.fileExists(atPath: row.path.path), "unopened remote history transfers no transcript bytes")
        var download: Result<RemoteTranscriptUpdate, Error>?
        func sync() throws -> RemoteTranscriptUpdate {
            lock.lock(); download = nil; lock.unlock()
            remote.syncTranscript(row) { result in lock.lock(); download = result; lock.unlock() }
            check(wait { download != nil }, "remote transcript round trip")
            lock.lock(); let result = download!; lock.unlock()
            return try result.get()
        }
        let firstRead = try sync()
        check(firstRead.reset && !firstRead.hasMore, "initial remote transcript resets cache")
        try checkThrowing(try Data(contentsOf: row.path) == bytes, "remote transcript bytes preserved")
        let extra = Data((String(repeating: "ø", count: 2 * 1024 * 1024 + 10) + "\n").utf8)
        let handle = try FileHandle(forWritingTo: remoteFile)
        try handle.seekToEnd(); try handle.write(contentsOf: extra); try handle.close()
        try checkThrowing(try sync().hasMore, "remote downloads are bounded chunks")
        try checkThrowing(try !sync().hasMore, "remote transcript continuation reaches EOF")
        try checkThrowing(try Data(contentsOf: row.path) == bytes + extra, "appended multibyte data is transferred once without corruption")
        try bytes.write(to: remoteFile, options: .atomic)
        try checkThrowing(try sync().reset, "replaced remote transcript resets cache")
        try checkThrowing(try Data(contentsOf: row.path) == bytes, "replacement removes old cached tail")
        let remotePID = Int32(try String(contentsOf: sshPID, encoding: .utf8))!
        kill(remotePID, SIGTERM)
        // Reconnecting waits out the provider's 1 s retry, then relaunches SSH and reruns the
        // Python bootstrap; on a CI host running several suites at once that can pass 8 s.
        check(wait(seconds: 30) { remoteFailures > 0 && remoteBaselines >= 2 }, "SSH disconnection reconnects with a silent baseline")
        remote.stop()
        check(!FileManager.default.fileExists(atPath: row.path.path), "remote cache removed on stop")
        print("PASS: SSH bootstrap, lazy chunks, Unicode, replacement, reconnect, and cache cleanup")

        try "#!/bin/sh\nexec sleep 30\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        let stalled = ProviderClient(source: .codex, interval: 2, host: "fixture-host", sshExecutable: fakeSSH)
        stalled.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let stopping = Date()
        stalled.stop()
        check(Date().timeIntervalSince(stopping) < 3, "stop cancels a blocked SSH bootstrap write")

        let remoteStore = SessionStore(startProviders: false, defaults: defaults, managesGit: false, enableSSH: true)
        remoteStore.configureSSH("fixture-host\nother-host fixture-host")
        check(remoteStore.sshHosts == ["fixture-host", "other-host"], "SSH aliases deduplicate and persist")
        let saved = defaults.string(forKey: "Workspace.sshHosts")
        remoteStore.configureSSH("-oProxyCommand=bad")
        check(defaults.string(forKey: "Workspace.sshHosts") == saved, "invalid SSH settings preserve last valid hosts")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "provider": "codex", "health": "ok",
            "sessions": [["session_id": uuid, "transcript_path": remoteFile.path, "cwd": scratch.path]], "active_subagents": []])
        let secondHost = try ProviderSnapshot.decode(data, source: .codex, host: "other-host", cache: scratch)
        remoteStore.applyProvider(firstRemote, baseline: true)
        remoteStore.applyProvider(secondHost, baseline: true)
        remoteStore.applyProvider(try ProviderSnapshot.decode(data, source: .codex), baseline: true)
        check(remoteStore.sessions.count == 3 && Set(remoteStore.sessions.map(\.id)).count == 3, "same native ID on two hosts and local stays distinct")
        remoteStore.providerFailed(.codex, message: "offline", host: "fixture-host")
        check(remoteStore.sessions.filter(\.stale).map(\.sshHost) == ["fixture-host"], "only the disconnected host becomes stale")
        check(remoteStore.providerHealth[.codex] == .ok, "remote failures do not alter local health")
        check(!row.canArchive, "remote archive never modifies a local file")
        let terminal = try RemoteSessions.terminalCommand(row, resume: true)
        check(terminal.contains("/usr/bin/ssh") && terminal.contains("fixture-host") && terminal.contains(uuid), "resume is routed through SSH")
        // A Linux host's live Codex row carries the TUI pane credited by the reader.
        let child = UUID().uuidString.lowercased(), daemonHeld = UUID().uuidString.lowercased()
        let liveData = try JSONSerialization.data(withJSONObject: ["version": 1, "provider": "codex", "health": "ok",
            "sessions": [["session_id": uuid, "transcript_path": "/home/u/.codex/sessions/rollout-a.jsonl", "cwd": "/home/u/project",
                          "liveness": "OPEN", "live_pid": 42, "tmux_socket": "/tmp/tmux-1000/default", "tmux_pane": "%60", "status": "BUSY"],
                         ["session_id": daemonHeld, "transcript_path": "/home/u/.codex/sessions/rollout-b.jsonl", "cwd": "/home/u/other",
                          "liveness": "OPEN", "live_pid": 7, "status": "BUSY"]],
            "active_subagents": [["session_id": child, "transcript_path": "/home/u/.codex/sessions/rollout-c.jsonl", "cwd": "/home/u/project",
                                  "liveness": "OPEN", "live_pid": 42, "status": "BUSY", "thread_source": "subagent",
                                  "root_session_id": uuid, "parent_thread_id": uuid]]])
        let live = try ProviderSnapshot.decode(liveData, source: .codex, host: "fixture-host", cache: scratch)
        check(live.sessions[0].agents.map(\.id) == ["ssh:fixture-host:codex:\(child)"], "remote Codex subagents nest under their host's root")
        let attach = try RemoteSessions.terminalCommand(live.sessions[0])
        check(attach.contains("attach-session -t") && attach.contains("%60") && attach.contains("/tmp/tmux-1000/default"),
              "remote Codex terminal attaches to the reported tmux pane")
        let shell = try RemoteSessions.terminalCommand(live.sessions[1])
        check(!shell.contains("attach") && shell.contains("/home/u/other"), "remote Codex without a pane opens a shell in its directory")
        check((try? RemoteSessions.terminalCommand(live.sessions[0], resume: true)) == nil, "live remote Codex sessions are not resumed twice")
        remoteStore.configureSSH("")
        check(remoteStore.sessions.count == 1 && !remoteStore.sessions[0].isRemote, "removing hosts removes only remote sessions")
        remoteStore.stop()
        print("PASS: remote settings, host isolation, stale state, and SSH action routing")
    }
}
