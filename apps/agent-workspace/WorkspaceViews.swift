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
    @AppStorage("Workspace.recentExpanded") private var recentExpanded = true
    @AppStorage("pinnedRepositories") private var pinnedRepositories = ""
    @State private var expandedSubagents: Set<String> = []
    @State private var archiveConfirmation = false
    @State private var showingThemes = false
    @State private var showingSearch = false
    @State private var showingSessionDetails = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = clampedSidebarWidth(CGFloat(sidebarWidth), available: geometry.size.width)
            let draggedWidth = clampedSidebarWidth(width + sidebarResize, available: geometry.size.width)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !sidebarCollapsed {
                        AppTheme.sidebar.frame(width: draggedWidth)
                        Rectangle().fill(AppTheme.separator.opacity(0.5)).frame(width: 1)
                    }
                    AppTheme.background
                }
                .frame(height: 32)
                .background(WorkspaceTitlebar(width: geometry.size.width - 78, content: AnyView(
                    HStack(spacing: 0) {
                        if !sidebarCollapsed {
                            navigationControls.padding(.trailing, 12)
                                .frame(width: draggedWidth - 78, alignment: .leading)
                        }
                        navigationBar
                    }
                    .foregroundStyle(AppTheme.foreground).tint(AppTheme.accent)
                    .font(AppFont.body).fontDesign(AppFont.shared.design)
                )))
                HStack(spacing: 0) {
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
                        if let status = model.sessions.providerSummary {
                            Text(status).font(AppFont.caption).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                        }
                        if !model.search.isEmpty { searchResults }
                        else { detail.id(model.page.id) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
            .coordinateSpace(name: "workspace")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: sidebarCollapsed)
        }
        .frame(minWidth: 1040, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.foreground)
        .tint(AppTheme.accent)
        .font(AppFont.body)
        .fontDesign(AppFont.shared.design)
        .preferredColorScheme(AppTheme.shared.palette?.scheme)
        .ignoresSafeArea(.container, edges: .top)
        .alert("Move session?", isPresented: $archiveConfirmation) {
            Button(model.sessions.selected?.archived == true ? "Unarchive" : "Archive") { model.sessions.archiveSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Move this inactive Codex conversation between history and the archive?") }
        .alert("Agent Workspace", isPresented: Binding(get: { model.sessions.errorMessage != nil }, set: { if !$0 { model.sessions.errorMessage = nil } })) {
            Button("OK") { model.sessions.errorMessage = nil }
        } message: { Text(model.sessions.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .codexFocusSessionSearch)) { _ in
            focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexArchiveSession)) { _ in
            if model.sessions.selected?.canArchive == true { archiveConfirmation = true }
        }
    }

    private var expandedSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(SidebarMode.allCases, id: \.self) { mode in
                    Button { sidebarMode = mode } label: {
                        Label(mode.rawValue, systemImage: mode.symbol)
                            .font(AppFont.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(sidebarMode == mode ? AppTheme.foreground.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(sidebarMode == mode ? AppTheme.foreground : AppTheme.foreground.opacity(0.55))
                    .accessibilityAddTraits(sidebarMode == mode ? .isSelected : [])
                    .accessibilityIdentifier("workspace.sidebar.mode.\(mode.rawValue.lowercased())")
                }
            }
            .padding(3).background(AppTheme.foreground.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12)
            if showingSearch || !model.search.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search workspace", text: $model.search).textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityIdentifier("workspace.search.field")
                    Button {
                        model.search = ""; showingSearch = false; searchFocused = false
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Close search").accessibilityLabel("Close search")
                }.padding(8).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            // Keep both lists mounted through tab switches and collapse/expand transitions.
            ZStack {
                sidebarList(.sessions) { sessionNavigation }
                sidebarList(.repositories) { repositoryNavigation }
            }
            if !sidebarCollapsed {
                appearanceButton(showTitle: true).padding(12)
            }
        }
        .background(AppTheme.sidebar)
    }

    private var sidebarToggle: some View {
        Button {
            searchFocused = false
            sidebarCollapsed.toggle()
            NSCursor.arrow.set()
        } label: {
            Label(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar", systemImage: "sidebar.left")
        }
        .labelStyle(.iconOnly).buttonStyle(WorkspaceToolbarButtonStyle())
        .help(sidebarCollapsed ? "Expand sidebar" : "Collapse sidebar")
        .accessibilityIdentifier("workspace.sidebar.toggle")
    }

    private func appearanceButton(showTitle: Bool) -> some View {
        Button { showingThemes.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "paintpalette")
                if showTitle {
                    Text("Appearance").font(AppFont.body)
                    Spacer()
                    Text(AppTheme.shared.palette?.name ?? "System").font(AppFont.caption).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(WorkspaceToolbarButtonStyle())
        .help("Appearance · \(AppTheme.shared.palette?.name ?? "System") · \(WorkspaceThemes.font.rawValue)")
        .accessibilityLabel("Choose theme and font")
        .accessibilityValue("\(AppTheme.shared.palette?.name ?? "System"), \(WorkspaceThemes.font.rawValue)")
        .accessibilityIdentifier("workspace.sidebar.themes")
        .popover(isPresented: $showingThemes, arrowEdge: showTitle ? .trailing : .bottom) { WorkspaceThemePicker() }
    }

    private func focusSearch() {
        sidebarCollapsed = false; showingSearch = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private var navigationControls: some View {
        HStack(spacing: 2) {
            sidebarToggle
            Button(action: focusSearch) { Image(systemName: "magnifyingglass") }
                .help("Search workspace (⌘K)").accessibilityLabel("Search workspace")
                .accessibilityIdentifier("workspace.navigation.search")
            Button { model.search = ""; model.back() } label: { Image(systemName: "arrow.left") }
                .disabled(model.backStack.isEmpty).keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)").accessibilityLabel("Back").accessibilityIdentifier("workspace.navigation.back")
            Button { model.search = ""; model.forward() } label: { Image(systemName: "arrow.right") }
                .disabled(model.forwardStack.isEmpty).keyboardShortcut("]", modifiers: .command)
                .help("Forward (⌘])").accessibilityLabel("Forward").accessibilityIdentifier("workspace.navigation.forward")
        }.buttonStyle(WorkspaceToolbarButtonStyle())
    }

    private func clampedSidebarWidth(_ proposed: CGFloat, available: CGFloat) -> CGFloat {
        // Reserve the repository pane's 660-point minimum and divider.
        min(max(240, proposed), min(380, max(240, available - 661)))
    }

    private func sidebarDivider(width: CGFloat, available: CGFloat) -> some View {
        Rectangle().fill(AppTheme.separator.opacity(0.5)).frame(width: sidebarCollapsed ? 0 : 1)
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
            .environment(\.defaultMinListRowHeight, 32)
            .scrollContentBackground(.hidden)
            .opacity(sidebarMode == mode ? 1 : 0)
            .disabled(sidebarMode != mode)
            .allowsHitTesting(sidebarMode == mode)
            .accessibilityHidden(sidebarMode != mode)
    }

    private var sessionNavigation: some View {
        Group {
            nav("All Sessions", "text.bubble", .init(kind: .history))
                .workspaceSidebarSelection(.init(kind: .history), current: model.page)
            nav("Mission Control", "square.grid.2x2", .init(kind: .dashboard))
                .workspaceSidebarSelection(.init(kind: .dashboard), current: model.page)
            Section {
                ForEach(model.live.filter(model.matches)) { session in
                    sessionRow(session, compact: true)
                    .workspaceSidebarSelection(.init(kind: .conversation, key: session.id), current: model.page)
                }
            }
            DisclosureGroup(isExpanded: $recentExpanded) {
                ForEach(model.recent.filter(model.matches)) { session in
                    sessionRow(session, compact: true)
                        .workspaceSidebarSelection(.init(kind: .conversation, key: session.id), current: model.page)
                }
            } label: {
                Button { recentExpanded.toggle() } label: {
                    Label("Recent", systemImage: "clock")
                        .font(AppFont.body).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.sidebar.recent")
                    // DisclosureGroup already toggles on an accessibility press;
                    // the label button must not toggle it a second time.
                    .accessibilityAction { }
            }
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
        HStack(spacing: 8) {
            if sidebarCollapsed { navigationControls }
            if model.page.kind == .conversation, let session = model.sessions.selected {
                Menu {
                    Toggle("Session details", isOn: $showingSessionDetails)
                    Button("Inspector") { model.sessions.toggleInspector() }
                    Button(model.sessions.isPinned(session.id) ? "Unpin conversation" : "Pin conversation") { model.sessions.togglePin(session.id) }
                    Button(session.isRemote ? "Open SSH Terminal" : "Show Terminal") { model.sessions.jump(session) }
                    Button("Copy Session ID") { copy(session.nativeID) }
                } label: {
                    HStack(spacing: 8) {
                        Text(pageTitle).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(AppFont.caption)
                    }.font(AppFont.system(size: 15, weight: .medium))
                }
                .menuStyle(.button).menuIndicator(.hidden)
                .buttonStyle(WorkspaceToolbarButtonStyle())
                .foregroundStyle(AppTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .help("Conversation actions").accessibilityIdentifier("workspace.conversation.menu")
            } else {
                Text(pageTitle).font(AppFont.system(size: 15, weight: .medium)).lineLimit(1)
            }
            Spacer(minLength: 8).background(WorkspaceWindowDragArea())
            if model.page.kind == .conversation, let session = model.sessions.selected, let record = model.worktreeFor(session) {
                Button { model.navigate(.init(kind: .worktree, key: record.path)) } label: { Image(systemName: "folder") }
                    .help("Open worktree: \(record.name)").accessibilityLabel("Open worktree: \(record.name)")
                Button { model.showDiff(.worktree(record)) } label: { Image(systemName: "plus.forwardslash.minus") }
                    .help("Changes").accessibilityLabel("Changes")
            }
            if model.page.kind == .conversation, let session = model.sessions.selected {
                Button { model.sessions.resume() } label: { Image(systemName: "play") }
                    .help("Resume session").accessibilityLabel("Resume session")
                    .disabled(session.isRemote && (session.isLive || session.stale))
                Button { model.sessions.toggleInspector() } label: { Image(systemName: "info.circle") }
                    .help("Inspector").accessibilityLabel("Inspector")
            }
            Button { model.sessions.refresh(full: true); model.worktrees.refreshAll() } label: {
                ZStack {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 16, height: 16)
            }
                .disabled(isLoading)
                .keyboardShortcut("r")
                .accessibilityLabel(isLoading ? "Refreshing" : "Refresh")
                .help("Refresh sessions, the open conversation, repositories, and pull requests")
            if sidebarCollapsed { appearanceButton(showTitle: false) }
        }
        .buttonStyle(WorkspaceToolbarButtonStyle())
        .padding(.leading, sidebarCollapsed ? 0 : 12).padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: 32)
    }

    private var pageTitle: String {
        if !model.search.isEmpty { return "Search results" }
        switch model.page.kind {
        case .conversation: return model.sessions.sessions.first { $0.id == model.page.key }?.title ?? "Conversation"
        case .repositories: return "All Repositories"
        case .repository: return (model.page.key as NSString).lastPathComponent
        case .worktree: return model.worktrees.records.first { $0.path == model.page.key }?.name ?? "Worktree"
        case .diff: return "Changes"
        case .live: return "Live Sessions"
        case .recent: return "Recent Sessions"
        case .history: return "All Sessions"
        case .dashboard: return "Mission Control"
        }
    }

    private func selectSidebar(_ page: WorkspacePage) {
        model.search = ""; model.navigate(page)
    }

    private func nav(_ title: String, _ symbol: String, _ page: WorkspacePage, pinned: Bool = false,
                     subtitle: String? = nil, changes: GitStatus? = nil, doubleClick: (() -> Void)? = nil) -> some View {
        Button {
            if page.kind == .repository { model.toggleExpanded(page.key) }
            selectSidebar(page)
            // Native click counts keep single-click navigation immediate.
            if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type), event.clickCount == 2 {
                doubleClick?()
            }
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(AppFont.body).lineLimit(1)
                        if let subtitle {
                            HStack(spacing: 6) {
                                Text(subtitle).lineLimit(1).truncationMode(.middle)
                                if let changes, !changes.isEmpty {
                                    GitCounts(git: changes).fixedSize().opacity(0.7)
                                }
                            }.font(AppFont.caption).foregroundStyle(.secondary)
                        }
                    }
                } icon: { Image(systemName: symbol) }
                Spacer(minLength: 0)
                if pinned { Image(systemName: "pin.fill").font(AppFont.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .tag(page)
            .help(title)
    }

    private func sessionRow(_ session: CodexSession, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.search = ""; model.sessions.openSession(session.id)
            } label: {
                Group {
                    if compact {
                        HStack(spacing: 8) {
                            Text(session.title).font(AppFont.system(size: 14)).lineLimit(1).truncationMode(.tail)
                                .help(session.title)
                            Spacer(minLength: 4)
                            if session.isLive || session.stale {
                                let started = session.lifecycleStartedAt.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
                                StatusPill(status: session.stale ? "STALE" : session.lifecycle.rawValue,
                                           elapsed: session.stale ? "" : StatusPill.elapsed(since: started), compact: true)
                            }
                        }.frame(minHeight: 24)
                    } else {
                        SessionRow(session: session, unread: 0, pinned: model.sessions.isPinned(session.id))
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("workspace.session.\(session.id)")
            if !compact {
                if !session.branch.isEmpty { BranchRef(name: session.branch).font(AppFont.caption) }
                if session.stale { Text("Stale").font(AppFont.caption).foregroundStyle(.orange) }
            }
            let children = compact ? [] : model.sessions.children(of: session)
            if !children.isEmpty {
                let title = "\(children.count) subagent\(children.count == 1 ? "" : "s")"
                let expanded = expandedSubagents.contains(session.id)
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        if expanded { expandedSubagents.remove(session.id) } else { expandedSubagents.insert(session.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(AppFont.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                            Text(title)
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    if expanded {
                        ForEach(children) { child in
                            Button { model.sessions.jump(child) } label: {
                                HStack { Text(child.agentLabel); Spacer(); Text(child.lifecycle.rawValue).font(AppFont.caption) }
                            }.buttonStyle(.plain).help("Jump to subagent terminal").padding(.leading, 16)
                        }
                    }
                }.font(AppFont.caption)
            }
        }
        .padding(4)
        .tag(WorkspacePage(kind: .conversation, key: session.id))
        .contextMenu {
            Button(model.sessions.isPinned(session.id) ? "Unpin" : "Pin") { model.sessions.togglePin(session.id) }
            Button(session.isRemote ? "Open SSH Terminal" : "Show Terminal") { model.sessions.jump(session) }
            if session.isRemote {
                Button("Resume over SSH") { model.sessions.choose(session.id); model.sessions.resume() }
                    .disabled(session.isLive || session.stale)
            } else {
                ForEach(ResumeTarget.allCases) { target in
                    Button("Resume in \(target.rawValue)") { model.sessions.choose(session.id); model.sessions.resume(target) }
                }
            }
            Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }.disabled(session.isRemote)
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
                                  showsRefresh: false, showsResumeTitle: false, showsConversationLabel: false,
                                  showsHeader: showingSessionDetails, extendsUnderTitlebar: false)
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
            Text("Live sessions").font(AppFont.title2.bold())
            ForEach(rows.filter(\.isLive)) { session in sessionRow(session) }
            if !rows.contains(where: \.isLive) { Text("No live sessions").foregroundStyle(.secondary) }
            Text("Recent conversations").font(AppFont.title2.bold())
            ForEach(Array(rows.filter { !$0.isLive && !$0.archived }.prefix(10))) { session in sessionRow(session) }
            Button("All conversations for this worktree") { model.navigate(.init(kind: .history, key: record.path)) }
        }
    }

    private func sessionPage(_ title: String, rows: [CodexSession]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(title).font(AppFont.largeTitle.bold())
                if let health = model.sessions.providerSummary { Text(health).foregroundStyle(.orange) }
                if rows.isEmpty { ContentUnavailableView("No sessions", systemImage: "text.bubble") }
                ForEach(rows) { session in sessionRow(session); Divider() }
            }.padding(20)
        }.background(PageScrollMemory(model: model, key: model.page.id))
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Search results").font(AppFont.largeTitle.bold())
                ForEach(model.groups) { group in
                    let repositoryMatches = model.matches([group.name, group.root])
                    let records = group.records.filter { repositoryMatches || model.matches([$0.name, $0.branch, $0.path]) }
                    let branches = group.branches.filter { repositoryMatches || model.matches([$0.name]) }
                    if repositoryMatches || !records.isEmpty || !branches.isEmpty {
                        nav(group.name, "folder", .init(kind: .repository, key: group.root)).font(AppFont.headline)
                        ForEach(records) { record in nav(record.name + " · " + record.branch, "folder", .init(kind: .worktree, key: record.path)) }
                        ForEach(branches) { branch in
                            Button("Branch: \(branch.name)") {
                                model.search = ""; model.navigate(.init(kind: .repository, key: group.root))
                                model.worktrees.search = branch.name; model.worktrees.selection = [branch.id]
                            }
                        }
                    }
                }
                Text("Sessions").font(AppFont.title2.bold())
                ForEach(model.sessions.sessions.filter(model.matches)) { session in sessionRow(session) }
            }.padding(20)
        }
    }
}

