import AppKit
import SwiftUI

@main
struct WorktreeManagerApp: App {
    init() {
        FocusReleaser.install()
        ClickToDeselect.install()
        // macOS waits about a second before showing a tooltip; most buttons here are icon-only, so show labels sooner.
        // Registered rather than set, so `defaults write local.worktree-manager NSInitialToolTipDelay -int MS` still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
    }

    var body: some Scene {
        WindowGroup("Worktree Manager") { WorktreeManagerView() }
            .defaultSize(width: 1180, height: 720)
    }
}
