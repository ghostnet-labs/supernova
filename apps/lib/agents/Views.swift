import AppKit
import SwiftUI

/// Builds the project workspace for apps that have one; Agent Control Center sets it, other apps leave it nil.
@MainActor var makeProjectWorkspace: (@MainActor (SessionStore, @escaping () -> Void) -> AnyView)?

struct RootView: View {
    @ObservedObject var store: SessionStore
    @State private var archiveConfirmation = false
    @State private var pinnedExpanded = false
    @State private var recentlyClosedExpanded = false
    @State private var projectsExpanded = false
    @State private var allSessionsExpanded = false
    @State private var showProjectWorkspace = false
    @State private var browserColumns: NavigationSplitViewVisibility = .all
    @State private var expandedProjects: Set<String> = []
    @State private var expandedSections: [String: Set<String>] = [:]
    @FocusState private var sessionSearchFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility:$browserColumns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 290, ideal: 350, max: 460)
                .background(SidebarSizing().frame(width: 0, height: 0))
        } detail: {
            if showProjectWorkspace, let makeProjectWorkspace {
                makeProjectWorkspace(store) { showProjectWorkspace = false }
            } else if store.showDashboard {
                DashboardView(store: store)
            } else if let session = store.selected {
                SessionDetailView(store: store, session: session)
            } else if store.isLoadingSessions {
                Color.clear
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "terminal",
                    description: Text("Choose a session or open the dashboard.")
                )
            }
        }
        // Keep the window and sidebar stable when auxiliary panels change.
        .frame(minWidth: 980, minHeight: 640)
        .background(AppTheme.background)
        .tint(AppTheme.accent)
        .onChange(of:showProjectWorkspace) { _,value in browserColumns = value ? .detailOnly:.all }
        .onChange(of:store.selection) { _,_ in showProjectWorkspace = false }
        .onOpenURL(perform: store.handleDeepLink)
        .alert("Move session?", isPresented: $archiveConfirmation) {
            Button(store.selected?.archived == true ? "Unarchive" : "Archive") {
                store.archiveSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.selected?.archived == true
                 ? "Move this rollout back into session history?"
                 : "Move this inactive rollout into Codex's archived session history?")
        }
        .alert("Agent Control Center", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        // Keep native window controls while session actions live in the details.
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: .codexFocusSessionSearch)) { _ in
            sessionSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexArchiveSession)) { _ in
            if store.selected?.canArchive == true { archiveConfirmation = true }
        }
    }

    private var sidebar: some View {
        let visibleSessions = store.filtered
        let isInitialLoad = store.isLoadingSessions && store.sessions.isEmpty
        let liveSessions = visibleSessions.filter(\.isLive)
        let pinnedSessions = visibleSessions.filter { store.isPinned($0.id) }
        // Session history is already sorted by latest activity; archived sessions stay separate.
        let recentlyClosedSessions = Array(visibleSessions.lazy.filter { !$0.isLive && !$0.archived }.prefix(10))
        let byProject = Dictionary(grouping: visibleSessions, by: { $0.project.id })
        let projects = ProjectSummary.group(visibleSessions.map(\.project))

        return VStack(spacing: 0) {
            Text("Agent Control Center")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            TextField("Search sessions", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .focused($sessionSearchFocused)
                .padding(10)

            if makeProjectWorkspace != nil {
                Button(showProjectWorkspace ? "Back to conversations" : "Project workspace") { showProjectWorkspace.toggle() }
                    .buttonStyle(.borderless).padding(.horizontal,12).padding(.bottom,8)
            }

            if let status = store.providerSummary {
                Text(status).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10)
            }

            List(selection: Binding(
                // A remembered session is not the active sidebar selection on the dashboard.
                get: { store.showDashboard ? nil : store.selection },
                set: { id in
                    guard let id else { return }
                    // List reconciles selection during refresh; don't reload the same transcript.
                    DispatchQueue.main.async {
                        guard store.showDashboard || store.selection != id else { return }
                        showProjectWorkspace = false
                        store.choose(id)
                    }
                }
            )) {
                sessionRows(liveSessions, level: 0)

                Group {
                    sidebarHeader("Pinned", count: pinnedSessions.count, icon: "pin", level: 0, expanded: $pinnedExpanded)
                    if pinnedExpanded {
                        sessionRows(pinnedSessions, level: 1)
                        if pinnedSessions.isEmpty && !isInitialLoad {
                            Text("No pinned sessions").foregroundStyle(.secondary)
                        }
                    }
                }

                Group {
                    sidebarHeader("Recently closed", count: recentlyClosedSessions.count, icon: "clock", level: 0, expanded: $recentlyClosedExpanded)
                        .help("The 10 most recently active sessions that are no longer live, excluding archived sessions")
                    if recentlyClosedExpanded {
                        sessionRows(recentlyClosedSessions, level: 1)
                        if recentlyClosedSessions.isEmpty && !isInitialLoad {
                            Text("No recently closed sessions").foregroundStyle(.secondary)
                        }
                    }
                }

                Group {
                    sidebarHeader("Projects", count: projects.count, octicon: "file-directory", level: 0, expanded: $projectsExpanded)
                    if projectsExpanded {
                        ForEach(projects) { project in
                            projectRow(project, sessions: byProject[project.id] ?? [])
                        }
                        if projects.isEmpty && !isInitialLoad {
                            Text("No matching sessions").foregroundStyle(.secondary)
                        }
                    }
                }

                Group {
                    sidebarHeader("All sessions", count: visibleSessions.count, icon: "tray.full", level: 0, expanded: $allSessionsExpanded)
                    if allSessionsExpanded {
                        sessionGroups(visibleSessions, scope: "all-sessions", level: 1)
                    }
                }

                Group {
                    Button {
                        store.showDashboard = true
                    } label: {
                        sidebarLabel("Mission Control", icon: "square.grid.2x2")
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                if store.isLoadingSessions || store.isLoadingTranscript {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.accent)
                        .accessibilityLabel("Loading")
                    Text(store.isLoadingSessions ? "Loading sessions…" : "Loading messages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 32)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("sidebar-loading-status")
        }
        .background(AppTheme.surface)
        .onChange(of: store.selection) { previousSelection, _ in
            // Initial automatic selection must not open the collapsed sidebar sections.
            guard previousSelection != nil else { return }
            if let selected = store.selected {
                let visibleInLive = selected.isLive
                let visibleInPinned = pinnedExpanded && store.isPinned(selected.id)
                let visibleInRecentlyClosed = recentlyClosedExpanded && recentlyClosedSessions.contains { $0.id == selected.id }
                let visibleInAll = allSessionsExpanded
                    && (expandedSections["all-sessions"] ?? []).contains(selected.section)
                if !visibleInLive && !visibleInPinned && !visibleInRecentlyClosed && !visibleInAll { revealSessions([selected]) }
            }
        }
        .onChange(of: store.query) {
            if !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { revealSessions(store.filtered) }
        }
    }

    @ViewBuilder
    private func projectRow(_ project: ProjectSummary, sessions: [CodexSession]) -> some View {
        let projectExpanded = Binding(
            get: { expandedProjects.contains(project.id) },
            set: { expanded in
                if expanded { expandedProjects.insert(project.id) }
                else { expandedProjects.remove(project.id) }
            }
        )
        sidebarHeader(
            project.name, count: project.count,
            icon: project.id == SessionProject.other.id ? "tray" : nil,
            octicon: project.id == SessionProject.other.id ? nil : "repo",
            level: 1, expanded: projectExpanded
        )
        .help(project.project.path.isEmpty ? "Sessions outside recognized project roots" : project.project.path)

        if projectExpanded.wrappedValue {
            sessionGroups(sessions, scope: project.id)
        }
    }

    @ViewBuilder
    private func sessionGroups(_ sessions: [CodexSession], scope: String, level: Int = 2) -> some View {
        let bySection = Dictionary(grouping: sessions, by: \.section)
        ForEach(["LIVE", "HISTORY", "ARCHIVED"], id: \.self) { section in
            if let rows = bySection[section], !rows.isEmpty {
                let sectionExpanded = Binding(
                    get: { (expandedSections[scope] ?? []).contains(section) },
                    set: { expanded in
                        var sections = expandedSections[scope] ?? []
                        if expanded { sections.insert(section) } else { sections.remove(section) }
                        expandedSections[scope] = sections
                    }
                )
                sidebarHeader(section, count: rows.count, level: level, expanded: sectionExpanded)
                if sectionExpanded.wrappedValue {
                    sessionRows(rows, level: level + 1)
                }
            }
        }
    }

    private func sessionRows(_ sessions: [CodexSession], level: Int) -> some View {
        ForEach(sessions) { session in
            let isSelected = !store.showDashboard && store.selection == session.id
            SessionRow(session: session, unread: store.unread[session.id] ?? 0, pinned: store.isPinned(session.id))
                .padding(.leading, CGFloat(level) * 16)
                .background(SidebarSelection(isSelected: isSelected).frame(width: 0, height: 0))
                .tag(session.id)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? AppTheme.accent.opacity(0.2) : .clear)
                        .padding(.horizontal, 10)
                )
                .contextMenu { contextMenu(for: session) }
        }
    }

    private func sidebarHeader(
        _ title: String, count: Int, icon: String? = nil, octicon: String? = nil, level: Int, expanded: Binding<Bool>
    ) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            sidebarLabel(title, icon: icon, octicon: octicon, count: count, level: level, expanded: expanded.wrappedValue)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .accessibilityLabel(title)
        .accessibilityIdentifier("sidebar-\(title)")
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    private func sidebarLabel(
        _ title: String, icon: String?, octicon: String? = nil, count: Int? = nil, level: Int = 0, expanded: Bool? = nil
    ) -> some View {
        HStack(spacing: 6) {
            // Reserve the same arrow gutter even for rows without a disclosure control.
            Image(systemName: expanded == true ? "chevron.down" : "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .opacity(expanded == nil ? 0 : 1)
                .accessibilityHidden(true)
            if let octicon { Octicons.swiftUIImage(octicon).foregroundStyle(.secondary).frame(width: 16) }
            else if let icon { Image(systemName: icon).frame(width: 16) }
            Text(title).font(icon == nil && octicon == nil ? .caption.bold() : .body)
            Spacer()
            if let count { Text("\(count)").foregroundStyle(.secondary) }
        }
        .padding(.leading, 10 + CGFloat(level) * 16)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, minHeight: 32)
        .contentShape(Rectangle())
    }

    private func revealSessions(_ sessions: [CodexSession]) {
        if !sessions.isEmpty { projectsExpanded = true }
        var projects = expandedProjects
        var groups = expandedSections
        for session in sessions {
            projects.insert(session.project.id)
            var sections = groups[session.project.id] ?? []
            sections.insert(session.section)
            groups[session.project.id] = sections
        }
        expandedProjects = projects
        expandedSections = groups
    }

    @ViewBuilder
    private func contextMenu(for session: CodexSession) -> some View {
        Button(store.isPinned(session.id) ? "Unpin" : "Pin") {
            store.togglePin(session.id)
        }
        Button("Resume in Ghostty") {
            store.choose(session.id)
            store.resume(.ghostty)
        }
        Button("Resume in tmux") {
            store.choose(session.id)
            store.resume(.tmux)
        }
        Button("Resume in Zellij") {
            store.choose(session.id)
            store.resume(.zellij)
        }
        if session.isLive {
            Button("Jump to Live Workspace") {
                store.choose(session.id)
                store.jumpToLiveWorkspace()
            }
        }
        Divider()
        Button("Open Folder") {
            store.choose(session.id)
            store.openFolder()
        }
        Button("Open Terminal Here") {
            store.choose(session.id)
            store.openTerminal()
        }
        Button("Reveal Rollout") {
            store.choose(session.id)
            store.revealRollout()
        }
        Divider()
        Button("Copy Session ID") {
            store.choose(session.id)
            store.copySessionID()
        }
        Button("Copy Working Directory") {
            store.choose(session.id)
            store.copyWorkingDirectory()
        }
        Button("Copy Last Request") {
            store.choose(session.id)
            store.copyLastRequest()
        }
        Divider()
        Button(session.archived ? "Unarchive" : "Archive") {
            store.choose(session.id)
            archiveConfirmation = true
        }
        .disabled(!session.canArchive)
    }
}

struct SessionRow: View {
    let session: CodexSession
    let unread: Int
    let pinned: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(2)
                        .help(session.title)
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.accent.opacity(0.12))
                            .foregroundStyle(AppTheme.accent)
                            .clipShape(Capsule())
                    }
                }

                Text((projectPath as NSString).abbreviatingWithTildeInPath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(projectPath)

                HStack {
                    Text(session.source.rawValue)
                    Text(session.lifecycle.rawValue)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(session.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var projectPath: String {
        session.project.path.isEmpty ? session.cwd : session.project.path
    }

    private var stateColor: Color {
        lifecycleColor(session.lifecycle)
    }
}

struct DashboardView: View {
    @ObservedObject var store: SessionStore
    var showsUnreadCounts = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text("Mission Control")
                            .font(.largeTitle.bold())
                        Text("\(store.liveSessions.count) live · \(store.attentionSessions.count) need attention")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { store.refresh(full: true) }
                }

                if store.liveSessions.isEmpty {
                    ContentUnavailableView(
                        "No Live Sessions",
                        systemImage: "moon.zzz",
                        description: Text("Active Codex and Claude Code sessions will appear here.")
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(store.liveSessions) { session in
                            DashboardCard(
                                session: session,
                                unread: showsUnreadCounts ? store.unread[session.id] ?? 0 : 0,
                                pinned: store.isPinned(session.id)
                            ) {
                                store.openSession(session.id)
                            }
                            .contextMenu {
                                Button("Open Session") { store.openSession(session.id) }
                                Button("Jump to Workspace") {
                                    store.openSession(session.id)
                                    store.jumpToLiveWorkspace()
                                }
                                Button("Resume in Ghostty") {
                                    store.openSession(session.id)
                                    store.resume(.ghostty)
                                }
                                Button(store.isPinned(session.id) ? "Unpin" : "Pin") {
                                    store.togglePin(session.id)
                                }
                            }
                        }
                    }
                }

                if !store.attentionSessions.isEmpty {
                    Divider()
                    Text("Needs Attention")
                        .font(.title2.bold())
                    ForEach(store.attentionSessions) { session in
                        Button {
                            store.openSession(session.id)
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(lifecycleColor(session.lifecycle))
                                VStack(alignment: .leading) {
                                    Text(session.title).font(.headline)
                                    Text(session.projectName).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(session.lifecycle.rawValue).font(.caption.bold())
                            }
                            .padding(12)
                            .background(AppTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
        .background(AppTheme.background)
    }
}

struct DashboardCard: View {
    let session: CodexSession
    let unread: Int
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(lifecycleColor(session.lifecycle)).frame(width: 9, height: 9)
                    Text(session.projectName).font(.headline)
                    if pinned { Image(systemName: "pin.fill").font(.caption) }
                    Spacer()
                    if unread > 0 {
                        Text("\(unread) new").font(.caption.bold()).foregroundStyle(AppTheme.accent)
                    }
                }

                Text(session.title)
                    .font(.title3.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !session.lastRequest.isEmpty {
                    Text(session.requestLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Text(session.source.rawValue)
                    Label(session.lifecycle.rawValue, systemImage: lifecycleSymbol(session.lifecycle))
                    if !session.model.isEmpty { Label(session.model, systemImage: "cpu") }
                    if !session.agents.isEmpty { Label("\(session.agents.count)", systemImage: "person.3") }
                }
                .font(.caption)

                ContextMeter(stats: session.stats)
            }
            .padding(16)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct SessionDetailView: View {
    @ObservedObject var store: SessionStore
    let session: CodexSession
    var showsRefresh = true
    var showsResumeTitle = true
    var showsConversationLabel = true

    var body: some View {
        GeometryReader { geometry in
            let hasPanel = store.showInspector
            let sideBySide = geometry.size.width >= 860
            let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                VStack(spacing: 0) {
                    SessionHeader(store: store, session: session, showsRefresh: showsRefresh, showsResumeTitle: showsResumeTitle)
                    Divider()
                    TranscriptView(store: store, session: session, showsConversationLabel: showsConversationLabel)
                        .id(session.id)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if hasPanel {
                    Divider()
                    VStack(spacing: 0) {
                        HStack {
                            Text("Inspector").font(.headline)
                            Spacer()
                            Button {
                                store.showInspector = false
                            } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .help("Close panel")
                        }
                        .padding(12)
                        Divider()
                        InspectorView(session: session, git: session.isLive ? store.gitStatuses[session.cwd] : nil)
                    }
                    .background(AppTheme.surface)
                    .frame(width: sideBySide ? 340 : nil,
                           height: sideBySide ? nil : max(220, geometry.size.height * 0.42))
                }
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct SessionHeader: View {
    @ObservedObject var store: SessionStore
    let session: CodexSession
    var showsRefresh = true
    var showsResumeTitle = true
    @State private var showAgents = false

    private var git: GitStatus? { session.isLive ? store.gitStatuses[session.cwd] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { store.showDashboard.toggle() } label: {
                    Label("Mission Control", systemImage: "square.grid.2x2")
                }
                .help("Toggle dashboard")
                if showsRefresh {
                    Button { store.refresh(full: true) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh sessions")
                }
                Button { store.toggleInspector() } label: {
                    Label("Inspector", systemImage: "info.circle")
                }
                .help("Session inspector")
                Menu {
                    Button("Ghostty") { store.resume(.ghostty) }
                    Button("tmux") { store.resume(.tmux) }
                    Button("Zellij") { store.resume(.zellij) }
                    if session.isLive {
                        Divider()
                        Button("Jump to Live Workspace") { store.jumpToLiveWorkspace() }
                    }
                } label: {
                    if showsResumeTitle { Label("Resume", systemImage: "play.fill").labelStyle(.titleAndIcon) }
                    else { Label("Resume", systemImage: "play.fill").labelStyle(.iconOnly) }
                }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Resume session")
                Button { store.togglePin(session.id) } label: {
                    Label(store.isPinned(session.id) ? "Unpin" : "Pin",
                          systemImage: store.isPinned(session.id) ? "pin.fill" : "pin")
                }
                .help(store.isPinned(session.id) ? "Unpin session" : "Pin session")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            SessionTitle(title: session.title, status: session.lifecycle.rawValue,
                         elapsed: session.isLive ? StatusPill.elapsed(since: session.lifecycleStartedAt) : "",
                         font: .system(size: 17, weight: .semibold))
                .textSelection(.enabled)
            SessionMetadata(repository: git?.repository ?? (session.project == .other ? session.cwd : session.project.path),
                            branch: git?.branch ?? session.branch, git: git,
                            model: session.model, source: session.source.rawValue, effort: session.reasoning,
                            totalTokens: session.stats.totalTokens, contextUsed: session.stats.contextUsed,
                            contextWindow: session.stats.contextWindow, contextEstimated: session.stats.contextWindowIsEstimated)
            if !session.agents.isEmpty {
                // Expand subagent details and history without leaving the conversation.
                SubagentToggle(count: session.agents.count, running: session.agents.filter(\.active).count,
                               expanded: showAgents) { showAgents.toggle() }
            }
            if showAgents && !session.agents.isEmpty {
                ScrollView {
                    SessionAgents(agents: session.agents, source: session.source)
                }
                .frame(height: min(160, CGFloat(session.agents.count) * 37))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.surface)
        .onChange(of: session.id) { _, _ in showAgents = false }
    }
}

struct SessionAgents: View {
    let agents: [AgentNode]
    let source: SessionSource

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 3) {
            ForEach(agents) { agent in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.nickname).font(.caption.weight(.semibold)).lineLimit(1)
                        if !agent.pathLabel.isEmpty {
                            Text(URL(fileURLWithPath: agent.pathLabel).lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(agent.pathLabel)
                        }
                    }
                    Spacer(minLength: 4)
                    if !agent.model.isEmpty {
                        Label { Text(agent.model).lineLimit(1).truncationMode(.middle) } icon: {
                            ModelLogo(model: agent.model, source: source.rawValue)
                        }
                        .font(.caption).foregroundStyle(.secondary).help(agent.model)
                    }
                    StatusPill(status: agent.status ?? (agent.active ? "Active" : "Idle"),
                               elapsed: agent.active ? StatusPill.elapsed(since: agent.startedAt) : "", compact: true)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .padding(.leading, CGFloat(min(5, max(0, agent.depth - 1))) * 12)
            }
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1) }
        .padding(.leading, 4)
    }
}

struct TranscriptView: View {
    private enum ScrollTarget { case bottom }
    @ObservedObject var store: SessionStore
    let session: CodexSession
    var showsConversationLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var matchIndex = 0
    @State private var followsLatest = true
    @AppStorage("CodexSessions.verboseTranscript") private var verbose = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if showsConversationLabel {
                    Text("Conversation").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Transcript view", selection: $verbose) {
                    Text("Normal").tag(false)
                    Text("Verbose").tag(true)
                }
                .pickerStyle(.menu).fixedSize().labelsHidden()
                .help("Normal groups tool activity. Verbose shows each event.")
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
            if !store.transcriptQuery.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Find in transcript", text: $store.transcriptQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    Spacer()
                    Text(matchStatus).font(.caption).foregroundStyle(.secondary)
                    Button { moveMatch(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain)
                        .disabled(store.transcriptMatches.isEmpty)
                    Button { moveMatch(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain)
                        .disabled(store.transcriptMatches.isEmpty)
                    Button { store.clearTranscriptSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(AppTheme.surface)
                Divider()
            }

            if store.messages.isEmpty && store.activity.isEmpty && store.isLoadingTranscript && !isWorking {
                Color.clear
            } else if store.messages.isEmpty && store.activity.isEmpty && !isWorking {
                ContentUnavailableView(
                    "No Messages Yet",
                    systemImage: "text.bubble",
                    description: Text("This rollout has no user-visible messages yet.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            MessageThread(messages: store.messages, searchQuery: store.transcriptQuery,
                                          activity: store.activity, path: session.path, isLive: session.isLive, verbose: verbose)
                            if isWorking { workingIndicator }
                            // Target the full thread, including lazy layout and bottom padding.
                            Color.clear.frame(height: 1).id(ScrollTarget.bottom)
                        }
                        // Every conversation opens at its latest message and stays there through
                        // incremental loading and lazy layout until the reader scrolls away.
                        .background(TranscriptScrollObserver(
                            followsLatest: followsLatest && store.transcriptQuery.isEmpty,
                            onUserScroll: { nearBottom in followsLatest = nearBottom },
                            scrollToBottom: { proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom) }
                        ).frame(width: 0, height: 0))
                    }
                    .defaultScrollAnchor(.bottom)
                    .background(AppTheme.background)
                    .overlay(alignment: .bottom) {
                        if !followsLatest && store.transcriptQuery.isEmpty {
                            Button {
                                followsLatest = true
                            } label: { Label("Latest", systemImage: "arrow.down") }
                            .buttonStyle(.bordered).controlSize(.small)
                            .background(AppTheme.background, in: Capsule())
                            .padding(12)
                        }
                    }
                    .onChange(of: matchIndex) {
                        let matches = store.transcriptMatches
                        guard !matches.isEmpty else { return }
                        proxy.scrollTo(matches[boundedMatchIndex(matches.count)].id, anchor: .center)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexFocusTranscriptSearch)) { _ in
            if store.transcriptQuery.isEmpty { store.transcriptQuery = " " }
            searchFocused = true
        }
    }

    private var isWorking: Bool { session.isLive && session.lifecycle == .busy }

    private var workingIndicator: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                Image(systemName: "ellipsis")
            } else {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                    .frame(width: 14, height: 14)
            }
            Text("Working")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private var matchStatus: String {
        let count = store.transcriptMatches.count
        return count == 0 ? "No matches" : "\(boundedMatchIndex(count) + 1) of \(count)"
    }

    private func boundedMatchIndex(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (matchIndex % count + count) % count
    }

    private func moveMatch(_ delta: Int) {
        matchIndex += delta
    }
}

struct MessageThread: View {
    let messages: [TranscriptMessage]
    let searchQuery: String
    var activity: [TimelineEvent] = []
    var path: URL?
    var isLive = false
    var verbose = false

    var body: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = ConversationBlock.group(ConversationItem.merge(messages: messages, activity: activity), verbose: verbose)
        let activeTurns = Set(TimelineTurn.group(activity).filter(\.isOpen).map(\.id))
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let previous = index > 0 ? items[index - 1] : nil
                switch item {
                case .message(let message):
                    let showsTimestamp = previous.map { separates($0.timestamp, message.timestamp) } ?? true
                    let startsGroup = showsTimestamp || previous?.message?.role != message.role || previous?.message?.phase != message.phase
                    MessageCard(message: message,
                                isSearchMatch: !query.isEmpty && message.text.localizedCaseInsensitiveContains(query),
                                showsTimestamp: showsTimestamp, startsGroup: startsGroup)
                        .padding(.top, showsTimestamp ? 0 : (startsGroup ? 24 : 12))
                        .id(message.id)
                case .activity(let events):
                    if let path {
                        ActivityGroupView(events: events, path: path, activeTurns: isLive ? activeTurns : [], verbose: verbose)
                            .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func separates(_ earlier: Date, _ later: Date) -> Bool {
        later.timeIntervalSince(earlier) >= 300 || !Calendar.current.isDate(earlier, inSameDayAs: later)
    }
}

struct MessageCard: View {
    let message: TranscriptMessage
    let isSearchMatch: Bool
    var showsTimestamp = true
    var startsGroup = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTimestamp {
                Text(message.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            if isUser {
                Text(verbatim: message.text)
                    .font(.system(size: 15)).lineSpacing(4)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(AppTheme.messageFill(isUser: true, scheme: colorScheme), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 52)
            } else {
                if startsGroup {
                    HStack(spacing: 5) {
                        Image(systemName: isFinal ? "checkmark.circle.fill" : "sparkle")
                        Text(isFinal ? "Final response" : "Update")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isFinal ? AppTheme.success : Color.secondary)
                }
                MarkdownMessage(message.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isFinal { CopyTextButton(text: message.text, label: "Copy response").padding(.top, 4) }
            }
        }
        .padding(4)
        .background(isSearchMatch ? AppTheme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSearchMatch ? AppTheme.accent : .clear, lineWidth: 1))
        .help(message.timestamp.formatted(date: .abbreviated, time: .shortened))
        .contextMenu { CopyTextButton(text: message.text, label: "Copy message") }
    }

    private var isUser: Bool { message.role == "user" }
    private var isFinal: Bool { !isUser && (message.phase == "final" || message.phase == "final_answer") }
}

struct ContextMeter: View {
    let stats: SessionStats
    var font: Font = .caption

    var body: some View {
        if let used = stats.contextUsed, let window = stats.contextWindow, window > 0 {
            ContextBar(used: used, window: window, estimated: stats.contextWindowIsEstimated)
                .frame(maxWidth: .infinity)
                .font(font)
                .foregroundStyle(.secondary)
        } else if let total = stats.totalTokens {
            Label("\(compactNumber(total)) tokens", systemImage: "text.word.spacing")
                .font(font)
                .foregroundStyle(.secondary)
        }
    }
}

struct InspectorView: View {
    let session: CodexSession
    var git: GitStatus?

    var body: some View {
        List {
            Section("Session") {
                DetailRow("Source", session.source.rawValue)
                DetailRow("ID", session.nativeID)
                InspectorField("State") {
                    StatusPill(status: session.lifecycle.rawValue,
                               elapsed: session.isLive ? StatusPill.elapsed(since: session.lifecycleStartedAt) : "")
                }
                DetailRow("Started", session.startedAt.formatted())
                DetailRow("Updated", session.updatedAt.formatted())
                InspectorField("Model") {
                    Label { Text(session.model.isEmpty ? "—" : session.model).textSelection(.enabled) } icon: {
                        ModelLogo(model: session.model, source: session.source.rawValue)
                    }
                }
                DetailRow("Reasoning", session.reasoning)
                DetailRow("CLI", session.cliVersion)
            }
            Section("Git") {
                InspectorField("Branch") {
                    BranchRef(name: git?.branch ?? session.branch, font: .callout.monospaced())
                        .textSelection(.enabled)
                }
                if let git {
                    InspectorField("Live changes") {
                        if git.summary == "Clean" { Text("Clean").foregroundStyle(.secondary) }
                        else { GitCounts(git: git) }
                    }
                }
                DetailRow("Recorded commit", session.commit)
                DetailRow("Remote", session.remote)
            }
            Section("Activity") {
                DetailRow("Messages", "\(session.stats.userTurns) user / \(session.stats.assistantMessages) assistant")
                DetailRow("Tasks", "\(session.stats.taskCompletes)/\(session.stats.taskStarts) complete")
                DetailRow("Aborted", "\(session.stats.abortedTurns)")
                DetailRow("Tool calls", "\(session.stats.toolCalls)")
                DetailRow("Reasoning", "\(session.stats.reasoningItems)")
                DetailRow("Subagents", "\(session.agents.count)")
            }
            Section("Tokens") {
                DetailRow("Total", numberText(session.stats.totalTokens))
                DetailRow("Cached", numberText(session.stats.cachedTokens))
                DetailRow("Output", numberText(session.stats.outputTokens))
                DetailRow("Reasoning", numberText(session.stats.reasoningTokens))
                DetailRow("Context", contextText(session.stats))
            }
            Section("Files") {
                DetailRow("Directory", (session.cwd as NSString).abbreviatingWithTildeInPath).help(session.cwd)
                DetailRow("Rollout", (session.path.path as NSString).abbreviatingWithTildeInPath).help(session.path.path)
                DetailRow("Size", ByteCountFormatter.string(fromByteCount: Int64(session.stats.fileBytes), countStyle: .file))
                DetailRow("Records", "\(session.stats.records)")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(AppTheme.surface)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value.isEmpty ? "—" : value
    }

    var body: some View {
        InspectorField(label) { Text(value).textSelection(.enabled) }
    }
}

struct InspectorField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            content.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

func lifecycleSymbol(_ lifecycle: SessionLifecycle) -> String {
    switch lifecycle {
    case .busy: return "bolt.fill"
    case .waiting: return "bell.fill"
    case .interrupted: return "exclamationmark.triangle.fill"
    case .idle: return "pause.circle"
    case .closed: return "checkmark.circle"
    case .unknown: return "questionmark.circle"
    }
}

func lifecycleColor(_ lifecycle: SessionLifecycle) -> Color {
    switch lifecycle {
    case .busy: return AppTheme.accent
    case .waiting: return AppTheme.warning
    case .interrupted: return AppTheme.error
    case .idle, .closed, .unknown: return .secondary
    }
}

func timelineSymbol(_ kind: TimelineKind) -> String {
    switch kind {
    case .taskStarted: return "play.circle"
    case .taskCompleted: return "checkmark.circle"
    case .taskAborted: return "xmark.circle"
    case .user: return "person.circle"
    case .assistant: return "sparkles"
    case .tool: return "wrench.and.screwdriver"
    case .subagent: return "person.3"
    }
}

func timelineColor(_ kind: TimelineKind) -> Color {
    switch kind {
    case .taskStarted: return AppTheme.accent
    case .taskCompleted: return AppTheme.success
    case .taskAborted: return AppTheme.error
    case .user, .assistant, .tool, .subagent: return .secondary
    }
}

func compactNumber(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
}

func numberText(_ value: Int?) -> String {
    value.map(compactNumber) ?? "—"
}

func contextText(_ stats: SessionStats) -> String {
    guard let used = stats.contextUsed, let window = stats.contextWindow else { return "—" }
    return "\(stats.contextWindowIsEstimated ? "≈" : "")\(compactNumber(used)) / \(compactNumber(window))"
}

extension Notification.Name {
    static let codexFocusSessionSearch = Notification.Name("CodexSessions.focusSessionSearch")
    static let codexFocusTranscriptSearch = Notification.Name("CodexSessions.focusTranscriptSearch")
    static let codexArchiveSession = Notification.Name("CodexSessions.archiveSession")
}
