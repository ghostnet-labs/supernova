import AppKit
import SwiftUI

@main
struct AgentWorkspaceApp {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--check-build") {
            print("Agent Workspace build OK")
            return
        }
        SessionSource.environmentPrefix = "AGENT_WORKSPACE"
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 250])
        let store = SessionStore(importPreferences: false, notificationsDefault: false, managesGit: false)
        let workspace = WorkspaceModel(sessions: store)
        let app = NSApplication.shared
        let delegate = AppDelegate(store: store, title: "Agent Workspace",
            rootView: { AnyView(WorkspaceView(model: workspace)) }, visibility: workspace.setVisible,
            windowSize: NSSize(width: 1320, height: 820), keepsDockIconWhenClosed: true)
        delegate.onRefresh = { workspace.worktrees.refreshAll() }
        app.delegate = delegate
        FocusReleaser.install()
        ClickToDeselect.install()
        withExtendedLifetime((delegate, workspace)) { app.run() }
    }
}
