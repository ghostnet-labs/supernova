import AppKit
import Foundation
import UserNotifications

extension Notification.Name {
    static let agentJumpStarted = Notification.Name("AgentControlCenter.agentJumpStarted")
}

enum ResumeTarget: String, CaseIterable, Identifiable {
    case ghostty = "Ghostty"
    case tmux = "tmux"
    case zellij = "Zellij"

    var id: String { rawValue }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var gitStatuses: [String: GitStatus] = [:]
    @Published private(set) var isLoadingSessions = true
    @Published private(set) var isLoadingTranscript = false
    @Published private(set) var messages: [TranscriptMessage] = []
    @Published private(set) var activity: [TimelineEvent] = []
    @Published private(set) var activityRevision = 0
    @Published private(set) var unread: [String: Int] = [:]
    @Published var selection: String?
    @Published var query = ""
    @Published var transcriptQuery = ""
    @Published var showDashboard = false
    @Published var showInspector = false
    @Published var errorMessage: String?

    @Published private(set) var subagents: [CodexSession] = []
    @Published private(set) var providerHealth: [SessionSource: ProviderHealth] = [:]
    @Published private(set) var providerErrors: [SessionSource: String] = [:]
    @Published private(set) var remoteHealth: [SessionEndpoint: ProviderHealth] = [:]
    @Published private(set) var remoteErrors: [SessionEndpoint: String] = [:]
    @Published private(set) var sshHosts: [String] = []
    @Published private(set) var transcriptError: String?
    let sshEnabled: Bool
    private let startsProviders: Bool
    @Published var expandedRoots: Set<String> = []
    var onOpenWindow: (() -> Void)?
    var onChooseSession: ((String) -> Void)?
    var acceptedSchemes = ["codex-sessions", "agent-control-center"]
    var onNotify: ((CodexSession, String) -> Void)?
    private var providers: [SessionEndpoint: ProviderClient] = [:]
    private var providerSessions: [SessionEndpoint: [CodexSession]] = [:]
    private var providerAgents: [SessionEndpoint: [CodexSession]] = [:]
    private var pendingSelection: String?
    private var archiveRequest: (id: String, archived: Bool, path: URL, requestID: String)?
    private var browserVisible = false
    private var gitRefreshPending = false
    private var lastGitRefresh = Date.distantPast
    private var stopped = false
    private var managesGit = true
    private var freshRequests: [String: (remaining: Set<SessionSource>, complete: (Result<Void, Error>) -> Void)] = [:]
    private var offsets: [String: UInt64] = [:]
    private var lastSizes: [String: Int] = [:]
    private var transcriptGeneration = 0
    private var transcriptReloadPending = false
    private var pendingTranscriptReset = false
    private var transcriptActivity = TimelineBuilder()
    private var pinned: Set<String>
    private let defaults: UserDefaults

    init(startProviders: Bool = true, defaults: UserDefaults = .standard,
         importPreferences: Bool = true, notificationsDefault: Bool = true, managesGit: Bool = true, enableSSH: Bool = false) {
        self.defaults = defaults
        self.sshEnabled = enableSSH
        self.startsProviders = startProviders
        self.managesGit = managesGit
        if importPreferences { Self.migratePreferences(defaults) }
        pinned = Set(defaults.stringArray(forKey: "CodexSessions.pinned") ?? [])
        if defaults.object(forKey: "CodexSessions.notifications") == nil {
            defaults.set(notificationsDefault, forKey: "CodexSessions.notifications")
        }
        guard startProviders else { return }
        NotificationManager.shared.onSession = { [weak self] id in
            Task { @MainActor in self?.openSession(id) }
        }
        for source in [SessionSource.codex, .claude] { startProvider(SessionEndpoint(source: source)) }
        if enableSSH { configureSSH(defaults.string(forKey: "Workspace.sshHosts") ?? "") }
    }

    private func startProvider(_ endpoint: SessionEndpoint) {
        let interval = max(2, Int(ProcessInfo.processInfo.environment[SessionSource.environmentPrefix + "_INTERVAL"] ?? "") ?? 5)
        let provider = ProviderClient(source: endpoint.source, interval: interval, host: endpoint.host)
        provider.onSnapshot = { [weak self, weak provider] snapshot, baseline in
            DispatchQueue.main.async {
                guard let self, let provider, self.providers[endpoint] === provider else { return }
                self.applyProvider(snapshot, baseline: baseline)
            }
        }
        provider.onFailure = { [weak self, weak provider] message in
            DispatchQueue.main.async {
                guard let self, let provider, self.providers[endpoint] === provider else { return }
                self.providerFailed(endpoint.source, message: message, host: endpoint.host)
            }
        }
        providers[endpoint] = provider
        provider.start()
    }

