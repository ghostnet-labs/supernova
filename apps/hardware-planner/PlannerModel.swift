import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PlannerModel: ObservableObject {
    @Published var summaries: [ProjectSummary] = []
    @Published var project: HardwareProject?
    @Published var error: String?
    @Published var notice = ""
    @Published var busy = false
    @Published var focusedSource: EvidenceSource?
    @Published var openedAssemblyID: UUID?
    @Published var openedLinkID: UUID?
    private var store: HardwareStore?
    private var pendingOpenID: UUID?
    private var pendingLink: HardwareProjectLink?

    init(preview: HardwareProject?) {
        project = preview
        if let preview { summaries = [ProjectSummary(id: preview.id, name: preview.name, version: preview.version, updatedAt: preview.updatedAt)] }
    }

    init(directory: URL = HardwareStore.defaultDirectory) {
        Task {
            do {
                store = try await Task.detached { try HardwareStore(directory: directory) }.value
                summaries = try await store!.list()
                if let link = pendingLink { pendingLink = nil; load(link.projectID, link: link) }
                else if let pending = pendingOpenID { pendingOpenID = nil; load(pending) }
                else if let first = summaries.first { project = try await store!.load(first.id) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func load(_ id: UUID, link: HardwareProjectLink? = nil) {
        guard store != nil else { pendingOpenID = id; return }
        guard !busy else { if let link { pendingLink = link }; return }
        busy = true
        Task {
            defer { finishOperation() }
            do {
                guard let store, let loaded = try await store.load(id) else { throw HardwareError.invalid("Project was not found in this data directory.") }
                var selected = loaded
                if let assemblyID = link?.assemblyID {
                    guard loaded.assemblies.contains(where: { $0.id == assemblyID }) else { throw HardwareError.invalid("The linked assembly revision is not in this project. Import the matching project JSON; the report remains available in Agent Control Center.") }
                    selected.selectedAssemblyID = assemblyID
                }
                let source = link?.sourceID.flatMap { id in loaded.sources.first { $0.id == id } }
                if link?.sourceID != nil && source == nil { throw HardwareError.invalid("The cited source is not in this project. Import the matching project JSON to open its original evidence.") }
                project = selected; focusedSource = source; openedAssemblyID = link?.assemblyID
                if link != nil {
                    openedLinkID = UUID()
                    notice = "Opened the linked revision. Current project version \(loaded.version); attached reports remain historical snapshots."
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    func save(_ draft: HardwareProject) {
        guard !busy, let store else { return }
        busy = true
        Task {
            defer { finishOperation() }
            do {
                project = try await store.save(draft)
                summaries = try await store.list()
                notice = "Saved version \(project!.version)"
            } catch { self.error = error.localizedDescription }
        }
    }
    func openURL(_ url: URL) {
        do {
            let link = try HardwareProjectLink(url: url)
            guard store != nil else { pendingLink = link; return }
            load(link.projectID, link: link)
        } catch { self.error = error.localizedDescription }
    }
    private func finishOperation() {
        busy = false
        if let link = pendingLink { pendingLink = nil; load(link.projectID, link: link) }
    }
    func importProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let store, !busy else { return }
        busy = true
        Task {
            defer { finishOperation() }
            do {
                let data = try await Task.detached { try ProjectFormat.readFile(url, maximumBytes: 50 * 1024 * 1024) }.value
                project = try await store.importProject(data)
                summaries = try await store.list()
                notice = "Imported \(project!.name)"
            } catch { self.error = error.localizedDescription }
        }
    }
    func export(_ format: String) {
        guard let project else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.name).\(format == "report" ? "hardware-report.json" : format)"
        panel.allowedContentTypes = [format == "json" || format == "report" ? .json : format == "csv" ? .commaSeparatedText : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached {
                    let data: Data
                    if format == "json" { data = try ProjectFormat.encode(project) }
                    else if format == "report" { data = try HardwareReportFormat.encode(HardwareReportExport.selected(project)) }
                    else {
                        guard let assembly = project.selectedAssembly else { throw HardwareError.invalid("Select an assembly before exporting a BOM or report.") }
                        data = Data((format == "csv" ? BOMExport.csv(project, assembly: assembly) : BOMExport.markdown(project, assembly: assembly)).utf8)
                    }
                    try data.write(to: url, options: .atomic)
                }.value
                notice = "Exported \(url.lastPathComponent)"
            } catch { self.error = error.localizedDescription }
        }
    }
    func backup() {
        Task {
            do {
                if let destination = try await store?.backup() { notice = "Backup saved: \(destination.lastPathComponent)" }
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension Binding where Value == String? {
    var unknownText: Binding<String> { Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 }) }
}

struct RangeFields: View {
    @Binding var value: NumericRange?
    var body: some View {
        HStack {
            TextField("Minimum V", value: Binding(get: { value?.minimum }, set: { new in
                if let new { value = NumericRange(minimum: new, maximum: value?.maximum ?? new) } else { value = nil }
            }), format: .number)
            Text("to")
            TextField("Maximum V", value: Binding(get: { value?.maximum }, set: { new in
                if let new { value = NumericRange(minimum: value?.minimum ?? new, maximum: new) } else { value = nil }
            }), format: .number)
        }
    }
}

struct SheetActions: View {
    var saveTitle = "Save"
    var enabled = true
    var save: () -> Void
    @Environment(\.dismiss) var dismiss
    var body: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(saveTitle) { save() }.keyboardShortcut(.defaultAction).disabled(!enabled)
        }.padding()
    }
}
