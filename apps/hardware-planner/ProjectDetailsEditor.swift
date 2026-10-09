import AppKit
import SwiftUI

struct ProjectDetailsEditor: View {
    @State var project: HardwareProject
    var save: (HardwareProject) -> Void
    @State private var newSource = EvidenceSource(title: "")
    @State private var attachment: ManagedAttachment?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Project, requirements and evidence").font(.title2).padding()
            Form {
                TextField("Project name", text: $project.name)
                TextField("Notes", text: $project.notes, axis: .vertical)
                Section("Requirements") {
                    ForEach($project.requirements) { $requirement in
                        DisclosureGroup(requirement.capability.isEmpty ? "New requirement" : requirement.capability) {
                            TextField("Capability", text: $requirement.capability)
                            TextField("Threshold", text: $requirement.threshold)
                            TextField("Operating condition", text: $requirement.operatingCondition)
                            TextField("Evidence needed", text: $requirement.evidenceNeeded)
                            Picker("Assessment", selection: $requirement.satisfied) { Text("Unknown").tag(nil as Bool?); Text("Satisfied").tag(Optional(true)); Text("Unsatisfied").tag(Optional(false)) }
                            EvidencePicker(sources: project.sources, selected: $requirement.sourceIDs)
                            TextField("Notes", text: $requirement.notes, axis: .vertical)
                            Button("Remove requirement", role: .destructive) { project.requirements.removeAll { $0.id == requirement.id } }
                        }
                    }
                    Button("Add requirement") { project.requirements.append(Requirement(capability: "New requirement")) }
                }
                Section("New source observation") {
                    TextField("Title", text: $newSource.title)
                    TextField("HTTP / HTTPS URL", text: $newSource.url)
                    TextField("Page / section", text: $newSource.section)
                    TextField("Document revision", text: $newSource.documentRevision)
                    DatePicker("Retrieved", selection: $newSource.retrievedAt)
                    Picker("Confidence", selection: $newSource.confidence) { ForEach(EvidenceConfidence.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    TextField("Notes", text: $newSource.notes, axis: .vertical)
                    HStack { Button("Attach document…", action: attach); Text(attachment?.filename ?? "No attachment").foregroundStyle(.secondary) }
                    Button("Add source to project") { addSource() }.disabled(newSource.title.isEmpty)
                    Text("Source observations are immutable after saving. Corrections are new observations with their own retrieval dates.").font(.caption).foregroundStyle(.secondary)
                    ForEach(project.sources) { Text("\($0.title) · \($0.confidence.rawValue)") }
                }
                Section("Decisions") {
                    ForEach($project.decisions) { $decision in
                        TextField("Choice", text: $decision.choice)
                        TextField("Reason", text: $decision.reason, axis: .vertical)
                        TextField("Alternatives considered", text: $decision.alternatives, axis: .vertical)
                        EvidencePicker(sources: project.sources, selected: $decision.sourceIDs)
                    }
                    Button("Add decision") { project.decisions.append(HardwareDecision(choice: "")) }
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal) }
            SheetActions(enabled: !project.name.isEmpty) {
                if !newSource.title.isEmpty { addSource() }
                do { try ProjectFormat.validate(project); save(project); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }.frame(minWidth: 600, idealWidth: 720, minHeight: 650, idealHeight: 800)
    }
    private func addSource() {
        if let attachment { project.attachments.append(attachment); newSource.attachmentID = attachment.id }
        project.sources.append(newSource); newSource = EvidenceSource(title: ""); attachment = nil
    }
    private func attach() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? Int.max) <= 20 * 1024 * 1024 else { throw HardwareError.invalid("Attachments must be 20 MB or smaller.") }
            attachment = ManagedAttachment(filename: url.lastPathComponent, content: try ProjectFormat.readFile(url, maximumBytes: 20 * 1024 * 1024))
        } catch { self.error = error.localizedDescription }
    }
}
