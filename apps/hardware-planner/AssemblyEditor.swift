import SwiftUI

struct AssemblyEditor: View {
    var project: HardwareProject
    var save: (HardwareProject) -> Void
    private let original: AssemblyRevision?
    @State private var assembly: AssemblyRevision
    @State private var error: String?
    @State private var removedConnections = 0
    @Environment(\.dismiss) private var dismiss

    init(project: HardwareProject, original: AssemblyRevision? = nil, save: @escaping (HardwareProject) -> Void) {
        self.project = project; self.save = save; self.original = original
        var draft = original?.revised() ?? AssemblyRevision(name: "New assembly")
        if let original { draft.revision = (project.assemblies.filter { $0.assemblyID == original.assemblyID }.map(\.revision).max() ?? 0) + 1 }
        _assembly = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Assembly revision \(assembly.revision)").font(.title2).padding()
            Form {
                TextField("Name", text: $assembly.name)
                Text("Saving creates an immutable assembly snapshot. Existing BOMs keep their original specifications and prices.").font(.caption).foregroundStyle(.secondary)
                Section("Selected parts") {
                    ForEach($assembly.items) { $item in
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Part revision", selection: $item.partRevisionID) {
                                ForEach(project.parts) { Text("\($0.name) · r\($0.revision)").tag($0.id) }
                            }.onChange(of: item.partRevisionID) { _, _ in
                                item.offerID = nil
                                let previousCount = assembly.connections.count
                                assembly.connections.removeAll { connection in
                                    [connection.from, connection.to].contains { endpoint in
                                        endpoint.itemID == item.id && !(project.part(item.partRevisionID)?.interfaces.contains { $0.id == endpoint.interfaceID } ?? false)
                                    }
                                }
                                removedConnections += previousCount - assembly.connections.count
                            }
                            TextField("Quantity", value: $item.quantity, format: .number)
                            TextField("Role / reference", text: $item.role)
                            Picker("Price observation", selection: $item.offerID) {
                                Text("Unknown price").tag(nil as UUID?)
                                ForEach(project.offers.filter { $0.partRevisionID == item.partRevisionID }) { offer in
                                    Text("\(offer.seller): \(offer.currency) \(BOMExport.money(offer.unitPrice)) · min \(offer.minimumQuantity)").tag(Optional(offer.id))
                                }
                            }
                            Menu("Alternatives (\(item.alternativeRevisionIDs.count))") {
                                ForEach(project.parts.filter { $0.id != item.partRevisionID }) { candidate in
                                    Toggle("\(candidate.name) · r\(candidate.revision)", isOn: Binding(get: { item.alternativeRevisionIDs.contains(candidate.id) }, set: { enabled in
                                        if enabled { item.alternativeRevisionIDs.append(candidate.id) } else { item.alternativeRevisionIDs.removeAll { $0 == candidate.id } }
                                    }))
                                }
                            }
                            Button("Remove item", role: .destructive) {
                                assembly.items.removeAll { $0.id == item.id }
                                assembly.connections.removeAll { $0.from.itemID == item.id || $0.to.itemID == item.id }
                            }
                        }.padding(.vertical, 6)
                    }
                    Button("Add selected part") {
                        if let first = project.parts.first { assembly.items.append(AssemblyItem(partRevisionID: first.id)) }
                    }.disabled(project.parts.isEmpty)
                }
                Section("Connections") {
                    Text("Choose exact interface endpoints. Two connector names alone do not establish compatibility.").font(.caption).foregroundStyle(.secondary)
                    if removedConnections > 0 { Text("\(removedConnections) connections referenced interfaces missing from the replacement and were removed from this draft. Reconnect them before saving.").foregroundStyle(.orange) }
                    ForEach($assembly.connections) { $connection in
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Connection name", text: $connection.name)
                            EndpointPicker(title: "From", project: project, items: assembly.items, endpoint: $connection.from)
                            EndpointPicker(title: "To", project: project, items: assembly.items, endpoint: $connection.to)
                            TextField("Required protocol", text: $connection.requiredProtocol.unknownText)
                            TextField("Required lanes", value: $connection.lanesRequired, format: .number)
                            EvidencePicker(sources: project.sources, selected: $connection.sourceIDs)
                            TextField("Notes / conditions", text: $connection.notes)
                            Button("Remove connection", role: .destructive) { assembly.connections.removeAll { $0.id == connection.id } }
                        }.padding(.vertical, 6)
                    }
                    Button("Add connection") {
                        let endpoints = availableEndpoints
                        guard let from = endpoints.first else { return }
                        assembly.connections.append(HardwareConnection(name: "New connection", from: from, to: endpoints.dropFirst().first ?? from))
                    }.disabled(availableEndpoints.isEmpty)
                }
                Section("Costs and notes") {
                    TextField("Tax", value: $assembly.tax, format: .number)
                    TextField("Shipping", value: $assembly.shipping, format: .number)
                    TextField("Tax / shipping currency", text: $assembly.costCurrency)
                    TextField("Notes", text: $assembly.notes, axis: .vertical)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal) }
            SheetActions(saveTitle: "Save assembly", enabled: !assembly.name.isEmpty) {
                var next = project
                next.assemblies.append(assembly); next.selectedAssemblyID = assembly.id
                if let previous = original ?? project.selectedAssembly {
                    HardwareChangeImpact.invalidateRequirements(in: &next, replacing: previous, with: assembly)
                    next.findings.append(contentsOf: CompatibilityEngine.evaluate(project, assembly: previous).findings)
                }
                do { try ProjectFormat.validate(next); save(next); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }.frame(minWidth: 620, idealWidth: 740, minHeight: 650, idealHeight: 820)
    }

    private var availableEndpoints: [ConnectionEndpoint] {
        assembly.items.flatMap { item in
            (project.part(item.partRevisionID)?.interfaces ?? []).map { ConnectionEndpoint(itemID: item.id, interfaceID: $0.id) }
        }
    }
}

