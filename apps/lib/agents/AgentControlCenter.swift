import AppKit
import Combine
import SwiftUI

struct CompactSessionRow: View {
    @ObservedObject var store: SessionStore
    let session: CodexSession
    var body: some View {
        CompactSessionDetails(session: session, git: store.gitStatuses[session.cwd])
            .contentShape(Rectangle()).contextMenu {
                Button("Show Terminal") { store.jump(session) }
                Button("Open Conversation") { store.openSession(session.id) }
                Button("Reveal Project") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }
            }
    }
}

/// The same session information in the menu bar and the Workspace sidebar, with actions supplied by each surface.
struct CompactSessionDetails: View {
    let session: CodexSession
    var git: GitStatus?
    var pinned = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).help("Pinned") }
                SessionTitle(title: session.title, status: session.lifecycle.rawValue,
                             elapsed: session.isLive ? StatusPill.elapsed(since: session.lifecycleStartedAt) : "")
            }
            if !session.lastRequest.isEmpty && session.lastRequest != session.title {
                Text(session.requestLine).font(.subheadline).lineLimit(1).truncationMode(.tail).help(session.requestLine)
            }
            SessionMetadata(repository: git?.repository ?? session.cwd, branch: git?.branch ?? session.branch, git: git,
                            model: session.model, source: session.source.rawValue, effort: session.reasoning,
                            totalTokens: session.stats.totalTokens, contextUsed: session.stats.contextUsed,
                            contextWindow: session.stats.contextWindow, contextEstimated: session.stats.contextWindowIsEstimated)
            if session.stale { Text("Stale").font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct CompactAgentTree: View {
    @ObservedObject var store: SessionStore
    let session: CodexSession
    var body: some View {
        let children = store.children(of: session)
        let expanded = store.expandedRoots.contains(session.id)
        VStack(alignment: .leading, spacing: 8) {
            Button { store.jump(session) } label: { CompactSessionRow(store: store, session: session) }.buttonStyle(.plain)
            if !children.isEmpty {
                SubagentToggle(count: children.count, running: children.filter { $0.lifecycle == .busy }.count, expanded: expanded) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if store.expandedRoots.remove(session.id) == nil { store.expandedRoots.insert(session.id) }
                    }
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(children) { child in
                            Button { store.jump(child) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(child.agentLabel).font(.caption.weight(.semibold))
                                        Text(child.requestLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    StatusPill(status: child.lifecycle.rawValue, elapsed: StatusPill.elapsed(since: child.lifecycleStartedAt), compact: true)
                                }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.leading, 6)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1) }
                        .padding(.leading, 4)
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct ControlCenterView: View {
    @ObservedObject var store: SessionStore
    let openWindow: () -> Void
    var title = "Agent Control Center"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title3.bold())
                    Text("\(store.liveSessions.count) live · \(store.sessions.count) known").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isLoadingSessions { ProgressView().controlSize(.small) }
                else { Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless) }
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let status = store.providerSummary {
                        Label(status, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(14)
                    }
                    if store.liveSessions.isEmpty {
                        ContentUnavailableView("No live agents", systemImage: "moon.zzz",
                            description: Text("Active Codex and Claude Code sessions will appear here automatically."))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    ForEach(store.liveSessions) { session in
                        CompactAgentTree(store: store, session: session)
                        Divider().padding(.leading, 14)
                    }
                    let recent = Array(store.sessions.lazy.filter { !$0.isLive && !$0.archived }.prefix(8))
                    if !recent.isEmpty {
                        Text("RECENT").font(.caption2.bold()).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                        ForEach(recent) { session in
                            Button { store.jump(session) } label: { CompactSessionRow(store: store, session: session) }
                                .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 8).opacity(0.7)
                        }
                    }
                }
            }.frame(maxHeight: max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 160))
            Divider()
            HStack {
                Button("Open \(title)", action: openWindow).buttonStyle(.borderless)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
            }.padding(10)
        }.frame(width: 470).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store: SessionStore
    private let title: String
    private let rootView: () -> AnyView
    private let visibility: ((Bool) -> Void)?
    private let windowSize: NSSize
    private let keepsDockIconWhenClosed: Bool
    var onRefresh: (() -> Void)?
    var shutdownOwnedWork: (() async -> Void)?

    init(store: SessionStore, title: String = "Agent Control Center", rootView: (() -> AnyView)? = nil,
         visibility: ((Bool) -> Void)? = nil, windowSize: NSSize = NSSize(width: 1180, height: 780),
         keepsDockIconWhenClosed: Bool = false) {
        self.store = store; self.title = title
        self.rootView = rootView ?? { AnyView(RootView(store: store)) }
        self.visibility = visibility
        self.windowSize = windowSize
        self.keepsDockIconWhenClosed = keepsDockIconWhenClosed
        super.init()
    }
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var openWindows: Set<ObjectIdentifier> = []
    private var observation: AnyCancellable?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateActivationPolicy()
        installMenus()
        store.onOpenWindow = { [weak self] in self?.showBrowser() }
        NotificationCenter.default.addObserver(forName: .agentJumpStarted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
        popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: ControlCenterView(store: store, openWindow: { [weak self] in self?.showBrowser() }, title: title))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        observation = store.$sessions.sink { [weak self] sessions in
            let attention = sessions.contains { $0.isLive && $0.lifecycle.isAttention }
            self?.statusItem.button?.image = NSImage(systemSymbolName: attention ? "exclamationmark.bubble.fill" : "cpu", accessibilityDescription: self?.title)
            self?.statusItem.button?.toolTip = "\(self?.title ?? "") — " + (attention ? "action required" : "\(sessions.filter(\.isLive).count) live")
        }
        if CommandLine.arguments.contains("--open") { showBrowser() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            await shutdownOwnedWork?()
            store.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { store.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showBrowser(); return true }
    func application(_ application: NSApplication, open urls: [URL]) { showBrowser(); urls.forEach(store.handleDeepLink) }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        openWindows.remove(ObjectIdentifier(closing))
        if closing === mainWindow { setVisible(false) }
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        // Hidden and minimized windows are still open. An early URL-open event can also
        // create a window before launch finishes; neither case should remove the Dock icon.
        let keepInDock = !openWindows.isEmpty || (keepsDockIconWhenClosed && (mainWindow != nil || settingsWindow != nil))
        let policy: NSApplication.ActivationPolicy = keepInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func showBrowser() {
        popover?.performClose(nil)
        if mainWindow == nil {
            mainWindow = makeWindow(NSHostingController(rootView: rootView()), title: title, size: windowSize)
        }
        activate(mainWindow!)
        setVisible(true)
        if Bundle.main.bundleIdentifier != nil && UserDefaults.standard.bool(forKey: "CodexSessions.notifications") { NotificationManager.shared.requestAuthorization() }
    }

    private func setVisible(_ visible: Bool) {
        if let visibility { visibility(visible) } else { store.setBrowserVisible(visible) }
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = makeWindow(NSHostingController(rootView: SettingsView()), title: "\(title) Settings", size: NSSize(width: 520, height: 320)) }
        activate(settingsWindow!)
    }
    private func makeWindow(_ controller: NSViewController, title: String, size: NSSize) -> NSWindow {
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
    private func activate(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        updateActivationPolicy()
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title); item.submenu = submenu; menu.addItem(item); return submenu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let row = NSMenuItem(title: title, action: action, keyEquivalent: key)
            row.keyEquivalentModifierMask = modifiers; row.target = target; menu.addItem(row)
        }
        let app = submenu(title)
        item(app, "Open \(title)", #selector(showBrowser), "o", target: self)
        item(app, "Settings…", #selector(showSettings), ",", target: self)
        app.addItem(.separator())
        item(app, "Hide \(title)", #selector(NSApplication.hide(_:)), "h")
        item(app, "Quit \(title)", #selector(NSApplication.terminate(_:)), "q")
        let edit = submenu("Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            item(edit, title, Selector(selector), key)
        }
        let sessions = submenu("Sessions")
        let actions: [(String, String, NSEvent.ModifierFlags)] = [
            ("Mission Control", "1", .command), ("Find Session", "k", .command), ("Find in Transcript", "f", .command),
            ("Previous Session", "\u{F700}", [.command, .option]), ("Next Session", "\u{F701}", [.command, .option]),
            ("Resume in Ghostty", "\r", .command), ("Jump to Live Workspace", "j", [.command, .shift]),
            ("Pin / Unpin", "p", [.command, .shift]), ("Archive / Unarchive", "a", [.command, .shift]),
            ("Refresh All", "r", [.command, .shift]), ("Toggle Inspector", "i", .command)]
        for (index, action) in actions.enumerated() {
            item(sessions, action.0, #selector(sessionAction(_:)), action.1, action.2, target: self)
            sessions.items.last?.tag = index
        }
        let window = submenu("Window")
        item(window, "Close", #selector(NSWindow.performClose(_:)), "w")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }
    @objc private func sessionAction(_ item: NSMenuItem) {
        showBrowser()
        switch item.tag {
        case 0: store.showDashboard.toggle()
        case 1: NotificationCenter.default.post(name: .codexFocusSessionSearch, object: nil)
        case 2: NotificationCenter.default.post(name: .codexFocusTranscriptSearch, object: nil)
        case 3: store.nextSession(delta: -1)
        case 4: store.nextSession(delta: 1)
        case 5: store.resume(.ghostty)
        case 6: store.jumpToLiveWorkspace()
        case 7: if let id = store.selection { store.togglePin(id) }
        case 8: NotificationCenter.default.post(name: .codexArchiveSession, object: nil)
        case 9: store.refresh(full: true); onRefresh?()
        case 10: store.toggleInspector()
        default: break
        }
    }
}

struct SettingsView: View {
    @AppStorage("CodexSessions.notifications") private var notifications = true
    @AppStorage("CodexSessions.notificationSound") private var notificationSound = true
    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Notify when a session needs input or finishes", isOn: $notifications)
                    .onChange(of: notifications) { _, enabled in if enabled { NotificationManager.shared.requestAuthorization() } }
                Toggle("Play notification sound", isOn: $notificationSound).disabled(!notifications)
            }
            Section("Data") {
                LabeledContent("Codex home", value: CodexData.home.path)
                LabeledContent("Claude Code home", value: ClaudeData.home.path)
                Text("Archive actions are available only for inactive Codex sessions.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(18).frame(width: 520).background(AppTheme.background).tint(AppTheme.accent)
    }
}
