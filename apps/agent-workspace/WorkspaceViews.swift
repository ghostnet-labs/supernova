import AppKit
import SwiftUI

struct WorkspaceView: View {
    private enum SidebarMode: String, CaseIterable {
        case sessions = "Sessions", repositories = "Repositories"
        var symbol: String { self == .sessions ? "text.bubble" : "folder" }
    }
    @AppStorage("Workspace.sidebarMode") private var sidebarMode: SidebarMode = .sessions
    @AppStorage("Workspace.sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("Workspace.sidebarWidth") private var sidebarWidth = 330.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var sidebarResize: CGFloat = 0
    @ObservedObject var model: WorkspaceModel
    @AppStorage("Workspace.recentExpanded") private var recentExpanded = false
    @AppStorage("pinnedRepositories") private var pinnedRepositories = ""
    @State private var expandedSubagents: Set<String> = []
    @State private var archiveConfirmation = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = clampedSidebarWidth(CGFloat(sidebarWidth), available: geometry.size.width)
            let draggedWidth = clampedSidebarWidth(width + sidebarResize, available: geometry.size.width)
            HStack(spacing: 0) {
                sidebarRail
                    .overlay(alignment: .trailing) { Rectangle().fill(AppTheme.separator).frame(width: 1) }
                expandedSidebar
                    .frame(width: draggedWidth)
                    .offset(x: sidebarCollapsed ? -draggedWidth : 0)
                    .opacity(sidebarCollapsed ? 0 : 1)
                    .disabled(sidebarCollapsed)
                    .allowsHitTesting(!sidebarCollapsed)
                    .accessibilityHidden(sidebarCollapsed)
                    .frame(width: sidebarCollapsed ? 0 : draggedWidth, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
                sidebarDivider(width: width, available: geometry.size.width)
                VStack(spacing: 0) {
                    navigationBar
                    if let status = model.sessions.providerSummary {
                        Text(status).font(.caption).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
                    }
                    Divider()
                    if !model.search.isEmpty { searchResults }
                    else { detail.id(model.page.id) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: "workspace")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: sidebarCollapsed)
        }
        .frame(minWidth: 1040, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .background(AppTheme.background)
        .alert("Move session?", isPresented: $archiveConfirmation) {
            Button(model.sessions.selected?.archived == true ? "Unarchive" : "Archive") { model.sessions.archiveSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Move this inactive Codex conversation between history and the archive?") }
        .alert("Agent Workspace", isPresented: Binding(get: { model.sessions.errorMessage != nil }, set: { if !$0 { model.sessions.errorMessage = nil } })) {
            Button("OK") { model.sessions.errorMessage = nil }
        } message: { Text(model.sessions.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .codexFocusSessionSearch)) { _ in
            sidebarCollapsed = false
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexArchiveSession)) { _ in
            if model.sessions.selected?.canArchive == true { archiveConfirmation = true }
        }
    }

    private var expandedSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent Workspace").font(.title3.bold())
                Spacer(minLength: 0)
            }.padding(10)
            TextField("Search sessions, repositories, branches", text: $model.search)
                .textFieldStyle(.roundedBorder).focused($searchFocused).padding(.horizontal, 10).padding(.bottom, 8)
            // Keep both lists mounted through tab switches and collapse/expand transitions.
            ZStack {
                sidebarList(.sessions) { sessionNavigation }
                sidebarList(.repositories) { repositoryNavigation }
            }
        }
    }

