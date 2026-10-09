import Foundation

struct CompatibilityPolicy {
    var maximumEvidenceAgeDays = 365.0
    var matingToleranceMM = 0.1
}

struct CompatibilityReport {
    var assemblyRevisionID: UUID
    var findings: [CompatibilityFinding]
    var checkedAt: Date
    var outcome: CheckOutcome {
        if findings.contains(where: { $0.outcome == .incompatible }) { return .incompatible }
        if findings.isEmpty || findings.contains(where: { $0.outcome == .unknown }) { return .unknown }
        return findings.contains(where: { $0.outcome == .conditional }) ? .conditional : .compatible
    }
    var evaluatedCount: Int { findings.filter { $0.outcome != .unknown }.count }
    var coverage: String { "\(evaluatedCount) of \(findings.count) checks have sufficient inputs and evidence" }
}

/// Rules assess only explicit facts. A connector label never implies a bus, voltage or pinout.
enum CompatibilityEngine {
    static let ruleVersion = "1"
    static func evaluate(_ project: HardwareProject, assembly: AssemblyRevision,
                         at now: Date = Date(), policy: CompatibilityPolicy = CompatibilityPolicy()) -> CompatibilityReport {
        var evaluator = Evaluator(project: project, assembly: assembly, now: now, policy: policy)
        return evaluator.run()
    }

