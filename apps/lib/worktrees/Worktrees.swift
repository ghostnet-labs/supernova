import AppKit
import SwiftUI

struct WorktreeRecord: Identifiable, Hashable {
    let repository: String
    let repositoryRoot: String
    let path: String
    let branch: String
    let head: String
    let dirty: Bool
    let ahead: Int
    let behind: Int
    let hasUpstream: Bool
    let locked: Bool
    var agentStateKnown = true
    /// The branch's upstream, such as origin/feature-x; empty when it has none.
    var upstream = ""
    /// Changed files by kind, from `git status`, and the stashes made on its branch.
    var staged = 0, unstaged = 0, untracked = 0, conflicted = 0, stashes = 0
    /// Its folder is gone (git calls it prunable), or `git status` failed there. Either way it stays protected.
    var missing = false, unreadable = false
    /// Ignored files and folders that removing it would delete, leaving out caches a build or test run recreates.
    var ignoredFiles: [String] = []
    /// HEAD is detached at a commit no branch, remote branch, or tag contains, so removing or pruning the worktree would
    /// leave that commit unreachable.
    var unbranched = false
    /// Live Claude Code and Codex sessions started in it, each with its subagents.
    var sessions: [AgentSession] = []
    /// Claude Code and Codex processes running in it, whether or not a session list knows them.
    var agentProcesses: [AgentProcess] = []

    /// The row's counts in the p10k style Agent Control Center uses.
    var changes: GitStatus {
        var git = GitStatus(porcelain: "")
        (git.ahead, git.behind, git.stashes) = (ahead, behind, stashes)
        (git.staged, git.unstaged, git.untracked, git.conflicted) = (staged, unstaged, untracked, conflicted)
        return git
    }

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    /// Agent processes no live session names, such as one whose session list timed out; they count without details.
    /// A desktop or editor Codex session names the app-server, which never counts as an agent, so it counts once.
    var unlistedProcesses: [AgentProcess] {
        let listed = Set(sessions.compactMap(\.pid))
        return agentProcesses.filter { !listed.contains($0.pid) }
    }
    var agentCount: Int { sessions.count + unlistedProcesses.count }
    var hasLiveAgent: Bool { agentCount > 0 }
    /// Such as "1 Claude Code, 2 Codex".
    var agentSummary: String {
        let kinds = sessions.map(\.kind) + unlistedProcesses.map(\.kind)
        return [AgentKind.claude, .codex].map { kind in (kinds.filter { $0 == kind }.count, kind.name) }
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }
    /// A live session to jump to; an agent known only by its process has no window to find.
    var canJump: Bool { !sessions.isEmpty }
    var isPrimary: Bool { path == repositoryRoot }
    /// Why Remove leaves it alone, or nil when deleting its folder would lose nothing. Reasons come in badge order, so
    /// the first one explains the badge.
    var protection: String? {
        if missing { return "Its folder is gone; Prune clears what git still records about it." }
        if unreadable { return "git status failed there." }
        if !agentStateKnown { return "Live agent status could not be verified." }
        if hasLiveAgent { return "Agents running there: \(agentSummary)." }
        if locked { return "It's locked." }
        if unbranched { return "HEAD is detached at commits no branch or tag has, which removing it would lose." }
        if dirty { return "It has uncommitted changes." }
        if !ignoredFiles.isEmpty {
            let shown = ignoredFiles.prefix(5).joined(separator: ", ")
            return "Removing it would delete ignored files that aren't caches: \(shown)"
                + (ignoredFiles.count > 5 ? ", and \(ignoredFiles.count - 5) more." : ".")
        }
        if isPrimary { return "It's the repository's main worktree." }
        return nil
    }
    var safeToRemove: Bool { protection == nil }
    var canRebase: Bool { agentStateKnown && !dirty && !hasLiveAgent && !locked && !missing && !unreadable && branch != "detached" }
}

/// A local branch that isn't checked out in any worktree.
struct BranchRecord: Identifiable, Hashable {
    let repositoryRoot: String
    let name: String
    let head: String
    let upstream: String
    let gone: Bool
    let ahead: Int
    let behind: Int
    let lastCommit: Date
    /// Origin's default branch, such as origin/main, when known.
    let base: String?
    let merged: Bool
    /// Commits not reachable from `base`; counted when Delete is clicked rather than on every scan.
    var unmergedCommits: Int?
    var stashes = 0
    /// A merged pull request into the default branch whose head was this exact tip, so all of its work merged even when
    /// a squash or rebase merge gave its commits new IDs. Set once pull requests load.
    var mergedPull: Int?
    /// Its upstream is gone and every commit on it has a patch-identical twin on the default branch, as a rebase merge
    /// leaves them, so deleting it loses no change.
    var mergedByPatch = false

    /// No working tree, so only how far it is from its upstream and its stashes, in the same style as worktrees.
    var changes: GitStatus {
        var git = GitStatus(porcelain: "")
        (git.ahead, git.behind, git.stashes) = (ahead, behind, stashes)
        return git
    }

    var id: String { repositoryRoot + "\u{0}" + name }
    var isDefault: Bool { baseName == name }
    /// Merged into origin's default branch, by ID, by identical changes, or through a pull request that had this
    /// exact tip; never the default branch. An upstream deleted on origin alone proves nothing: the pull request may
    /// have closed unmerged, or commits may never have been pushed.
    var canDelete: Bool { !isDefault && base != nil && (merged || mergedByPatch || mergedPull != nil) }
    /// Merged, or its upstream was deleted: listed after the branches with work still in them.
    var finished: Bool { !isDefault && (merged || gone || mergedPull != nil) }
    var baseName: String? { base.map { String($0.split(separator: "/", maxSplits: 1).last ?? "") } }

    /// The branch with the merged pull request, if any, that proves all of its work reached the default branch.
    func proven(by pulls: [PullRequestInfo]?) -> BranchRecord {
        var branch = self
        branch.mergedPull = pulls?.first { $0.state == .merged && $0.headOid == head && $0.baseRef == baseName }?.number
        return branch
    }
}

struct RepositoryGroup: Identifiable {
    let root: String
    let name: String
    var records: [WorktreeRecord]
    var branches: [BranchRecord] = []
    var id: String { root }
    /// Agents running across its worktrees.
    var liveAgentCount: Int { records.reduce(0) { $0 + $1.agentCount } }

    /// Pinned repositories first, each part keeping its existing (alphabetical) order.
    static func pinnedFirst(_ groups: [RepositoryGroup], pinned: Set<String>) -> [RepositoryGroup] {
        groups.filter { pinned.contains($0.root) } + groups.filter { !pinned.contains($0.root) }
    }
}

struct WorktreeError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

