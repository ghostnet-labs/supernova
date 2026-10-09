import AppKit
import SwiftUI

struct SidebarSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> SizingView { SizingView() }

    func updateNSView(_ view: SizingView, context: Context) {
        view.configureSplitView()
    }

    final class SizingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureSplitView()
        }

        func configureSplitView() {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical,
                   let index = split.arrangedSubviews.firstIndex(where: { isDescendant(of: $0) }) {
                    // Preserve the user's width on window resize, but stay below
                    // AppKit's divider-drag priority (490) so manual resizing works.
                    let priority = NSLayoutConstraint.Priority(480)
                    if let controller = split.delegate as? NSSplitViewController,
                       controller.splitViewItems.indices.contains(index) {
                        let item = controller.splitViewItems[index]
                        if item.holdingPriority != priority { item.holdingPriority = priority }
                        item.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
                    } else if split.holdingPriorityForSubview(at: index) != priority {
                        split.setHoldingPriority(priority, forSubviewAt: index)
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