    private var sidebarToggle: some View {
        Button {
            searchFocused = false
            sidebarCollapsed.toggle()
            NSCursor.arrow.set()
        } label: {
            Label(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar", systemImage: "sidebar.left")
        }
        .labelStyle(.iconOnly).buttonStyle(.bordered)
        .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityIdentifier("workspace.sidebar.toggle")
    }

    private var sidebarRail: some View {
        VStack(spacing: 10) {
            ForEach(SidebarMode.allCases, id: \.self) { mode in
                Button {
                    sidebarMode = mode
                    sidebarCollapsed = false
                } label: {
                    Image(systemName: mode.symbol).font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .background(sidebarMode == mode ? AppTheme.accent.opacity(0.2) : AppTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AppTheme.separator.opacity(0.5)))
                }
                .buttonStyle(.plain).help(mode.rawValue)
                .accessibilityLabel(mode.rawValue)
                .accessibilityAddTraits(sidebarMode == mode ? .isSelected : [])
                .accessibilityIdentifier("workspace.sidebar.rail.\(mode.rawValue.lowercased())")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10).frame(width: 52)
        .background(AppTheme.surface)
    }

    private func clampedSidebarWidth(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        // Reserve the 52-point rail, repository pane's 660-point minimum, and divider.
        min(max(260, proposed), min(440, max(260, available - 713)))
    }

    private func sidebarDivider(width: CGFloat, available: CGFloat) -> some View {
        Rectangle().fill(AppTheme.separator).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("workspace"))
                        .updating($sidebarResize) { value, state, _ in state = value.translation.width }
                        .onEnded { value in
                            sidebarWidth = Double(clampedSidebarWidth(width + value.translation.width, available: available))
                        })
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
            }
            .allowsHitTesting(!sidebarCollapsed)
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityAdjustableAction { direction in
                let change: CGFloat = direction == .increment ? 20 : -20
                sidebarWidth = Double(clampedSidebarWidth(width + change, available: available))
            }
            .accessibilityHidden(sidebarCollapsed)
    }

    private func sidebarList<Content: View>(_ mode: SidebarMode, @ViewBuilder content: () -> Content) -> some View {
        List(selection: Binding<WorkspacePage?>(get: { model.page }, set: { page in
            if let page, page != model.page { selectSidebar(page) }
        })) { content() }
            .listStyle(.sidebar)
            .opacity(sidebarMode == mode ? 1 : 0)
            .disabled(sidebarMode != mode)
            .allowsHitTesting(sidebarMode == mode)
            .accessibilityHidden(sidebarMode != mode)
    }

    private var sessionNavigation: some View {
        Group {
            ForEach(model.live.filter(model.matches)) { session in
                sessionRow(session, detailed: true)
                    .workspaceSidebarSelection(.init(kind: .conversation, key: session.id), current: model.page)
            }
            DisclosureGroup(isExpanded: Binding(get: { recentExpanded }, set: {
                recentExpanded = $0; selectSidebar(.init(kind: .recent))
            })) {
                ForEach(model.recent.filter(model.matches)) { session in
                    sessionRow(session, detailed: true)
                        .workspaceSidebarSelection(.init(kind: .conversation, key: session.id), current: model.page)
                }
            } label: { nav("Recent", "clock", .init(kind: .recent)) }
                .tag(WorkspacePage(kind: .recent))
                .workspaceSidebarSelection(.init(kind: .recent), current: model.page)
            nav("All Sessions", "text.bubble", .init(kind: .history))
                .workspaceSidebarSelection(.init(kind: .history), current: model.page)
            nav("Mission Control", "square.grid.2x2", .init(kind: .dashboard))
                .workspaceSidebarSelection(.init(kind: .dashboard), current: model.page)
        }
    }

    private var repositoryNavigation: some View {
        Section("Repositories") {
            nav("All Repositories", "square.stack.3d.up", .home)
                .workspaceSidebarSelection(.home, current: model.page)
            ForEach(model.groups) { group in
                let page = WorkspacePage(kind: .repository, key: group.root)
                DisclosureGroup(isExpanded: Binding(get: { model.expandedRepositories.contains(group.root) },
                    set: { expanded in
                        if model.expandedRepositories.contains(group.root) != expanded { model.toggleExpanded(group.root) }
                        model.search = ""; model.navigate(page)
                    })) {
                    ForEach(group.records) { record in
                        nav(record.name, record.isPrimary ? "house" : "folder",
                            .init(kind: .worktree, key: record.path), subtitle: record.branch, changes: record.changes,
                            doubleClick: { WorktreeActions.openTerminal(record.path) })
                            .workspaceSidebarSelection(.init(kind: .worktree, key: record.path), current: model.page)
                            .help("\(record.path)\n\(record.branch)\nDouble-click to open in a new terminal")
                    }
                } label: {
                    nav(group.name, "folder.badge.gearshape", page,
                        pinned: pinnedRepositories.split(separator: "\n").contains(Substring(group.root)))
                }.tag(page)
                    .workspaceSidebarSelection(page, current: model.page)
            }
        }
    }

    private var isLoading: Bool {
        model.worktrees.loading || model.worktrees.loadingPulls || model.sessions.isLoadingSessions || model.sessions.isLoadingTranscript
    }

    private var navigationBar: some View {
        HStack {
            sidebarToggle
            Button("Back", systemImage: "chevron.left") { model.search = ""; model.back() }
                .disabled(model.backStack.isEmpty).keyboardShortcut("[", modifiers: .command)
            Spacer()
            if model.page.kind == .conversation, let session = model.sessions.selected, let record = model.worktreeFor(session) {
                Button(record.name, systemImage: "folder") { model.navigate(.init(kind: .worktree, key: record.path)) }
                Button("Changes") { model.showDiff(.worktree(record)) }
            }
            Button { model.sessions.refresh(full: true); model.worktrees.refreshAll() } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    ZStack {
                        if isLoading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }.frame(width: 16, height: 16)
                }
            }
                .disabled(isLoading)
                .keyboardShortcut("r")
                .accessibilityLabel(isLoading ? "Refreshing" : "Refresh")
                .help("Refresh sessions, the open conversation, repositories, and pull requests")
        }.padding(10)
    }

    private func selectSidebar(_ page: WorkspacePage) {
        model.search = ""; model.navigate(page)
    }

    private func nav(_ title: String, _ symbol: String, _ page: WorkspacePage, pinned: Bool = false,
                     subtitle: String? = nil, changes: GitStatus? = nil, doubleClick: (() -> Void)? = nil) -> some View {
        Button {
            if page.kind == .repository { model.toggleExpanded(page.key) }
            if page.kind == .recent { recentExpanded.toggle() }
            selectSidebar(page)
            // Native click counts keep single-click navigation immediate.
            if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount == 2 {
                doubleClick?()
            }
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).lineLimit(1)
                        if let subtitle {
                            HStack(spacing: 6) {
                                Text(subtitle).lineLimit(1).truncationMode(.middle)
                                if let changes, !changes.isEmpty {
                                    GitCounts(git: changes).fixedSize().opacity(0.7)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: { Image(systemName: symbol) }
                Spacer(minLength: 0)
                if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .tag(page)
            .help(title)
    }

    private func sessionRow(_ session: CodexSession, detailed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.search = ""; model.sessions.openSession(session.id)
            } label: {
                Group {
                    if detailed {
                        CompactSessionDetails(session: session, git: model.sessions.gitStatuses[session.cwd],
                                              pinned: model.sessions.isPinned(session.id))
                    } else {
                        SessionRow(session: session, unread: 0, pinned: model.sessions.isPinned(session.id))
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if !detailed {
                if !session.branch.isEmpty { BranchRef(name: session.branch).font(.caption) }
                if session.stale { Text("Stale").font(.caption).foregroundStyle(.orange) }
            }
            let children = model.sessions.children(of: session)
            if !children.isEmpty {
                let running = children.filter { $0.lifecycle == .busy }.count
                let title = "\(children.count) subagent\(children.count == 1 ? "" : "s")"
                    + (detailed && running > 0 ? " · \(running) running" : "")
                let expanded = expandedSubagents.contains(session.id)
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if expanded { expandedSubagents.remove(session.id) } else { expandedSubagents.insert(session.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(title)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    if expanded {
                        ForEach(children) { child in
                            Button { model.sessions.jump(child) } label: {
                                HStack { Text(child.agentLabel); Spacer(); Text(child.lifecycle.rawValue).font(.caption) }
                            }.buttonStyle(.plain).help("Jump to subagent terminal").padding(.leading, 16)
                        }
                    }
                }.font(.caption)
            }
        }
        .padding(4)
        .tag(WorkspacePage(kind: .conversation, key: session.id))
        .contextMenu {
            Button(model.sessions.isPinned(session.id) ? "Unpin" : "Pin") { model.sessions.togglePin(session.id) }
            Button("Show Terminal") { model.sessions.jump(session) }
            ForEach(ResumeTarget.allCases) { target in
                Button("Resume in \(target.rawValue)") { model.sessions.choose(session.id); model.sessions.resume(target) }
            }
            Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }
            Button("Open Terminal Here") { model.sessions.choose(session.id); model.sessions.openTerminal() }
            Button("Reveal Transcript") { NSWorkspace.shared.activateFileViewerSelecting([session.path]) }
            Button("Copy Session ID") { copy(session.nativeID) }
            Button("Copy Working Directory") { copy(session.cwd) }
            Button("Copy Last Request") { copy(session.lastRequest) }
            Button(session.archived ? "Unarchive" : "Archive") {
                model.sessions.choose(session.id); archiveConfirmation = true
            }.disabled(!session.canArchive)
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    @ViewBuilder private var detail: some View {
        switch model.page.kind {
        case .repositories: repositoryPage(title: "All Repositories")
        case .repository: repositoryPage(root: model.page.key, title: (model.page.key as NSString).lastPathComponent)
        case .worktree: repositoryPage(path: model.page.key, title: "Worktree")
        case .conversation:
            if let session = model.sessions.sessions.first(where: { $0.id == model.page.key }) {
                SessionDetailView(store: model.sessions, session: session,
                                  showsRefresh: false, showsResumeTitle: false, showsConversationLabel: false)
            } else { ContentUnavailableView("Conversation unavailable", systemImage: "text.bubble") }
        case .diff:
            if let source = model.difference { DiffSheet(source: source, done: model.back, embedded: true) }
        case .live: sessionPage("Live", rows: model.live)
        case .recent: sessionPage("Recent", rows: model.recent)
        case .history:
            VStack {
                HStack {
                    Toggle("Include archived", isOn: $model.showArchived)
                    Toggle("Pinned only", isOn: $model.onlyPinned)
                    Spacer()
                }.padding()
                let candidates = model.page.key.isEmpty ? model.sessions.sessions : model.sessionsFor(model.page.key)
                let rows = candidates.filter {
                    (model.showArchived || !$0.archived) && (!model.onlyPinned || model.sessions.isPinned($0.id))
                }
                sessionPage("All Sessions", rows: rows)
            }
        case .dashboard: DashboardView(store: model.sessions, showsUnreadCounts: false)
        }
    }

    private func repositoryPage(root: String? = nil, path: String? = nil, title: String) -> some View {
        WorktreeManagerView(model: model.worktrees, repositoryRoot: root, worktreePath: path, title: title, showsRefresh: false,
            openOverview: { model.navigate(.init(kind: .worktree, key: $0.path)) },
            showDiff: model.showDiff, sessionContent: { AnyView(worktreeSessions($0)) },
            createSheet: { request, done in AnyView(WorkspaceCreateSheet(request: request, model: model.worktrees, done: done)) })
            .background(PageScrollMemory(model: model, key: model.page.id))
    }

    private func worktreeSessions(_ record: WorktreeRecord) -> some View {
        let rows = model.sessionsFor(record.path)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Live sessions").font(.title2.bold())
            ForEach(rows.filter(\.isLive)) { session in sessionRow(session) }
            if !rows.contains(where: \.isLive) { Text("No live sessions").foregroundStyle(.secondary) }
            Text("Recent conversations").font(.title2.bold())
            ForEach(Array(rows.filter { !$0.isLive && !$0.archived }.prefix(10))) { session in sessionRow(session) }
            Button("All conversations for this worktree") { model.navigate(.init(kind: .history, key: record.path)) }
        }
    }

    private func sessionPage(_ title: String, rows: [CodexSession]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(title).font(.largeTitle.bold())
                if let health = model.sessions.providerSummary { Text(health).foregroundStyle(.orange) }
                if rows.isEmpty { ContentUnavailableView("No sessions", systemImage: "text.bubble") }
                ForEach(rows) { session in sessionRow(session); Divider() }
            }.padding(20)
        }.background(PageScrollMemory(model: model, key: model.page.id))
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Search results").font(.largeTitle.bold())
                ForEach(model.groups) { group in
                    let repositoryMatches = model.matches([group.name, group.root])
                    let records = group.records.filter { repositoryMatches || model.matches([$0.name, $0.branch, $0.path]) }
                    let branches = group.branches.filter { repositoryMatches || model.matches([$0.name]) }
                    if repositoryMatches || !records.isEmpty || !branches.isEmpty {
                        nav(group.name, "folder", .init(kind: .repository, key: group.root)).font(.headline)
                        ForEach(records) { record in nav(record.name + " · " + record.branch, "folder", .init(kind: .worktree, key: record.path)) }
                        ForEach(branches) { branch in
                            Button("Branch: \(branch.name)") {
                                model.search = ""; model.navigate(.init(kind: .repository, key: group.root))
                                model.worktrees.search = branch.name; model.worktrees.selection = [branch.id]
                            }
                        }
                    }
                }
                Text("Sessions").font(.title2.bold())
                ForEach(model.sessions.sessions.filter(model.matches)) { session in sessionRow(session) }
            }.padding(20)
        }
    }
}