private extension View {
    func workspaceSidebarSelection(_ page: WorkspacePage, current: WorkspacePage) -> some View {
        modifier(WorkspaceSidebarRowStyle(selected: page == current))
    }
}

private struct WorkspaceSidebarRowStyle: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(SidebarSelection(isSelected: selected).frame(width: 0, height: 0))
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.foreground.opacity(selected ? 0.12 : hovering ? 0.055 : 0))
                    .padding(.horizontal, 8)
            )
            .onHover { hovering = $0 }
    }
}

private struct WorkspaceToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration) }
    private struct Content: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(AppFont.system(size: 14))
                .padding(6).frame(minWidth: 28, minHeight: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(AppTheme.foreground.opacity(enabled && (hovering || configuration.isPressed) ? 0.09 : 0),
                            in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.3)
                .onHover { hovering = $0 }
        }
    }
}

enum WorkspaceWindowChrome {
    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }
}

/// Put interactive header controls in the native title bar, above its drag region.
private struct WorkspaceTitlebar: NSViewRepresentable {
    let width: CGFloat
    let content: AnyView
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.update(content, width: width) }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }

    final class HostingView: NSHostingView<AnyView> {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    final class Anchor: NSView {
        let accessory = NSTitlebarAccessoryViewController()
        let hosting = HostingView(rootView: AnyView(EmptyView()))
        weak var owner: NSWindow?
        override init(frame: NSRect) {
            super.init(frame: frame)
            accessory.layoutAttribute = .left
            accessory.view = hosting
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        func update(_ content: AnyView, width: CGFloat) {
            hosting.rootView = content
            hosting.setFrameSize(NSSize(width: max(0, width), height: 32))
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== owner else { return }
            detach()
            if let window { owner = window; window.addTitlebarAccessoryViewController(accessory) }
        }
        func detach() {
            if let owner, let index = owner.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                owner.removeTitlebarAccessoryViewController(at: index)
            }
            owner = nil
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Only empty header space drags the window; controls and transcript selection keep their events.
private struct WorkspaceWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            else { window?.performDrag(with: event) }
        }
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
