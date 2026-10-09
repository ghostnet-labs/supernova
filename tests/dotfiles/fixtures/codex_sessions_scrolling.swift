import AppKit

private final class TranscriptDocument: NSView {
    override var isFlipped: Bool { true }
}

@main struct ScrollingChecks {
    static func main() {
        _ = NSApplication.shared
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }
        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let document = TranscriptDocument(frame: NSRect(x: 0, y: 0, width: 500, height: 1_000))
        scroll.documentView = document
        let observer = TranscriptScrollObserver.ObserverView(frame: .zero)
        document.addSubview(observer)
        #if !BASELINE
        observer.scrollToBottom = {
            document.scroll(NSPoint(x: 0, y: document.bounds.maxY - scroll.documentVisibleRect.height))
        }
        #endif
        func following(_ enabled: Bool) {
            #if !BASELINE
            observer.followsLatest = enabled
            observer.scheduleBottom()
            #endif
        }
        var nearBottomEvents: [Bool] = []
        observer.onUserScroll = { nearBottom in
            nearBottomEvents.append(nearBottom)
            following(nearBottom)
        }
        following(true)
        observer.attach()
        document.scroll(NSPoint(x: 0, y: 700))
        settle()
        func atBottom() -> Bool { abs(document.bounds.maxY - scroll.documentVisibleRect.maxY) < 1 }
        check(atBottom(), "initial bottom position")
        document.setFrameSize(NSSize(width: 500, height: 1_400))
        settle()
        check(atBottom(), "appended message stays at bottom after layout")
        document.setFrameSize(NSSize(width: 500, height: 1_900))
        settle()
        check(atBottom(), "later Markdown/tool height change stays at bottom without another message")
        scroll.setFrameSize(NSSize(width: 400, height: 200))
        settle()
        check(atBottom(), "viewport resize follows bottom")
        check(nearBottomEvents.isEmpty, "layout corrections never masquerade as user scrolls")

        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        document.scroll(NSPoint(x: 0, y: 300))
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        // A delayed layout arrives before the gesture ends.
        document.setFrameSize(NSSize(width: 500, height: 2_100))
        settle()
        check(abs(scroll.documentVisibleRect.minY - 300) < 1, "new content does not interrupt a scroll-up gesture")
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        check(nearBottomEvents.last == false, "scrolling up pauses following")
        document.setFrameSize(NSSize(width: 500, height: 2_400))
        settle()
        check(abs(scroll.documentVisibleRect.minY - 300) < 1, "paused reader stays in place on new content")

        following(true) // The Latest button resumes following.
        settle()
        check(atBottom(), "Latest returns to the final layout position")
        following(false) // Transcript search disables automatic follow.
        document.scroll(NSPoint(x: 0, y: 600))
        document.setFrameSize(NSSize(width: 500, height: 2_700))
        settle()
        check(abs(scroll.documentVisibleRect.minY - 600) < 1, "search navigation is not pulled to the bottom")

        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY - scroll.documentVisibleRect.height))
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        check(nearBottomEvents.last == true, "scrolling back to the bottom resumes following")
        document.setFrameSize(NSSize(width: 500, height: 3_000))
        settle()
        check(atBottom(), "following stays active on the next append")
        print("Transcript scrolling checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
