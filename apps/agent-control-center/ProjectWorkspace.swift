import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ProjectWorkspaceModel: ObservableObject {
    @Published var projects: [MemoryProject] = []
    @Published var project: MemoryProject?
    @Published var scope = "Personal"
    @Published var workJob = ""
    @Published var query = ""
    @Published var hits: [MemoryHit] = []
    @Published var decisions: [ProjectDecision] = []
    @Published var coverage = IndexCoverage()
    @Published var summary = ""
    @Published var error: String?
    @Published var indexing = false
    @Published var selectedSource: MemoryHit?
    @Published var editingDecision: ProjectDecision?
    @Published var importChoices: [MemoryImportConversation] = []
    @Published var importSelection: Set<String> = []
    @Published var importURL: URL?
    @Published private(set) var database: AgentDatabase?
    private var memory: ProjectMemoryStore?
    private var indexingTask: Task<Void,Never>?
    private var searchTask: Task<Void,Never>?
    private let automaticLoad: Bool
    init(automaticLoad: Bool = true) { self.automaticLoad = automaticLoad }
    var selectedScope: String { scope == "Personal" ? "Personal" : "work:" + workJob.trimmingCharacters(in:.whitespacesAndNewlines) }

    func load() async {
        guard automaticLoad else { return }
        do {
            if memory == nil { let database = try AgentDatabase(); self.database = database; memory = ProjectMemoryStore(database:database) }
            projects = try await memory!.projects(scope:selectedScope)
            if let project, !projects.contains(where: { $0.id == project.id }) { select(nil) }
        } catch { self.error = error.localizedDescription }
    }

    func select(_ value: MemoryProject?) {
        pause()
        searchTask?.cancel()
        project = value; hits = []; decisions = []; coverage = IndexCoverage(); summary = ""
        Task { await refresh() }
    }
    func refresh() async {
        guard let memory, let selected = project else { return }
        do {
            let records = try await memory.decisions(projectID:selected.id)
            let progress = try await memory.coverage(projectID:selected.id)
            let text = try await memory.summary(projectID:selected.id)
            guard project?.id == selected.id else { return }
            decisions = records; coverage = progress; summary = text
        } catch { self.error = error.localizedDescription }
    }
    func addProject(relink: Bool = false) {
        if scope != "Personal" && workJob.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { error = "Enter the Work job before opening its separate project list."; return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = relink ? "Relink project":"Add project"
        guard panel.runModal() == .OK, let path = panel.url?.path, let memory else { return }
        let selected = project, scope = selectedScope
        Task {
            do {
                let value: MemoryProject
                if relink, let selected { value = try await memory.relink(project:selected,path:path) }
                else { value = try await memory.attachProject(path:path,scope:scope) }
                await load(); select(value)
            } catch { self.error = error.localizedDescription }
        }
    }
    func search() {
        searchTask?.cancel()
        guard let memory, let selected = project else { return }
        let query = query
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds:150_000_000)
                let results = try await memory.search(projectID:selected.id,query:query)
                guard !Task.isCancelled, project?.id == selected.id else { return }
                hits = results
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func index(sessions: [CodexSession], backfill: Bool = false) {
        pause()
        guard let memory, let selected = project else { return }
        indexing = true
        indexingTask = Task {
            defer { indexing = false }
            do {
                // Register only this explicitly selected project. No global history scan.
                var sourceIDs: [String] = []
                var memberships: [String:Bool] = [:]
                for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                    try Task.checkCancellation()
                    let belongs: Bool
                    if let cached = memberships[session.cwd] { belongs = cached }
                    else { belongs = try await memory.contains(project:selected,cwd:session.cwd); memberships[session.cwd] = belongs }
                    guard belongs else { continue }
                    let source = try await memory.registerSource(projectID:selected.id,provider:session.source.rawValue,sessionID:session.nativeID,title:session.title,path:session.path.path)
                    sourceIDs.append(source.id)
                }
                let imported = try await memory.sources(projectID:selected.id).filter { $0.provider.hasSuffix("import") }.map(\.id)
                var pending = Array(sourceIDs.prefix(backfill ? sourceIDs.count:50)) + imported
                await refresh()
                while !pending.isEmpty {
                    var next: [String] = []
                    for id in pending {
                        try Task.checkCancellation()
                        let progress = try await memory.index(sourceID:id)
                        if progress.hasMore { next.append(id) }
                        await refresh()
                        try await Task.sleep(nanoseconds:20_000_000)
                    }
                    pending = next
                }
                search()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func pause() { indexingTask?.cancel(); indexingTask = nil; indexing = false }
    func open(_ reference: SourceReference) {
        guard let memory else { return }
        Task { do { selectedSource = try await memory.openSource(reference) } catch { self.error = error.localizedDescription } }
    }
    func capture(_ hit: MemoryHit) {
        guard let project else { return }
        editingDecision = ProjectDecision(id:UUID().uuidString,projectID:project.id,title:String(hit.text.prefix(90)),detail:hit.text,evidence:[DecisionEvidence(id:UUID().uuidString,kind:"source",detail:"Captured from selected message",source:hit.source)])
    }
    func save(_ decision: ProjectDecision) {
        guard let memory else { return }
        Task {
            do { try await memory.saveDecision(decision,userAction:true); editingDecision = nil; await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func importFile(chatGPT: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = chatGPT ? [.json]:[.plainText,.text]
        guard panel.runModal() == .OK, let url = panel.url, let memory, let project else { return }
        Task {
            do {
                if chatGPT {
                    importChoices = try await Task.detached(priority:.utility) { try MemoryImport.preview(url) }.value
                    importSelection = []; importURL = url
                } else {
                    let source = try await memory.importDocument(url:url,projectID:project.id)
                    var more = true
                    while more { more = try await memory.index(sourceID:source.id).hasMore; await Task.yield() }
                    await refresh(); search()
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func importSelected() {
        guard let url = importURL, let memory, let project else { return }
        let selection = importSelection; importURL = nil
        Task {
            do {
                let sources = try await memory.importChatGPT(url:url,selectedIDs:selection,projectID:project.id)
                for source in sources {
                    var more = true
                    while more { more = try await memory.index(sourceID:source.id).hasMore; await Task.yield() }
                }
                await refresh(); search()
            } catch { self.error = error.localizedDescription }
        }
    }
    func backup() {
        guard let memory else { return }
        Task { do { let url = try await memory.database.backup(); NSWorkspace.shared.activateFileViewerSelecting([url]) } catch { self.error = error.localizedDescription } }
    }
}

struct ProjectWorkspaceView: View {
    @ObservedObject var sessionStore: SessionStore
    let onClose: (() -> Void)?
    @StateObject private var model: ProjectWorkspaceModel
    @StateObject private var hardware = HardwareReportModel()
    @State private var tab = "Memory"
    init(sessionStore: SessionStore, model: ProjectWorkspaceModel? = nil, onClose: (() -> Void)? = nil) {
        self.sessionStore = sessionStore
        self.onClose = onClose
        _model = StateObject(wrappedValue:model ?? ProjectWorkspaceModel())
    }
    var body: some View {
        HSplitView {
            VStack(alignment:.leading,spacing:12) {
                if let onClose { Button("Back to conversations",action:onClose).font(.caption) }
                Text("Project workspace").font(.title2.bold())
                Picker("Scope",selection:$model.scope) { Text("Personal").tag("Personal"); Text("Work").tag("Work") }.pickerStyle(.segmented)
                    .onChange(of:model.scope) { _,_ in model.select(nil); Task { await model.load() } }
                if model.scope == "Work" {
                    TextField("Work job",text:$model.workJob).onSubmit { Task { await model.load() } }
                    Button("Open Work projects") { model.select(nil); Task { await model.load() } }.disabled(model.workJob.isEmpty)
                    Text("Scope is explicit. Opening Personal does not load Work project memory.").font(.caption).foregroundStyle(.secondary)
                }
                List(model.projects,selection:Binding(get:{model.project?.id},set:{ id in model.select(model.projects.first { $0.id == id }) })) { project in
                    VStack(alignment:.leading) { Text(project.name); if project.isMissing { Label("Directory missing",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) } }.tag(project.id)
                }
                Button("Add project…") { model.addProject() }
                Button("Back up project data") { model.backup() }.font(.caption)
            }.padding().frame(minWidth:210,idealWidth:240,maxWidth:310,maxHeight:.infinity,alignment:.topLeading)
            if let project = model.project {
                VStack(alignment:.leading,spacing:10) {
                    HStack {
                        VStack(alignment:.leading) { Text(project.name).font(.title2.bold()); Text("\(project.scope) · \(project.workingDirectory)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Spacer(); Button("Relink…") { model.addProject(relink:true) }
                    }
                    if project.isMissing { Label("Project directory is missing. Memory is retained; relink before executing work.",systemImage:"exclamationmark.triangle").foregroundStyle(.orange) }
                    Picker("Workspace",selection:$tab) { ForEach(["Conversation","Tasks","Memory","Hardware"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    switch tab {
                    case "Conversation":
                        if let database = model.database {
                            if !hardware.context(projectID:project.id).isEmpty { Text("Hardware snapshot included with the next message. Manage it in Hardware.").font(.caption).foregroundStyle(.secondary) }
                            ProjectConversationSlot(context:ManagedConversationContext(projectID:project.id,name:project.name,cwd:project.workingDirectory,retrievedContext:hardware.context(projectID:project.id) + [model.summary] + model.hits.prefix(8).map { "Context source \($0.id): \($0.text)" }),database:database)
                        }
                    case "Tasks":
                        if let database = model.database { ProjectTasksSlot(projectID:project.id,database:database) }
                    case "Hardware": HardwareReportView(model:hardware)
                    default: memory(project)
                    }
                }.padding().frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            } else {
                ContentUnavailableView("Choose a project",systemImage:"folder",description:Text("Add a directory to create durable project memory. Git worktrees share one project within the selected scope."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .task { await model.load() }
        .task(id:model.project?.id) {
            if let project = model.project, let database = model.database { await hardware.load(projectID:project.id,database:database) }
        }
        .onDisappear { model.pause() }
        .alert("Project memory",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error = nil}})) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(item:$model.selectedSource) { hit in sourceSheet(hit) }
        .sheet(item:$model.editingDecision) { decision in DecisionEditor(decision:decision,onSave:model.save,onCancel:{model.editingDecision = nil}) }
        .sheet(isPresented:Binding(get:{model.importURL != nil},set:{if !$0 {model.importURL = nil}})) { importSheet }
    }

    private func memory(_ project: MemoryProject) -> some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                TextField("Search visible project messages",text:$model.query).textFieldStyle(.roundedBorder).onChange(of:model.query) { _,_ in model.search() }
                Menu("Import") { Button("Selected ChatGPT conversations…") { model.importFile(chatGPT:true) }; Button("Text or Markdown document…") { model.importFile(chatGPT:false) } }
            }
            Text(model.coverage.description).font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.indexing { ProgressView().controlSize(.small); Button("Pause indexing") { model.pause() } }
                else {
                    Button("Index recent history") { model.index(sessions:sessionStore.sessions) }
                    Button("Backfill all project history") { model.index(sessions:sessionStore.sessions,backfill:true) }
                }
                Spacer()
                Button("New decision") { model.editingDecision = ProjectDecision(id:UUID().uuidString,projectID:project.id,title:"",detail:"") }
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:16) {
                    if !model.query.isEmpty {
                        if model.hits.isEmpty { Text("No indexed matches. Check coverage or index more history.").foregroundStyle(.secondary) }
                        ForEach(model.hits) { hit in
                            VStack(alignment:.leading,spacing:6) {
                                Text("\(hit.title) · \(hit.source.provider) · \(hit.role)").font(.headline)
                                Text(hit.source.timestamp).font(.caption).foregroundStyle(.secondary)
                                Text(hit.text).textSelection(.enabled).lineLimit(8)
                                HStack { Button("Open original message") { model.open(hit.source) }; Button("Capture decision") { model.capture(hit) } }.font(.caption)
                            }.padding().frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                        }
                    }
                    Text("Decisions").font(.headline)
                    if model.decisions.isEmpty { Text("Capture a decision from a message or add one manually. Acceptance and delivery are tracked separately.").foregroundStyle(.secondary) }
                    ForEach(model.decisions) { decision in
                        VStack(alignment:.leading,spacing:6) {
                            HStack { Text(decision.title).font(.headline); Spacer(); Button("Edit") { model.editingDecision = decision } }
                            Text("\(decision.status.rawValue) · \(decision.delivery.rawValue)").font(.caption.bold())
                            Text(decision.detail).textSelection(.enabled)
                            ForEach(decision.evidence) { evidence in
                                HStack { Text("\(evidence.kind): \(evidence.detail)").font(.caption); if let source = evidence.source { Button("Source") { model.open(source) }.font(.caption) } }
                            }
                        }.padding().frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                    }
                    DisclosureGroup("Structured project summary") { Text(model.summary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                }
            }
        }
    }
    private func sourceSheet(_ hit: MemoryHit) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(hit.title).font(.title2.bold())
            Text("\(hit.source.provider) · \(hit.role) · \(hit.source.timestamp)").font(.caption)
            Text("\(hit.source.path)\nByte \(hit.source.byteOffset) · \(hit.source.nativeID.isEmpty ? hit.id:hit.source.nativeID)").font(.caption.monospaced()).textSelection(.enabled)
            ScrollView { Text(hit.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
            HStack {
                Button("Reveal source file") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:hit.source.path)]) }
                if let original = hit.source.originalURL, let url = URL(string:original) { Link("Original import source",destination:url) }
                Button("Capture decision") { model.selectedSource = nil; model.capture(hit) }
                Menu("Attach to decision") {
                    ForEach(model.decisions) { original in
                        Button(original.title) {
                            var decision = original
                            decision.evidence.append(DecisionEvidence(id:UUID().uuidString,kind:"source",detail:"Additional evidence",source:hit.source))
                            model.selectedSource = nil; model.editingDecision = decision
                        }
                    }
                }.disabled(model.decisions.isEmpty)
                Spacer(); Button("Done") { model.selectedSource = nil }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth:620,minHeight:480)
    }
    private var importSheet: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Select conversations to import").font(.title2.bold())
            Text("Only selected conversations are copied into this project's local memory.").foregroundStyle(.secondary)
            List(model.importChoices,selection:$model.importSelection) { item in Text(item.title).tag(item.id) }
            HStack { Button("Cancel") { model.importURL = nil }; Spacer(); Button("Import selected") { model.importSelected() }.disabled(model.importSelection.isEmpty) }
        }.padding(24).frame(width:560,height:460)
    }
}

private struct DecisionEditor: View {
    @State var decision: ProjectDecision
    let onSave: (ProjectDecision) -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Project decision").font(.title2.bold())
            TextField("Decision",text:$decision.title)
            TextEditor(text:$decision.detail).frame(minHeight:120)
            HStack {
                Picker("Decision",selection:$decision.status) { ForEach(DecisionStatus.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Picker("Delivery",selection:$decision.delivery) { ForEach(DeliveryStatus.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            }
            Text("Saving Accepted records your acceptance. Verified requires linked test or inspected artifact evidence; a completion claim alone is insufficient.").font(.caption).foregroundStyle(.secondary)
            ForEach($decision.evidence) { $evidence in
                HStack {
                    Picker("Evidence",selection:$evidence.kind) { ForEach(["source","test","artifact","conflict"],id:\.self) { Text($0.capitalized).tag($0) } }.frame(width:170)
                    TextField("What this evidence establishes",text:$evidence.detail)
                }
            }
            HStack { Button("Cancel",action:onCancel).keyboardShortcut(.cancelAction); Spacer(); Button("Save") { onSave(decision) }.keyboardShortcut(.defaultAction).disabled(decision.title.isEmpty) }
        }.padding(24).frame(width:680).frame(minHeight:400)
    }
}