private extension View {
    func workspaceSidebarSelection(_ page: WorkspacePage, current: WorkspacePage) -> some View {
        let selected = page == current
        // Keep the current page visible when focus moves to search, the detail pane, or another app.
        return self
            .background(SidebarSelection(isSelected: selected).frame(width: 0, height: 0))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? AppTheme.accent.opacity(0.2) : .clear)
                    .background(selected ? AppTheme.background : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 10)
            )
    }
}

/// Remembers the native list/overview scroll position independently for each navigation page.
struct PageScrollMemory: NSViewRepresentable {
    let model: WorkspaceModel
    let key: String
    func makeNSView(context: Context) -> Anchor { Anchor(model: model, key: key) }
    func updateNSView(_ view: Anchor, context: Context) {}
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
    final class Anchor: NSView {
        let model: WorkspaceModel
        let key: String
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        init(model: WorkspaceModel, key: String) { self.model = model; self.key = key; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
        func attach() {
            guard let content = window?.contentView else { return }
            func find(_ view: NSView) -> [NSScrollView] {
                if let scroll = view as? NSScrollView { return [scroll] }
                return view.subviews.flatMap(find)
            }
            // SwiftUI backgrounds can share a native parent with the sidebar. Choose the
            // scroll view overlapping this page, never the first scroll view in the window.
            let frame = convert(bounds, to: content)
            func area(_ scroll: NSScrollView) -> CGFloat {
                let overlap = frame.intersection(scroll.convert(scroll.bounds, to: content))
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            guard let found = find(content).filter({ area($0) > 0 }).max(by: { area($0) < area($1) }) else { return }
            scroll = found
            if let origin = model.scrollPositions[key] { found.contentView.scroll(to: origin); found.reflectScrolledClipView(found.contentView) }
            found.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: found.contentView, queue: .main) { [weak self] _ in self?.save() }
        }
        func save() { if let scroll { model.scrollPositions[key] = scroll.contentView.bounds.origin } }
        func detach() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
    }
}
