import Foundation

struct SessionProject: Hashable {
    let id: String
    let name: String
    let path: String

    static let other = SessionProject(id: "other", name: "Other sessions", path: "")
}

// One resolver per refresh avoids repeating filesystem checks for shared directories.
struct ProjectResolver {
    private let registered: [SessionProject]
    private var cache: [String: SessionProject] = [:]

    init(registered: [SessionProject] = []) {
        self.registered = registered.compactMap { project in
            guard let root = Self.directory(project.path) else { return nil }
            return SessionProject(id: project.id, name: project.name, path: root.path)
        }.sorted { $0.path.count > $1.path.count }
    }

    mutating func resolve(_ cwd: String) -> SessionProject {
        if let project = cache[cwd] { return project }
        let project = findProject(cwd)
        cache[cwd] = project
        return project
    }

    private func findProject(_ cwd: String) -> SessionProject {
        guard var directory = Self.directory(cwd) else { return .other }
        if let project = registered.first(where: {
            directory.path == $0.path || directory.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/")
        }) {
            return project
        }
        while true {
            // Git worktrees use a .git file; ordinary repositories use a directory.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return SessionProject(id: "git:" + directory.path, name: directory.lastPathComponent, path: directory.path)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return .other }
            directory = parent
        }
    }

    private static func directory(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}
