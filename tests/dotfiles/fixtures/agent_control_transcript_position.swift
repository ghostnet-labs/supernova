import AppKit
import SwiftUI

// Open live and closed sessions in the real conversation view, off screen, and check
// that each one lands on its latest message after loading.
@main struct TranscriptPositionChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var failures = 0
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
        let transcript = scratch.appendingPathComponent("conversation.jsonl")
        var data = Data()
        for turn in 0..<40 {
            for (role, kind) in [("user", "input_text"), ("assistant", "output_text")] {
                let text = (0..<4).map { "Turn \(turn) \(role) paragraph \($0): keep the transcript long enough to scroll." }.joined(separator: "\n\n")
                let record: [String: Any] = ["type": "response_item", "timestamp": "2026-10-07T12:00:00.000Z",
                    "payload": ["type": "message", "role": role, "content": [["type": kind, "text": text]]]]
                data.append(try JSONSerialization.data(withJSONObject: record))
                data.append(10)
            }
        }
        try data.write(to: transcript)
        let suite = "AgentControlCenter.TranscriptPosition.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "CodexSessions.notifications")
        defaults.set(true, forKey: "AgentControlCenter.importedCodexSessions")
        defer { defaults.removePersistentDomain(forName: suite) }
        for live in [false, true] {
            let store = SessionStore(startProviders: false, defaults: defaults)
            var row: [String: Any] = ["session_id": "s", "root_session_id": "s", "thread_source": "user", "transcript_path": transcript.path,
                "cwd": scratch.path, "title": "Position", "status": live ? "WAITING" : "CLOSED", "liveness": live ? "OPEN" : "CLOSED",
                "last_activity": 1791384000, "started_at": 1791384000, "file_bytes": data.count]
            if live { row["live_pid"] = 1 }
            store.applyProvider(try ProviderSnapshot.decode(JSONSerialization.data(withJSONObject: ["version": 1, "provider": "codex",
                "health": "ok", "sessions": [row], "active_subagents": []]), source: .codex), baseline: true)
            store.applyProvider(ProviderSnapshot(source: .claude, health: .unavailable, error: nil, sessions: [], subagents: []), baseline: true)
            store.setBrowserVisible(true)
            store.choose("s")
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: SessionDetailView(store: store, session: store.sessions[0]))
            window.orderFrontRegardless()
            func transcriptScroll(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > scroll.frame.height { return scroll }
                return view.subviews.lazy.compactMap(transcriptScroll).first
            }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline && (store.isLoadingTranscript || store.messages.count < 80) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            let label = live ? "live" : "closed"
            if let scroll = transcriptScroll(window.contentView!), let document = scroll.documentView {
                let visible = scroll.documentVisibleRect
                let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
                if distance > 1 { failures += 1; print("FAIL: \(label) session opens \(Int(distance)) points above its latest message") }
            } else {
                failures += 1; print("FAIL: \(label) session shows no scrollable transcript (\(store.messages.count) messages)")
            }
            window.orderOut(nil)
            store.stop()
        }
        print("Transcript position checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