    private struct Evaluator {
        let project: HardwareProject
        let assembly: AssemblyRevision
        let now: Date
        let policy: CompatibilityPolicy
        var findings: [CompatibilityFinding] = []
        func normalized(_ text: String?) -> String? {
            guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
            return value
        }
        func sourceValid(_ id: UUID, measured: Bool = false) -> Bool {
            guard let source = project.sources.first(where: { $0.id == id }), source.confidence != .candidate,
                  !measured || source.confidence == .measured else { return false }
            let age = now.timeIntervalSince(source.retrievedAt)
            return age >= -300 && age <= policy.maximumEvidenceAgeDays * 86400 &&
                (!source.url.isEmpty || source.attachmentID != nil || (source.confidence == .measured && !source.notes.isEmpty))
        }
        mutating func add(_ rule: String, _ outcome: CheckOutcome, _ explanation: String,
                          items: [UUID] = [], connection: UUID? = nil, groups: [[UUID]] = [],
                          inputs: [String: String] = [:], measured: Bool = false) {
            let missing = groups.contains { !$0.contains { sourceValid($0, measured: measured) } }
            let status: CheckOutcome = missing ? .unknown : outcome
            let suffix = missing ? " Evidence is missing, candidate, stale, or lacks a source location; this check is unverified." : ""
            findings.append(CompatibilityFinding(ruleID: rule, ruleVersion: CompatibilityEngine.ruleVersion,
                assemblyRevisionID: assembly.id, outcome: status, explanation: explanation + suffix,
                affectedItemIDs: Array(Set(items)).sorted { $0.uuidString < $1.uuidString }, connectionID: connection,
                sourceIDs: Array(Set(groups.flatMap { $0 })).sorted { $0.uuidString < $1.uuidString },
                inputs: inputs.merging(["maximumEvidenceAgeDays": String(policy.maximumEvidenceAgeDays),
                    "matingToleranceMM": String(policy.matingToleranceMM)]) { original, _ in original }, checkedAt: now))
        }
        func endpoint(_ endpoint: ConnectionEndpoint) -> (AssemblyItem, PartRevision, InterfaceSpec)? {
            guard let item = assembly.items.first(where: { $0.id == endpoint.itemID }),
                  let part = project.part(item.partRevisionID),
                  let port = part.interfaces.first(where: { $0.id == endpoint.interfaceID }) else { return nil }
            return (item, part, port)
        }
        mutating func run() -> CompatibilityReport {
            do { try ProjectFormat.validate(project) }
            catch {
                add("input.integrity", .unknown, error.localizedDescription)
                return report()
            }
            guard !assembly.items.isEmpty else {
                add("assembly.empty", .unknown, "Add parts and explicit connections before checking compatibility.")
                return report()
            }
            for connection in assembly.connections { check(connection) }
            for item in assembly.items {
                guard let part = project.part(item.partRevisionID) else { continue }
                if !assembly.connections.contains(where: { $0.from.itemID == item.id || $0.to.itemID == item.id }) {
                    add("connection.unconnected", .unknown, "\(part.name) has no explicit connection; connectivity is unverified.", items: [item.id])
                }
                resources(item, part)
                adapters(item, part)
                power(item, part)
                if part.software.isEmpty {
                    add("software.coverage", .unknown, "\(part.name): record software/driver support or an evidenced 'no driver required' entry.", items: [item.id])
                }
                for software in part.software {
                    add("software.\(software.id)", software.supported.map { $0 ? (software.conditions.isEmpty ? .compatible : .conditional) : .incompatible } ?? .unknown,
                        "\(part.name): \(software.name) \(software.version), driver \(software.driver.isEmpty ? "unspecified" : software.driver). \(software.conditions)",
                        items: [item.id], groups: [software.sourceIDs], inputs: ["supported": software.supported.map(String.init) ?? "Unknown"])
                }
                for question in part.unresolvedQuestions {
                    add("part.question.\(question)", .unknown, "\(part.name): \(question)", items: [item.id])
                }
            }
            for requirement in project.requirements {
                let field = ["rf", "thermal", "battery", "endurance", "field", "runtime"].contains { requirement.capability.lowercased().contains($0) }
                let status: CheckOutcome = requirement.satisfied.map { $0 ? (requirement.operatingCondition.isEmpty ? .compatible : .conditional) : .incompatible } ?? .unknown
                add("requirement.\(requirement.id)", status,
                    "\(requirement.capability): \(requirement.threshold). Conditions: \(requirement.operatingCondition). Evidence needed: \(requirement.evidenceNeeded)\(field ? ". Requires measured evidence; no simulated field-performance claim is made." : "")",
                    items: requirement.affectedItemIDs, groups: [requirement.sourceIDs], measured: field)
            }
            return report()
        }
        func report() -> CompatibilityReport { CompatibilityReport(assemblyRevisionID: assembly.id, findings: findings, checkedAt: now) }
        mutating func check(_ connection: HardwareConnection) {
            guard let (fromItem, _, source) = endpoint(connection.from), let (toItem, _, sink) = endpoint(connection.to) else { return }
            let items = [fromItem.id, toItem.id], groups = [source.sourceIDs, sink.sourceIDs]
            func text(_ range: NumericRange?) -> String { range.map { "\($0.minimum)…\($0.maximum) V" } ?? "Unknown" }
            func match(_ a: String?, _ b: String?) -> CheckOutcome {
                guard let a = normalized(a), let b = normalized(b) else { return .unknown }
                return a == b ? .compatible : .incompatible
            }
            add("connection.connector", match(source.connector, sink.connector), "\(connection.name): connector \(source.connector ?? "Unknown") → \(sink.connector ?? "Unknown").", items: items, connection: connection.id, groups: groups)
            add("connection.key", match(source.key, sink.key), "\(connection.name): mating key \(source.key ?? "Unknown") → \(sink.key ?? "Unknown"); use 'none' for a documented unkeyed interface.", items: items, connection: connection.id, groups: groups)
            let genders = ["male": "female", "female": "male", "plug": "receptacle", "receptacle": "plug", "genderless": "genderless"]
            let gender: CheckOutcome
            if let a = normalized(source.gender), let b = normalized(sink.gender), let mate = genders[a], genders[b] != nil { gender = mate == b ? .compatible : .incompatible } else { gender = .unknown }
            add("connection.gender", gender, "\(connection.name): gender \(source.gender ?? "Unknown") → \(sink.gender ?? "Unknown").", items: items, connection: connection.id, groups: groups)
            let direction: CheckOutcome = source.direction == .unknown || sink.direction == .unknown ? .unknown :
                ((source.direction == .output || source.direction == .bidirectional) && (sink.direction == .input || sink.direction == .bidirectional) ? .compatible : .incompatible)
            add("connection.direction", direction, "\(connection.name): declared flow \(source.direction.rawValue) → \(sink.direction.rawValue).", items: items, connection: connection.id, groups: groups)
            let voltage: CheckOutcome
            if let a = source.voltage, let b = sink.voltage {
                voltage = a.minimum >= b.minimum && a.maximum <= b.maximum ? .compatible : .incompatible
            } else { voltage = .unknown }
            add("connection.voltage", voltage, "\(connection.name): full source range \(text(source.voltage)) must fit receiver range \(text(sink.voltage)).", items: items, connection: connection.id, groups: groups,
                inputs: ["source": text(source.voltage), "receiver": text(sink.voltage)])
            let protocolStatus: CheckOutcome
            if let required = normalized(connection.requiredProtocol) {
                protocolStatus = source.protocols.isEmpty || sink.protocols.isEmpty ? .unknown :
                    (source.protocols.compactMap(normalized).contains(required) && sink.protocols.compactMap(normalized).contains(required) ? .compatible : .incompatible)
            } else { protocolStatus = .unknown }
            add("connection.protocol", protocolStatus, "\(connection.name): required bus/protocol \(connection.requiredProtocol ?? "Unknown"); source [\(source.protocols.joined(separator: ", "))], receiver [\(sink.protocols.joined(separator: ", "))].", items: items, connection: connection.id, groups: groups)
            let aPins = Dictionary(source.pinMapping.map { (normalized($0.key) ?? "", normalized($0.value) ?? "") }, uniquingKeysWith: { a, _ in a })
            let bPins = Dictionary(sink.pinMapping.map { (normalized($0.key) ?? "", normalized($0.value) ?? "") }, uniquingKeysWith: { a, _ in a })
            let pinStatus: CheckOutcome = aPins.isEmpty || bPins.isEmpty || aPins.values.contains("") || bPins.values.contains("") ? .unknown : (aPins == bPins ? .compatible : .incompatible)
            add("connection.pinmap", pinStatus, "\(connection.name): pin numbers and signal labels must match at this physical edge; adapter transformations apply only inside the adapter.", items: items, connection: connection.id, groups: groups)
            let aDims = [source.dimensions?.widthMM, source.dimensions?.lengthMM, source.dimensions?.heightMM]
            let bDims = [sink.dimensions?.widthMM, sink.dimensions?.lengthMM, sink.dimensions?.heightMM]
            let dims: CheckOutcome = aDims.contains(nil) || bDims.contains(nil) ? .unknown :
                (zip(aDims, bDims).allSatisfy { abs($0! - $1!) <= policy.matingToleranceMM } ? .compatible : .incompatible)
            add("connection.mating_dimensions", dims, "\(connection.name): interface mating dimensions compared within \(policy.matingToleranceMM) mm. Enclosure clearance and mechanical tolerances beyond these records remain unverified.", items: items, connection: connection.id, groups: groups)
        }