enum GitTool {
    /// `timeout` stops the command and throws once it has run that many seconds.
    static func run(_ args: [String], cwd: String? = nil, allowFailure: Bool = false,
                    executable: String = "/usr/bin/git", timeout: TimeInterval? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        // A GUI app has no terminal, so credential prompts must fail instead of hanging.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let timedOut = TimeoutFlag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
        }
        // Drain both pipes before waiting; large output such as a diff would otherwise fill the pipe and deadlock.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        process.waitUntilExit()
        if timedOut.isSet {
            throw WorktreeError("\((executable as NSString).lastPathComponent) timed out after \(Int(timeout ?? 0))s")
        }
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 && !allowFailure {
            throw WorktreeError(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Set from the timeout timer's queue and read after the process exits.
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// One `git status` of a worktree: its counts, and what deleting its folder would take with it. Untracked files are
/// listed whatever the repository's status.showUntrackedFiles says, since git's own check before `worktree remove`
/// honors it. Ignored files are listed by the pattern that ignores them, so ignored folders aren't walked.
struct FolderStatus {
    var git: GitStatus
    /// Ignored paths, leaving out caches a build or test run recreates.
    var ignored: [String] = []
    var dirty: Bool { git.staged + git.unstaged + git.untracked + git.conflicted > 0 }

    static let caches: Set<String> = ["__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache", ".venv", "node_modules", ".DS_Store"]
    static let cacheExtensions: Set<String> = ["pyc", "pyo", "zwc"]

    init(porcelain: String) {
        git = GitStatus(porcelain: porcelain)
        for line in porcelain.split(separator: "\n") where line.hasPrefix("! ") {
            let path = String(line.dropFirst(2))
            let cache = path.split(separator: "/").contains { Self.caches.contains(String($0)) }
                || Self.cacheExtensions.contains((path as NSString).pathExtension)
            if !cache { ignored.append(path) }
        }
    }

    /// Never takes the index lock an agent may need; nil when status fails.
    static func load(_ path: String) -> FolderStatus? {
        (try? GitTool.run(["--no-optional-locks", "-C", path, "status", "--porcelain=v2", "--branch", "--show-stash",
                           "--untracked-files=normal", "--ignored=matching"])).map(FolderStatus.init(porcelain:))
    }
}

enum WorktreeScanner {
    static var projectRoot: String {
        ProcessInfo.processInfo.environment["WORKTREE_MANAGER_ROOT"]
            ?? ProcessInfo.processInfo.environment["TW_PROJECT_ROOT"]
            ?? "\(NSHomeDirectory())/dev"
    }

    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url.path }
        return (canonical(parent.path) as NSString).appendingPathComponent(url.lastPathComponent)
    }

    static func scan(projectRoot: String = WorktreeScanner.projectRoot, additionalPaths: [String] = [],
                     sessions suppliedSessions: [AgentSession]? = nil,
                     running suppliedProcesses: [(folder: String, process: AgentProcess)]? = nil, includeRoot: Bool = true) async
        -> (records: [WorktreeRecord], branches: [String: [BranchRecord]]) {
        let fm = FileManager.default
        let sessions = suppliedSessions ?? AgentSessions.load()
        let running = suppliedProcesses ?? agentFolders()
        let repos = includeRoot ? ((try? fm.contentsOfDirectory(atPath: projectRoot)) ?? []) : []
        let paths = Set(repos.map { URL(fileURLWithPath: projectRoot).appendingPathComponent($0).path } + additionalPaths)
        var records: [WorktreeRecord] = []
        var branches: [String: [BranchRecord]] = [:]
        var seenRepositories: Set<String> = []
        for repo in paths.map(canonical).sorted() {
            let firstRecord = records.count
            var isDir: ObjCBool = false
            // Linked worktrees share their repository's common Git dir; list each repository once.
            guard fm.fileExists(atPath: repo, isDirectory: &isDir), isDir.boolValue,
                  let commonDir = try? GitTool.run(["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]),
                  seenRepositories.insert(canonical(commonDir)).inserted,
                  let porcelain = try? GitTool.run(["-C", repo, "worktree", "list", "--porcelain"]) else { continue }
            // Git always lists the main worktree first.
            var primary: String?
            var hasStashes = false
            for block in worktreeBlocks(porcelain) {
                guard let path = blockPath(block) else { continue }
                primary = primary ?? path
                let (record, stashes) = inspect(block, path: path, root: primary ?? path, sessions: sessions, running: running)
                records.append(record)
                hasStashes = hasStashes || stashes > 0
            }
            let root = primary ?? repo
            let stashes = hasStashes ? stashCounts(repo) : [:]
            let local = localBranches(repo, root: root, stashes: stashes)
            for index in records.indices.dropFirst(firstRecord) {
                records[index].upstream = local.upstreams[records[index].branch] ?? ""
                records[index].stashes = stashes[records[index].branch] ?? 0
            }
            branches[root] = local.withoutWorktrees
        }
        // Grouped by repository: primary first, then worktrees with live agents, then by path.
        let sorted = records.sorted {
            if $0.repositoryRoot != $1.repositoryRoot { return ($0.repository, $0.repositoryRoot) < ($1.repository, $1.repositoryRoot) }
            if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
            if $0.hasLiveAgent != $1.hasLiveAgent { return $0.hasLiveAgent }
            return $0.path < $1.path
        }
        return (sorted, branches)
    }

    /// `git worktree list --porcelain` output split into one block of lines per worktree.
    static func worktreeBlocks(_ porcelain: String) -> [[String]] {
        porcelain.components(separatedBy: "\n\n").map { $0.split(separator: "\n").map(String.init) }.filter { !$0.isEmpty }
    }

    static func blockPath(_ block: [String]) -> String? {
        block.first { $0.hasPrefix("worktree ") }.map { canonical(String($0.dropFirst("worktree ".count))) }
    }

    /// One worktree's record from its `git worktree list --porcelain` block, and how many stashes its repository has.
    private static func inspect(_ block: [String], path: String, root: String, sessions: [AgentSession],
                                running: [(folder: String, process: AgentProcess)]) -> (WorktreeRecord, Int) {
        let head = block.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst(5)) } ?? "-"
        let branchRef = block.first(where: { $0.hasPrefix("branch ") }).map { String($0.dropFirst(7)) } ?? "detached"
        let locked = block.contains { $0 == "locked" || $0.hasPrefix("locked ") }
        let missing = block.contains { $0.hasPrefix("prunable") } || !FileManager.default.fileExists(atPath: path)
        // A status that fails counts as dirty, so the worktree stays protected.
        let folder = FolderStatus.load(path)
        let counts = aheadBehind(path)
        func inside(_ cwd: String) -> Bool {
            guard cwd.hasPrefix("/") else { return false }
            let directory = canonical(cwd)
            return directory == path || directory.hasPrefix(path + "/")
        }
        let record = WorktreeRecord(repository: URL(fileURLWithPath: root).lastPathComponent, repositoryRoot: root, path: path,
                                    branch: branchRef.replacingOccurrences(of: "refs/heads/", with: ""), head: head,
                                    dirty: folder?.dirty ?? true, ahead: counts?.0 ?? 0, behind: counts?.1 ?? 0, hasUpstream: counts != nil,
                                    locked: locked,
                                    staged: folder?.git.staged ?? 0, unstaged: folder?.git.unstaged ?? 0,
                                    untracked: folder?.git.untracked ?? 0, conflicted: folder?.git.conflicted ?? 0,
                                    missing: missing, unreadable: folder == nil && !missing, ignoredFiles: folder?.ignored ?? [],
                                    unbranched: branchRef == "detached" && !onSomeRef(root, head), sessions: sessions.filter { inside($0.cwd) },
                                    agentProcesses: running.filter { inside($0.folder) }.map(\.process))
        return (record, folder?.git.stashes ?? 0)
    }

    /// Whether a branch, remote branch, or tag contains the commit, so a worktree can stop pointing at it without losing
    /// it. False when git can't tell, which keeps the worktree protected.
    static func onSomeRef(_ repo: String, _ commit: String) -> Bool {
        let refs = try? GitTool.run(["-C", repo, "for-each-ref", "--contains", commit, "--count=1", "--format=%(refname)",
                                     "refs/heads", "refs/remotes", "refs/tags"])
        return !(refs ?? "").isEmpty
    }

    /// The worktree as it is now, for one last look right before Remove deletes it; nil when git no longer lists it.
    /// It keeps the live sessions the scan found, since listing them again can take seconds; processes are read again.
    static func current(_ record: WorktreeRecord) -> WorktreeRecord? {
        guard let porcelain = try? GitTool.run(["-C", record.repositoryRoot, "worktree", "list", "--porcelain"]),
              let block = worktreeBlocks(porcelain).first(where: { blockPath($0) == record.path }) else { return nil }
        var current = inspect(block, path: record.path, root: record.repositoryRoot, sessions: record.sessions, running: agentFolders()).0
        current.agentStateKnown = record.agentStateKnown
        current.stashes = record.stashes
        return current
    }

    /// One for-each-ref call lists every local branch and its upstream; `branch --merged` runs only when some
    /// branches lack a worktree, and only those become records.
    private static func localBranches(_ repo: String, root: String,
                                      stashes: [String: Int]) -> (upstreams: [String: String], withoutWorktrees: [BranchRecord]) {
        let format = "%(refname:short)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(worktreepath)%00%(objectname)"
        guard let text = try? GitTool.run(["-C", repo, "for-each-ref", "--format=\(format)", "refs/heads"]) else { return ([:], []) }
        let all = text.split(separator: "\n").map { $0.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == 6 }
        let upstreams = Dictionary(all.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        let rows = all.filter { $0[4].isEmpty }
        guard !rows.isEmpty else { return (upstreams, []) }
        let base = try? WorktreeActions.defaultBranch(repo)
        let merged = base.flatMap { try? GitTool.run(["-C", repo, "branch", "--merged", $0, "--format=%(refname:short)"]) }
            .map { Set($0.split(separator: "\n").map(String.init)) } ?? []
        var records = rows.map { row in
            let (name, track) = (row[0], row[2])
            // track looks like "[ahead 1, behind 2]", "[gone]", or "".
            func count(_ key: String) -> Int {
                guard let range = track.range(of: key + " ") else { return 0 }
                return Int(track[range.upperBound...].prefix { $0.isNumber }) ?? 0
            }
            return BranchRecord(repositoryRoot: root, name: name, head: row[5], upstream: row[1], gone: track == "[gone]", ahead: count("ahead"),
                                behind: count("behind"), lastCommit: Date(timeIntervalSince1970: Double(row[3]) ?? 0),
                                base: base, merged: merged.contains(name), stashes: stashes[name] ?? 0)
        }
        // Only a gone branch can be finished without being merged by ID, so only those compare patches, in parallel.
        if let base {
            let candidates = records.indices.filter { records[$0].gone && !records[$0].merged }
            let refs = candidates.map { "refs/heads/\(records[$0].name)" }
            var proven = [Bool](repeating: false, count: refs.count)
            proven.withUnsafeMutableBufferPointer { results in
                DispatchQueue.concurrentPerform(iterations: refs.count) { results[$0] = mergedByPatch(repo, base: base, ref: refs[$0]) }
            }
            for (index, proof) in zip(candidates, proven) { records[index].mergedByPatch = proof }
        }
        return (upstreams, records.sorted { $0.lastCommit > $1.lastCommit })
    }

    /// Every commit on the branch has a patch-identical twin on the default branch, as a rebase merge leaves them. A
    /// merge commit never has one, so a branch with a merge commit isn't proven this way.
    static func mergedByPatch(_ repo: String, base: String, ref: String) -> Bool {
        guard let marks = try? GitTool.run(["-C", repo, "rev-list", "--cherry-mark", "--right-only", "\(base)...\(ref)"]) else { return false }
        let lines = marks.split(separator: "\n")
        return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("=") }
    }

    /// Stashes are shared by every worktree; each counts on the branch it was made on, which its subject names:
    /// "WIP on main: …" from a plain `git stash`, or "On main: …" from one with a message. Branch names can't hold ":".
    private static func stashCounts(_ repo: String) -> [String: Int] {
        guard let text = try? GitTool.run(["-C", repo, "stash", "list", "--format=%gs"]) else { return [:] }
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let subject: Substring? = line.hasPrefix("WIP on ") ? line.dropFirst(7) : line.hasPrefix("On ") ? line.dropFirst(3) : nil
            if let branch = subject?.split(separator: ":", maxSplits: 1).first { counts[String(branch), default: 0] += 1 }
        }
        return counts
    }

    /// Returns nil when the branch has no upstream.
    private static func aheadBehind(_ path: String) -> (Int, Int)? {
        guard let text = try? GitTool.run(["-C", path, "rev-list", "--left-right", "--count", "@{upstream}...HEAD"]) else { return nil }
        let parts = text.split { $0.isWhitespace }.compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[1], parts[0])
    }

    /// How long each session list may take before the scan goes on without it.
    static let liveAgentTimeout: TimeInterval = 5

    /// Folders where Claude Code or Codex is running, from each process's working directory. Unlike the session lists,
    /// reading it from the kernel takes a couple of milliseconds and can't time out.
    static func agentFolders() -> [(folder: String, process: AgentProcess)] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(count, 0)).compactMap { pid in
            guard pid > 0, proc_pidpath(pid, &executable, UInt32(executable.count)) > 0,
                  let kind = agentKind(String(cString: executable), arguments: { arguments(pid) }) else { return nil }
            var info = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
            return (withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
                    AgentProcess(pid: pid, kind: kind))
        }
    }

    /// Claude Code's native build runs from …/claude/versions/X.Y.Z, so its process is named after its version; other
    /// installs, and Codex, run as claude or codex. `codex app-server` isn't an agent: it hosts desktop and editor
    /// sessions, which the session list reports, and its own folder is just wherever it started.
    static func agentKind(_ executable: String, arguments: () -> [String]) -> AgentKind? {
        let name = (executable as NSString).lastPathComponent
        if executable.contains("/claude/versions/") || name == "claude" { return .claude }
        return name == "codex" && arguments().first != "app-server" ? .codex : nil
    }

    /// A process's arguments after the program name, from the kernel; empty when they can't be read.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        // The argument count, then the executable's path, NUL padding, and each argument ending in NUL.
        return buffer[MemoryLayout<Int32>.size..<size].split(separator: 0).dropFirst().prefix(count).dropFirst()
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

enum WorktreeActions {
    static func continueWork(_ record: WorktreeRecord) {
        if let session = record.sessions.first { jump(session) }
        else { openTerminal(record.path) }
    }

    static func startCodex(_ record: WorktreeRecord) {
        openTerminal(record.path, command: "exec codex")
    }

    static func startClaude(_ record: WorktreeRecord) {
        openTerminal(record.path, command: "exec claude")
    }

    static func remove(_ record: WorktreeRecord) throws -> String {
        // The list can be minutes old, so look again right before deleting anything.
        guard let current = WorktreeScanner.current(record) else { throw WorktreeError("\(record.name) is no longer a worktree; refresh") }
        if let reason = current.protection { throw WorktreeError("\(record.name) is protected. \(reason)") }
        _ = try GitTool.run(["-C", record.repositoryRoot, "worktree", "remove", record.path])
        return "Removed \(record.path)"
    }

