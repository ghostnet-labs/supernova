import Foundation

@main struct SharedSessionDetailsChecks {
    static func main() {
        let parsed = GitStatus(porcelain: """
        # branch.oid 123456789abcdef
        # branch.head (detached)
        # branch.ab +3 -2
        # stash 4
        1 M. staged
        1 .M unstaged
        2 RM renamed
        u UU conflicted
        ? untracked
        """)
        precondition(parsed.branch == "@12345678")
        precondition(parsed.ahead == 3 && parsed.behind == 2 && parsed.stashes == 4)
        precondition(parsed.staged == 2 && parsed.unstaged == 2 && parsed.conflicted == 1 && parsed.untracked == 1)
        precondition(GitStatus(porcelain: "# branch.head main").summary == "Clean")

        let now = Date(timeIntervalSince1970: 200_000)
        for (seconds, expected) in [(0, "0s"), (59, "59s"), (60, "1m"), (3599, "59m"), (3600, "1h"), (86400, "1d")] {
            precondition(StatusPill.elapsed(since: now.addingTimeInterval(-Double(seconds)), until: now) == expected)
        }
        precondition(StatusPill.elapsed(since: nil, until: now).isEmpty)
        precondition(StatusPill.elapsed(since: now.addingTimeInterval(10), until: now) == "0s")

        let args = CommandLine.arguments
        let repository = args[1], subdirectory = args[2], worktree = args[3], nonRepository = args[4]
        let started = Date()
        let snapshots = GitStatus.snapshots(directories: Array(repeating: repository, count: 1000)
                                           + [subdirectory, worktree, nonRepository, "relative/path"])
        precondition(snapshots.count == 3)
        precondition(snapshots[repository] == snapshots[subdirectory], "Subdirectories must share their checkout snapshot")
        let checkout = snapshots[repository]!
        precondition(checkout.branch == "main" && checkout.repository == URL(fileURLWithPath: repository).standardizedFileURL.resolvingSymlinksInPath().path)
        precondition(checkout.staged == 1 && checkout.unstaged == 1 && checkout.untracked == 1)
        precondition(snapshots[worktree]?.branch == "details-worktree", "Worktrees must retain their own branch")
        precondition(snapshots[worktree]?.repository == URL(fileURLWithPath: worktree).standardizedFileURL.resolvingSymlinksInPath().path)
        precondition(snapshots[nonRepository] == nil)
        print("PASS: shared Git parsing, checkout deduplication, worktrees, index-lock coexistence, and elapsed status")
        print(String(format: "Two checkout snapshots for 1,004 directory entries: %.1f ms", Date().timeIntervalSince(started) * 1000))
    }
}
