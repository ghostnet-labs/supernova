import AppKit
import SwiftUI

// Keep following through lazy layout and asynchronous tool/Markdown resizing.
// Only user gestures can suspend following; layout corrections cannot.
struct TranscriptScrollObserver: NSViewRepresentable {
    var followsLatest: Bool
    var onUserScroll: (Bool) -> Void
    var scrollToBottom: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onUserScroll = onUserScroll
        view.scrollToBottom = scrollToBottom
        view.followsLatest = followsLatest
        DispatchQueue.main.async {
            view.attach()
            view.scheduleBottom()
        }
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.detach()
    }

    final class ObserverView: NSView {
        var onUserScroll: ((Bool) -> Void)?
        var scrollToBottom: (() -> Void)?
        var followsLatest = false
        private weak var observedScroll: NSScrollView?
        private weak var observedDocument: NSView?
        private var observers: [NSObjectProtocol] = []
        private var userScrolling = false
        private var bottomScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        func attach() {
            guard let scroll = enclosingScrollView, let document = scroll.documentView,
                  scroll !== observedScroll || document !== observedDocument else { return }
            detach()
            observedScroll = scroll
            observedDocument = document
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                    guard let self, let scroll else { return }
                    self.userScrolling = name != NSScrollView.didEndLiveScrollNotification
                    let nearBottom = self.distanceFromBottom(scroll) < 48
                    if name == NSScrollView.willStartLiveScrollNotification || !nearBottom {
                        self.followsLatest = false
                    }
                    self.onUserScroll?(name == NSScrollView.willStartLiveScrollNotification ? false : nearBottom)
                })
            }
            // Frame changes cover content growth and viewport resizing; bounds
            // changes also catch SwiftUI adjusting its estimated lazy positions.
            for view in [document, scroll.contentView] {
                view.postsFrameChangedNotifications = true
                view.postsBoundsChangedNotifications = true
                for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                        self?.scheduleBottom()
                    })
                }
            }
            scheduleBottom()
        }

        func scheduleBottom() {
            guard followsLatest, !userScrolling, !bottomScheduled else { return }
            bottomScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bottomScheduled = false
                guard self.followsLatest, !self.userScrolling, let scroll = self.observedScroll,
                      self.distanceFromBottom(scroll) > 0.5 else { return }
                // SwiftUI must position its own lazy content; moving the AppKit
                // clip view directly can leave those rows unmaterialized.
                self.scrollToBottom?()
            }
        }

        private func distanceFromBottom(_ scroll: NSScrollView) -> CGFloat {
            guard let document = scroll.documentView else { return 0 }
            let visible = scroll.documentVisibleRect
            return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedScroll = nil
            observedDocument = nil
            userScrolling = false
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