    static func prune(repositoryRoot: String) throws -> String {
        // Pruning forgets a missing worktree's HEAD; refuse while that is all that keeps its commits.
        let porcelain = try GitTool.run(["-C", repositoryRoot, "worktree", "list", "--porcelain"])
        for block in WorktreeScanner.worktreeBlocks(porcelain) where block.contains("detached")
            && block.contains(where: { $0.hasPrefix("prunable") }) && !block.contains(where: { $0.hasPrefix("locked") }) {
            let head = block.first { $0.hasPrefix("HEAD ") }.map { String($0.dropFirst(5)) } ?? ""
            guard WorktreeScanner.onSomeRef(repositoryRoot, head) else {
                throw WorktreeError("Prune would lose commits on no branch from \(WorktreeScanner.blockPath(block) ?? "a missing worktree"). "
                                    + "Keep them first with: git branch NAME \(head.prefix(12))")
            }
        }
        let output = try GitTool.run(["-C", repositoryRoot, "worktree", "prune", "--verbose"])
        return output.isEmpty ? "Nothing to prune" : output
    }

    static func fetch(repositoryRoot: String) throws -> String {
        _ = try GitTool.run(["-C", repositoryRoot, "fetch", "--prune"])
        return "Fetched \((repositoryRoot as NSString).lastPathComponent)"
    }

