import AppKit
import SwiftUI

// Match Worktree Manager's soft selection without changing native List navigation.
// Attach inside a session row so only its enclosing sidebar table is affected.
struct SidebarSelection: NSViewRepresentable {
    let isSelected: Bool

    func makeNSView(context: Context) -> StylingView { StylingView() }

    func updateNSView(_ view: StylingView, context: Context) {
        DispatchQueue.main.async { view.configure() }
    }

    final class StylingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }

        func configure() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
