import AppKit
import Combine
import SwiftUI

struct WorkspacePage: Hashable, Codable, Identifiable {
    enum Kind: String, Codable { case repositories, repository, worktree, conversation, diff, live, recent, history, dashboard }
    var kind: Kind
    var key = ""
    var id: String { kind.rawValue + ":" + key }
    static let home = WorkspacePage(kind: .repositories)
}

@MainActor
final class WorkspaceModel: ObservableObject {
    let sessions: SessionStore
    let worktrees: WorktreeModel
    let defaults: UserDefaults
    @Published private(set) var page: WorkspacePage
    @Published private(set) var backStack: [WorkspacePage] = []
    @Published var search = ""
    @Published var showArchived = false
    @Published var onlyPinned = false
    @Published var expandedRepositories: Set<String>
    private var selections: [WorkspacePage: Set<String>] = [:]
    private var queries: [WorkspacePage: String] = [:]
    private var differences: [String: DiffSource] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var visible = false
    private var discovered = false
    private var sessionProjects: Set<String> = []
    private var linkedPaths: [String: String] = [:]
    private var lastScan = Date.distantPast
    var scrollPositions: [String: CGPoint] = [:]

    static var projectRoot: String {
        ProcessInfo.processInfo.environment["AGENT_WORKSPACE_ROOT"]
            ?? ProcessInfo.processInfo.environment["TW_PROJECT_ROOT"] ?? NSHomeDirectory() + "/dev"
    }