    static func pull(_ record: WorktreeRecord) throws -> String {
        guard record.hasUpstream else { throw WorktreeError("\(record.branch) has no upstream branch") }
        let output = try GitTool.run(["-C", record.path, "pull", "--ff-only"])
        let summary = output.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces) ?? "pulled"
        return "Pulled \(record.name): \(summary)"
    }

    /// Rebases onto origin's default branch and aborts on conflict so the worktree is never left mid-rebase.
    static func rebase(_ record: WorktreeRecord) throws -> String {
        guard record.canRebase else { throw WorktreeError("worktree must be clean, on a branch, and have no live agent to rebase") }
        let base = try defaultBranch(record.path)
        do {
            _ = try GitTool.run(["-C", record.path, "rebase", base])
        } catch {
            _ = try? GitTool.run(["-C", record.path, "rebase", "--abort"])
            // Git's stderr is mostly carriage-return progress; keep only the line naming the conflict.
            let reason = error.localizedDescription.components(separatedBy: .newlines)
                .first { $0.hasPrefix("CONFLICT") || $0.hasPrefix("error:") || $0.hasPrefix("fatal:") } ?? ""
            throw WorktreeError("rebase onto \(base) stopped and was aborted. \(reason)")
        }
        return "Rebased \(record.branch) onto \(base)"
    }

    /// Validate the same branch tip and deletion reason the user saw. Fail closed on Git errors.
    static func unmergedCommits(_ branch: BranchRecord) throws -> Int {
        guard branch.canDelete, let base = branch.base, try defaultBranch(branch.repositoryRoot) == base else {
            throw WorktreeError("cannot verify the default branch for \(branch.name); refresh before removing it")
        }
        let ref = "refs/heads/\(branch.name)"
        let head = try GitTool.run(["-C", branch.repositoryRoot, "rev-parse", "--verify", ref])
        guard head == branch.head else { throw WorktreeError("\(branch.name) changed; refresh and confirm its removal again") }
        let merged = (try? GitTool.run(["-C", branch.repositoryRoot, "merge-base", "--is-ancestor", ref, base])) != nil
        // The tip hasn't moved, so a pull request that merged it still covers every commit; patches are compared again.
        let byPatch = !merged && branch.mergedByPatch && WorktreeScanner.mergedByPatch(branch.repositoryRoot, base: base, ref: ref)
        guard merged || (!branch.merged && (branch.mergedPull != nil || byPatch)) else {
            throw WorktreeError("\(branch.name) is no longer merged; refresh before removing it")
        }
        guard let count = Int(try GitTool.run(["-C", branch.repositoryRoot, "rev-list", "--count", "\(base)..\(ref)"])) else {
            throw WorktreeError("cannot count unmerged commits for \(branch.name)")
        }
        return count
    }

    static func deleteBranch(_ branch: BranchRecord) throws -> String {
        guard let confirmed = branch.unmergedCommits, try unmergedCommits(branch) == confirmed else {
            throw WorktreeError("\(branch.name) changed; refresh and confirm its removal again")
        }
        // -D rather than -d: -d checks against HEAD or the upstream, not origin's default branch, so it refuses
        // branches that are merged on origin but not yet pulled. canDelete and the confirmation cover safety.
        _ = try GitTool.run(["-C", branch.repositoryRoot, "branch", "-D", "--", branch.name])
        return "Deleted branch \(branch.name)"
    }

    static func defaultBranch(_ path: String) throws -> String {
        if let ref = try? GitTool.run(["-C", path, "rev-parse", "--abbrev-ref", "origin/HEAD"]), ref != "origin/HEAD" { return ref }
        for ref in ["origin/main", "origin/master"] where (try? GitTool.run(["-C", path, "rev-parse", "--verify", "--quiet", ref])) != nil {
            return ref
        }
        throw WorktreeError("cannot find origin's default branch; run Fetch or `git remote set-head origin --auto`")
    }

    static let maxUntrackedDiffs = 50
    static let maxUntrackedBytes = 512 * 1024

    /// Uncommitted changes against HEAD, plus untracked files shown as new-file diffs.
    static func diff(_ path: String) throws -> (branch: String, text: String, untracked: Set<String>) {
        let status = try GitTool.run(["-C", path, "status", "--short", "--branch"])
        let branch = status.split(separator: "\n").first.map { String($0.dropFirst(3)) } ?? ""
        var sections = [try GitTool.run(["-C", path, "-c", "color.ui=false", "diff", "HEAD", "--no-ext-diff"])]
        let untracked = try GitTool.run(["-C", path, "ls-files", "-z", "--others", "--exclude-standard"])
            .split(separator: "\0").map(String.init)
        for file in untracked.prefix(maxUntrackedDiffs) {
            let size = (try? FileManager.default.attributesOfItem(atPath: "\(path)/\(file)")[.size] as? Int) ?? 0
            if size > maxUntrackedBytes {
                sections.append("diff --git a/\(file) b/\(file)\nnew file mode 100644\n(untracked file not shown: \(size / 1024) KB)")
            } else {
                // --no-index exits 1 when the files differ, which they always do here.
                sections.append(try GitTool.run(["-C", path, "-c", "color.ui=false", "diff", "--no-index", "--no-ext-diff",
                                                 "--", "/dev/null", file], allowFailure: true))
            }
        }
        if untracked.count > maxUntrackedDiffs {
            sections.append("… \(untracked.count - maxUntrackedDiffs) more untracked files not shown")
        }
        return (branch, sections.filter { !$0.isEmpty }.joined(separator: "\n"), Set(untracked))
    }

    static func create(repositoryRoot: String, branch: String, path: String, createBranch: Bool) throws {
        var args = ["-C", repositoryRoot, "worktree", "add"]
        if createBranch { args += ["-b", branch, path] }
        else { args += [path, branch] }
        _ = try GitTool.run(args)
    }

    /// The origin's web page, or a branch's page when `branch` is given. SSH host aliases such as
    /// git@github-personal:owner/repo are resolved to their real host with `ssh -G`.
    static func webURL(repositoryRoot: String, branch: String?) throws -> URL {
        let remote = try GitTool.run(["-C", repositoryRoot, "remote", "get-url", "origin"])
        guard let base = webBase(remote) else { throw WorktreeError("can't make a web address from origin \(remote)") }
        let page = branch.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) }.map { "\(base)/tree/\($0)" } ?? base
        guard let url = URL(string: page) else { throw WorktreeError("invalid web address \(page)") }
        return url
    }

    /// https://host/owner/repo for https, ssh://, and scp-style (user@host:owner/repo) remotes.
    static func webBase(_ remote: String, resolveHost: (String) -> String = sshHostname) -> String? {
        var host: String, path: String
        if remote.hasPrefix("https://") || remote.hasPrefix("http://") || remote.hasPrefix("ssh://") {
            guard let url = URL(string: remote), let urlHost = url.host else { return nil }
            host = remote.hasPrefix("ssh://") ? resolveHost(urlHost) : urlHost
            path = url.path
        } else if let colon = remote.firstIndex(of: ":") {
            let authority = remote[..<colon]
            host = resolveHost(String(authority.split(separator: "@").last ?? authority))
            path = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        return path.isEmpty ? nil : "https://\(host)/\(path)"
    }

    /// The real hostname for an SSH alias from ~/.ssh/config; the alias itself when ssh has none.
    static func sshHostname(_ alias: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", alias]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return alias }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return output.split(separator: "\n").first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst(9)) } ?? alias
    }

    /// The branch name on origin for a worktree, or nil when it has no upstream.
    static func upstreamBranch(_ record: WorktreeRecord) -> String? {
        guard record.hasUpstream, let ref = try? GitTool.run(["-C", record.path, "rev-parse", "--abbrev-ref", "@{upstream}"]),
              let slash = ref.firstIndex(of: "/") else { return nil }
        return String(ref[ref.index(after: slash)...])
    }

    static func reveal(_ records: [WorktreeRecord]) {
        NSWorkspace.shared.activateFileViewerSelecting(records.map { URL(fileURLWithPath: $0.path) })
    }

    /// `codex-sessions` and `claude-sessions` each find their own session's Ghostty window, tab, and pane.
    private static func jump(_ session: AgentSession) {
        guard let command = session.kind.command else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["--jump", session.sessionID]
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }

    /// Ghostty's `-e` goes through /usr/bin/login and mangles arguments, so pass `--initial-command=` instead;
    /// `--command=` would also run in every later window and tab of the instance. `-n` is required or Ghostty
    /// focuses the running instance and ignores the arguments, the new instance must not restore saved windows,
    /// and it quits with its last window so it can't linger and catch the next new-window request.
    static func openTerminal(_ path: String, command: String? = nil) {
        var args = ["-na", "Ghostty.app", "--args", "--window-save-state=never",
                    "--quit-after-last-window-closed=true", "--working-directory=\(path)"]
        if let command {
            // Interactive login shell so PATH entries from .zshrc (such as ~/.local/bin for claude) are present.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
            args.append("--initial-command=\(shell) -lic \(quoted)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = args
        try? task.run()
    }
}

@MainActor
final class WorktreeModel: ObservableObject {
    @Published private(set) var records: [WorktreeRecord] = []
    @Published private(set) var branches: [String: [BranchRecord]] = [:]
    @Published private(set) var loading = false
    @Published private(set) var busy: Set<String> = []
    @Published var search = ""
    /// Selected worktree paths and branch IDs.
    @Published var selection: Set<String> = []
    @Published var errorMessage: String?
    @Published var notice: String?
    /// Each branch's recent pull requests, newest first, keyed like `BranchRecord.id`.
    @Published private(set) var pulls: [String: [PullRequestInfo]] = [:]
    @Published private(set) var pullsError: String?
    @Published private(set) var loadingPulls = false
    private var refreshAgain = false
    private let lookupPulls: @Sendable ([PullRequestQuery]) async -> PullRequestLookup
    private var pullsGeneration = 0
    private var pullsTask: Task<Void, Never>?
    var scan: (() async -> (records: [WorktreeRecord], branches: [String: [BranchRecord]]))?
    var validateWorktrees: (([WorktreeRecord], Bool) async throws -> [WorktreeRecord])?
    var continueWork: ((WorktreeRecord) -> Void)?
    var onScan: (() -> Void)?
    var pullRefreshInterval: TimeInterval = 0
    private var lastPullRefresh = Date.distantPast
    private var lastPullQueries: [PullRequestQuery] = []

    /// Records are already sorted by repository, so consecutive runs form the groups. Search keeps a group
    /// when its name, any worktree's branch or path, or any branch without a worktree matches.
    var groups: [RepositoryGroup] {
        var groups: [RepositoryGroup] = []
        for record in records {
            if groups.last?.root == record.repositoryRoot {
                groups[groups.count - 1].records.append(record)
            } else {
                groups.append(RepositoryGroup(root: record.repositoryRoot, name: record.repository, records: [record],
                                              branches: (branches[record.repositoryRoot] ?? []).map { $0.proven(by: pulls[$0.id]) }))
            }
        }
        guard !search.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.name.localizedCaseInsensitiveContains(search) { return group }
            var group = group
            group.records = group.records.filter {
                $0.branch.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
            }
            group.branches = group.branches.filter { $0.name.localizedCaseInsensitiveContains(search) }
            return group.records.isEmpty && group.branches.isEmpty ? nil : group
        }
    }

    var branchCount: Int { branches.values.reduce(0) { $0 + $1.count } }

    var safeCount: Int { records.filter(\.safeToRemove).count }
    var protectedCount: Int { records.filter { !$0.isPrimary && !$0.safeToRemove }.count }
    var openPullCount: Int { Set(pulls.values.joined().filter(\.state.isOpen).map(\.url)).count }

    /// Every row a selection can name: worktrees, branches without a worktree, and the pull requests under them.
    var selectableIDs: Set<String> {
        var ids = Set(records.map(\.id)).union(branches.values.joined().map(\.id))
        for (key, list) in pulls { for pull in list { ids.insert(ListRow.pull(pull, key: key).id) } }
        return ids
    }

    /// Tests pass a stub lookup so they never contact GitHub.
    init(autoRefresh: Bool = true, lookupPulls: @escaping @Sendable ([PullRequestQuery]) async -> PullRequestLookup = { await PullRequestClient.lookup($0) }) {
        self.lookupPulls = lookupPulls
        if autoRefresh { refresh() }
    }

    func refresh() {
        guard !loading else { refreshAgain = true; return }
        loading = true
        Task {
            if let scan { (records, branches) = await scan() }
            else { (records, branches) = await WorktreeScanner.scan() }
            // Drop selections for worktrees, branches, and pull requests that no longer exist.
            selection.formIntersection(selectableIDs)
            loading = false
            onScan?()
            if refreshAgain { refreshAgain = false; refresh() } else { lookUpPulls() }
        }
    }

    func updateAgents(_ agents: [AgentSession], known: Bool) {
        var updated = records
        for index in updated.indices {
            let path = updated[index].path
            updated[index].sessions = agents.filter { $0.cwd == path || $0.cwd.hasPrefix(path + "/") }
            updated[index].agentStateKnown = known
        }
        if updated != records { records = updated }
    }

    /// Hold the batch lock through provider confirmation and Git revalidation.
    func performProtected(_ records: [WorktreeRecord], removing: Bool, branches: [BranchRecord] = []) {
        guard busy.isEmpty else { return }
        busy = Set(records.map(\.path) + branches.map(\.id))
        Task {
            do {
                let fresh = try await validateWorktrees?(records, removing) ?? records
                let jobs = fresh.map { record in Job(key: record.path) {
                    try removing ? WorktreeActions.remove(record) : WorktreeActions.rebase(record)
                } } + branches.map { branch in Job(key: branch.id) { try WorktreeActions.deleteBranch(branch) } }
                busy = []
                perform(jobs)
            } catch {
                busy = []
                errorMessage = error.localizedDescription
            }
        }
    }

    /// One query per repository: its worktrees on a branch and its branches without a worktree.
    var pullQueries: [PullRequestQuery] {
        var heads: [String: [String: String]] = [:]
        for record in records where record.branch != "detached" {
            heads[record.repositoryRoot, default: [:]][record.branch] = Self.head(local: record.branch, upstream: record.upstream)
        }
        for (root, list) in branches {
            for branch in list { heads[root, default: [:]][branch.name] = Self.head(local: branch.name, upstream: branch.upstream) }
        }
        return heads.keys.sorted().map { PullRequestQuery(repositoryRoot: $0, heads: heads[$0] ?? [:]) }
    }

    /// The branch's name on origin, which is what pull requests record: its upstream when that is on origin.
    nonisolated static func head(local: String, upstream: String) -> String {
        upstream.hasPrefix("origin/") ? String(upstream.dropFirst("origin/".count)) : local
    }

    /// Looks up pull requests for the last scan. Earlier results stay on screen until this one finishes,
    /// and a lookup that a newer scan superseded is dropped.
    private func lookUpPulls() {
        if pullQueries == lastPullQueries && Date().timeIntervalSince(lastPullRefresh) < pullRefreshInterval { return }
        lastPullQueries = pullQueries
        lastPullRefresh = Date()
        pullsGeneration += 1
        let generation = pullsGeneration, queries = pullQueries, lookup = lookupPulls
        pullsTask?.cancel()
        loadingPulls = true
        pullsTask = Task {
            let result = await lookup(queries)
            guard generation == pullsGeneration else { return }
            pulls = result.pulls
            // A pull request that dropped out of the list can't stay selected.
            selection.formIntersection(selectableIDs)
            pullsError = result.error
            loadingPulls = false
        }
    }

    struct Job {
        /// The worktree path or branch ID shown busy while the job runs.
        let key: String
        let work: @Sendable () throws -> String
    }

    func refreshAll() { lastPullRefresh = .distantPast; refresh() }

    /// Runs one batch of Git jobs off the main thread, then rescans once; rejects overlapping batches.
    func perform(_ jobs: [Job]) {
        // A fetch keyed by the primary path must not overlap a rebase or removal keyed by a linked path.
        guard busy.isEmpty, !jobs.isEmpty else { return }
        let keys = Set(jobs.map(\.key))
        busy.formUnion(keys)
        Task {
            let results = await Task.detached { jobs.map { Result(catching: $0.work) } }.value
            busy.subtract(keys)
            let messages = results.compactMap { try? $0.get() }
            let failures = results.compactMap { result -> String? in
                if case .failure(let error) = result { return error.localizedDescription } else { return nil }
            }
            notice = messages.isEmpty ? nil : messages.joined(separator: " · ")
            errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
            refresh()
        }
    }
}

/// What the action bar can do with the current selection. Each action applies to the selected items it fits.
/// A selected pull request and the repository whose list shows it.
struct PullSelection {
    let pull: PullRequestInfo
    let repositoryRoot: String
}

struct SelectionActions {
    var worktrees: [WorktreeRecord] = []
    var branches: [BranchRecord] = []
    /// Pull requests get Show Diff, Open on GitHub, their repository's actions, and New Worktree for their branch.
    var pulls: [PullSelection] = []

    var isEmpty: Bool { worktrees.isEmpty && branches.isEmpty && pulls.isEmpty }
    var count: Int { worktrees.count + branches.count + pulls.count }
    /// Repositories touched by the selection, in list order; Fetch and Prune run once per repository.
    var repositories: [String] {
        var seen = Set<String>()
        return (worktrees.map(\.repositoryRoot) + branches.map(\.repositoryRoot) + pulls.map(\.repositoryRoot)).filter { seen.insert($0).inserted }
    }
    /// One worktree with uncommitted changes, or one pull request, selected alone.
    var diff: DiffSource? {
        if worktrees.count == 1, branches.isEmpty, pulls.isEmpty, worktrees[0].dirty { return .worktree(worktrees[0]) }
        if pulls.count == 1, worktrees.isEmpty, branches.isEmpty { return .pull(pulls[0].pull) }
        return nil
    }
    var pullable: [WorktreeRecord] { worktrees.filter(\.hasUpstream) }
    var rebaseable: [WorktreeRecord] { worktrees.filter(\.canRebase) }
    var removable: [WorktreeRecord] { worktrees.filter(\.safeToRemove) }
    var deletable: [BranchRecord] { branches.filter(\.canDelete) }
    /// One repository and at most one branch: the sheet opens for that repository, filled in with the branch, or with
    /// a lone pull request's branch so it can be checked out (git creates it from origin's copy).
    var newWorktree: CreateRequest? {
        guard repositories.count == 1, branches.count <= 1 else { return nil }
        if let branch = branches.first { return .forBranch(branch) }
        if pulls.count == 1, let head = pulls.first?.pull.headRef, !head.isEmpty, !head.contains(":") {
            return .named(head, in: repositories[0])
        }
        return CreateRequest(repositoryRoot: repositories[0])
    }
    var openTitle: (full: String, short: String) {
        if !worktrees.isEmpty, worktrees.allSatisfy(\.canJump) { return ("Jump to Existing Ghostty Window", "Jump") }
        if worktrees.contains(where: \.canJump) { return ("Open or Jump in Ghostty", "Open/Jump") }
        return ("Open in New Ghostty Window", "Open")
    }
}

/// Worktrees and branches a confirmed Remove would delete, plus how many selected items it skips.
struct RemovalPlan: Identifiable {
    let worktrees: [WorktreeRecord]
    let branches: [BranchRecord]
    let skipped: Int
    var id: String { (worktrees.map(\.id) + branches.map(\.id)).joined(separator: "|") }

    static func prepare(_ selected: SelectionActions) throws -> RemovalPlan {
        let branches = try selected.deletable.map { branch -> BranchRecord in
            var branch = branch
            branch.unmergedCommits = try WorktreeActions.unmergedCommits(branch)
            return branch
        }
        let skipped = selected.worktrees.count + selected.branches.count - selected.removable.count - branches.count
        return RemovalPlan(worktrees: selected.removable, branches: branches, skipped: skipped)
    }

    var title: String {
        var parts: [String] = []
        if !worktrees.isEmpty { parts.append(worktrees.count == 1 ? "1 worktree" : "\(worktrees.count) worktrees") }
        if !branches.isEmpty { parts.append(branches.count == 1 ? "1 branch" : "\(branches.count) branches") }
        return "Remove \(parts.joined(separator: " and "))?"
    }

    var message: String {
        var lines: [String] = []
        if !worktrees.isEmpty {
            lines.append("Worktree folders deleted (their branches are kept): " + worktrees.map(\.name).joined(separator: ", "))
        }
        for branch in branches {
            let base = branch.baseName ?? "the default branch", count = branch.unmergedCommits ?? 0
            let commits = "\(count) commit\(count == 1 ? "" : "s")"
            if branch.merged {
                lines.append("Branch \(branch.name): merged into \(branch.base ?? "origin"), so its commits stay there.")
            } else if let pull = branch.mergedPull {
                lines.append("Branch \(branch.name): pull request #\(pull) merged this exact tip into \(base), so all of its work is there. "
                             + "Its \(commits) landed under new IDs, as squash and rebase merges do.")
            } else {
                lines.append("Branch \(branch.name): each of its \(commits) has an identical change on \(base), as a rebase merge leaves "
                             + "them, so none of its work is lost.")
            }
        }
        if skipped > 0 { lines.append("\(skipped) selected item\(skipped == 1 ? " is" : "s are") protected and will be skipped.") }
        return lines.joined(separator: "\n\n")
    }
}

extension WorktreeRecord {
    /// The one state worth a badge, most important first: a missing folder, an unreadable status, a live agent, a
    /// lock, ignored files Remove would delete, or safe to remove. Uncommitted changes show as counts beside the
    /// branch instead. Its tooltip says why Remove leaves the worktree alone.
    var badge: (text: String, color: Color)? {
        if missing { return ("MISSING", .red) }
        if unreadable { return ("NO STATUS", .orange) }
        if hasLiveAgent { return (agentCount == 1 ? "AGENT LIVE" : "\(agentCount) AGENTS LIVE", .blue) }
        if locked { return ("LOCKED", .gray) }
        if unbranched { return ("COMMITS ON NO BRANCH", .orange) }
        if !isPrimary, !dirty, !ignoredFiles.isEmpty { return ("IGNORED FILES", .orange) }
        if safeToRemove { return ("SAFE TO REMOVE", .green) }
        return nil
    }

    var badgeHelp: String {
        protection ?? "Clean, on a commit a branch keeps, with no ignored files but caches, so removing it loses nothing."
    }
}

extension GitStatus {
    var isEmpty: Bool { ahead + behind + stashes + conflicted + staged + unstaged + untracked == 0 }
}

struct WorktreeRow: View {
    let record: WorktreeRecord
    let busy: Bool
    /// No pull requests under it: neighbors without any sit closer, so long runs of rows lose dead space. A row with
    /// pull requests keeps room above it, and its first pull request sits as close as the others do.
    var compact = false

    var body: some View {
        // Top-aligned, so the icon stays beside the name when agents make the row tall.
        HStack(alignment: .top, spacing: 12) {
            // What the row is; the badge says what state it's in.
            Octicons.swiftUIImage(record.isPrimary ? "home" : "file-directory").foregroundStyle(.secondary).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                // Name, badge, branch, and sync counts share one line; the branch shortens first when space runs out.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.name).font(.headline).lineLimit(1).truncationMode(.middle).layoutPriority(2)
                    if let badge = record.badge { Badge(text: badge.text, color: badge.color).help(record.badgeHelp) }
                    HStack(spacing: 8) {
                        BranchRef(name: record.branch)
                        if !record.changes.isEmpty { GitCounts(git: record.changes).fixedSize().layoutPriority(1) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text((record.path as NSString).abbreviatingWithTildeInPath).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).help(record.path)
                ForEach(record.sessions) { AgentRow(session: $0) }
                ForEach(record.unlistedProcesses, id: \.pid) { process in
                    Text("↳ \(process.kind.name) process \(process.pid), not in its session list").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.top, compact ? 1 : 6).padding(.bottom, compact ? 1 : 2)
    }
}

struct DiffFile: Identifiable, Hashable {
    let line: Int
    let path: String
    let kind: String
    var added = 0
    var removed = 0
    var id: Int { line }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

struct DiffDocument {
    var branch = ""
    var lines: [String] = []
    var files: [DiffFile] = []
    var headers: [Int: DiffFile] = [:]
    var truncated = 0
    /// The rendered diff and the UTF-16 offset where each line starts, for jumping to a file.
    var text = NSAttributedString()
    var lineOffsets: [Int] = []
    static let maxLines = 20_000

    /// Splits the patch into per-file sections keyed by the line index of each `diff --git` header.
    init(branch: String = "", text: String = "", untracked: Set<String> = []) {
        self.branch = branch
        let all = text.isEmpty ? [] : text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        // A blank line before each file after the first separates files.
        for line in all.prefix(Self.maxLines) {
            if line.hasPrefix("diff --git "), !lines.isEmpty { lines.append("") }
            lines.append(line)
        }
        truncated = max(0, all.count - Self.maxLines)
        var current: DiffFile?
        var kind = "M", newPath: String?, oldPath: String?, header = 0
        // Git ends ---/+++ paths that contain spaces with a tab, which is now padding.
        func path(_ line: String, drop: Int) -> String {
            String(line.dropFirst(drop)).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
        func finish() {
            guard var file = current else { return }
            let path = newPath ?? oldPath ?? file.path
            file = DiffFile(line: header, path: path, kind: untracked.contains(path) ? "U" : kind,
                            added: file.added, removed: file.removed)
            files.append(file)
        }
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("diff --git ") {
                finish()
                // Fallback path from the header; the +++/--- lines below are more reliable when present.
                let fallback = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) } ?? line
                current = DiffFile(line: index, path: fallback, kind: "M")
                kind = "M"; newPath = nil; oldPath = nil; header = index
            } else if current != nil {
                if line.hasPrefix("new file mode") { kind = "A" }
                else if line.hasPrefix("deleted file mode") { kind = "D" }
                else if line.hasPrefix("rename to ") { kind = "R"; newPath = String(line.dropFirst(10)) }
                else if line.hasPrefix("+++ b/") { newPath = path(line, drop: 6) }
                else if line.hasPrefix("--- a/") { oldPath = path(line, drop: 6) }
                else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") { }
                else if line.hasPrefix("+") { current?.added += 1 }
                else if line.hasPrefix("-") { current?.removed += 1 }
            }
        }
        finish()
        headers = Dictionary(uniqueKeysWithValues: files.map { ($0.line, $0) })
        render()
    }

    private mutating func render() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        // Each file starts with a title line in place of the raw `diff --git` line.
        let shown = lines.indices.map { index in headers[index].map { " \($0.kind)  \($0.path) " } ?? lines[index] }
        var body = shown.joined(separator: "\n")
        if truncated > 0 { body += "\n\n… \(truncated) more lines not shown" }
        let result = NSMutableAttributedString(string: body, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        var offset = 0
        lineOffsets.reserveCapacity(shown.count)
        for (index, line) in shown.enumerated() {
            let length = (line as NSString).length
            lineOffsets.append(offset)
            let range = NSRange(location: offset, length: length)
            if let file = headers[index] {
                result.addAttributes([.font: bold, .backgroundColor: NSColor.quaternaryLabelColor], range: range)
                result.addAttribute(.foregroundColor, value: Self.kindColor(file.kind), range: NSRange(location: offset + 1, length: 1))
            } else if let color = Self.color(line) {
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
            offset += length + 1
        }
        text = result
    }

    static func kindColor(_ kind: String) -> NSColor {
        switch kind {
        case "A", "U": return .systemGreen
        case "D": return .systemRed
        case "R": return .systemPurple
        default: return .systemOrange
        }
    }

    private static func color(_ line: String) -> NSColor? {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") || line.hasPrefix("new file mode")
            || line.hasPrefix("deleted file mode") || line.hasPrefix("similarity index") || line.hasPrefix("rename ") {
            return .secondaryLabelColor
        }
        if line.hasPrefix("@@") { return .systemPurple }
        if line.hasPrefix("+") { return .systemGreen }
        if line.hasPrefix("-") { return .systemRed }
        return nil
    }
}

/// A read-only AppKit text view for the diff: exact jumps to a line, and selection across lines.
struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    let target: Int?

    final class Coordinator {
        var shown: NSAttributedString?
        var target: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView { Self.makeScrollView() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let state = context.coordinator
        if state.shown !== document.text {
            Self.show(document, in: scroll)
            state.shown = document.text
        }
        if let target, target != state.target {
            Self.scroll(scroll, toLine: target, in: document)
        }
        state.target = target
    }

    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // Long lines scroll sideways instead of wrapping.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        scroll.documentView = textView
        return scroll
    }

    static func show(_ document: DiffDocument, in scroll: NSScrollView) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(document.text)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Puts `line` at the top of the visible area, or as close as the end of the text allows.
    static func scroll(_ scroll: NSScrollView, toLine line: Int, in document: DiffDocument) {
        guard let textView = scroll.documentView as? NSTextView, let layout = textView.layoutManager,
              let container = textView.textContainer, document.lineOffsets.indices.contains(line) else { return }
        let character = document.lineOffsets[line]
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(character + 1, document.text.length)))
        let glyph = layout.glyphIndexForCharacter(at: character)
        let y = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
        layout.ensureLayout(for: container)
        let maxY = max(0, textView.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y - 4), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// What the diff viewer shows: a worktree's uncommitted changes, or a pull request's changes from GitHub.
enum DiffSource: Identifiable {
    case worktree(WorktreeRecord)
    case pull(PullRequestInfo)

    var id: String {
        switch self {
        case .worktree(let record): "worktree:" + record.id
        case .pull(let pull): "pull:" + pull.url.absoluteString
        }
    }
}

struct DiffSheet: View {
    let source: DiffSource
    let done: () -> Void
    var embedded = false
    @State private var document = DiffDocument()
    @State private var selection: DiffFile.ID?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    switch source {
                    case .worktree(let record):
                        Text("Diff · \(record.name)").font(.title2.bold())
                        HStack(spacing: 6) {
                            if !document.branch.isEmpty { BranchRef(name: document.branch) }
                            Text((document.branch.isEmpty ? "" : "·  ") + summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    case .pull(let pull):
                        // The title and number, then the same line its row shows.
                        Text("\(Text(pull.title)) \(Text("#\(pull.number)").foregroundStyle(.secondary))").font(.title2.bold())
                            .lineLimit(1).truncationMode(.tail)
                        HStack(spacing: 6) {
                            PullSentence(pull: pull)
                            Text("·  " + summary).font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Done") { done() }.keyboardShortcut(.cancelAction)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HSplitView {
                fileList.frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
                DiffTextView(document: document, target: selection)
            }
        }
        .padding(20)
        .frame(minWidth: embedded ? 600 : 1000, minHeight: embedded ? 540 : 640)
        .task {
            let source = source
            let result = await Task.detached { () async -> Result<DiffDocument, Error> in
                do {
                    switch source {
                    case .worktree(let record):
                        let diff = try WorktreeActions.diff(record.path)
                        return .success(DiffDocument(branch: diff.branch, text: diff.text, untracked: diff.untracked))
                    case .pull(let pull):
                        return .success(DiffDocument(branch: pull.headRef, text: try await PullRequestClient.diff(pull)))
                    }
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let parsed): document = parsed
            case .failure(let failure): error = failure.localizedDescription
            }
            loading = false
        }
    }

    private var summary: String {
        let added = document.files.reduce(0) { $0 + $1.added }, removed = document.files.reduce(0) { $0 + $1.removed }
        let files = document.files.count == 1 ? "1 file" : "\(document.files.count) files"
        return "\(files)  ·  +\(added) −\(removed)"
    }

    private var fileList: some View {
        List(document.files, selection: $selection) { file in
            HStack(spacing: 8) {
                Text(file.kind).font(.caption.monospaced().bold()).foregroundStyle(Self.kindColor(file.kind)).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    if !file.folder.isEmpty {
                        Text(file.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if file.added > 0 { Text("+\(file.added)").foregroundStyle(.green) }
                if file.removed > 0 { Text("−\(file.removed)").foregroundStyle(.red) }
            }
            .font(.callout)
            .help(file.path)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(file.kind) \(file.path)")
            .listRowSeparator(.hidden)
        }
    }

    private static func kindColor(_ kind: String) -> Color { Color(nsColor: DiffDocument.kindColor(kind)) }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).fixedSize()
    }
}

struct BranchRow: View {
    let branch: BranchRecord
    let busy: Bool
    /// No pull requests under it: neighbors without any sit closer, so long runs of rows lose dead space. A row with
    /// pull requests keeps room above it, and its first pull request sits as close as the others do.
    var compact = false
    private static let age = RelativeDateTimeFormatter()

    var body: some View {
        HStack(spacing: 12) {
            Octicons.swiftUIImage("git-branch").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BranchRef(name: branch.name, font: .body.monospaced().weight(.semibold))
                    if branch.merged {
                        Badge(text: "MERGED", color: .purple).help("Merged into \(branch.base ?? "the default branch"), so deleting it loses nothing.")
                    } else if branch.gone {
                        Badge(text: "UPSTREAM GONE", color: .orange).help(branch.mergedPull.map {
                            "Deleted on origin after pull request #\($0) merged this exact tip, so deleting it loses nothing."
                        } ?? (branch.mergedByPatch
                              ? "Deleted on origin, and each of its commits has an identical change on \(branch.baseName ?? "the default branch"), so deleting it loses nothing."
                              : "Deleted on origin, but neither a merged pull request with this exact tip nor identical changes on "
                                + "\(branch.baseName ?? "the default branch") show its work landed, so Remove leaves it alone."))
                    }
                    if !branch.changes.isEmpty { GitCounts(git: branch.changes).font(.caption).fixedSize() }
                }
                HStack(spacing: 4) {
                    if branch.upstream.isEmpty { Text("no upstream") } else { BranchRef(name: branch.upstream) }
                    Text("· last commit \(Self.age.localizedString(for: branch.lastCommit, relativeTo: Date()))").lineLimit(1)
                }
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.top, compact ? 1 : 6).padding(.bottom, compact ? 1 : 2)
    }
}

extension PullRequestState {
    var symbol: String {
        switch self {
        case .open: "git-pull-request"
        case .draft: "git-pull-request-draft"
        case .merged: "git-merge"
        case .closed: "git-pull-request-closed"
        }
    }

    var color: Color {
        switch self {
        case .open: .green
        case .draft: .gray
        case .merged: .purple
        case .closed: .red
        }
    }
}

extension CheckState {
    var symbol: String {
        switch self {
        case .success: "check"
        case .failure: "x"
        case .pending: "dot-fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        }
    }

    var title: String {
        switch self {
        case .success: "Checks passed"
        case .failure: "Checks failed"
        case .pending: "Checks running"
        }
    }
}

extension ReviewState {
    var title: String {
        switch self {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        }
    }

    var color: Color {
        switch self {
        case .approved: .green
        case .changesRequested: .red
        case .reviewRequired: .secondary
        }
    }
}

/// GitHub's small StateLabel: a white Octicon and the state's name in a pill of its color.
struct PullStateLabel: View {
    let state: PullRequestState

    var body: some View {
        HStack(spacing: 3) {
            Octicons.swiftUIImage(state.symbol).resizable().frame(width: 12, height: 12)
            Text(state.rawValue)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        // Darkened like GitHub's own labels: white text on the bright system colors was too faint.
        .background { Capsule().fill(state.color).overlay(Capsule().fill(.black.opacity(0.3))) }
        .fixedSize()
    }
}

/// The words GitHub puts under a pull request's title: "alice merged 3 commits into main from feature-x on Jul 2".
extension PullRequestInfo {
    /// Whoever merged it, else its author.
    var actor: String { state == .merged ? mergedBy ?? "ghost" : author }

    var action: String {
        let count = "\(commits) commit\(commits == 1 ? "" : "s")"
        return state == .merged ? "merged \(count) into" : "wants to merge \(count) into"
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter
    }()

    /// The date that fits its state, as 10/04/2026: when it merged or closed, else when it was opened.
    var when: String {
        let date = Self.day.string(from: state.isOpen ? createdAt : closedAt ?? updatedAt)
        switch state {
        case .merged: return "on \(date)"
        case .closed: return "· closed \(date)"
        case .open, .draft: return "· opened \(date)"
        }
    }

    var sentence: String { "\(actor) \(action) \(baseRef) from \(headRef) \(when)" }

    /// The number, and for a merged pull request its author too, as GitHub's pull request list shows: "#121 by alice".
    /// Other states already start their sentence with the author.
    var reference: String { state == .merged ? "#\(number) by \(author)" : "#\(number)" }
}

/// The line under a pull request's title, as on its GitHub page: state, who, what, which branches, and when.
/// A long source branch shortens in the middle; the rest of the sentence stays whole.
struct PullSentence: View {
    let pull: PullRequestInfo

    var body: some View {
        HStack(spacing: 4) {
            PullStateLabel(state: pull.state)
            Text(pull.actor).fontWeight(.semibold).fixedSize()
            Text(pull.action).foregroundStyle(.secondary).fixedSize()
            BranchRef(name: pull.baseRef).fixedSize()
            Text("from").foregroundStyle(.secondary).fixedSize()
            BranchRef(name: pull.headRef)
            Text(pull.when).foregroundStyle(.secondary).fixedSize()
        }
        .font(.caption)
    }
}

/// One pull request under its branch, laid out like the top of its GitHub page: the title and number, then the state
/// and who merged or wants to merge which branch. Review, checks, and size follow the title rather than sitting at the
/// far edge, so the row stays as short as its content. A click selects it, like any row; double-click, Return, or Open
/// on GitHub opens it.
struct PullRequestRow: View {
    let pull: PullRequestInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The number (and a merged pull request's author) follows the title and stays whole when a long title is shortened.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(pull.title).lineLimit(1).truncationMode(.tail)
                    Text(pull.reference).foregroundStyle(.secondary).fixedSize()
                }
                .font(.callout)
                HStack(spacing: 10) {
                    if let review = pull.review { Text(review.title).foregroundStyle(review.color) }
                    if let checks = pull.checks {
                        Octicons.swiftUIImage(checks.symbol).resizable().frame(width: 12, height: 12)
                            .foregroundStyle(checks.color).help(checks.title)
                    }
                    Text("\(Text("+\(pull.additions)").foregroundStyle(.green)) \(Text("−\(pull.deletions)").foregroundStyle(.red))")
                        .monospacedDigit()
                }
                .font(.caption)
                .fixedSize()
            }
            PullSentence(pull: pull)
        }
        .contentShape(Rectangle())
        .help("\(pull.title)\n\(pull.url.absoluteString)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([
            "\(pull.state.rawValue) pull request \(pull.reference): \(pull.title)", pull.sentence,
            pull.review?.title, pull.checks?.title, "\(pull.additions) additions, \(pull.deletions) deletions"
        ].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAction(named: "Open on GitHub") { NSWorkspace.shared.open(pull.url) }
    }
}

struct CreateRequest: Identifiable {
    let repositoryRoot: String
    var branch = ""
    var path = ""
    var id: String { repositoryRoot + "\u{0}" + branch }

    static func forBranch(_ branch: BranchRecord) -> CreateRequest { named(branch.name, in: branch.repositoryRoot) }

    /// Suggests a sibling of the primary worktree, such as ~/dev/repo-feature-x for feature/x.
    static func named(_ branch: String, in repositoryRoot: String) -> CreateRequest {
        let root = repositoryRoot as NSString
        let folder = "\(root.lastPathComponent)-\(branch.replacingOccurrences(of: "/", with: "-"))"
        return CreateRequest(repositoryRoot: repositoryRoot, branch: branch,
                             path: (root.deletingLastPathComponent as NSString).appendingPathComponent(folder))
    }
}

struct RepositoryHeader: View {
    let group: RepositoryGroup
    let expanded: Bool
    let pinned: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 16)
            Octicons.swiftUIImage("repo").foregroundStyle(.secondary)
            Text(group.name).font(.title3.bold()).foregroundStyle(.primary)
            if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).help("Pinned") }
            Text(group.records.count == 1 ? "1 worktree" : "\(group.records.count) worktrees").foregroundStyle(.secondary)
            if group.liveAgentCount > 0 {
                Badge(text: "\(group.liveAgentCount) AGENT\(group.liveAgentCount == 1 ? "" : "S") LIVE", color: .blue)
            }
            Spacer()
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
    }
}

