import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CompatibilityWorkspace: View {
    let project: HardwareProject
    let onAccept: (HardwareProject) -> Void
    @State private var report: CompatibilityReport?
    @State private var showChange = false
    @State private var overrideFinding: CompatibilityFinding?
    @State private var overrideReason = ""
    @State private var overrideAuthor = ""
    @State private var error = ""
    @State private var filter: CheckOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compatibility and changes").font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("Recheck") { evaluate() }.disabled(project.selectedAssembly == nil)
                    Button("Preview change…") { showChange = true }.disabled(project.selectedAssembly?.items.isEmpty != false)
                    Button("Save check") { saveCheck() }.disabled(report == nil)
                    Button("Export report…") { exportReport() }.disabled(report == nil)
                    Menu("Saved checks") {
                        ForEach(savedCheckDates, id: \.self) { date in
                            Button(date.formatted()) {
                                guard let assemblyID = project.selectedAssemblyID else { return }
                                report = CompatibilityReport(assemblyRevisionID: assemblyID,
                                    findings: project.findings.filter { $0.assemblyRevisionID == assemblyID && $0.checkedAt == date }, checkedAt: date)
                            }
                        }
                    }.disabled(savedCheckDates.isEmpty)
                }.padding(.vertical, 2)
            }.frame(height: 30)
            if let report {
                HStack {
                    outcomeLabel(report.outcome)
                    Text(report.coverage).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Show", selection: $filter) {
                        Text("All checks").tag(Optional<CheckOutcome>.none)
                        ForEach(CheckOutcome.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                    }.frame(width: 190)
                }
                Text("Checked \(report.checkedAt.formatted()). Results cover the recorded rules only. Candidate or stale sources cannot pass a check. Overrides preserve the machine result.")
                    .font(.caption).foregroundStyle(.secondary)
                if report.findings.contains(where: { finding in project.findings.contains { $0.id == finding.id } }) {
                    Text("Saved check: evidence was assessed at its check time. Recheck to assess current freshness.").font(.caption).foregroundStyle(.secondary)
                }
                List(report.findings.filter { filter == nil || $0.outcome == filter }) { finding in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            outcomeLabel(finding.outcome)
                            Text(finding.ruleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Record override…") { overrideFinding = finding; overrideReason = ""; overrideAuthor = NSFullUserName() }.buttonStyle(.link)
                        }
                        Text(finding.explanation).textSelection(.enabled)
                        ForEach(finding.sourceIDs, id: \.self) { id in
                            if let source = project.sources.first(where: { $0.id == id }) {
                                HStack {
                                    Text("\(source.title) · \(source.confidence.rawValue) · \(source.retrievedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                                    if let url = URL(string: source.url), ["https", "http"].contains(url.scheme ?? "") { Link("Source", destination: url).font(.caption) }
                                }.foregroundStyle(.secondary)
                            }
                        }
                        ForEach(project.overrides.filter { $0.findingID == finding.id }) { value in
                            Text("Manual override by \(value.author): \(value.reason). Machine result unchanged.").font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(.vertical, 5)
                }
            } else {
                ContentUnavailableView("Select an assembly", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create parts and explicit assembly connections to evaluate compatibility."))
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { evaluate() }
        .onChange(of: project.selectedAssemblyID) { _, _ in evaluate() }
        .onChange(of: project.requirements) { _, _ in evaluate() }
        .sheet(isPresented: $showChange) { HardwareChangeSheet(project: project, onAccept: onAccept) }
        .sheet(item: $overrideFinding) { finding in
            VStack(alignment: .leading, spacing: 14) {
                Text("Record a manual override").font(.title2.bold())
                Text(finding.explanation)
                Text("This records your decision beside the \(finding.outcome.rawValue) result. It does not change evidence coverage or the machine check.").foregroundStyle(.secondary)
                TextField("Author", text: $overrideAuthor)
                TextField("Reason and remaining risk", text: $overrideReason, axis: .vertical).lineLimit(3...6)
                HStack {
                    Spacer()
                    Button("Cancel") { overrideFinding = nil }.keyboardShortcut(.cancelAction)
                    Button("Save override") {
                        var next = project
                        if let report { next.findings += report.findings.filter { candidate in !next.findings.contains { $0.id == candidate.id } } }
                        next.overrides.append(FindingOverride(findingID: finding.id, reason: overrideReason, author: overrideAuthor))
                        onAccept(next); overrideFinding = nil
                    }.disabled(overrideReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || overrideAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 540)
        }
    }
    private var savedCheckDates: [Date] {
        Array(Set(project.findings.filter { $0.assemblyRevisionID == project.selectedAssemblyID }.map(\.checkedAt))).sorted(by: >)
    }
    private func evaluate() {
        guard let assembly = project.selectedAssembly else { report = nil; return }
        report = CompatibilityEngine.evaluate(project, assembly: assembly)
    }
    private func saveCheck() {
        guard let report else { return }
        var next = project
        next.findings += report.findings.filter { finding in !next.findings.contains { $0.id == finding.id } }
        onAccept(next)
    }
    private func exportReport() {
        guard let report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "compatibility-report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try CompatibilityExport.markdown(project, report: report).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = error.localizedDescription }
    }
}

private func outcomeLabel(_ outcome: CheckOutcome) -> some View {
    let color: Color = outcome == .compatible ? .green : outcome == .incompatible ? .red : outcome == .conditional ? .orange : .secondary
    let icon = outcome == .compatible ? "checkmark.circle" : outcome == .incompatible ? "xmark.octagon" : outcome == .conditional ? "exclamationmark.triangle" : "questionmark.circle"
    return Label(outcome.rawValue.capitalized, systemImage: icon).foregroundStyle(color).font(.callout.bold())
}

private struct HardwareChangeSheet: View {
    let project: HardwareProject
    let onAccept: (HardwareProject) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var itemID: UUID?
    @State private var replacementID: UUID?
    @State private var quantity = 1
    @State private var offerID: UUID?
    @State private var interfaceMap: [UUID: UUID] = [:]
    @State private var preview: HardwareChangePreview?
    @State private var error = ""
    var item: AssemblyItem? { project.selectedAssembly?.items.first { $0.id == itemID } }
    var original: PartRevision? { item.flatMap { project.part($0.partRevisionID) } }
    var replacement: PartRevision? { replacementID.flatMap(project.part) }
    var connectedPorts: [InterfaceSpec] {
        guard let itemID, let assembly = project.selectedAssembly else { return [] }
        let ids = Set(assembly.connections.flatMap { [$0.from, $0.to] }.filter { $0.itemID == itemID }.map(\.interfaceID))
        return original?.interfaces.filter { ids.contains($0.id) } ?? []
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preview an assembly change").font(.title2.bold())
            Text("A change creates a new assembly revision. Map each connected interface explicitly, review the effects, then accept.").foregroundStyle(.secondary)
            Form {
                Picker("Assembly item", selection: $itemID) {
                    Text("Choose…").tag(Optional<UUID>.none)
                    ForEach(project.selectedAssembly?.items ?? []) { item in Text("\(project.part(item.partRevisionID)?.name ?? "Unknown") · \(item.role)").tag(Optional(item.id)) }
                }
                Picker("Replacement revision", selection: $replacementID) {
                    Text("Choose…").tag(Optional<UUID>.none)
                    ForEach(project.parts) { part in Text("\(part.name) · revision \(part.revision)").tag(Optional(part.id)) }
                }
                TextField("Quantity", value: $quantity, format: .number)
                Picker("Offer", selection: $offerID) {
                    Text("Unknown price").tag(Optional<UUID>.none)
                    ForEach(project.offers.filter { $0.partRevisionID == replacementID }) { offer in Text("\(offer.seller) · \(offer.currency) \(BOMExport.money(offer.unitPrice))").tag(Optional(offer.id)) }
                }
                ForEach(connectedPorts) { port in
                    Picker("Map \(port.name)", selection: Binding<UUID?>(get: { interfaceMap[port.id] }, set: { interfaceMap[port.id] = $0; preview = nil })) {
                        Text("Choose interface…").tag(Optional<UUID>.none)
                        ForEach(replacement?.interfaces ?? []) { target in Text(target.name).tag(Optional(target.id)) }
                    }
                }
            }.formStyle(.grouped).frame(maxHeight: 290)
            Button("Calculate impact") { calculate() }.disabled(itemID == nil || replacementID == nil)
            if let preview {
                HStack { outcomeLabel(preview.before.outcome); Image(systemName: "arrow.right"); outcomeLabel(preview.after.outcome); Text(preview.after.coverage).font(.caption) }
                Text("\(preview.affectedItemIDs.count) affected items · \(preview.affectedConnectionIDs.count) connections · \(preview.affectedRequirementIDs.count) requirements · quantity change \(preview.quantityDelta)")
                if !preview.affectedAdapterNames.isEmpty { Text("Affected adapters: \(preview.affectedAdapterNames.joined(separator: ", "))").font(.caption) }
                ForEach(preview.newAdapterNeeds) { need in
                    Text("\(need.connectionName) needs a corrected part or documented adapter for \(need.transformations.joined(separator: ", ")). An adapter must be added as an explicit part and checked before use.").font(.caption).foregroundStyle(.orange)
                }
                Text(preview.costDelta.sorted { $0.key < $1.key }.map { "Known cost change \($0.key) \(BOMExport.money($0.value))" }.joined(separator: " · ")).font(.callout)
                ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                List(preview.changedChecks) { delta in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(delta.before?.outcome.rawValue ?? "Absent") → \(delta.after?.outcome.rawValue ?? "Removed") · \(delta.after?.ruleID ?? delta.before?.ruleID ?? "")").font(.caption.bold())
                        Text(delta.after?.explanation ?? delta.before?.explanation ?? "").font(.callout)
                    }.padding(.vertical, 3)
                }.frame(minHeight: 160)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Accept new revision") {
                    do { if let preview { onAccept(try preview.accepting(current: project)); dismiss() } }
                    catch { self.error = error.localizedDescription }
                }.disabled(preview == nil)
            }
        }.padding(24).frame(width: 820, height: 780)
        .onChange(of: itemID) { _, _ in replacementID = item?.partRevisionID; quantity = item?.quantity ?? 1; offerID = item?.offerID; resetMapping() }
        .onChange(of: replacementID) { _, _ in offerID = nil; resetMapping() }
        .onChange(of: quantity) { _, _ in preview = nil }
        .onChange(of: offerID) { _, _ in preview = nil }
    }
    private func resetMapping() {
        interfaceMap = [:]
        for port in connectedPorts where replacement?.interfaces.contains(where: { $0.id == port.id }) == true { interfaceMap[port.id] = port.id }
        preview = nil
    }
    private func calculate() {
        guard let itemID, let replacementID else { return }
        do {
            guard connectedPorts.allSatisfy({ interfaceMap[$0.id] != nil }) else { throw HardwareError.invalid("Map every connected interface first.") }
            preview = try HardwareChangeImpact.preview(project, itemID: itemID, replacementRevisionID: replacementID, quantity: quantity, offerID: offerID, interfaceMap: interfaceMap)
            error = ""
        } catch { preview = nil; self.error = error.localizedDescription }
    }
}
