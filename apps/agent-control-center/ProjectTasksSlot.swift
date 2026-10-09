import SwiftUI
import AppKit

struct ProjectTasksSlot: View {
    let projectID: String
    let database: AgentDatabase
    @State private var coordinator: Coordinator?
    @State private var error: String?
    var body: some View {
        Group {
            if let coordinator { ProjectTaskList(coordinator: coordinator) }
            else if let error { ContentUnavailableView("Tasks unavailable", systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView("Loading saved tasks") }
        }.task(id: projectID) {
            do {
                guard let project = try await database.read({ db in try db.query("SELECT * FROM projects WHERE id=?", [projectID]).first.map(ProjectMemoryStore.project) }) else {
                    throw AgentStorageError.invalid("Project no longer exists.")
                }
                let context = ManagedConversationContext(projectID: project.id, name: project.name, cwd: project.workingDirectory)
                let value = CoordinatorRegistry.store(context: context, database: database)
                await value.load(); coordinator = value
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct DelegationControls: View {
    @ObservedObject var coordinator: Coordinator
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { toggles; Spacer(); state }
            VStack(alignment: .leading, spacing: 6) { toggles; state }
        }.font(.caption)
    }
    private var toggles: some View {
        HStack {
            Toggle("Delegate research", isOn: $coordinator.allowResearch)
            Toggle("Delegate code changes", isOn: $coordinator.allowImplementation)
        }.toggleStyle(.checkbox)
            .help("These choices apply when you next send or steer a human instruction. Code tasks use separate Git worktrees from committed HEAD; uncommitted edits are not copied.")
    }
    private var state: some View {
        HStack {
            Text("\(coordinator.runningCount) active tasks")
            if coordinator.paused { Button("Resume dispatch") { Task { await coordinator.resumeDispatch() } } }
            else { Button("Pause coordinator") { Task { await coordinator.pause() } } }
        }
    }
}

struct ProjectTaskList: View {
    @ObservedObject var coordinator: Coordinator
    @State private var expanded: Set<String> = []
    @State private var continuation: ManagedTaskRecord?
    @State private var continuationText = "Continue the saved task and satisfy its completion checks."
    @State private var verification: ManagedTaskRecord?
    @State private var verificationText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { title; Spacer(); controls }
                VStack(alignment: .leading) { title; controls }
            }
            if let error = coordinator.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if coordinator.paused {
                Text("Dispatch is paused. Saved tasks need an explicit continuation after a restart; reconnecting checks existing provider state.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            if coordinator.tasks.isEmpty {
                ContentUnavailableView("No project tasks", systemImage: "checklist", description: Text("Enable delegation beside the Conversation composer, then describe the work to delegate. Tasks will show their objective, evidence, and result here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(coordinator.tasks) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(task.objective).font(.headline).textSelection(.enabled)
                                    Spacer()
                                    Text(task.state.rawValue).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(color(task.state).opacity(0.14), in: Capsule())
                                }
                                Text("\(task.provider) · \(task.mode.rawValue) · \(task.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                Text(task.latestUpdate).textSelection(.enabled)
                                Text(task.cwd).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                                actions(task)
                                DisclosureGroup("Deliverable and completion evidence", isExpanded: Binding(get: { expanded.contains(task.id) }, set: { if $0 { expanded.insert(task.id) } else { expanded.remove(task.id) } })) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Requested: " + task.expectedDeliverable).textSelection(.enabled)
                                        ForEach(task.checks) { check in
                                            let result = task.deliverable?.checks.first { $0.checkID == check.id }
                                            Label(check.description, systemImage: result?.passed == true ? "checkmark.circle" : "circle.dashed")
                                            Text(result?.evidence ?? "\(check.kind.rawValue): \(check.target)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                        if let result = task.deliverable {
                                            Text(result.content).textSelection(.enabled)
                                            ForEach(result.files, id: \.self) { file in
                                                Button(file) { if let path = TaskWorktrees.relativeArtifact(file, cwd: task.cwd) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }.buttonStyle(.link)
                                            }
                                        } else if !task.lastAssistantText.isEmpty { Text(task.lastAssistantText).textSelection(.enabled) }
                                        Text(task.independentlyVerified ? "Independent verification: \(task.verificationEvidence)" : "Independent verification: not performed").font(.caption).foregroundStyle(.secondary)
                                        if let thread = task.nativeThreadID { Text("Native thread \(thread)").font(.caption.monospaced()).textSelection(.enabled) }
                                    }.padding(.top, 6)
                                }
                                ForEach(coordinator.requests.filter { $0.threadID == task.nativeThreadID }) { request in
                                    ManagedRequestView(request: request, item: coordinator.approvalItems[request.params["itemId"].string ?? ""] ?? .null) { result in Task { await coordinator.respond(request, result: result) } }
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }.padding().task { await coordinator.load() }
        .sheet(item: $continuation) { task in
            VStack(alignment: .leading, spacing: 12) {
                Text("Continue task").font(.headline)
                Text(task.objective).lineLimit(4)
                TextField("Additional instruction", text: $continuationText, axis: .vertical).lineLimit(4...10)
                Text("Continues from saved conversation context. It does not restore a shell command halfway through execution.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Cancel") { continuation = nil }; Spacer(); Button("Continue") { let text = continuationText; continuation = nil; Task { await coordinator.continueTask(task.id, instruction: text) } }.disabled(continuationText.isEmpty) }
            }.padding(20).frame(width: 480)
        }
        .sheet(item: $verification) { task in
            VStack(alignment: .leading, spacing: 12) {
                Text("Record independent verification").font(.headline)
                Text("Describe the test or artifact you inspected, with a path, command result, or source reference.")
                TextField("Verification evidence", text: $verificationText, axis: .vertical).lineLimit(4...10)
                HStack { Button("Cancel") { verification = nil }; Spacer(); Button("Save verification") { let text = verificationText; verification = nil; Task { await coordinator.verify(task.id, evidence: text) } }.disabled(verificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(20).frame(width: 480)
        }
    }
    private var title: some View { Label("Project tasks", systemImage: "checklist").font(.headline) }
    private var controls: some View {
        HStack {
            Stepper("Concurrent tasks: \(coordinator.simultaneousLimit)", value: $coordinator.simultaneousLimit, in: 1...8).fixedSize()
            if coordinator.paused { Button("Resume dispatch") { Task { await coordinator.resumeDispatch() } } }
            else { Button("Pause all") { Task { await coordinator.pause() } } }
        }
    }
    @ViewBuilder private func actions(_ task: ManagedTaskRecord) -> some View {
        HStack {
            Button("Open checkout") { NSWorkspace.shared.open(URL(fileURLWithPath: task.cwd)) }
            if task.recoveryRequired || task.state == .unknown { Button("Reconcile") { Task { await coordinator.reconcile(task.id) } } }
            else if [.paused, .failed, .needsInput].contains(task.state), !coordinator.requests.contains(where: { $0.threadID == task.nativeThreadID }) {
                Button("Continue…") { continuationText = "Continue the saved task and satisfy its completion checks."; continuation = task }
            }
            if !task.state.terminal { Button("Cancel task") { Task { await coordinator.cancel(task.id) } } }
            if task.state == .completed { Button("Verify…") { verificationText = task.verificationEvidence; verification = task } }
        }.font(.caption)
    }
    private func color(_ state: ManagedTaskState) -> Color {
        switch state { case .completed: return .green; case .failed: return .red; case .needsInput, .unknown: return .orange; case .running: return .blue; default: return .secondary }
    }
}