struct NewWorktreeSheet: View {
    let request: CreateRequest
    let done: () -> Void
    @State private var branch: String
    @State private var path: String
    @State private var createBranch = false
    @State private var error = ""

    init(request: CreateRequest, done: @escaping () -> Void) {
        self.request = request
        self.done = done
        _branch = State(initialValue: request.branch)
        _path = State(initialValue: request.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Worktree").font(.title2.bold())
            Text((request.repositoryRoot as NSString).abbreviatingWithTildeInPath).font(.caption.monospaced()).foregroundStyle(.secondary).help(request.repositoryRoot)
            TextField(createBranch ? "New branch name" : "Existing branch", text: $branch)
            TextField("Worktree path", text: $path)
            Toggle("Create a new branch", isOn: $createBranch)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    do {
                        try WorktreeActions.create(repositoryRoot: request.repositoryRoot, branch: branch, path: path, createBranch: createBranch)
                        done()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(branch.isEmpty || path.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

enum BarAction {
    case open, codex, claude, diff, fetch, pull, rebase, reveal, github, pin, newWorktree, prune, remove
}

/// One shared row of actions for the selection; full titles when they fit, short ones otherwise.
/// Lets the action bar switch between icon-only and titled buttons.
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<Style: LabelStyle>(_ style: Style) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct ActionBar: View {
    let selected: SelectionActions
    /// Every selected repository is pinned, so Pin becomes Unpin.
    let allPinned: Bool
    let run: (BarAction) -> Void

    private enum Density { case full, short, icons }

    var body: some View {
        // The buttons pick the widest layout that fits first; the selection note takes what's left and truncates.
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                buttons(.full)
                buttons(.short)
                buttons(.icons)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Text(selected.isEmpty ? "Click to select · ⌘-click to add" : "\(selected.count) selected")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func buttons(_ density: Density) -> some View {
        let short = density != .full, icons = density == .icons
        let worktrees = selected.worktrees, repositories = selected.repositories
        let none = "Select worktrees in the list first"
        return HStack(spacing: 6) {
            action(short ? selected.openTitle.short : selected.openTitle.full, "terminal", .open, enabled: !worktrees.isEmpty,
                   help: worktrees.isEmpty ? none : "Jump to a live agent's pane, or open a new Ghostty window in each selected worktree")
            actionButton("Codex", .codex, enabled: !worktrees.isEmpty,
                         help: worktrees.isEmpty ? none : "Start Codex in a new Ghostty window for each selected worktree") {
                ModelLogo(model: "Codex")
            }
            actionButton("Claude", .claude, enabled: !worktrees.isEmpty,
                         help: worktrees.isEmpty ? none : "Start Claude Code in a new Ghostty window for each selected worktree") {
                ModelLogo(model: "Claude")
            }
            Divider().frame(height: 18)
            action(short ? "Diff" : "Show Diff", "plus.forwardslash.minus", .diff, enabled: selected.diff != nil,
                   help: {
                       switch selected.diff {
                       case .worktree?: "Show uncommitted changes"
                       case .pull?: "Show the pull request's changes from GitHub"
                       case nil: "Select one worktree with uncommitted changes, or one pull request"
                       }
                   }())
            action("Fetch", "arrow.down.circle", .fetch, enabled: !repositories.isEmpty,
                   help: repositories.isEmpty ? "Select a worktree, branch, or pull request first" : "git fetch --prune in \(names(repositories))")
            action("Pull", "arrow.down.to.line", .pull, enabled: !selected.pullable.isEmpty,
                   help: selected.pullable.isEmpty ? "Select worktrees whose branch has an upstream"
                       : "git pull --ff-only in \(selected.pullable.count) worktree\(selected.pullable.count == 1 ? "" : "s")")
            action("Rebase", "arrow.triangle.pull", .rebase, enabled: !selected.rebaseable.isEmpty,
                   help: selected.rebaseable.isEmpty ? "Select clean worktrees on a branch with no live agent"
                       : "Rebase onto origin's default branch; a conflicting rebase is aborted")
            Divider().frame(height: 18)
            action(short ? "Finder" : "Reveal in Finder", "folder", .reveal, enabled: !worktrees.isEmpty,
                   help: worktrees.isEmpty ? none : "Reveal the selected worktrees in Finder")
            action(short ? "GitHub" : "Open on GitHub", "arrow.up.right.square", .github, enabled: !repositories.isEmpty,
                   help: repositories.isEmpty ? "Select a worktree, branch, or pull request first"
                       : "Open each selected pull request, and each selected branch on GitHub or its repository when the branch isn't on origin")
            action(allPinned ? "Unpin" : "Pin", allPinned ? "pin.slash" : "pin", .pin, enabled: !repositories.isEmpty,
                   help: repositories.isEmpty ? "Select a worktree, branch, or pull request first"
                       : allPinned ? "Unpin \(names(repositories))" : "Pin \(names(repositories)) to the top of the list")
            action(short ? "New" : "New Worktree", "plus.square.on.square", .newWorktree, enabled: selected.newWorktree != nil,
                   help: selected.newWorktree.map { $0.branch.isEmpty ? "New worktree in \(names([$0.repositoryRoot]))"
                                                                       : "New worktree for \($0.branch)" }
                       ?? "Select items from one repository, with at most one branch")
            action("Prune", "scissors", .prune, enabled: !repositories.isEmpty,
                   help: repositories.isEmpty ? "Select a worktree, branch, or pull request first" : "Prune stale worktree metadata in \(names(repositories))")
            action("Remove", "trash", .remove, enabled: !selected.removable.isEmpty || !selected.deletable.isEmpty,
                   help: selected.removable.isEmpty && selected.deletable.isEmpty
                       ? "Select worktrees that are safe to remove, or branches whose work is already on the default branch"
                       : "Remove the selected safe worktrees and delete the selected merged branches")
        }
        .controlSize(.small)
        .labelStyle(icons ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
        .fixedSize()
    }

    private func action(_ title: String, _ symbol: String, _ action: BarAction, enabled: Bool, help: String) -> some View {
        actionButton(title, action, enabled: enabled, help: help) { Image(systemName: symbol) }
    }

    private func actionButton<Icon: View>(_ title: String, _ action: BarAction, enabled: Bool, help: String,
                                        @ViewBuilder icon: () -> Icon) -> some View {
        Button { run(action) } label: { Label { Text(title) } icon: { icon() }.fixedSize() }
            .disabled(!enabled)
            // Icon-only buttons still name the action first in their tooltip.
            .help(help.hasPrefix(title) ? help : "\(title): \(help)")
    }

    private func names(_ roots: [String]) -> String {
        roots.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }
}

/// Turns off the main list's built-in selection fill (a solid accent color with white text) so rows can draw a
/// lighter tint instead. Re-applied when the selection changes, in case the list resets it.
struct SoftSelection: NSViewRepresentable {
    let selectionCount: Int

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let root = view.window?.contentView else { return }
            var stack = [root]
            while let next = stack.popLast() {
                if let table = next as? NSTableView, table.allowsMultipleSelection, table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                stack += next.subviews
            }
        }
    }
}

/// The refresh arrow and the loading spinner share one slot, so nothing moves when a scan starts or ends.
struct RefreshControl: View {
    let loading: Bool
    let refresh: () -> Void

    var body: some View {
        ZStack {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r")
                .help("Refresh (⌘R)")
                .accessibilityLabel("Refresh")
            }
        }
        .frame(width: 24, height: 24)
    }
}

/// One row under a repository: a worktree or branch, or one of its pull requests.
enum ListRow: Identifiable {
    case worktree(WorktreeRecord)
    case branch(BranchRecord)
    case pull(PullRequestInfo, key: String)

    var id: String {
        switch self {
        case .worktree(let record): record.id
        case .branch(let branch): branch.id
        case .pull(let pull, let key): "pull:" + key + "\u{0}" + pull.url.absoluteString
        }
    }
}

struct WorktreeManagerView: View {
    @StateObject private var model: WorktreeModel
    @FocusState private var searchFocused: Bool
    @State private var createFrom: CreateRequest?
    @State private var diffFor: DiffSource?
    @State private var confirmRemove: RemovalPlan?
    @State private var preparingRemoval = false
    @State private var confirmRebase: [WorktreeRecord]?
    /// Repository roots the user collapsed, newline-separated so the choice survives relaunches.
    @AppStorage("collapsedRepositories") private var collapsedStore = ""
    /// Pinned repository roots, newline-separated; pinned repositories sort first.
    @AppStorage("pinnedRepositories") private var pinnedStore = ""
    var repositoryRoot: String?
    var worktreePath: String?
    var title = "Worktree Manager"
    var showsRefresh = true
    var openOverview: ((WorktreeRecord) -> Void)?
    var showDiff: ((DiffSource) -> Void)?
    var sessionContent: ((WorktreeRecord) -> AnyView)?
    var createSheet: ((CreateRequest, @escaping () -> Void) -> AnyView)?
    var overview: WorktreeRecord? { model.records.first { $0.path == worktreePath } }
    private var groups: [RepositoryGroup] {
        model.groups.filter { repositoryRoot == nil || $0.root == repositoryRoot }
    }

    init(model: WorktreeModel? = nil, repositoryRoot: String? = nil, worktreePath: String? = nil,
         title: String = "Worktree Manager", showsRefresh: Bool = true, openOverview: ((WorktreeRecord) -> Void)? = nil,
         showDiff: ((DiffSource) -> Void)? = nil, sessionContent: ((WorktreeRecord) -> AnyView)? = nil,
         createSheet: ((CreateRequest, @escaping () -> Void) -> AnyView)? = nil) {
        _model = StateObject(wrappedValue: model ?? WorktreeModel())
        self.repositoryRoot = repositoryRoot; self.worktreePath = worktreePath; self.title = title
        self.showsRefresh = showsRefresh
        self.openOverview = openOverview; self.showDiff = showDiff
        self.sessionContent = sessionContent; self.createSheet = createSheet
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(overview?.name ?? title).font(.largeTitle.bold())
                    if let overview {
                        WorktreeRow(record: overview, busy: model.busy.contains(overview.path), compact: false)
                    } else {
                    Text("\(model.records.count) worktrees · \(model.safeCount) safely removable · \(model.protectedCount) protected · \(model.branchCount) branches without a worktree"
                         + (model.openPullCount > 0 ? " · \(model.openPullCount) open pull request\(model.openPullCount == 1 ? "" : "s")" : ""))
                        .foregroundStyle(.secondary)
                    }
                    if let error = model.pullsError {
                        Text("Pull requests: \(error)").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer()
                if showsRefresh {
                    RefreshControl(loading: model.loading || model.loadingPulls) { model.refreshAll() }
                }
            }
            .padding(20)

            if worktreePath == nil { TextField("Search repository, branch, or path", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onExitCommand { searchFocused = false }
                .overlay(alignment: .trailing) {
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: {
                            Label("Clear Search", systemImage: "xmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
            }

            ActionBar(selected: selectedItems, allPinned: !selectedItems.repositories.isEmpty
                      && selectedItems.repositories.allSatisfy(pinned.contains), run: run).padding(.horizontal, 20).padding(.bottom, 8)
                .disabled(!model.busy.isEmpty || preparingRemoval)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 6)
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 20).padding(.bottom, 6)
            }

            if let overview { overviewBody(overview) } else { list }
        }
        .frame(minWidth: openOverview == nil ? 1060 : 660, minHeight: openOverview == nil ? 640 : 540)
        .sheet(item: $createFrom) { request in
            if let createSheet {
                createSheet(request, { createFrom = nil; model.refreshAll() })
            } else {
                NewWorktreeSheet(request: request) { createFrom = nil; model.refresh() }
            }
        }
        .sheet(item: $diffFor) { source in
            DiffSheet(source: source) { diffFor = nil }
        }
        .confirmationDialog(confirmRemove?.title ?? "Remove?", isPresented: present($confirmRemove), presenting: confirmRemove) { plan in
            Button("Remove", role: .destructive) {
                model.performProtected(plan.worktrees, removing: true, branches: plan.branches)
            }
        } message: { plan in
            Text(plan.message)
        }
        .confirmationDialog(rebaseTitle, isPresented: present($confirmRebase), presenting: confirmRebase) { records in
            Button("Rebase") {
                model.performProtected(records, removing: false)
            }
        } message: { records in
            Text("Rebase \(records.map(\.branch).joined(separator: ", ")) onto origin's default branch. "
                 + "Fetch first for the latest commits. A rebase that conflicts is aborted.")
        }
    }

    // MARK: - Actions

    private func run(_ action: BarAction) {
        let selected = selectedItems
        switch action {
        case .open: selected.worktrees.forEach(model.continueWork ?? WorktreeActions.continueWork)
        case .codex: selected.worktrees.forEach(WorktreeActions.startCodex)
        case .claude: selected.worktrees.forEach(WorktreeActions.startClaude)
        case .diff:
            if let showDiff, let source = selected.diff { showDiff(source) } else { diffFor = selected.diff }
        case .fetch:
            model.perform(selected.repositories.map { root in .init(key: root) { try WorktreeActions.fetch(repositoryRoot: root) } })
        case .pull: model.perform(selected.pullable.map { record in .init(key: record.path) { try WorktreeActions.pull(record) } })
        case .rebase: confirmRebase = selected.rebaseable
        case .reveal: WorktreeActions.reveal(selected.worktrees)
        case .newWorktree: createFrom = selected.newWorktree
        case .prune:
            model.perform(selected.repositories.map { root in .init(key: root) { try WorktreeActions.prune(repositoryRoot: root) } })
        case .remove:
            preparingRemoval = true
            Task {
                let result = await Task.detached { Result { try RemovalPlan.prepare(selected) } }.value
                switch result {
                case .success(let plan): confirmRemove = plan
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
                preparingRemoval = false
            }
        case .github: openOnGitHub(selected)
        case .pin:
            var roots = pinned
            if selected.repositories.allSatisfy(roots.contains) { roots.subtract(selected.repositories) }
            else { roots.formUnion(selected.repositories) }
            pinnedStore = roots.sorted().joined(separator: "\n")
        }
    }

    private var pinned: Set<String> { Set(pinnedStore.split(separator: "\n").map(String.init)) }

    /// Opens one page per selected branch (deduplicated), resolving remotes off the main thread.
    private func openOnGitHub(_ selected: SelectionActions) {
        let worktrees = selected.worktrees, branches = selected.branches, pulls = selected.pulls.map(\.pull.url)
        Task {
            let results = await Task.detached { () -> [Result<URL, Error>] in
                let targets: [(String, String?)] =
                    worktrees.map { ($0.repositoryRoot, WorktreeActions.upstreamBranch($0)) }
                    // A branch whose upstream is gone or missing has no page on origin, so open its repository.
                    + branches.map { ($0.repositoryRoot, $0.gone || $0.upstream.isEmpty ? nil : $0.upstream.split(separator: "/", maxSplits: 1).last.map(String.init)) }
                return targets.map { root, branch in Result { try WorktreeActions.webURL(repositoryRoot: root, branch: branch) } }
            }.value
            var opened = Set<URL>()
            for url in pulls where opened.insert(url).inserted { NSWorkspace.shared.open(url) }
            for case .success(let url) in results where opened.insert(url).inserted { NSWorkspace.shared.open(url) }
            let failures = results.compactMap { result -> String? in
                if case .failure(let error) = result { return error.localizedDescription } else { return nil }
            }
            model.errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        }
    }

    private var rebaseTitle: String {
        let count = confirmRebase?.count ?? 0
        return count == 1 ? "Rebase 1 worktree?" : "Rebase \(count) worktrees?"
    }

    /// Selected items that are actually on screen: hidden by search or collapsed groups means not acted on.
    private var selectedItems: SelectionActions {
        if let overview {
            let key = PullRequestLookup.key(repositoryRoot: overview.repositoryRoot, branch: overview.branch)
            let pulls = (model.pulls[key] ?? []).filter { model.selection.contains(ListRow.pull($0, key: key).id) }
            if !pulls.isEmpty { return SelectionActions(pulls: pulls.map { PullSelection(pull: $0, repositoryRoot: overview.repositoryRoot) }) }
            return SelectionActions(worktrees: [overview])
        }
        var selected = SelectionActions()
        func pulls(_ rows: [ListRow], in root: String) -> [PullSelection] {
            rows.compactMap { row in
                guard case .pull(let pull, _) = row, model.selection.contains(row.id) else { return nil }
                return PullSelection(pull: pull, repositoryRoot: root)
            }
        }
        for group in groups where isExpanded(group) {
            selected.worktrees += group.records.filter { model.selection.contains($0.id) }
            selected.pulls += pulls(group.records.flatMap { rows(.worktree($0), key: PullRequestLookup.key(repositoryRoot: $0.repositoryRoot, branch: $0.branch)) },
                                    in: group.root)
            selected.branches += group.branches.filter { model.selection.contains($0.id) }
            selected.pulls += pulls(group.branches.flatMap { rows(.branch($0), key: $0.id) }, in: group.root)
        }
        return selected
    }

    // MARK: - List

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(RepositoryGroup.pinnedFirst(groups, pinned: pinned)) { group in
                let expanded = isExpanded(group)
                if repositoryRoot == nil {
                    Button { toggleCollapsed(group.root) } label: {
                        RepositoryHeader(group: group, expanded: expanded, pinned: pinned.contains(group.root))
                    }
                        .buttonStyle(.plain)
                        .help(expanded ? "Collapse \(group.name)" : "Expand \(group.name)")
                        .tag("repository:" + group.root)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                }
                if expanded {
                    ForEach(group.records.flatMap { record in
                        rows(.worktree(record), key: PullRequestLookup.key(repositoryRoot: record.repositoryRoot, branch: record.branch))
                    }, content: listRow)
                    if !group.branches.isEmpty { branchSection(group) }
                }
            }
        }
        .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in
            // Double-click or Return opens pull requests on GitHub; that never waits for a Git action.
            openPulls(ids)
            guard model.busy.isEmpty, !preparingRemoval else { return }
            // It also opens worktrees, or starts a new worktree for a lone branch.
            let opened = model.records.filter { ids.contains($0.id) }
            if !opened.isEmpty { opened.forEach(model.continueWork ?? WorktreeActions.continueWork); return }
            let branches = model.branches.values.joined().filter { ids.contains($0.id) }
            if branches.count == 1, let branch = branches.first { createFrom = .forBranch(branch) }
        })
        .onExitCommand { model.selection = [] }
        .background(SoftSelection(selectionCount: model.selection.count))
    }

    /// Opens the pull requests among `ids` on GitHub, each once.
    private func openPulls(_ ids: Set<String>) {
        var opened = Set<URL>()
        for key in model.pulls.keys.sorted() {
            for pull in model.pulls[key] ?? [] where ids.contains(ListRow.pull(pull, key: key).id) && opened.insert(pull.url).inserted {
                NSWorkspace.shared.open(pull.url)
            }
        }
    }

    /// A light tint of the user's accent color behind selected rows, in place of the list's solid fill.
    @ViewBuilder
    private func selectionFill(_ id: String) -> some View {
        if model.selection.contains(id) {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.2)).padding(.horizontal, 10)
        } else {
            Color.clear
        }
    }

    /// Branches without a worktree, all shown: active ones first, then merged ones, which wait at the end until cleanup.
    @ViewBuilder
    private func branchSection(_ group: RepositoryGroup) -> some View {
        let ordered = group.branches.filter { !$0.finished } + group.branches.filter(\.finished)
        ForEach(ordered.flatMap { rows(.branch($0), key: $0.id) }, content: listRow)
    }

    /// Single-repository pages have no group header to indent beneath.
    private var rowIndent: CGFloat { repositoryRoot == nil ? 18 : 0 }
    /// Pull requests stay indented beneath their worktree or branch.
    private var pullIndent: CGFloat { rowIndent + 58 }

    /// A worktree or branch, then its recent pull requests, newest first.
    /// Each is its own element: List misplaced rows when one element's row count changed as pull requests loaded.
    private func rows(_ row: ListRow, key: String) -> [ListRow] {
        [row] + (model.pulls[key] ?? []).map { ListRow.pull($0, key: key) }
    }

    @ViewBuilder
    private func listRow(_ row: ListRow) -> some View {
        switch row {
        case .worktree(let record):
            HStack {
            WorktreeRow(record: record, busy: model.busy.contains(record.path),
                        compact: model.pulls[PullRequestLookup.key(repositoryRoot: record.repositoryRoot, branch: record.branch)] == nil)
            if let openOverview {
                Button("Overview") { openOverview(record) }.buttonStyle(.borderless)
            }
            }
                .padding(.leading, rowIndent)
                .tag(record.id)
                .listRowSeparator(.hidden)
                .listRowBackground(selectionFill(record.id))
        case .branch(let branch):
            BranchRow(branch: branch, busy: model.busy.contains(branch.id), compact: model.pulls[branch.id] == nil)
                .padding(.leading, rowIndent)
                .tag(branch.id)
                .listRowSeparator(.hidden)
                .listRowBackground(selectionFill(branch.id))
        case .pull(let pull, _):
            PullRequestRow(pull: pull)
                .padding(.leading, pullIndent)
                // About the same breathing room as worktree rows, so pull requests don't look packed together.
                .padding(.vertical, 3)
                .overlay(alignment: .topLeading) {
                    // Marks a sub-row of the worktree or branch above, beside the title.
                    Text("↳").font(.callout).foregroundStyle(.tertiary).padding(.leading, pullIndent - 18).accessibilityHidden(true)
                }
                .tag(row.id)
                .listRowSeparator(.hidden)
                .listRowBackground(selectionFill(row.id))
        }
    }

    /// A selected repository always shows its contents; search also opens matching groups.
    private func isExpanded(_ group: RepositoryGroup) -> Bool {
        repositoryRoot != nil || !collapsed.contains(group.root) || !model.search.isEmpty
    }

    private var collapsed: Set<String> { Set(collapsedStore.split(separator: "\n").map(String.init)) }

    private func overviewBody(_ record: WorktreeRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !record.agentStateKnown {
                    Label("Agent status unavailable. Removal and rebase are disabled.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button("Changes", systemImage: "plus.forwardslash.minus") {
                    if let showDiff { showDiff(.worktree(record)) } else { diffFor = .worktree(record) }
                }
                if let sessionContent { sessionContent(record) }
                Text("Pull requests").font(.title2.bold())
                let key = PullRequestLookup.key(repositoryRoot: record.repositoryRoot, branch: record.branch)
                let pulls = model.pulls[key] ?? []
                if pulls.isEmpty { Text(model.loadingPulls ? "Loading pull requests…" : "No pull requests").foregroundStyle(.secondary) }
                ForEach(pulls) { pull in
                    let id = ListRow.pull(pull, key: key).id
                    PullRequestRow(pull: pull).padding(8)
                        .background(model.selection.contains(id) ? Color.accentColor.opacity(0.2) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(pull.url) }
                        .onTapGesture { model.selection = model.selection.contains(id) ? [] : [id] }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.onExitCommand { model.selection = [] }
    }

    private func toggleCollapsed(_ root: String) {
        var roots = collapsed
        if roots.remove(root) == nil { roots.insert(root) }
        collapsedStore = roots.sorted().joined(separator: "\n")
    }

    private func present<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// macOS keeps a text field focused when you click a view that can't take focus, such as empty space or a plain
/// SwiftUI button, so the search field stayed highlighted. Any click outside a text input now releases it.
enum FocusReleaser {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window, window.firstResponder is NSText,
                  let content = window.contentView, let frame = content.superview else { return event }
            var view = content.hitTest(frame.convert(event.locationInWindow, from: nil))
            while let current = view, !(current is NSTextField || current is NSText) { view = current.superview }
            if view == nil { window.makeFirstResponder(nil) }
            return event
        }
    }
}

/// A plain click on the only selected row deselects it. Applies to multi-select lists (the main list), not the
/// diff sheet's single-select file list. The list handles the click normally and the row is deselected afterwards;
/// swallowing the click instead left the list ignoring the next click on that row.
enum ClickToDeselect {
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  let content = event.window?.contentView, let frame = content.superview,
                  var view = content.hitTest(frame.convert(event.locationInWindow, from: nil)) else { return event }
            while !(view is NSTableView) {
                guard let parent = view.superview else { return event }
                view = parent
            }
            guard let table = view as? NSTableView, table.allowsMultipleSelection else { return event }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard row >= 0, table.selectedRowIndexes == IndexSet(integer: row) else { return event }
            DispatchQueue.main.async { table.deselectRow(row) }
            return event
        }
    }
}
