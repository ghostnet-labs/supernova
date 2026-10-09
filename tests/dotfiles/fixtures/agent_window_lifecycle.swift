import AppKit
import SwiftUI

@main struct WindowLifecycleChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        // Keep the app out of the Dock of whoever is logged in (CI runs as that user):
        // the delegate's Dock decisions are recorded in dockPolicy instead of applied.
        app.setActivationPolicy(.prohibited)
        AppDelegate.applyActivationPolicy = { _ in }
        let mode = CommandLine.arguments[1]
        let suite = "AgentWorkspace.WindowTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(startProviders: false, defaults: defaults, importPreferences: false,
                                 notificationsDefault: false, managesGit: false)
        defer { store.stop() }
        let title = "Agent Workspace Window Test"
        let delegate = AppDelegate(store: store, title: title, rootView: { AnyView(Text("Window lifecycle fixture")) },
                                   keepsDockIconWhenClosed: mode != "legacy")
        app.delegate = delegate
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { print("FAIL: \(message)"); exit(1) }
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        if mode == "early-open" {
            delegate.application(app, open: [URL(string: "agent-workspace://open")!])
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        if mode == "early-open" {
            check(delegate.dockPolicy == .regular, "launch completion must not remove an already opened app from the Dock")
        } else {
            check(delegate.dockPolicy == .accessory, "login starts quietly in the menu bar")
            check(!app.windows.contains { $0.title == title && $0.isVisible }, "login does not open a browser")
        }
        delegate.showBrowser(); settle()
        let window = app.windows.first { $0.title == title }!
        check(window.isVisible && delegate.dockPolicy == .regular, "opening joins the Dock and app switcher")
        check(!window.hidesOnDeactivate, "switching apps must not hide the browser")
        delegate.showBrowser(); settle()
        check(app.windows.filter { $0.title == title }.count == 1, "reopening reuses the browser")
        window.miniaturize(nil); settle()
        check(delegate.dockPolicy == .regular, "minimizing keeps the Dock icon")
        let settingsItem = app.mainMenu!.items[0].submenu!.items.first { $0.title == "Settings…" }!
        check(app.sendAction(settingsItem.action!, to: settingsItem.target, from: settingsItem), "settings menu opens")
        settle()
        let settings = app.windows.first { $0.title == title + " Settings" }!
        settings.performClose(nil); settle()
        check(delegate.dockPolicy == .regular, "closing settings preserves a minimized browser in the Dock")
        _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false); settle()
        check(window.isVisible && !window.isMiniaturized, "reopening restores a minimized browser")
        app.hide(nil); settle()
        check(delegate.dockPolicy == .regular, "hiding the app keeps it in the app switcher")
        delegate.showBrowser(); settle()
        check(!app.isHidden && window.isVisible, "opening unhides the browser")
        window.performClose(nil); settle()
        check(!window.isVisible, "closing closes the browser")
        check(delegate.dockPolicy == (mode == "legacy" ? .accessory : .regular), "closing keeps Agent Workspace in the Dock and app switcher")
        check(!delegate.applicationShouldTerminateAfterLastWindowClosed(app), "monitoring survives window close")
        _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false); settle()
        check(window.isVisible && delegate.dockPolicy == .regular, "Dock reopen restores the same browser")
        check(app.windows.filter { $0.title == title }.count == 1, "Dock reopen does not create a duplicate")
        window.orderOut(nil)
        print("PASS: \(mode) window lifecycle")
    }
}
