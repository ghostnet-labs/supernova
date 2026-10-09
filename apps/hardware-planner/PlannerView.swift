import AppKit
import SwiftUI

enum PlannerSection: String, CaseIterable { case overview = "Project", parts = "Parts", assemblies = "Assemblies", bom = "BOM", alternatives = "Alternatives", compatibility = "Compatibility", changes = "Changes" }

struct PlannerView: View {
    @ObservedObject var model: PlannerModel
    @State private var section: PlannerSection = .overview
    @State private var newProject = false
    @State private var projectName = ""
    @State private var sheet: PlannerSheet?

    init(model: PlannerModel, section: PlannerSection = .overview) {
        self.model = model; _section = State(initialValue: section)
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Projects") {
                    ForEach(model.summaries) { summary in
                        Button { model.load(summary.id) } label: {
                            HStack {
                                Octicons.swiftUIImage("repo").frame(width: 16, height: 16)
                                Text(summary.name).lineLimit(2)
                                Spacer()
                                if model.project?.id == summary.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, 4)
                    }
                }
                if model.project != nil {
                    Section("Workspace") {
                        ForEach(PlannerSection.allCases, id: \.self) { item in
                            Button { section = item } label: {
                                HStack { Text(item.rawValue); Spacer(); if section == item { Image(systemName: "chevron.right").font(.caption) } }
                            }.buttonStyle(.plain).padding(.vertical, 3)
                        }
                    }
                }
            }.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { newProject = true } label: { Label("New project", systemImage: "plus") }
                    Spacer()
                    Button { model.importProject() } label: { Image(systemName: "square.and.arrow.down") }.help("Import versioned project JSON")
                }.padding()
            }
        } detail: {
            if let project = model.project {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(project.name).font(.title).textSelection(.enabled)
                            Text("\(section.rawValue) · saved version \(project.version)").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small) }
                        Menu("Export") {
                            Button("Project JSON (lossless)") { model.export("json") }
                            Button("Purchasing BOM CSV") { model.export("csv") }.disabled(project.selectedAssembly == nil)
                            Button("Review report Markdown") { model.export("md") }.disabled(project.selectedAssembly == nil)
                            Button("Coordinator report JSON") { model.export("report") }.disabled(project.selectedAssembly == nil)
                            Divider()
                            Button("Copy project link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.projectURL.absoluteString, forType: .string) }
                            Button("Back up database") { model.backup() }
                        }.fixedSize()
                    }.padding()
                    Divider()
                    workspace(project)
                    Divider()
                    Text(model.notice.isEmpty ? "Local projects · unknown specifications remain unknown" : model.notice).font(.caption).foregroundStyle(.secondary).padding(10)
                }
            } else {
                ContentUnavailableView {
                    Label("Plan an assembly", systemImage: "cpu")
                } description: {
                    Text("Keep exact part revisions, evidence, connections and purchasing quantities together.")
                } actions: {
                    Button("New project") { newProject = true }.buttonStyle(.borderedProminent)
                    Button("Start field-node worksheet") { model.save(HardwareProject.fieldNodeCandidates()) }
                    Button("Import project") { model.importProject() }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        .disabled(model.busy)
        .sheet(item: $sheet) { target in
            if let project = model.project {
                switch target {
                case .part(let part): PartEditor(project: project, original: part, save: model.save)
                case .assembly(let assembly): AssemblyEditor(project: project, original: assembly, save: model.save)
                case .offer: OfferEditor(project: project, save: model.save)
                case .details: ProjectDetailsEditor(project: project, save: model.save)
                }
            }
        }
        .alert("New project", isPresented: $newProject) {
            TextField("Project name", text: $projectName)
            Button("Create") { model.save(HardwareProject(name: projectName)); projectName = "" }.disabled(projectName.isEmpty)
            Button("Cancel", role: .cancel) { projectName = "" }
        }
        .alert("Hardware Planner", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onOpenURL(perform: model.openURL)
        .onChange(of: model.openedLinkID) { _, value in if value != nil { section = model.openedAssemblyID == nil ? .overview : .compatibility } }
        .sheet(item: $model.focusedSource) { source in
            VStack(alignment: .leading, spacing: 12) {
                Text(source.title).font(.title2.bold())
                Text("Source \(source.id) · \(source.confidence.rawValue)").font(.caption.monospaced()).textSelection(.enabled)
                Text("Section: \(source.section)\nDocument revision: \(source.documentRevision)\nRetrieved: \(source.retrievedAt.formatted())")
                ScrollView { Text(source.notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if let url = URL(string: source.url), ["https", "http"].contains(url.scheme ?? "") { Link("Open source document", destination: url) }
                if source.attachmentID != nil { Text("The original document is retained in this Hardware Planner project's attachments.").font(.caption).foregroundStyle(.secondary) }
                HStack { Spacer(); Button("Done") { model.focusedSource = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(minWidth: 540, minHeight: 340)
        }
    }

    @ViewBuilder private func workspace(_ project: HardwareProject) -> some View {
        switch section {
        case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text("Project notes").font(.headline); Spacer(); Button("Edit project and evidence") { sheet = .details } }
                    Text(project.notes.isEmpty ? "Add requirements and source evidence to guide this project." : project.notes).textSelection(.enabled)
                    HStack(spacing: 25) {
                        metric("Part revisions", project.parts.count); metric("Assembly snapshots", project.assemblies.count); metric("Requirements", project.requirements.count)
                    }
                    if let assembly = project.selectedAssembly { Text("Selected: \(assembly.name) · revision \(assembly.revision)").font(.headline) }
                    ForEach(project.requirements) { requirement in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(requirement.capability).font(.headline)
                            Text(requirement.threshold.isEmpty ? "Threshold not set" : requirement.threshold)
                            Text(requirement.evidenceNeeded).foregroundStyle(.secondary)
                            Text(requirement.satisfied.map { $0 ? "Satisfied — review cited evidence" : "Unsatisfied" } ?? "Unknown").font(.caption)
                        }
                    }
                    if !project.sources.isEmpty { Text("Source observations").font(.headline) }
                    ForEach(project.sources) { source in
                        VStack(alignment: .leading) {
                            if let url = URL(string: source.url), ["https", "http"].contains(url.scheme ?? "") { Link(source.title, destination: url) }
                            else { Text(source.title) }
                            Text("\(source.confidence.rawValue) · \(source.section) · \(source.retrievedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(project.decisions) { decision in
                        VStack(alignment: .leading) { Text(decision.choice).font(.headline); Text(decision.reason); Text("Alternatives: \(decision.alternatives)").foregroundStyle(.secondary) }
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .parts:
            VStack {
                HStack { Text("Exact specifications are saved as new revisions.").foregroundStyle(.secondary); Spacer(); Button("Add part") { sheet = .part(nil) }; Button("Record offer") { sheet = .offer }.disabled(project.parts.isEmpty) }.padding()
                List(project.parts.sorted { ($0.name, $0.revision) < ($1.name, $1.revision) }) { part in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(part.name).font(.headline); Text("r\(part.revision)").foregroundStyle(.secondary); Spacer(); Button("Inspect / revise") { sheet = .part(part) } }
                        Text([part.manufacturer, part.partNumber, part.boardRevision, part.category].filter { !$0.isEmpty }.joined(separator: " · "))
                        Text("\(part.interfaces.count) interfaces · \(part.sourceIDs.count) sources · \(part.unresolvedQuestions.count) open questions").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }.overlay { if project.parts.isEmpty { ContentUnavailableView("No parts yet", systemImage: "cpu", description: Text("Add candidate parts and fill in only specifications you know.")) } }
            }
        case .assemblies:
            VStack {
                HStack { Text("Saved snapshots remain reproducible.").foregroundStyle(.secondary); Spacer(); Button("New assembly") { sheet = .assembly(nil) }.disabled(project.parts.isEmpty) }.padding()
                List(project.assemblies.reversed()) { assembly in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(assembly.name) · r\(assembly.revision)").font(.headline)
                            if project.selectedAssemblyID == assembly.id { Text("Selected").foregroundStyle(.tint) }
                            Spacer()
                            Button("Select") { var next = project; next.selectedAssemblyID = assembly.id; model.save(next) }
                            Button("Revise") { sheet = .assembly(assembly) }
                        }
                        Text("\(assembly.items.count) BOM lines · \(assembly.connections.count) connections · \(assembly.createdAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }.overlay { if project.assemblies.isEmpty { ContentUnavailableView("No assembly selected", systemImage: "shippingbox", description: Text("Add parts, then create an assembly with quantities and exact interfaces.")) } }
            }
        case .bom:
            if let assembly = project.selectedAssembly { BOMView(project: project, assembly: assembly) }
            else { ContentUnavailableView("Select an assembly", systemImage: "list.bullet.rectangle", description: Text("The BOM follows the selected immutable assembly revision.")) }
        case .alternatives: AlternativeComparisonView(project: project)
        case .compatibility:
            CompatibilityWorkspace(project: project, onAccept: model.save)
        case .changes:
            List {
                Section("Part revision history") { ForEach(project.parts.sorted { $0.createdAt > $1.createdAt }) { Text("\($0.name) · r\($0.revision) · \($0.createdAt.formatted())") } }
                Section("Assembly revision history") { ForEach(project.assemblies.sorted { $0.createdAt > $1.createdAt }) { Text("\($0.name) · r\($0.revision) · \($0.createdAt.formatted())") } }
            }
        }
    }
    private func metric(_ label: String, _ value: Int) -> some View { VStack(alignment: .leading) { Text(String(value)).font(.title); Text(label).font(.caption).foregroundStyle(.secondary) } }
}

enum PlannerSheet: Identifiable {
    case part(PartRevision?), assembly(AssemblyRevision?), offer, details
    var id: String {
        switch self { case .part(let part): return "part-\(part?.id.uuidString ?? "new")"; case .assembly(let assembly): return "assembly-\(assembly?.id.uuidString ?? "new")"; case .offer: return "offer"; case .details: return "details" }
    }
}

struct BOMView: View {
    var project: HardwareProject
    var assembly: AssemblyRevision
    var body: some View {
        let rows = BOMExport.rows(project, assembly: assembly)
        VStack(alignment: .leading) {
            Text("\(assembly.name) · revision \(assembly.revision)").font(.headline).padding([.horizontal, .top])
            Table(rows) {
                TableColumn("Part") { row in VStack(alignment: .leading) { Text(row.part.name); Text(row.part.partNumber).font(.caption).foregroundStyle(.secondary) } }
                TableColumn("Revision") { Text(String($0.part.revision)) }.width(65)
                TableColumn("Quantity") { Text(String($0.quantity)) }.width(65)
                TableColumn("Currency") { Text($0.offer?.currency ?? "Unknown") }.width(75)
                TableColumn("Extended") { Text(BOMExport.money($0.extendedPrice)) }.width(100)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Known subtotals").font(.headline)
                ForEach(BOMExport.totals(rows).keys.sorted(), id: \.self) { currency in Text("\(currency) \(BOMExport.money(BOMExport.totals(rows)[currency]))") }
                Text("\(rows.filter { $0.extendedPrice == nil }.count) unpriced lines · tax \(assembly.costCurrency) \(BOMExport.money(assembly.tax)) · shipping \(BOMExport.money(assembly.shipping))").foregroundStyle(.secondary)
                Text("Unknown prices and unmet quantity breaks are excluded. Different currencies are never added together.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
}

struct AlternativeComparisonView: View {
    var project: HardwareProject
    @State private var first: UUID?
    @State private var second: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Compare exact revisions").font(.headline)
                HStack {
                    candidatePicker("Selected", selection: $first)
                    candidatePicker("Alternative", selection: $second)
                }
                HStack(alignment: .top, spacing: 25) {
                    comparison(first.flatMap(project.part)); comparison(second.flatMap(project.part))
                }
                Text("Comparison does not change an assembly. Revise the assembly to choose a different part; saved revisions remain available.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.onAppear { first = project.selectedAssembly?.items.first?.partRevisionID ?? project.parts.first?.id; second = project.parts.dropFirst().first?.id }
    }
    private func candidatePicker(_ label: String, selection: Binding<UUID?>) -> some View {
        Picker(label, selection: selection) { Text("Choose part").tag(nil as UUID?); ForEach(project.parts) { Text("\($0.name) · r\($0.revision)").tag(Optional($0.id)) } }
    }
    @ViewBuilder private func comparison(_ part: PartRevision?) -> some View {
        if let part {
            VStack(alignment: .leading, spacing: 12) {
                Text(part.name).font(.title2)
                Text("\(part.manufacturer) \(part.partNumber) · board \(part.boardRevision.isEmpty ? "Unknown" : part.boardRevision)")
                ForEach(part.interfaces) { port in
                    VStack(alignment: .leading) {
                        Text(port.name).font(.headline)
                        Text("\(port.connector ?? "Unknown connector") · \(port.key ?? "Unknown key")")
                        Text(port.protocols.isEmpty ? "Protocols unknown" : port.protocols.joined(separator: ", "))
                        Text(port.voltage.map { "\($0.minimum)–\($0.maximum) V" } ?? "Voltage unknown")
                    }
                }
                ForEach(project.offers.filter { $0.partRevisionID == part.id }) { offer in Text("\(offer.seller): \(offer.currency) \(BOMExport.money(offer.unitPrice)) · \(offer.observedAt.formatted(date: .abbreviated, time: .omitted))") }
                Text("Evidence sources: \(part.sourceIDs.count)")
                ForEach(part.unresolvedQuestions, id: \.self) { Text("• \($0)").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else { Text("Choose a revision to compare.").frame(maxWidth: .infinity) }
    }
}
