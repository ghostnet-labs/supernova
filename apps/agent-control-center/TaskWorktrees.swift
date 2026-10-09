import Foundation

enum TaskWorktrees {
    /// No shell evaluation, hooks, setup scripts, or remote operations are involved.
    static func prepare(task: ManagedTaskRecord, directory: URL) async throws -> (String, String) {
        try await Task.detached(priority: .utility) {
            guard task.mode == .implementation, let repository = MemoryRepositoryIdentity.resolve(task.baseCWD) else {
                throw AgentStorageError.invalid("Code tasks require a Git repository. Choose a repository project or a read-only task.")
            }
            if task.selectedWorktree {
                guard let selected = MemoryRepositoryIdentity.resolve(task.cwd), selected.common == repository.common,
                      selected.root != repository.root else { throw AgentStorageError.invalid("Select a separate worktree belonging to this repository.") }
                return (selected.root, try run(["-C", selected.root, "rev-parse", "--abbrev-ref", "HEAD"]))
            }
            guard UUID(uuidString: task.id) != nil, UUID(uuidString: task.projectID) != nil else { throw AgentStorageError.invalid("Invalid task or project identity.") }
            let parent = directory.appendingPathComponent("task-worktrees", isDirectory: true).appendingPathComponent(task.projectID, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let target = parent.appendingPathComponent(task.id, isDirectory: true)
            let branch = "codex/acc-" + task.id.lowercased()
            if FileManager.default.fileExists(atPath: target.path) {
                guard let existing = MemoryRepositoryIdentity.resolve(target.path), existing.root == target.resolvingSymlinksInPath().path,
                      existing.common == repository.common,
                      try run(["-C", target.path, "rev-parse", "--abbrev-ref", "HEAD"]) == branch else {
                    throw AgentStorageError.invalid("The task worktree path already exists and cannot safely be reused.")
                }
                return (target.path, branch)
            }
            let revision = try run(["-C", repository.root, "rev-parse", "--verify", "HEAD^{commit}"])
            _ = try run(["-C", repository.root, "-c", "core.hooksPath=/dev/null", "worktree", "add", "-b", branch, target.path, revision])
            return (target.path, branch)
        }.value
    }
    static func relativeArtifact(_ path: String, cwd: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { return nil }
        let root = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        return target.path.hasPrefix(root.path + "/") ? target.path : nil
    }
    private static func run(_ arguments: [String]) throws -> String {
        let child = Process(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/git"); child.arguments = arguments
        child.standardOutput = output; child.standardError = output; child.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        child.environment = environment
        try child.run()
        let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit(); timeout.cancel()
        let text = String(decoding: data.prefix(16_384), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard child.terminationStatus == 0 else { throw AgentStorageError.invalid("Git worktree preparation failed: " + text) }
        return text
    }
}