        mutating func resources(_ item: AssemblyItem, _ part: PartRevision) {
            var groups: [String: [InterfaceSpec]] = [:]
            for port in part.interfaces {
                let connections = assembly.connections.filter { ($0.from.itemID == item.id && $0.from.interfaceID == port.id) || ($0.to.itemID == item.id && $0.to.interfaceID == port.id) }
                guard !connections.isEmpty else { continue }
                resourceCheck(item, ports: [port], connections: connections, scope: port.id.uuidString)
                if let group = normalized(port.resourceGroup) { groups[group, default: []].append(port) }
            }
            for (group, ports) in groups.sorted(by: { $0.key < $1.key }) {
                let ids = Set(ports.map(\.id))
                let connections = assembly.connections.filter { ($0.from.itemID == item.id && ids.contains($0.from.interfaceID)) || ($0.to.itemID == item.id && ids.contains($0.to.interfaceID)) }
                resourceCheck(item, ports: ports, connections: connections, scope: "group:\(group)")
            }
        }
        mutating func resourceCheck(_ item: AssemblyItem, ports: [InterfaceSpec], connections: [HardwareConnection], scope: String) {
            var count = 0, lanes = 0, known = true, overflow = false
            for connection in connections {
                let peerID = connection.from.itemID == item.id ? connection.to.itemID : connection.from.itemID
                let quantity = assembly.items.first { $0.id == peerID }?.quantity ?? 1
                // Multiple source instances cannot be assumed to distribute a shared load evenly.
                let multiplier = connection.from.itemID == item.id ? quantity : 1
                let newCount = count.addingReportingOverflow(multiplier)
                overflow = overflow || newCount.overflow; count = newCount.partialValue
                if let required = connection.lanesRequired {
                    let demand = required.multipliedReportingOverflow(by: multiplier)
                    let newLanes = lanes.addingReportingOverflow(demand.partialValue)
                    overflow = overflow || demand.overflow || newLanes.overflow
                    lanes = newLanes.partialValue
                } else { known = false }
            }
            let capacityValues = Set(ports.compactMap(\.capacity)), laneValues = Set(ports.compactMap(\.lanes))
            let capacity = capacityValues.count == 1 && ports.allSatisfy({ $0.capacity != nil }) ? capacityValues.first : nil
            let available = laneValues.count == 1 && ports.allSatisfy({ $0.lanes != nil }) ? laneValues.first : nil
            let uncertainMultiplicity = overflow || (item.quantity != 1 && connections.contains { $0.from.itemID == item.id })
            if overflow { known = false; count = 0; lanes = 0 }
            add("resource.ports.\(scope)", uncertainMultiplicity ? .unknown : capacity.map { count <= $0 ? .compatible : .incompatible } ?? .unknown,
                "\(scope): \(overflow ? "Unrepresentable demand" : String(count)) attached instances; declared connection capacity \(capacity.map(String.init) ?? "Unknown or inconsistent"). Multiple source instances require separate item rows.",
                items: [item.id], groups: ports.map(\.sourceIDs), inputs: ["used": String(count), "capacity": capacity.map(String.init) ?? "Unknown"])
            add("resource.lanes.\(scope)", known && !uncertainMultiplicity ? available.map { lanes <= $0 ? .compatible : .incompatible } ?? .unknown : .unknown,
                "\(scope): \(known ? String(lanes) : "Unknown") lanes required; declared shared/port budget \(available.map(String.init) ?? "Unknown or inconsistent").",
                items: [item.id], groups: ports.map(\.sourceIDs), inputs: ["used": known ? String(lanes) : "Unknown", "capacity": available.map(String.init) ?? "Unknown"])
        }

