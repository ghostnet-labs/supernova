import AppKit
import Foundation
import SwiftUI

@main struct UIValidation {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
        let suite = "AgentControlCenter.UI.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "CodexSessions.notifications")
        defaults.set(true, forKey: "AgentControlCenter.importedCodexSessions")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(startProviders: false, defaults: defaults)
        defer { store.stop() }
        let delegate = AppDelegate(store: store)
        app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        func check(_ condition: Bool, _ description: String) {
            if !condition { print("FAIL: \(description)"); exit(1) }
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
        check(app.activationPolicy() == .accessory, "quiet startup")
        check(!app.windows.contains { $0.isVisible && $0.title == "Agent Control Center" }, "no login browser")
        let transcript = scratch.appendingPathComponent("conversation.jsonl")
        let records: [[String: Any]] = [
            ["type": "event_msg", "timestamp": "2026-10-05T12:00:00Z", "payload": ["type": "task_started", "turn_id": "demo"]],
            ["type": "response_item", "timestamp": "2026-10-05T12:00:01Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Unify the menu bar and conversation browser, preserving saved sessions."]]]],
            ["type": "response_item", "timestamp": "2026-10-05T12:00:02Z", "payload": ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "## Shared session store\n\nThe browser and popover now display the same session information.\n\n- Stable session selection\n- Incremental transcript updates\n- One notification per transition\n\n```swift\nlet store = SessionStore()\n```"]]]],
            ["type": "response_item", "timestamp": "2026-10-05T12:00:03Z", "payload": ["type": "function_call", "call_id": "test", "name": "exec_command", "arguments": "{\"cmd\":\"python3 -m unittest\"}"]],
            ["type": "response_item", "timestamp": "2026-10-05T12:00:04Z", "payload": ["type": "function_call_output", "call_id": "test", "output": "All checks passed"]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: transcript)
        var row: [String: Any] = ["session_id": "root", "root_session_id": "root", "thread_source": "user", "transcript_path": transcript.path,
            "cwd": NSHomeDirectory() + "/dev/supernova/apps", "title": "Unify Agent Control Center", "model": "gpt-6", "reasoning_effort": "high",
            "status": "BUSY", "liveness": "OPEN", "live_pid": 42, "last_activity": Date().timeIntervalSince1970, "started_at": 1791192000,
            "state_started_at": Date().addingTimeInterval(-125).timeIntervalSince1970, "last_user_request": "Keep the popover and browser in sync.",
            "file_bytes": data.count, "git_branch": "main", "context_used_tokens": 64000, "context_window_tokens": 256000, "tokens_total": 250000]
        var waiting = row
        waiting["session_id"] = "waiting"; waiting["root_session_id"] = "waiting"; waiting["status"] = "WAITING"; waiting["title"] = "Review provider migration"
        var history = row
        history["session_id"] = "history"; history["root_session_id"] = "history"; history["status"] = "CLOSED"; history["liveness"] = "CLOSED"; history["title"] = "Previous conversation"
        row["file_identity"] = "fixture"
        let child: [String: Any] = ["session_id": "child", "root_session_id": "root", "parent_thread_id": "root", "thread_source": "subagent",
            "transcript_path": transcript.path, "cwd": NSHomeDirectory() + "/dev/supernova/apps", "title": "Review", "table_detail": "Reviewer",
            "status": "BUSY", "liveness": "OPEN", "last_user_request": "Verify migration and rollback", "state_started_at": Date().addingTimeInterval(-65).timeIntervalSince1970]
        let snapshot = try ProviderSnapshot.decode(JSONSerialization.data(withJSONObject: ["version": 1, "provider": "codex", "health": "ok", "sessions": [row, waiting, history], "active_subagents": [child]]), source: .codex)
        store.applyProvider(snapshot, baseline: true)
        store.applyProvider(ProviderSnapshot(source: .claude, health: .unavailable, error: nil, sessions: [], subagents: []), baseline: true)
        store.choose("root")
        delegate.showBrowser(); settle()
        check(app.activationPolicy() == .regular, "Dock visible with window")
        let window = app.windows.first { $0.title == "Agent Control Center" }!
        delegate.showBrowser(); settle()
        check(app.windows.filter { $0.title == "Agent Control Center" }.count == 1, "one browser window")
        check(!store.messages.isEmpty, "conversation rendered")
        func capture(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            if let window = view.window {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), scratch.appendingPathComponent(name + ".png").path]
                try capture.run()
                capture.waitUntilExit()
                if capture.terminationStatus == 0 { return }
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ProviderError("No bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: scratch.appendingPathComponent(name + ".png"))
        }
        store.showInspector = true
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            app.appearance = NSAppearance(named: appearance); settle()
            try capture(window.contentView!, name: "browser-" + name)
        }
        let popoverWindow = NSWindow(contentViewController: NSHostingController(rootView: ControlCenterView(store: store, openWindow: {})))
        popoverWindow.setContentSize(NSSize(width: 470, height: 720)); popoverWindow.orderFront(nil)
        store.expandedRoots.insert("root"); settle()
        try capture(popoverWindow.contentView!, name: "popover-expanded")
        popoverWindow.orderOut(nil)
        store.query = "no matching fixture"; settle()
        try capture(window.contentView!, name: "search-empty")
        store.query = ""; store.showDashboard = true; settle()
        try capture(window.contentView!, name: "dashboard")
        delegate.application(app, open: [URL(string: "codex-sessions://session/waiting")!]); settle()
        check(store.selection == "waiting" && !store.showDashboard, "legacy links select and focus")
        window.performClose(nil); settle()
        check(app.activationPolicy() == .accessory, "closing hides Dock")
        check(!window.isVisible, "browser closed")
        _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false); settle()
        check(window.isVisible && app.activationPolicy() == .regular, "reopening restores browser")
        window.performClose(nil)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS: quiet launch, Dock/window lifecycle, single window, links, transcript, and five layout captures")
    }
}