    func configureSSH(_ text: String) {
        guard sshEnabled, !stopped else { return }
        do {
            let hosts = try RemoteSessions.hosts(text)
            let removed = Set(sshHosts).subtracting(hosts)
            sshHosts = hosts
            defaults.set(hosts.joined(separator: "\n"), forKey: "Workspace.sshHosts")
            for endpoint in Array(providers.keys) where removed.contains(endpoint.host) {
                providers.removeValue(forKey: endpoint)?.stop()
            }
            for endpoint in Array(remoteHealth.keys) where removed.contains(endpoint.host) {
                remoteHealth.removeValue(forKey: endpoint); remoteErrors.removeValue(forKey: endpoint)
                providerSessions.removeValue(forKey: endpoint); providerAgents.removeValue(forKey: endpoint)
            }
            subagents = providerAgents.values.flatMap { $0 }
            let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            applyRefresh(providerSessions.values.flatMap { $0 }.sorted(by: CodexSession.orderedBefore), previous: previous, full: false)
            for host in hosts {
                for source in [SessionSource.codex, .claude] {
                    let endpoint = SessionEndpoint(source: source, host: host)
                    guard providers[endpoint] == nil else { continue }
                    remoteHealth[endpoint] = .loading
                    if startsProviders { startProvider(endpoint) }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    static func migratePreferences(_ defaults: UserDefaults, legacy supplied: [String: Any]? = nil) {
        guard !defaults.bool(forKey: "AgentControlCenter.importedCodexSessions") else { return }
        let legacy = supplied ?? defaults.persistentDomain(forName: "local.codex-sessions") ?? [:]
        for (key, value) in legacy where key.hasPrefix("CodexSessions.") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "AgentControlCenter.importedCodexSessions")
    }

    func stop() {
        stopped = true
        for request in freshRequests.values { request.complete(.failure(ProviderError("Agent monitoring stopped"))) }
        freshRequests.removeAll()
        providers.values.forEach { $0.stop() }
        providers.removeAll()
    }

    var providerSummary: String? {
        var messages = [SessionSource.codex, .claude].compactMap { source -> String? in
            switch providerHealth[source] {
            case .error: return "\(source.rawValue) is stale: \(providerErrors[source] ?? "refresh failed")"
            case .unavailable: return "\(source.rawValue) is unavailable"
            case .loading: return "Loading \(source.rawValue) history…"
            default: return nil
            }
        }
        for endpoint in remoteHealth.keys.sorted(by: { $0.label < $1.label }) {
            if remoteHealth[endpoint] == .error {
                messages.append("\(endpoint.label) disconnected: \(remoteErrors[endpoint] ?? "connection failed")")
            } else if remoteHealth[endpoint] == .unavailable, providerSessions[endpoint]?.isEmpty == false {
                messages.append("\(endpoint.label) history is unavailable; showing stale sessions")
            }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    func children(of root: CodexSession) -> [CodexSession] {
        subagents.filter { $0.source == root.source && $0.rootID == root.id }.sorted(by: CodexSession.orderedBefore)
    }

    var selected: CodexSession? {
        sessions.first { $0.id == selection }
    }

    func toggleInspector() {
        showInspector.toggle()
    }

    var filtered: [CodexSession] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.filter { session in
            guard !needle.isEmpty else { return true }
            return [
                session.title,
                session.cwd,
                session.projectName,
                session.branch,
                session.model,
                session.id,
                session.lastRequest,
                session.sourceLabel,
            ].joined(separator: "\n").lowercased().contains(needle)
        }
    }

    var liveSessions: [CodexSession] {
        sessions.filter(\.isLive)
    }

    var attentionSessions: [CodexSession] {
        sessions.filter { $0.lifecycle.isAttention }
    }

    func isPinned(_ id: String) -> Bool {
        pinned.contains(id)
    }

    func togglePin(_ id: String) {
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        defaults.set(Array(pinned).sorted(), forKey: "CodexSessions.pinned")
        objectWillChange.send()
    }

    func refresh(full: Bool = false) {
        if full { loadTranscript(reset: true) }
        providers.values.forEach { $0.refresh() }
    }

    /// Confirm that both streams collected a snapshot after this request, not a cached timer result.
    func confirmFreshAgents(timeout: TimeInterval = 15, requestRefresh: ((String) -> Void)? = nil) async throws {
        let id = UUID().uuidString
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            freshRequests[id] = (Set([.codex, .claude]), { continuation.resume(with: $0) })
            if let requestRefresh { requestRefresh(id) }
            else { providers.filter { $0.key.host.isEmpty }.values.forEach { $0.refresh(requestID: id) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.freshRequests.removeValue(forKey: id)?.complete(.failure(ProviderError("Timed out verifying live agents. No protected action was performed.")))
            }
        }
    }

    func useGitStatuses(_ statuses: [String: GitStatus]) {
        if gitStatuses != statuses { gitStatuses = statuses }
    }

    func providerFailed(_ source: SessionSource, message: String, host: String = "") {
        applyProvider(ProviderSnapshot(source: source, health: .error, error: message, sessions: [], subagents: [], host: host), baseline: true)
    }

    // Until its host answers, a saved remote conversation may still exist.
    // A connection failure is retried and cannot establish that history is gone.
    func isSessionDiscoveryPending(_ id: String) -> Bool {
        remoteHealth.contains { endpoint, health in
            id.hasPrefix("ssh:\(endpoint.host):\(endpoint.source.executable):")
                && (health == .loading || health == .error)
        }
    }

    func applyProvider(_ snapshot: ProviderSnapshot, baseline: Bool) {
        guard !stopped else { return }
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let endpoint = snapshot.endpoint
        let wasHealthy = (snapshot.host.isEmpty ? providerHealth[snapshot.source] : remoteHealth[endpoint]) == .ok
        if snapshot.host.isEmpty {
            providerHealth[snapshot.source] = snapshot.health
            providerErrors[snapshot.source] = snapshot.error
        } else {
            remoteHealth[endpoint] = snapshot.health
            remoteErrors[endpoint] = snapshot.error
        }
        if snapshot.health == .ok {
            if !baseline && wasHealthy {
                for session in snapshot.sessions {
                    if let old = previous[session.id], old.lifecycle != session.lifecycle {
                        notifyTransition(session, from: old.lifecycle, to: session.lifecycle)
                    }
                }
            }
            providerSessions[endpoint] = snapshot.sessions
            providerAgents[endpoint] = snapshot.subagents
        } else {
            // A failed or unavailable provider cannot turn its last good busy rows into completions.
            providerSessions[endpoint] = providerSessions[endpoint]?.map { var row = $0; row.stale = true; return row }
            providerAgents[endpoint] = providerAgents[endpoint]?.map { var row = $0; row.stale = true; return row }
        }
        subagents = providerAgents.values.flatMap { $0 }
        let discovered = providerSessions.values.flatMap { $0 }.sorted(by: CodexSession.orderedBefore)
        applyRefresh(discovered, previous: previous, full: false)
        isLoadingSessions = providerHealth.count < 2 || providerHealth.values.contains(.loading)
        refreshGit()
        for id in Array(freshRequests.keys) {
            guard snapshot.host.isEmpty, var request = freshRequests[id], request.remaining.contains(snapshot.source) else { continue }
            if snapshot.health == .error || snapshot.health == .unavailable {
                freshRequests.removeValue(forKey: id)
                request.complete(.failure(ProviderError("Cannot verify live agents: \(snapshot.source.rawValue) is \(snapshot.health.rawValue). Refresh and try again.")))
            } else if snapshot.health == .ok && snapshot.refreshIDs.contains(id) {
                request.remaining.remove(snapshot.source)
                if request.remaining.isEmpty {
                    freshRequests.removeValue(forKey: id)
                    request.complete(.success(()))
                } else { freshRequests[id] = request }
            }
        }
        if let request = archiveRequest, snapshot.host.isEmpty, snapshot.source == .codex,
           snapshot.health == .error || snapshot.refreshIDs.contains(request.requestID) {
            archiveRequest = nil
            guard snapshot.health == .ok, !baseline, let fresh = snapshot.sessions.first(where: { $0.id == request.id }),
                  fresh.canArchive, fresh.archived == request.archived, fresh.path == request.path else {
                errorMessage = "Archive cancelled: the session is active, changed, or could not be checked."
                return
            }
            do {
                _ = try CodexData.moveArchive(fresh, archive: !fresh.archived)
                refresh(full: true)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setBrowserVisible(_ visible: Bool) {
        guard browserVisible != visible else { return }
        browserVisible = visible
        if visible { loadTranscript(reset: true) }
        else {
            transcriptGeneration &+= 1
            offsets.removeAll()
            messages = []
            clearActivity()
        }
    }

    private func refreshGit() {
        guard managesGit, !gitRefreshPending else { return }
        gitRefreshPending = true
        let delay = max(0.2, 4 - Date().timeIntervalSince(lastGitRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            let directories = self.liveSessions.filter { !$0.isRemote }.map(\.cwd)
            DispatchQueue.global(qos: .utility).async {
                let git = GitStatus.snapshots(directories: directories)
                DispatchQueue.main.async {
                    if self.gitStatuses != git { self.gitStatuses = git }
                    self.lastGitRefresh = Date()
                    self.gitRefreshPending = false
                }
            }
        }
    }

    private func applyRefresh(
        _ discovered: [CodexSession],
        previous: [String: CodexSession],
        full: Bool
    ) {
        sessions = discovered

        let oldSelection = selection
        if let pendingSelection, discovered.contains(where: { $0.id == pendingSelection }) {
            selection = pendingSelection
            self.pendingSelection = nil
            showDashboard = false
            onChooseSession?(pendingSelection)
        } else if selection == nil {
            selection = discovered.first?.id
        }

        for session in discovered {
            let oldSize = lastSizes[session.id] ?? 0
            let newSize = session.stats.fileBytes
            let changed = newSize > oldSize
            if changed && session.id != selection {
                unread[session.id, default: 0] += max(1, session.stats.assistantMessages - (previous[session.id]?.stats.assistantMessages ?? 0))
            }
            lastSizes[session.id] = newSize


        }

        if let selected {
            let pathChanged = previous[selected.id]?.path != selected.path
            let replaced = previous[selected.id]?.fileIdentity != selected.fileIdentity
                || selected.stats.fileBytes < (previous[selected.id]?.stats.fileBytes ?? 0)
                || (previous[selected.id]?.fileModifiedNS != selected.fileModifiedNS && previous[selected.id]?.stats.fileBytes == selected.stats.fileBytes)
            if full || pathChanged || replaced || selection != oldSelection {
                loadTranscript(reset: true)
            } else if previous[selected.id]?.updatedAt != selected.updatedAt || previous[selected.id]?.stats.fileBytes != selected.stats.fileBytes
                || (previous[selected.id]?.stale == true && !selected.stale) {
                loadTranscript(reset: false)
            }
        } else {
            messages = []
            clearActivity()
        }
    }

    func choose(_ id: String?) {
        transcriptError = nil
        pendingSelection = nil
        selection = id
        if let id {
            unread[id] = 0
            showDashboard = false
        }
        loadTranscript(reset: true)
        if let id { onChooseSession?(id) }
    }

    func openSession(_ id: String) {
        onOpenWindow?()
        query = ""
        showDashboard = false
        guard sessions.contains(where: { $0.id == id }) else {
            pendingSelection = id
            refresh()
            return
        }
        pendingSelection = nil
        choose(id)
    }

    func handleDeepLink(_ url: URL) {
        guard acceptedSchemes.contains(url.scheme ?? "") else { return }
        guard url.host != "open" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host == "session", let id = parts.first {
            openSession(id)
        } else if parts.count >= 2, parts[0] == "session" {
            openSession(parts[1])
        } else if let host = url.host, host != "session" {
            openSession(host)
        }
    }

    func nextSession(delta: Int) {
        let rows = filtered
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? 0
        let next = (current + delta + rows.count) % rows.count
        choose(rows[next].id)
    }

    func resume(_ target: ResumeTarget = .ghostty) {
        guard let session = selected else { return }
        do {
            try launchResume(session, target: target)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func jump(_ session: CodexSession) {
        if session.isRemote {
            do { try openSSH(session) } catch { errorMessage = error.localizedDescription }
            return
        }
        let root = sessions.first { $0.id == session.rootID }
        if session.clientType == "APP" || (session.isSubagent && root?.clientType == "APP") {
            openSession(session.isSubagent ? session.rootID : session.id)
            return
        }
        NotificationCenter.default.post(name: .agentJumpStarted, object: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let command = try session.source.commandURL()
                guard Shell.run(command.path, ["--jump", session.nativeID], timeout: 15) != nil else {
                    throw ProviderError("Could not jump to \(session.title)")
                }
            } catch {
                DispatchQueue.main.async { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func jumpToLiveWorkspace() {
        if let session = selected, session.isLive { jump(session) }
    }

    func archiveSelected() {
        guard let session = selected, session.canArchive, providerHealth[.codex] == .ok else { return }
        let requestID = UUID().uuidString
        archiveRequest = (session.id, session.archived, session.path, requestID)
        providers[SessionEndpoint(source: .codex)]?.refresh(requestID: requestID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.archiveRequest?.requestID == requestID else { return }
            self.archiveRequest = nil
            self.errorMessage = "Archive cancelled: the provider did not confirm that the session is inactive."
        }
    }

    func copySessionID() {
        guard let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.nativeID, forType: .string)
    }

    func copyWorkingDirectory() {
        guard let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.cwd, forType: .string)
    }

    func copyLastRequest() {
        guard let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.lastRequest, forType: .string)
    }

    func revealRollout() {
        guard let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selected.path])
    }

    func openFolder() {
        guard let selected, !selected.isRemote else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: selected.cwd))
    }

    func openTerminal() {
        guard let selected else { return }
        if selected.isRemote {
            do { try openSSH(selected) } catch { errorMessage = error.localizedDescription }
            return
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        try? Shell.launch("/usr/bin/open", GhosttyLaunch.arguments(directory: selected.cwd, command: "exec \(quote(shell)) -i", shell: shell))
    }

    func clearTranscriptSearch() {
        transcriptQuery = ""
    }

    var transcriptMatches: [TranscriptMessage] {
        let q = transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return messages.filter { $0.text.lowercased().contains(q) }
    }

    private func loadTranscript(reset: Bool) {
        guard browserVisible else { return }
        guard let session = selected else {
            transcriptGeneration &+= 1
            transcriptReloadPending = false
            pendingTranscriptReset = false
            messages = []
            clearActivity()
            return
        }
        if reset {
            transcriptGeneration &+= 1
            offsets[session.id] = 0
            messages = []
            clearActivity()
        }
        if isLoadingTranscript {
            transcriptReloadPending = true
            pendingTranscriptReset = pendingTranscriptReset || reset
            return
        }
        isLoadingTranscript = true
        let generation = transcriptGeneration
        let sessionID = session.id
        let path = session.path
        let offset = offsets[sessionID] ?? 0
        let previousActivity = transcriptActivity
        let read: (Result<RemoteTranscriptUpdate, Error>) -> Void = { [weak self] result in
            DispatchQueue.global(qos: .userInitiated).async {
            let update = try? result.get()
            var builder = previousActivity
            let start = update?.reset == true ? 0 : offset
            let chunk = update == nil ? TranscriptChunk(messages: [], nextOffset: offset) : (session.source == .claude
                ? ClaudeData.readTranscript(path, from: start, activity: &builder)
                : CodexData.readTranscript(path, from: start, activity: &builder))
            let updatedActivity = builder
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingTranscript = false
                if self.selected?.id == sessionID && self.transcriptGeneration == generation {
                    if case .failure(let error) = result { self.transcriptError = error.localizedDescription }
                    else { self.transcriptError = nil }
                    if chunk.didReset || update?.reset == true || updatedActivity.revision != self.transcriptActivity.revision {
                        self.activity = updatedActivity.events
                        self.activityRevision += 1
                    }
                    self.transcriptActivity = updatedActivity
                    if chunk.didReset || update?.reset == true {
                        self.messages = chunk.messages
                    } else if !chunk.messages.isEmpty {
                        self.messages.append(contentsOf: chunk.messages)
                    }
                    self.offsets[sessionID] = chunk.nextOffset
                    self.unread[sessionID] = 0
                    if chunk.hasMore || update?.hasMore == true { self.transcriptReloadPending = true }
                }
                guard self.transcriptReloadPending else { return }
                let resetPending = self.pendingTranscriptReset
                self.transcriptReloadPending = false
                self.pendingTranscriptReset = false
                self.loadTranscript(reset: resetPending)
            }
            }
        }
        if session.isRemote, let provider = providers[session.endpoint] {
            provider.syncTranscript(session, complete: read)
        } else if session.isRemote { read(.failure(ProviderError("\(session.sshHost) is disconnected"))) }
        else { read(.success(RemoteTranscriptUpdate())) }
    }

    private func clearActivity() {
        transcriptActivity = TimelineBuilder()
        activity = []
        activityRevision += 1
    }

    private func notifyTransition(_ session: CodexSession, from old: SessionLifecycle, to new: SessionLifecycle) {
        guard defaults.bool(forKey: "CodexSessions.notifications") else { return }
        let title: String
        switch new {
        case .waiting: title = "\(session.source.rawValue) needs input"
        case .interrupted: title = "\(session.source.rawValue) session interrupted"
        case .closed where old == .busy, .idle where old == .busy: title = "\(session.source.rawValue) finished"
        default: return
        }
        if let onNotify { onNotify(session, title) }
        else { NotificationManager.shared.send(title: title, body: session.title, sessionID: session.id) }
    }

    private func openSSH(_ session: CodexSession, resume: Bool = false) throws {
        let command = try RemoteSessions.terminalCommand(session, resume: resume)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        try Shell.launch("/usr/bin/open", GhosttyLaunch.arguments(directory: NSHomeDirectory(), command: command, shell: shell))
    }

    private func launchResume(_ session: CodexSession, target: ResumeTarget) throws {
        if session.isRemote { try openSSH(session, resume: true); return }
        guard UUID(uuidString: session.nativeID) != nil else {
            throw NSError(domain: "CodexSessions", code: 2, userInfo: [NSLocalizedDescriptionKey: "Session ID is not a valid UUID."])
        }
        guard FileManager.default.fileExists(atPath: session.cwd) else {
            throw NSError(domain: "CodexSessions", code: 3, userInfo: [NSLocalizedDescriptionKey: "Working directory is unavailable: \(session.cwd)"])
        }
        guard let executable = Shell.executable(session.source.executable) else {
            throw NSError(domain: "CodexSessions", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(session.source.executable) is not installed or not on PATH."])
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = (session.source == .claude ? ["/usr/bin/env", "CLAUDE_CONFIG_DIR=" + ClaudeData.home.path] : []) + [executable] + session.resumeArguments
        let resume = "exec " + command.map(quote).joined(separator: " ")

        switch target {
        case .ghostty:
            try Shell.launch("/usr/bin/open", GhosttyLaunch.arguments(directory: session.cwd, command: resume, shell: shell))
        case .tmux:
            guard let tmux = Shell.executable("tmux") else {
                throw NSError(domain: "CodexSessions", code: 5, userInfo: [NSLocalizedDescriptionKey: "tmux is not installed."])
            }
            let name = session.source.executable + "-" + String(session.nativeID.prefix(8))
            let command = [
                quote(tmux), "new-session", "-A", "-s", quote(name),
                "-c", quote(session.cwd), quote(shell), "-lc", quote(resume)
            ].joined(separator: " ")
            try Shell.launch("/usr/bin/open", GhosttyLaunch.arguments(directory: session.cwd, command: "exec \(command)", shell: shell))
        case .zellij:
            guard let zellij = Shell.executable("zellij") else {
                throw NSError(domain: "CodexSessions", code: 6, userInfo: [NSLocalizedDescriptionKey: "zellij is not installed."])
            }
            if let live = session.live, !live.zellijSession.isEmpty {
                try Shell.launch(zellij, ["--session", live.zellijSession, "action", "new-pane", "--cwd", session.cwd, "--"] + command)
            } else {
                try Shell.launch(zellij, ["action", "new-pane", "--cwd", session.cwd, "--"] + command)
            }
        }
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    var onSession: ((String) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func send(title: String, body: String, sessionID: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UserDefaults.standard.object(forKey: "CodexSessions.notificationSound") == nil || UserDefaults.standard.bool(forKey: "CodexSessions.notificationSound") ? .default : nil
        content.userInfo = ["sessionID": sessionID]
        let request = UNNotificationRequest(
            identifier: "codex-session-\(sessionID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["sessionID"] as? String {
            onSession?(id)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