    init(sessions: SessionStore, worktrees supplied: WorktreeModel? = nil,
         defaults: UserDefaults = .standard, start: Bool = true, confirmAgents: (() async throws -> Void)? = nil) {
        let worktrees = supplied ?? WorktreeModel(autoRefresh: false)
        self.sessions = sessions; self.worktrees = worktrees; self.defaults = defaults
        page = defaults.data(forKey: "Workspace.page").flatMap { try? JSONDecoder().decode(WorkspacePage.self, from: $0) } ?? .home
        expandedRepositories = Set(defaults.stringArray(forKey: "Workspace.expandedRepositories") ?? [])
        sessions.acceptedSchemes = ["agent-workspace"]
        sessions.onChooseSession = { [weak self] id in self?.navigate(WorkspacePage(kind: .conversation, key: id)) }
        worktrees.pullRefreshInterval = 60
        worktrees.scan = { [weak self] in
            guard let self else { return ([], [:]) }
            return await WorktreeScanner.scan(projectRoot: Self.projectRoot,
                additionalPaths: Array(self.sessionProjects), sessions: self.agentSessions, running: [])
        }
        worktrees.onScan = { [weak self] in
            guard let self else { return }
            self.discovered = true; self.lastScan = Date()
            self.updateAssociations(); self.validateRestoredPage()
        }
        worktrees.validateWorktrees = { [weak self] records, removing in
            guard let self else { throw WorktreeError("Agent Workspace is unavailable") }
            if records.isEmpty { return [] }
            if let confirmAgents { try await confirmAgents() }
            else { try await self.sessions.confirmFreshAgents() }
            let snapshot = await WorktreeScanner.scan(additionalPaths: records.map(\.repositoryRoot), sessions: self.agentSessions, includeRoot: false)
            guard self.agentsKnown else { throw WorktreeError("Live agent locations could not be verified. Refresh and try again.") }
            let livePaths = Array(self.agentPaths.keys)
            // A confirmation is tied to the same checkout, branch and HEAD the user reviewed.
            return try records.map { old in
                guard let fresh = snapshot.records.first(where: { $0.path == old.path }),
                      fresh.head == old.head, fresh.branch == old.branch,
                      !livePaths.contains(where: { $0 == old.path || $0.hasPrefix(old.path + "/") }),
                      removing ? fresh.safeToRemove : fresh.canRebase else {
                    throw WorktreeError("\(old.name) changed or is protected. Refresh and confirm again.")
                }
                return fresh
            }
        }
        worktrees.continueWork = { [weak self] record in
            guard let self else { return }
            if let session = self.sessionsFor(record.path).first(where: \.isLive) { self.sessions.jump(session) }
            else { WorktreeActions.continueWork(record) }
        }
        sessions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        worktrees.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        sessions.$sessions.combineLatest(sessions.$subagents, sessions.$providerHealth)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                let paths = Set(self.sessions.sessions.map(\.project.path).filter { !$0.isEmpty })
                let changed = paths != self.sessionProjects
                self.sessionProjects = paths
                self.updateAssociations()
                if start && changed { self.worktrees.refresh() }
                self.validateRestoredPage()
            }.store(in: &subscriptions)
        sessions.$showDashboard.dropFirst().removeDuplicates().sink { [weak self] show in
            if show { self?.navigate(WorkspacePage(kind: .dashboard)) }
            else if self?.page.kind == .dashboard { self?.back() }
        }.store(in: &subscriptions)
        if start {
            worktrees.refresh()
            Timer.publish(every: 10, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                guard let self, self.worktrees.busy.isEmpty else { return }
                if self.visible || Date().timeIntervalSince(self.lastScan) >= 60 { self.worktrees.refresh() }
            }.store(in: &subscriptions)
        }
    }

    var agentPaths: [String: [String]] {
        Dictionary(grouping: (sessions.sessions + sessions.subagents).filter { $0.isLive && $0.cwd.hasPrefix("/") }, by: { WorktreeScanner.canonical($0.cwd) })
            .mapValues { $0.map(\.id) }
    }
    /// Reuse the provider streams for worktree rows instead of starting another pair of session commands.
    var agentSessions: [AgentSession] {
        var live = (sessions.sessions + sessions.subagents).filter { $0.isLive && $0.cwd.hasPrefix("/") }.compactMap { session -> AgentSession? in
            guard var agent = AgentSession(row: ["session_id": session.nativeID, "cwd": WorktreeScanner.canonical(session.cwd)],
                                           kind: session.source == .claude ? .claude : .codex) else { return nil }
            agent.title = session.title.oneLine(limit: 180)
            agent.status = session.lifecycle.rawValue
            agent.statusSince = session.lifecycleStartedAt
            agent.lastRequest = session.requestLine
            agent.model = session.model; agent.effort = session.reasoning
            agent.totalTokens = session.stats.totalTokens
            agent.contextUsed = session.stats.contextUsed; agent.contextWindow = session.stats.contextWindow
            agent.contextEstimated = session.stats.contextWindowIsEstimated
            agent.pid = session.live.flatMap { Int32(exactly: $0.pid) }
            agent.rootID = session.source == .claude && session.rootID.hasPrefix("claude:") ? String(session.rootID.dropFirst(7)) : session.rootID
            agent.isSubagent = session.isSubagent
            agent.label = session.agentLabel
            return agent
        }
        // An orphan or a child in another worktree must still protect its own checkout.
        let roots = Dictionary(live.filter { !$0.isSubagent }.map { ($0.id, $0.cwd) }, uniquingKeysWith: { first, _ in first })
        for index in live.indices where live[index].isSubagent {
            let agent = live[index]
            if roots["\(agent.kind.name)-\(agent.rootID)"] != agent.cwd { live[index].isSubagent = false }
        }
        return AgentSessions.attachingSubagents(live)
    }
    var agentsKnown: Bool {
        [SessionSource.codex, .claude].allSatisfy { sessions.providerHealth[$0] == .ok }
            && (sessions.sessions + sessions.subagents).allSatisfy { !$0.isLive || $0.cwd.hasPrefix("/") }
    }

    func updateAssociations() {
        let paths = worktrees.records.filter { !$0.missing }.map(\.path).sorted { $0.count > $1.count }
        linkedPaths = [:]
        var byDirectory: [String: String] = [:]
        // Large histories often share a handful of directories. Resolve each only once.
        for directory in Set(sessions.sessions.map(\.cwd)) {
            var isDirectory: ObjCBool = false
            guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let cwd = WorktreeScanner.canonical(directory)
            byDirectory[directory] = paths.first { cwd == $0 || cwd.hasPrefix($0 + "/") }
        }
        for session in sessions.sessions {
            linkedPaths[session.id] = byDirectory[session.cwd]
        }
        worktrees.updateAgents(agentSessions, known: agentsKnown)
        var statuses: [String: GitStatus] = [:]
        let records = Dictionary(uniqueKeysWithValues: worktrees.records.map { ($0.path, $0) })
        for session in sessions.sessions {
            if let path = linkedPaths[session.id], let record = records[path], !record.unreadable {
                var status = record.changes; status.branch = record.branch; status.repository = path
                statuses[session.cwd] = status
            }
        }
        sessions.useGitStatuses(statuses)
    }

    func worktreeFor(_ session: CodexSession) -> WorktreeRecord? {
        guard let path = linkedPaths[session.id] else { return nil }
        return worktrees.records.first { $0.path == path }
    }
    func sessionsFor(_ path: String) -> [CodexSession] { sessions.sessions.filter { linkedPaths[$0.id] == path } }
    var live: [CodexSession] { sessions.liveSessions }
    // The shared store already orders inactive history by activity and stable identity.
    var recent: [CodexSession] { Array(sessions.sessions.lazy.filter { !$0.isLive && !$0.archived }.prefix(20)) }
    var groups: [RepositoryGroup] {
        let pinned = Set((defaults.string(forKey: "pinnedRepositories") ?? "").split(separator: "\n").map(String.init))
        // The repository page's filter must not hide sidebar navigation.
        var groups: [RepositoryGroup] = []
        for record in worktrees.records {
            if groups.last?.root == record.repositoryRoot { groups[groups.count - 1].records.append(record) }
            else { groups.append(RepositoryGroup(root: record.repositoryRoot, name: record.repository, records: [record], branches: worktrees.branches[record.repositoryRoot] ?? [])) }
        }
        return RepositoryGroup.pinnedFirst(groups, pinned: pinned)
    }
    func matches(_ values: [String]) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
    func matches(_ session: CodexSession) -> Bool {
        matches([session.title, session.cwd, session.branch, session.projectName, session.lastRequest, session.id, session.source.rawValue])
    }

    func navigate(_ next: WorkspacePage) {
        guard next != page else { return }
        savePageState()
        backStack.append(page)
        show(next)
    }
    func back() {
        guard let previous = backStack.popLast() else { return }
        savePageState(); show(previous)
    }
    private func savePageState() { selections[page] = worktrees.selection; queries[page] = worktrees.search }
    private func show(_ next: WorkspacePage) {
        page = next
        worktrees.selection = selections[next] ?? []
        worktrees.search = queries[next] ?? ""
        defaults.set(try? JSONEncoder().encode(next), forKey: "Workspace.page")
        sessions.setBrowserVisible(visible && next.kind == .conversation)
        if next.kind == .conversation, sessions.selection != next.key { sessions.choose(next.key) }
        if next.kind != .dashboard { sessions.showDashboard = false }
    }
    func setVisible(_ value: Bool) {
        visible = value
        sessions.setBrowserVisible(value && page.kind == .conversation)
        if value { worktrees.refresh() }
    }
    func showDiff(_ source: DiffSource) {
        differences[source.id] = source
        navigate(WorkspacePage(kind: .diff, key: source.id))
    }
    var difference: DiffSource? { differences[page.key] }
    func toggleExpanded(_ root: String) {
        if expandedRepositories.remove(root) == nil { expandedRepositories.insert(root) }
        defaults.set(expandedRepositories.sorted(), forKey: "Workspace.expandedRepositories")
    }
    private func validateRestoredPage() {
        guard discovered, !sessions.isLoadingSessions else { return }
        let exists: Bool
        switch page.kind {
        case .repository: exists = worktrees.records.contains { $0.repositoryRoot == page.key }
        case .worktree: exists = worktrees.records.contains { $0.path == page.key }
        case .conversation: exists = sessions.sessions.contains { $0.id == page.key }
        case .diff: exists = differences[page.key] != nil
        default: exists = true
        }
        if !exists { show(.home) }
        else if page.kind == .conversation, sessions.selection != page.key { sessions.choose(page.key) }
    }
}