struct EndpointPicker: View {
    var title: String
    var project: HardwareProject
    var items: [AssemblyItem]
    @Binding var endpoint: ConnectionEndpoint
    var body: some View {
        Picker(title, selection: Binding(get: { "\(endpoint.itemID):\(endpoint.interfaceID)" }, set: { value in
            let components = value.split(separator: ":")
            if components.count == 2, let item = UUID(uuidString: String(components[0])), let port = UUID(uuidString: String(components[1])) {
                endpoint = ConnectionEndpoint(itemID: item, interfaceID: port)
            }
        })) {
            ForEach(items) { item in
                if let part = project.part(item.partRevisionID) {
                    ForEach(part.interfaces) { port in
                        Text("\(item.role.isEmpty ? part.name : item.role): \(port.name)").tag("\(item.id):\(port.id)")
                    }
                }
            }
        }
    }
}

struct OfferEditor: View {
    var project: HardwareProject
    var save: (HardwareProject) -> Void
    @State private var offer: Offer
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(project: HardwareProject, save: @escaping (HardwareProject) -> Void) {
        self.project = project; self.save = save
        _offer = State(initialValue: Offer(partRevisionID: project.parts.first?.id ?? UUID(), seller: ""))
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Record price observation").font(.title2).padding()
            Form {
                Picker("Part revision", selection: $offer.partRevisionID) { ForEach(project.parts) { Text("\($0.name) · r\($0.revision)").tag($0.id) } }
                TextField("Seller", text: $offer.seller)
                TextField("Offer URL", text: $offer.url)
                TextField("Currency", text: $offer.currency)
                TextField("Unit price (blank is unknown)", value: $offer.unitPrice, format: .number)
                TextField("Minimum quantity", value: $offer.minimumQuantity, format: .number)
                TextField("Availability", text: $offer.availability)
                DatePicker("Observed", selection: $offer.observedAt)
                Text("Record a new offer when price or stock changes. Existing assembly snapshots retain the selected observation.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal) }
            SheetActions(enabled: !offer.seller.isEmpty && !project.parts.isEmpty) {
                var next = project; next.offers.append(offer)
                do { try ProjectFormat.validate(next); save(next); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }.frame(width: 560, height: 530)
    }
}
