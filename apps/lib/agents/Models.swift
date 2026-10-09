import Foundation

enum SessionSource: String, Hashable {
    static var environmentPrefix = "AGENT_CONTROL"
    case codex = "Codex"
    case claude = "Claude Code"

    var executable: String { self == .codex ? "codex" : "claude" }
    var resumeFlag: String { self == .codex ? "resume" : "--resume" }
}

enum SessionLifecycle: String, Codable {
    case busy = "BUSY"
    case waiting = "WAITING"
    case interrupted = "INTERRUPTED"
    case idle = "IDLE"
    case closed = "CLOSED"
    case unknown = "UNKNOWN"

    var isAttention: Bool { self == .waiting || self == .interrupted }

    var sortPriority: Int {
        switch self {
        case .busy: 0
        case .waiting: 1
        case .interrupted: 2
        case .idle: 3
        case .closed: 4
        case .unknown: 5
        }
    }
}

struct LiveContext: Hashable {
    var pid: Int
    var tmuxSocket: String = ""
    var tmuxPane: String = ""
    var zellijSession: String = ""
    var zellijPane: String = ""
}

struct SessionStats: Hashable {
    var records = 0
    var userTurns = 0
    var assistantMessages = 0
    var reasoningItems = 0
    var toolCalls = 0
    var taskStarts = 0
    var taskCompletes = 0
    var abortedTurns = 0
    var totalTokens: Int?
    var cachedTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var contextUsed: Int?
    var contextWindow: Int?
    var contextWindowIsEstimated = false
    var fileBytes = 0

    var contextPercent: Int? {
        guard let used = contextUsed, let window = contextWindow, window > 0 else { return nil }
        return max(0, min(100, Int((Double(used) / Double(window) * 100).rounded())))
    }
}

struct AgentNode: Identifiable, Hashable {
    let id: String
    var parentID: String
    var nickname: String
    var pathLabel: String
    var model: String
    var startedAt: Date
    var updatedAt: Date
    var active: Bool
    var depth: Int
    var status: String? = nil
}

enum TimelineKind: String, Hashable {
    case taskStarted
    case taskCompleted
    case taskAborted
    case user
    case assistant
    case tool
    case subagent
}

struct TimelineEvent: Identifiable, Hashable {
    let id: String
    let timestamp: Date
    let kind: TimelineKind
    let label: String
    let detail: String
    let turnID: String
    let offset: UInt64
    var outputOffset: UInt64?
    var endedAt: Date?
    var duration: TimeInterval?
    var failed = false
    var source: SessionSource = .codex
    var contentIndex = 0
    var outputContentIndex = 0
}

struct CodexSession: Identifiable, Hashable {
    let id: String
    let path: URL
    let cwd: String
    let project: SessionProject
    let title: String
    let updatedAt: Date
    let startedAt: Date
    let live: LiveContext?
    let archived: Bool
    let model: String
    let reasoning: String
    let branch: String
    let commit: String
    let remote: String
    let cliVersion: String
    let lifecycle: SessionLifecycle
    let lifecycleStartedAt: Date?
    let lastRequest: String
    let stats: SessionStats
    var agents: [AgentNode]
    var clientType = ""
    var source: SessionSource = .codex
    var rootID = ""
    var parentID = ""
    var isSubagent = false
    var agentLabel = ""
    var fileIdentity = ""
    var fileModifiedNS = ""
    var stale = false

    /// The last request as rows show it; search and Copy Last Request keep the whole text.
    var requestLine: String { lastRequest.oneLine(limit: 500) }
    var nativeID: String { source == .claude ? String(id.dropFirst("claude:".count)) : id }
    var canArchive: Bool { source == .codex && !isLive && !stale }
    var resumeArguments: [String] { [source.resumeFlag, nativeID] }
    var isLive: Bool { live != nil }
    var projectName: String { project.name }
    var section: String {
        if archived { return "ARCHIVED" }
        if isLive { return "LIVE" }
        return "HISTORY"
    }
    var deepLink: URL? {
        let scheme = SessionSource.environmentPrefix == "AGENT_WORKSPACE" ? "agent-workspace" : "agent-control-center"
        return URL(string: "\(scheme)://session/\(id)")
    }

    /// Live sessions group by status, newest activity first within each group; history stays chronological.
    static func orderedBefore(_ lhs: CodexSession, _ rhs: CodexSession) -> Bool {
        if lhs.isLive != rhs.isLive { return lhs.isLive }
        if lhs.archived != rhs.archived { return !lhs.archived }
        if lhs.isLive && lhs.lifecycle != rhs.lifecycle {
            return lhs.lifecycle.sortPriority < rhs.lifecycle.sortPriority
        }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}

struct TranscriptMessage: Identifiable, Hashable {
    let id: String
    let role: String
    let text: String
    let timestamp: Date
    let phase: String
    let byteOffset: UInt64
    var contentIndex = 0
}

struct TranscriptChunk {
    var messages: [TranscriptMessage]
    var nextOffset: UInt64
    var didReset = false
    var hasMore = false
}

struct ProjectSummary: Identifiable, Hashable {
    let project: SessionProject
    let count: Int
    var id: String { project.id }
    var name: String { project.name }

    static func group(_ projects: [SessionProject]) -> [ProjectSummary] {
        Dictionary(grouping: projects, by: \.id).values.compactMap { group in
            group.first.map { ProjectSummary(project: $0, count: group.count) }
        }.sorted {
            if $0.id == SessionProject.other.id { return false }
            if $1.id == SessionProject.other.id { return true }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}
