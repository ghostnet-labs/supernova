import AppKit
import SwiftUI

@main
struct AgentControlCenterApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--check-build") {
            print("Agent Control Center build OK")
            return
        }
        let app = NSApplication.shared
        makeProjectWorkspace = { store, close in AnyView(ProjectWorkspaceView(sessionStore: store, onClose: close)) }
        let delegate = AppDelegate(store: SessionStore())
        delegate.shutdownOwnedWork = { await ManagedConversationRegistry.shutdown() }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
