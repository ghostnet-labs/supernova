import SwiftUI

enum WorkspaceAgent: String, CaseIterable, Identifiable {
    case none = "None", codex = "Codex", claude = "Claude"
    var id: String { rawValue }

    func launch(in path: String) throws {
        guard self != .none else { return }
        let command = self == .codex ? "codex" : "claude"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Verify the login shell's PATH before asking Ghostty to execute the agent.
        _ = try GitTool.run(["-lic", "command -v \(command) >/dev/null"], executable: shell, timeout: 10)
        _ = try GitTool.run(["-na", "Ghostty.app", "--args", "--window-save-state=never",
                            "--quit-after-last-window-closed=true", "--working-directory=\(path)",
                            "--initial-command=\(shell) -lic 'exec \(command)'"], executable: "/usr/bin/open", timeout: 10)
    }
}

/// Creation and launch are separate steps: a failed launch must never create a second checkout.
@MainActor
final class WorkspaceCreation: ObservableObject {
    @Published private(set) var createdPath: String?
    @Published private(set) var busy = false
    @Published var error: String?

    func submit(request: CreateRequest, branch: String, path: String, createBranch: Bool, agent: WorkspaceAgent,
                create: @escaping @Sendable (String, String, String, Bool) throws -> Void = { try WorktreeActions.create(repositoryRoot: $0, branch: $1, path: $2, createBranch: $3) },
                launch: @escaping @Sendable (WorkspaceAgent, String) throws -> Void = { try $0.launch(in: $1) }) async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil
        defer { busy = false }
        do {
            if createdPath == nil {
                let target = (path as NSString).expandingTildeInPath
                try await Task.detached { try create(request.repositoryRoot, branch, target, createBranch) }.value
                createdPath = target
            }
            let target = createdPath!
            try await Task.detached { try launch(agent, target) }.value
            return true
        } catch {
            self.error = (createdPath == nil ? "" : "Worktree created. Agent launch failed; retry or close this sheet. ") + error.localizedDescription
            return false
        }
    }
}

struct WorkspaceCreateSheet: View {
    let request: CreateRequest
    @ObservedObject var model: WorktreeModel
    let done: () -> Void
    @StateObject private var creation = WorkspaceCreation()
    @State private var branch: String
    @State private var path: String
    @State private var createBranch = false
    @State private var agent: WorkspaceAgent = .none

    init(request: CreateRequest, model: WorktreeModel, done: @escaping () -> Void) {
        self.request = request; self.model = model; self.done = done
        _branch = State(initialValue: request.branch); _path = State(initialValue: request.path)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Worktree").font(.title2.bold())
            Text((request.repositoryRoot as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
            Group {
                TextField(createBranch ? "New branch name" : "Existing branch", text: $branch)
                TextField("Worktree path", text: $path)
                Toggle("Create a new branch", isOn: $createBranch)
            }.disabled(creation.createdPath != nil || creation.busy)
            Picker("Launch after creation", selection: $agent) {
                ForEach(WorkspaceAgent.allCases) { Text($0.rawValue).tag($0) }
            }.disabled(creation.busy)
            if let error = creation.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if creation.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(creation.createdPath == nil ? "Cancel" : "Done", action: done)
                    .keyboardShortcut(.cancelAction).disabled(creation.busy)
                Button(creation.createdPath == nil ? "Create" : "Retry Launch") {
                    Task {
                        if await creation.submit(request: request, branch: branch, path: path, createBranch: createBranch, agent: agent) { done() }
                        else { model.refresh() }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(branch.isEmpty || path.isEmpty || creation.busy || !model.busy.isEmpty)
            }
        }.padding(20).frame(width: 540).interactiveDismissDisabled(creation.busy)
    }
}