        mutating func adapters(_ item: AssemblyItem, _ part: PartRevision) {
            for mapping in part.adapters {
                guard let input = part.interfaces.first(where: { $0.id == mapping.inputInterfaceID }),
                      let output = part.interfaces.first(where: { $0.id == mapping.outputInterfaceID }) else { continue }
                var status = CheckOutcome.compatible
                var reasons: [String] = []
                if let a = normalized(mapping.inputProtocol), let b = normalized(mapping.outputProtocol) {
                    if !input.protocols.compactMap(normalized).contains(a) || !output.protocols.compactMap(normalized).contains(b) { status = .incompatible; reasons.append("mapping protocol is absent from an endpoint") }
                } else { status = .unknown; reasons.append("input/output protocol transformation is unspecified") }
                if let voltage = mapping.outputVoltage, let portVoltage = output.voltage {
                    if voltage != portVoltage { status = .incompatible; reasons.append("mapping output voltage disagrees with the output port") }
                } else if status != .incompatible { status = .unknown; reasons.append("output voltage is unspecified") }
                if mapping.inputInterfaceID == mapping.outputInterfaceID { status = .incompatible; reasons.append("adapter input and output must be different interfaces") }
                if status == .compatible && !mapping.conditions.isEmpty { status = .conditional }
                add("adapter.mapping.\(mapping.id)", status, "\(part.name): \(input.name) → \(output.name). \(reasons.joined(separator: "; ")). \(mapping.conditions) External connector, pinmap, voltage, bus and resource checks still apply.",
                    items: [item.id], groups: [mapping.sourceIDs, input.sourceIDs, output.sourceIDs])
                if let limit = mapping.capacityCurrentA {
                    let load = downstream(item: item, port: output, visited: [])
                    let voltage = output.voltage?.minimum
                    let current = load.watts.flatMap { watts in voltage.flatMap { $0 > 0 ? watts / $0 : nil } }
                    add("adapter.current.\(mapping.id)", current.map { $0 <= limit ? .compatible : .incompatible } ?? .unknown,
                        "\(part.name): adapter peak output current \(current.map { String(format: "%.3f A", $0) } ?? "Unknown") versus \(limit) A. \(load.notes.joined(separator: "; "))",
                        items: [item.id] + load.items, groups: [mapping.sourceIDs] + load.groups)
                } else {
                    add("adapter.current.\(mapping.id)", .unknown, "\(part.name): adapter current capacity is unknown.", items: [item.id], groups: [mapping.sourceIDs])
                }
            }
        }

