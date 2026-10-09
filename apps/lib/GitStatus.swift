import Foundation

/// The p10k-style summary of one checkout: branch, ahead/behind, stashes, and file counts.
struct GitStatus: Equatable {
    var repository = ""
    var branch = ""
    var ahead = 0, behind = 0, stashes = 0, conflicted = 0, staged = 0, unstaged = 0, untracked = 0

    var summary: String {
        let counts = [(behind, "behind"), (ahead, "ahead"), (stashes, "stashes"), (conflicted, "conflicted"),
                      (staged, "staged"), (unstaged, "unstaged"), (untracked, "untracked")]
        let parts = counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Clean" : parts.joined(separator: ", ")
    }

    /// Parses `git status --porcelain=v2 --branch --show-stash`.
    init(porcelain: String) {
        var oid = ""
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.oid ") { oid = String(line.dropFirst(13)) }
            else if line.hasPrefix("# branch.head ") { branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                behind = parts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
            } else if line.hasPrefix("# stash ") { stashes = Int(line.dropFirst(8)) ?? 0 }
            else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // "1 XY ...": X is the index (staged) side, Y the worktree (unstaged) side.
                let codes = Array(line.dropFirst(2).prefix(2))
                if codes.count == 2 {
                    if codes[0] != "." { staged += 1 }
                    if codes[1] != "." { unstaged += 1 }
                }
            } else if line.hasPrefix("u ") { conflicted += 1 }
            else if line.hasPrefix("? ") { untracked += 1 }
        }
        if branch == "(detached)" { branch = "@" + oid.prefix(8) }
    }

    /// Runs one status per checkout. `--no-optional-locks` never takes the index lock an agent may need.
    static func load(repository: String) -> GitStatus? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--no-optional-locks", "-C", repository, "status", "--porcelain=v2", "--branch", "--show-stash"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        var status = GitStatus(porcelain: text)
        status.repository = repository
        return status
    }

    /// Resolve working directories independently of UI project groups, which can span worktrees.
    /// Each checkout is read once, even when several live sessions use its subdirectories.
    static func snapshots(directories: [String]) -> [String: GitStatus] {
        var roots: [String: String] = [:]
        for directory in Set(directories) where directory.hasPrefix("/") {
            var url = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
            while url.path != "/" {
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    roots[directory] = url.path
                    break
                }
                url.deleteLastPathComponent()
            }
        }
        let repositories = Array(Set(roots.values))
        guard !repositories.isEmpty else { return [:] }
        let workers = min(4, repositories.count)
        let lock = NSLock()
        var snapshots: [String: GitStatus] = [:]
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var results: [String: GitStatus] = [:]
            for index in stride(from: worker, to: repositories.count, by: workers) {
                let root = repositories[index]
                if let status = load(repository: root) { results[root] = status }
            }
            lock.lock()
            snapshots.merge(results) { _, new in new }
            lock.unlock()
        }
        return roots.compactMapValues { snapshots[$0] }
    }
}
