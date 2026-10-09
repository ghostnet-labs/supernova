import SwiftUI

struct PartEditor: View {
    var project: HardwareProject
    var original: PartRevision?
    var save: (HardwareProject) -> Void
    @State private var part: PartRevision
    @State private var evidenceTitle = ""
    @State private var evidenceURL = ""
    @State private var evidenceSection = ""
    @State private var confidence: EvidenceConfidence = .candidate
    @State private var question = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(project: HardwareProject, original: PartRevision? = nil, save: @escaping (HardwareProject) -> Void) {
        self.project = project; self.original = original; self.save = save
        var draft = original?.revised() ?? PartRevision(name: "")
        if let original { draft.revision = (project.parts.filter { $0.partID == original.partID }.map(\.revision).max() ?? 0) + 1 }
        _part = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(original == nil ? "Add part" : "New revision of \(original!.name)").font(.title2).padding()
            Form {
                Section("Identity") {
                    TextField("Name", text: $part.name)
                    TextField("Manufacturer", text: $part.manufacturer)
                    TextField("Part number", text: $part.partNumber)
                    TextField("Board revision", text: $part.boardRevision)
                    TextField("Category", text: $part.category)
                    Text("Saved specifications stay unchanged. This saves revision \(part.revision). Unknown ratings stay blank.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Interfaces") {
                    ForEach($part.interfaces) { $port in
                        DisclosureGroup(port.name.isEmpty ? "New interface" : port.name) {
                            TextField("Interface name", text: $port.name)
                            TextField("Connector", text: $port.connector.unknownText)
                            TextField("Key", text: $port.key.unknownText)
                            TextField("Gender / mating type", text: $port.gender.unknownText)
                            Text("Use “none” or “genderless” for documented absence. A blank value remains unknown.").font(.caption).foregroundStyle(.secondary)
                            TextField("Protocols (comma separated)", text: Binding(get: { port.protocols.joined(separator: ", ") }, set: { port.protocols = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                            Picker("Direction", selection: $port.direction) { ForEach(PortDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            RangeFields(value: $port.voltage)
                            TextField("Lanes (unknown if blank)", value: $port.lanes, format: .number)
                            TextField("Connection capacity", value: $port.capacity, format: .number)
                            TextField("Shared resource group", text: $port.resourceGroup.unknownText)
                            DimensionFields(dimensions: $port.dimensions)
                            Text("Interface dimensions describe the documented mating geometry.").font(.caption).foregroundStyle(.secondary)
                            PinMappingEditor(mapping: $port.pinMapping)
                            EvidencePicker(sources: project.sources, selected: $port.sourceIDs)
                            TextField("Notes", text: $port.notes, axis: .vertical)
                            Button("Remove interface", role: .destructive) {
                                part.interfaces.removeAll { $0.id == port.id }
                                part.power.removeAll { $0.interfaceID == port.id }
                                part.adapters.removeAll { $0.inputInterfaceID == port.id || $0.outputInterfaceID == port.id }
                            }
                        }
                    }
                    Button("Add interface") { part.interfaces.append(InterfaceSpec(name: "New interface")) }
                }
                Section("Power rails") {
                    ForEach($part.power) { $rail in
                        DisclosureGroup(rail.rail.isEmpty ? "Power rail" : rail.rail) {
                            TextField("Rail name", text: $rail.rail)
                            Picker("Interface", selection: $rail.interfaceID) {
                                Text("Unspecified").tag(nil as UUID?)
                                ForEach(part.interfaces) { Text($0.name).tag(Optional($0.id)) }
                            }
                            Picker("Direction", selection: $rail.direction) { ForEach(PortDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            RangeFields(value: $rail.voltage)
                            TextField("Typical demand (A)", value: $rail.typicalCurrentA, format: .number)
                            TextField("Peak demand (A)", value: $rail.peakCurrentA, format: .number)
                            TextField("Source capacity (A)", value: $rail.capacityCurrentA, format: .number)
                            TextField("Typical demand (W)", value: $rail.typicalPowerW, format: .number)
                            TextField("Peak demand (W)", value: $rail.peakPowerW, format: .number)
                            TextField("Source capacity (W)", value: $rail.capacityPowerW, format: .number)
                            TextField("Efficiency (0–1)", value: $rail.efficiency, format: .number)
                            TextField("Headroom fraction", value: $rail.headroomFraction, format: .number)
                            TextField("Operating conditions", text: $rail.operatingConditions)
                            EvidencePicker(sources: project.sources, selected: $rail.sourceIDs)
                            Button("Remove rail", role: .destructive) { part.power.removeAll { $0.id == rail.id } }
                        }
                    }
                    Button("Add power rail") { part.power.append(PowerSpec(rail: "New rail")) }
                }
                Section("Dimensions and software") {
                    DimensionFields(dimensions: $part.dimensions)
                    ForEach($part.software) { $software in
                        TextField("Software / OS", text: $software.name)
                        TextField("Version", text: $software.version)
                        TextField("Driver", text: $software.driver)
                        Picker("Support", selection: $software.supported) {
                            Text("Unknown").tag(nil as Bool?); Text("Supported").tag(Optional(true)); Text("Unsupported").tag(Optional(false))
                        }
                        EvidencePicker(sources: project.sources, selected: $software.sourceIDs)
                    }
                    Button("Add software support") { part.software.append(SoftwareSupport(name: "")) }
                }
                Section("Adapter transformations") {
                    ForEach($part.adapters) { $adapter in
                        AdapterFields(adapter: $adapter, interfaces: part.interfaces, sources: project.sources)
                        Button("Remove transformation", role: .destructive) { part.adapters.removeAll { $0.id == adapter.id } }
                    }
                    Button("Add adapter transformation") {
                        guard let input = part.interfaces.first, let output = part.interfaces.dropFirst().first else { return }
                        part.adapters.append(AdapterMapping(inputInterfaceID: input.id, outputInterfaceID: output.id))
                    }.disabled(part.interfaces.count < 2)
                    Text("An adapter requires separate input and output interfaces and documented behavior. Connector shape alone is not evidence of conversion.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Evidence and rationale") {
                    EvidencePicker(sources: project.sources, selected: $part.sourceIDs)
                    TextField("New source title", text: $evidenceTitle)
                    TextField("Source URL", text: $evidenceURL)
                    TextField("Page or section", text: $evidenceSection)
                    Picker("Source confidence", selection: $confidence) { ForEach(EvidenceConfidence.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Text("New evidence is linked to this part. Associate it with specific interface/rail claims by creating another revision after saving.").font(.caption).foregroundStyle(.secondary)
                    TextField("Notes", text: $part.notes, axis: .vertical)
                    TextField("Unresolved questions (one per line)", text: Binding(get: { part.unresolvedQuestions.joined(separator: "\n") }, set: { part.unresolvedQuestions = $0.components(separatedBy: "\n").filter { !$0.isEmpty } }), axis: .vertical)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal).textSelection(.enabled) }
            SheetActions(saveTitle: "Save revision", enabled: !part.name.isEmpty) {
                var next = project
                var savedPart = part
                if !evidenceTitle.isEmpty || !evidenceURL.isEmpty {
                    let source = EvidenceSource(title: evidenceTitle.isEmpty ? evidenceURL : evidenceTitle, url: evidenceURL, section: evidenceSection, confidence: confidence)
                    next.sources.append(source); savedPart.sourceIDs.append(source.id)
                }
                next.parts.append(savedPart)
                do { try ProjectFormat.validate(next); save(next); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }.frame(minWidth: 600, idealWidth: 720, minHeight: 650, idealHeight: 820)
    }
}

struct AdapterFields: View {
    @Binding var adapter: AdapterMapping
    var interfaces: [InterfaceSpec]
    var sources: [EvidenceSource]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Input interface", selection: $adapter.inputInterfaceID) { ForEach(interfaces) { Text($0.name).tag($0.id) } }
            Picker("Output interface", selection: $adapter.outputInterfaceID) { ForEach(interfaces) { Text($0.name).tag($0.id) } }
            TextField("Input protocol", text: $adapter.inputProtocol.unknownText)
            TextField("Output protocol", text: $adapter.outputProtocol.unknownText)
            RangeFields(value: $adapter.outputVoltage)
            TextField("Output capacity (A)", value: $adapter.capacityCurrentA, format: .number)
            TextField("Efficiency (0–1)", value: $adapter.efficiency, format: .number)
            TextField("Conditions", text: $adapter.conditions, axis: .vertical)
            EvidencePicker(sources: sources, selected: $adapter.sourceIDs)
        }
    }
}

struct PinMappingEditor: View {
    @Binding var mapping: [String: String]
    @State private var pin = ""
    @State private var signal = ""
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(mapping.keys.sorted(), id: \.self) { key in
                HStack {
                    Text("Pin \(key)")
                    TextField("Signal", text: Binding(get: { mapping[key] ?? "" }, set: { mapping[key] = $0 }))
                    Button { mapping.removeValue(forKey: key) } label: { Image(systemName: "minus.circle") }.help("Remove pin mapping")
                }
            }
            HStack {
                TextField("Pin", text: $pin); TextField("Signal", text: $signal)
                Button("Add pin") { mapping[pin] = signal; pin = ""; signal = "" }.disabled(pin.isEmpty || signal.isEmpty)
            }
        }
    }
}

struct DimensionFields: View {
    @Binding var dimensions: Dimensions?
    func field(_ key: WritableKeyPath<Dimensions, Double?>) -> Binding<Double?> {
        Binding(get: { dimensions?[keyPath: key] }, set: { value in
            var changed = dimensions ?? Dimensions(); changed[keyPath: key] = value; dimensions = changed
        })
    }
    var body: some View {
        HStack {
            TextField("Width (mm)", value: field(\.widthMM), format: .number)
            TextField("Length (mm)", value: field(\.lengthMM), format: .number)
            TextField("Height (mm)", value: field(\.heightMM), format: .number)
        }
    }
}

struct EvidencePicker: View {
    var sources: [EvidenceSource]
    @Binding var selected: [UUID]
    var body: some View {
        Menu("Evidence (\(selected.count))") {
            if sources.isEmpty { Text("Add a project source first") }
            ForEach(sources) { source in
                Toggle(source.title, isOn: Binding(get: { selected.contains(source.id) }, set: { checked in
                    if checked { selected.append(source.id) } else { selected.removeAll { $0 == source.id } }
                }))
            }
        }
    }
}
