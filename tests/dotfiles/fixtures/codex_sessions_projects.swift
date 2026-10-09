import Foundation

@main struct ProjectChecks {
    static func main() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        func directory(_ path: String) throws -> String {
            let url = base.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        }
        func expect(_ condition: Bool, _ message: String) {
            if !condition {
                print("FAIL: \(message)")
                exit(1)
            }
        }
        let repo = try directory("first/repo")
        _ = try directory("first/repo/.git")
        let nested = try directory("first/repo/apps/client")
        let secondRepo = try directory("second/repo/.git")
        let secondRoot = URL(fileURLWithPath: secondRepo).deletingLastPathComponent().path
        let worktree = try directory("worktree")
        try "gitdir: /example/repo/.git/worktrees/test\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        let loose = try directory("Downloads")
        let configured = try directory("configured")
        let configuredChild = try directory("configured/subfolder")
        let prefixSibling = try directory("configured-other")
        let link = base.appendingPathComponent("repo-link").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: repo)
        var resolver = ProjectResolver()
        let rootProject = resolver.resolve(repo)
        expect(rootProject.path == repo, "recognize repository root")
        expect(resolver.resolve(nested) == rootProject, "group nested directories under repository")
        expect(resolver.resolve(link) == rootProject, "group symlinked directories under repository")
        expect(resolver.resolve(worktree).path == worktree, "recognize Git worktree file")
        expect(resolver.resolve(secondRoot).id != rootProject.id, "separate repositories with the same name")
        for cwd in [loose, base.path, repo + "/missing", "", "-", "relative/path"] {
            expect(resolver.resolve(cwd) == .other, "incidental or missing directory belongs in Other sessions")
        }
        let registration = SessionProject(id: "project:test", name: "Named project", path: configured)
        let override = SessionProject(id: "project:nested", name: "Nested project", path: nested)
        var registered = ProjectResolver(registered: [registration, override])
        expect(registered.resolve(configuredChild) == registration, "configured non-Git roots include descendants")
        expect(registered.resolve(nested) == override, "explicit project takes precedence over Git root")
        expect(registered.resolve(prefixSibling) == .other, "root matching respects path boundaries")
        let groups = ProjectSummary.group([rootProject, resolver.resolve(nested), resolver.resolve(secondRoot), .other])
        expect(groups.count == 3, "same-name repositories remain distinct groups")
        expect(groups.first(where: { $0.id == rootProject.id })?.count == 2, "count all sessions under a root")
        expect(groups.last?.id == SessionProject.other.id, "Other sessions sorts last")
        expect(ProjectSummary.group([]).isEmpty, "empty history has no project groups")
        try fm.removeItem(atPath: repo + "/.git")
        var refreshed = ProjectResolver()
        expect(refreshed.resolve(nested) == .other, "refresh recognizes removed Git roots")
        try fm.removeItem(atPath: configured)
        var missingRegistration = ProjectResolver(registered: [registration])
        expect(missingRegistration.resolve(configuredChild) == .other, "missing registered roots do not create projects")
        print("PASS: project roots, worktrees, symlinks, grouping, identities, and refresh")
    }
}
