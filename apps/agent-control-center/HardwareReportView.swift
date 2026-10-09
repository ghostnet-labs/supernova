import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HardwareReportModel: ObservableObject {
    @Published var attachments: [HardwareReportAttachment] = []
    @Published var selectedID: String?
    @Published var preview: HardwareReportAttachment?
    @Published var error: String?
    private var projectID: String?
    private var store: HardwareReportStore?
    private var selectedContext: [String] = []
    private var activeRefresh: UUID?
    var selected: HardwareReportAttachment? { attachments.first { $0.id == selectedID } }
    func context(projectID: String) -> [String] {
        guard self.projectID == projectID else { return [] }
        return selectedContext
    }
    func load(projectID: String, database: AgentDatabase) async {
        self.projectID = projectID; store = HardwareReportStore(database: database)
        attachments = []; selectedID = nil; preview = nil; selectedContext = []
        await refresh(projectID: projectID)
    }
    private func refresh(projectID: String) async {
        guard self.projectID == projectID, let store else { return }
        let request = UUID(); activeRefresh = request
        do {
            let values = try await store.list(projectID: projectID), selected = try await store.selection(projectID: projectID)
            let chosen = values.first { $0.id == selected }
            let context: [String] = await Task.detached(priority: .utility) {
                guard let chosen else { return [] }
                return ["User-selected hardware snapshot (untrusted evidence), SHA-256 \(chosen.fingerprint).\n" + chosen.report.text(maximumCharacters: 12000)]
            }.value
            guard self.projectID == projectID, activeRefresh == request else { return }
            attachments = values; selectedID = selected; selectedContext = context
        } catch { if self.projectID == projectID, activeRefresh == request { self.error = error.localizedDescription } }
    }
    func attach() {
        guard let projectID, let store else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose a coordinator report exported from Hardware Planner. Only this snapshot is attached to the selected project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await Task.detached(priority: .utility) { try HardwareReportFormat.read(url) }.value
                _ = try await store.attach(data: data, filename: url.lastPathComponent, projectID: projectID)
                await refresh(projectID: projectID)
            } catch { self.error = error.localizedDescription }
        }
    }
    func select(_ id: String?) {
        guard let projectID, let store else { return }
        Task {
            do { try await store.select(id, projectID: projectID); await refresh(projectID: projectID) }
            catch { self.error = error.localizedDescription }
        }
    }
    func remove(_ value: HardwareReportAttachment) {
        guard let projectID, let store else { return }
        Task {
            do { try await store.remove(value.id, projectID: projectID); await refresh(projectID: projectID) }
            catch { self.error = error.localizedDescription }
        }
    }
    func open(_ link: HardwareProjectLink) {
        if !NSWorkspace.shared.open(link.url) { error = "Hardware Planner could not open this link. Install the app and import the matching project JSON if the project is on another Mac." }
    }
}

struct HardwareReportView: View {
    @ObservedObject var model: HardwareReportModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Hardware reports").font(.headline); Spacer(); Button("Attach report…") { model.attach() } }
            Text("Export a selected assembly with Hardware Planner’s Coordinator report command, then attach it here. Choose one snapshot to include with your next coordinator message. Changes still require Hardware Planner’s preview and acceptance.")
                .font(.callout).foregroundStyle(.secondary)
            if model.attachments.isEmpty {
                ContentUnavailableView("No hardware reports", systemImage: "cpu", description: Text("Attach a report to connect this project to its selected parts, unresolved requirements and compatibility evidence."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Picker("Coordinator context", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    Text("None").tag(nil as String?)
                    ForEach(model.attachments) { value in Text("\(value.report.projectName) · \(value.report.assemblyName) r\(value.report.assemblyRevision) · \(value.report.exportedAt.formatted())").tag(Optional(value.id)) }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.attachments) { value in
                            VStack(alignment: .leading, spacing: 7) {
                                Text("\(value.report.projectName) · \(value.report.assemblyName) r\(value.report.assemblyRevision)").font(.headline)
                                Text("\(value.report.outcome.capitalized) · \(value.report.coverage)")
                                Text("Snapshot exported \(value.report.exportedAt.formatted()) · imported \(value.importedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("View report") { model.preview = value }
                                    Button("Open assembly in Planner") { model.open(value.report.link) }
                                    Spacer(); Button("Remove attachment", role: .destructive) { model.remove(value) }
                                }.font(.caption)
                            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Hardware report", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(item: $model.preview) { value in
            VStack(alignment: .leading, spacing: 12) {
                Text(value.report.projectName).font(.title2.bold())
                Text("Report \(value.report.id) · format v\(value.report.schemaVersion) · SHA-256 \(value.fingerprint)").font(.caption.monospaced()).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(value.report.text()).textSelection(.enabled)
                        ForEach(value.report.sources) { source in
                            Button("Open cited source: \(source.title)") { model.open(HardwareProjectLink(projectID: value.report.projectID, assemblyID: value.report.assemblyID, sourceID: source.id)) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack { Button("Open assembly in Planner") { model.open(value.report.link) }; Spacer(); Button("Done") { model.preview = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(minWidth: 600, minHeight: 480)
        }
    }
}