        struct Load {
            var watts: Double? = 0
            var groups: [[UUID]] = []
            var items: [UUID] = []
            var notes: [String] = []
            var conditions: [String] = []
            mutating func combine(_ other: Load, multiplier: Double = 1) {
                watts = watts.flatMap { a in other.watts.map { a + $0 * multiplier } }
                groups += other.groups; items += other.items; notes += other.notes; conditions += other.conditions
            }
        }
        func downstream(item: AssemblyItem, port: InterfaceSpec, visited: Set<String>) -> Load {
            let key = "\(item.id):\(port.id)"
            guard !visited.contains(key) else { return Load(watts: nil, notes: ["Power cycle detected"]) }
            let visited = visited.union([key])
            let edges = assembly.connections.filter { $0.from.itemID == item.id && $0.from.interfaceID == port.id }
            guard !edges.isEmpty else { return Load(watts: nil, notes: ["No explicit downstream power connection"]) }
            var total = Load()
            for edge in edges {
                guard let (sinkItem, sinkPart, sinkPort) = endpoint(edge.to) else { continue }
                let rails = sinkPart.power.filter { $0.interfaceID == sinkPort.id && ($0.direction == .input || $0.direction == .bidirectional) }
                var load = Load(groups: [sinkPort.sourceIDs], items: [sinkItem.id])
                if rails.isEmpty { load.watts = nil; load.notes.append("\(sinkPart.name): missing peak input demand; typical values are never substituted") }
                for rail in rails {
                    let currentWatts = rail.peakCurrentA.flatMap { a in rail.voltage.map { a * $0.maximum } }
                    let watts = [rail.peakPowerW, currentWatts].compactMap { $0 }.max()
                    load.combine(Load(watts: watts, groups: [rail.sourceIDs], notes: watts == nil ? ["\(sinkPart.name): missing peak input demand"] : [],
                        conditions: rail.operatingConditions.isEmpty ? [] : [rail.operatingConditions]))
                }
                for mapping in sinkPart.adapters where mapping.inputInterfaceID == sinkPort.id {
                    guard let output = sinkPart.interfaces.first(where: { $0.id == mapping.outputInterfaceID }) else { continue }
                    var transformed = downstream(item: sinkItem, port: output, visited: visited)
                    if let efficiency = mapping.efficiency, efficiency > 0, efficiency <= 1 { transformed.watts = transformed.watts.map { $0 / efficiency } }
                    else { transformed.watts = nil; transformed.notes.append("\(sinkPart.name): adapter efficiency is unknown") }
                    transformed.groups.append(mapping.sourceIDs)
                    if !mapping.conditions.isEmpty { transformed.conditions.append(mapping.conditions) }
                    if sinkItem.quantity != 1 {
                        transformed.watts = nil
                        transformed.notes.append("\(sinkPart.name): multiple adapter instances need separate item rows to establish load distribution")
                    }
                    load.combine(transformed)
                }
                // Demand on an adapter's input is its own peak consumption plus downstream demand / efficiency.
                total.combine(load, multiplier: Double(sinkItem.quantity))
            }
            return total
        }
        mutating func power(_ item: AssemblyItem, _ part: PartRevision) {
            if part.power.isEmpty { add("power.coverage", .unknown, "\(part.name): no power specification recorded.", items: [item.id]); return }
            for rail in part.power {
                let port = part.interfaces.first { $0.id == rail.interfaceID }
                if rail.direction == .unknown {
                    add("power.direction.\(rail.id)", .unknown, "\(part.name): power direction is unspecified for \(rail.rail).", items: [item.id], groups: [rail.sourceIDs])
                }
                if rail.direction == .input || rail.direction == .bidirectional {
                    let incoming = assembly.connections.filter { $0.to.itemID == item.id && $0.to.interfaceID == rail.interfaceID }
                    add("power.input_path.\(rail.id)", port != nil && incoming.count == 1 ? .compatible : .unknown,
                        "\(part.name), \(rail.rail): \(incoming.count) upstream paths. Each input rail requires one explicit supply connection; parallel supplies and internal battery semantics need separate documentation.",
                        items: [item.id], groups: [rail.sourceIDs, port?.sourceIDs ?? []])
                }
                let coherent: CheckOutcome
                if let railRange = rail.voltage, let portRange = port?.voltage { coherent = railRange == portRange ? .compatible : .incompatible } else { coherent = .unknown }
                add("power.voltage_record.\(rail.id)", coherent,
                    "\(part.name), \(rail.rail): the rail voltage record must agree with its linked physical interface.",
                    items: [item.id], groups: [rail.sourceIDs, port?.sourceIDs ?? []])
            }
            var shared: [String: [(PowerSpec, Load)]] = [:]
            for rail in part.power where rail.direction == .output || rail.direction == .bidirectional {
                guard let port = part.interfaces.first(where: { $0.id == rail.interfaceID }) else {
                    add("power.port.\(rail.id)", .unknown, "\(part.name): output rail needs an explicit interface.", items: [item.id]); continue
                }
                let load = downstream(item: item, port: port, visited: [])
                powerBudget(item, rails: [rail], load: load, scope: rail.id.uuidString)
                if let key = normalized(rail.rail) { shared[key, default: []].append((rail, load)) }
            }
            for (key, values) in shared.sorted(by: { $0.key < $1.key }) where values.count > 1 {
                var total = Load()
                for (_, load) in values { total.combine(load) }
                powerBudget(item, rails: values.map { $0.0 }, load: total, scope: "shared:\(key)")
            }
        }
        mutating func powerBudget(_ item: AssemblyItem, rails: [PowerSpec], load: Load, scope: String) {
            let capacities = rails.map { rail -> Double? in
                let fromCurrent = rail.capacityCurrentA.flatMap { a in rail.voltage.map { a * $0.minimum } }
                return [rail.capacityPowerW, fromCurrent].compactMap { $0 }.min()
            }
            let capacity = Set(capacities.compactMap { $0 }).count == 1 && !capacities.contains(nil) ? capacities[0] : nil
            let margins = rails.map(\.headroomFraction)
            let margin = Set(margins.compactMap { $0 }).count == 1 && !margins.contains(nil) ? margins[0] : nil
            let required = load.watts.flatMap { watts in margin.map { watts * (1 + $0) } }
            let conditions = Array(Set(load.conditions + rails.map(\.operatingConditions).filter { !$0.isEmpty })).sorted()
            let pass: CheckOutcome = conditions.isEmpty ? .compatible : .conditional
            let status: CheckOutcome = item.quantity == 1 ? required.flatMap { used in capacity.map { used <= $0 ? pass : .incompatible } } ?? .unknown : .unknown
            add("power.budget.\(scope)", status,
                "Peak load \(load.watts.map { String(format: "%.3f W", $0) } ?? "Unknown"), headroom \(margin.map { String(format: "%.0f%%", $0 * 100) } ?? "Unknown"), required \(required.map { String(format: "%.3f W", $0) } ?? "Unknown"), capacity \(capacity.map { String(format: "%.3f W", $0) } ?? "Unknown or inconsistent"). Adapter losses and recipient quantities are included. Multiple supply instances require separate item rows. \(load.notes.joined(separator: "; "))\(conditions.isEmpty ? "" : " Conditions: " + conditions.joined(separator: "; "))",
                items: [item.id] + load.items, groups: rails.map(\.sourceIDs) + load.groups,
                inputs: ["peakWatts": load.watts.map(String.init(describing:)) ?? "Unknown", "requiredWatts": required.map(String.init(describing:)) ?? "Unknown", "capacityWatts": capacity.map(String.init(describing:)) ?? "Unknown"])
        }
    }
}
