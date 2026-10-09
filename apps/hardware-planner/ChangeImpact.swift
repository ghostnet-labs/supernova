import Foundation

struct CheckDelta: Identifiable {
    var id: String
    var before: CompatibilityFinding?
    var after: CompatibilityFinding?
}

struct AdapterNeed: Identifiable {
    var id: UUID
    var connectionName: String
    var transformations: [String]
}

struct HardwareChangePreview {
    var originalProject: HardwareProject
    var proposedProject: HardwareProject
    var before: CompatibilityReport
    var after: CompatibilityReport
    var affectedItemIDs: Set<UUID>
    var affectedConnectionIDs: Set<UUID>
    var affectedRequirementIDs: Set<UUID>
    var affectedAdapterNames: [String]
    var newAdapterNeeds: [AdapterNeed]
    var changedChecks: [CheckDelta]
    var quantityDelta: Int
    var costDelta: [String: Decimal]
    var unpricedBefore: Int
    var unpricedAfter: Int
    var warnings: [String]

    /// Accept only against the exact snapshot previewed. Saving remains the caller's transaction.
    func accepting(current: HardwareProject) throws -> HardwareProject {
        guard current == originalProject else { throw HardwareError.conflict }
        try ProjectFormat.validateRevisionHistory(proposedProject, previous: current)
        try ProjectFormat.validate(proposedProject)
        return proposedProject
    }
}

enum HardwareChangeImpact {
    static func preview(_ project: HardwareProject, itemID: UUID, replacementRevisionID: UUID,
                        quantity: Int, offerID: UUID?, interfaceMap: [UUID: UUID],
                        at now: Date = Date(), policy: CompatibilityPolicy = CompatibilityPolicy()) throws -> HardwareChangePreview {
        guard let original = project.selectedAssembly,
              let index = original.items.firstIndex(where: { $0.id == itemID }),
              let replacement = project.part(replacementRevisionID) else { throw HardwareError.invalid("Choose an assembly item and a replacement revision.") }
        guard quantity > 0 && quantity <= 1_000_000 else { throw HardwareError.invalid("Quantity must be between 1 and 1,000,000.") }
        if let offerID, !project.offers.contains(where: { $0.id == offerID && $0.partRevisionID == replacementRevisionID }) {
            throw HardwareError.invalid("Choose an offer for the replacement revision.")
        }
        var proposed = original.revised()
        proposed.revision = (project.assemblies.filter { $0.assemblyID == original.assemblyID }.map(\.revision).max() ?? 0) + 1
        proposed.createdAt = now
        proposed.items[index].partRevisionID = replacementRevisionID
        proposed.items[index].quantity = quantity
        proposed.items[index].offerID = offerID
        for connectionIndex in proposed.connections.indices {
            for isFrom in [true, false] {
                let endpoint = isFrom ? proposed.connections[connectionIndex].from : proposed.connections[connectionIndex].to
                guard endpoint.itemID == itemID else { continue }
                let mappedID = interfaceMap[endpoint.interfaceID] ?? endpoint.interfaceID
                guard replacement.interfaces.contains(where: { $0.id == mappedID }) else {
                    throw HardwareError.invalid("Map every connected old interface to a replacement interface. Connections are never silently deleted.")
                }
                let mapped = ConnectionEndpoint(itemID: itemID, interfaceID: mappedID)
                if isFrom { proposed.connections[connectionIndex].from = mapped } else { proposed.connections[connectionIndex].to = mapped }
            }
        }
        let graph = affectedGraph(original, startingAt: itemID)
        let requirements = project.requirements.filter { $0.affectedItemIDs.isEmpty || !Set($0.affectedItemIDs).isDisjoint(with: graph.items) }
        let affectedRequirementIDs = Set(requirements.map(\.id))
        var next = project
        next.assemblies.append(proposed); next.selectedAssemblyID = proposed.id; next.updatedAt = now
        let invalidated = invalidateRequirements(in: &next, replacing: original, with: proposed)
        try ProjectFormat.validate(next)
        let before = CompatibilityEngine.evaluate(project, assembly: original, at: now, policy: policy)
        let after = CompatibilityEngine.evaluate(next, assembly: proposed, at: now, policy: policy)
        // Preserve the old assessment even when the user had not saved a report.
        // Its evidence remains attached to the original immutable assembly.
        next.findings.append(contentsOf: before.findings + after.findings)
        let adapterNames = proposed.items.filter { graph.items.contains($0.id) }.compactMap { item -> String? in
            guard let part = next.part(item.partRevisionID), !part.adapters.isEmpty else { return nil }
            return part.name
        }
        let transformations = ["connection.connector": "connector mating", "connection.key": "keying", "connection.gender": "gender",
            "connection.voltage": "voltage regulation", "connection.protocol": "protocol conversion", "connection.pinmap": "pin routing"]
        let adapterNeeds = proposed.connections.compactMap { connection -> AdapterNeed? in
            let newConflicts = after.findings.filter { finding in
                finding.connectionID == connection.id && finding.outcome == .incompatible && transformations[finding.ruleID] != nil &&
                    !before.findings.contains { $0.connectionID == connection.id && $0.ruleID == finding.ruleID && $0.outcome == .incompatible }
            }
            guard !newConflicts.isEmpty else { return nil }
            return AdapterNeed(id: connection.id, connectionName: connection.name,
                transformations: newConflicts.compactMap { transformations[$0.ruleID] }.sorted())
        }
        let oldRows = BOMExport.rows(project, assembly: original), newRows = BOMExport.rows(next, assembly: proposed)
        let oldTotals = BOMExport.totals(oldRows), newTotals = BOMExport.totals(newRows)
        let currencies = Set(oldTotals.keys).union(newTotals.keys)
        var warnings: [String] = []
        if oldRows.contains(where: { $0.extendedPrice == nil }) || newRows.contains(where: { $0.extendedPrice == nil }) {
            warnings.append("Cost deltas include known offers only. Unknown prices and minimum quantities prevent a complete total.")
        }
        if requirements.contains(where: { $0.affectedItemIDs.isEmpty }) {
            warnings.append("Requirements without explicit item scope are included conservatively.")
        }
        if !invalidated.isEmpty {
            warnings.append("Affected requirement outcomes are now Unknown until the changed hardware is assessed. Original checks and supporting evidence remain in history.")
        }
        if replacement.adapters.isEmpty && project.part(original.items[index].partRevisionID)?.adapters.isEmpty == false {
            warnings.append("The replacement removes documented adapter mappings; downstream checks may become unknown or incompatible.")
        }
        return HardwareChangePreview(originalProject: project, proposedProject: next, before: before, after: after,
            affectedItemIDs: graph.items, affectedConnectionIDs: graph.connections,
            affectedRequirementIDs: affectedRequirementIDs, affectedAdapterNames: adapterNames.sorted(), newAdapterNeeds: adapterNeeds,
            changedChecks: deltas(before.findings, after.findings),
            quantityDelta: quantity - original.items[index].quantity,
            costDelta: Dictionary(uniqueKeysWithValues: currencies.map { ($0, (newTotals[$0] ?? 0) - (oldTotals[$0] ?? 0)) }),
            unpricedBefore: oldRows.filter { $0.extendedPrice == nil }.count, unpricedAfter: newRows.filter { $0.extendedPrice == nil }.count,
            warnings: warnings)
    }

    /// Used by both the comparison preview and the general assembly editor.
    /// Price/name edits do not change hardware; topology, parts and quantities do.
    @discardableResult
    static func invalidateRequirements(in project: inout HardwareProject, replacing original: AssemblyRevision,
                                       with proposed: AssemblyRevision) -> Set<UUID> {
        let oldItems = Dictionary(uniqueKeysWithValues: original.items.map { ($0.id, $0) })
        let newItems = Dictionary(uniqueKeysWithValues: proposed.items.map { ($0.id, $0) })
        var changed = Set(oldItems.keys).union(newItems.keys).filter { id in
            oldItems[id]?.partRevisionID != newItems[id]?.partRevisionID || oldItems[id]?.quantity != newItems[id]?.quantity
        }
        let oldConnections = Dictionary(uniqueKeysWithValues: original.connections.map { ($0.id, $0) })
        let newConnections = Dictionary(uniqueKeysWithValues: proposed.connections.map { ($0.id, $0) })
        for id in Set(oldConnections.keys).union(newConnections.keys) where oldConnections[id] != newConnections[id] {
            for connection in [oldConnections[id], newConnections[id]].compactMap({ $0 }) {
                changed.formUnion([connection.from.itemID, connection.to.itemID])
            }
        }
        guard !changed.isEmpty else { return [] }
        var affected = changed
        for itemID in changed {
            affected.formUnion(affectedGraph(original, startingAt: itemID).items)
            affected.formUnion(affectedGraph(proposed, startingAt: itemID).items)
        }
        var invalidated = Set<UUID>()
        for index in project.requirements.indices {
            let requirement = project.requirements[index]
            guard requirement.affectedItemIDs.isEmpty || !Set(requirement.affectedItemIDs).isDisjoint(with: affected) else { continue }
            if requirement.satisfied != nil { invalidated.insert(requirement.id) }
            project.requirements[index].satisfied = nil
        }
        return invalidated
    }

    static func affectedGraph(_ assembly: AssemblyRevision, startingAt itemID: UUID) -> (items: Set<UUID>, connections: Set<UUID>) {
        var items: Set<UUID> = [itemID], connectionIDs = Set<UUID>(), queue = [itemID]
        while let current = queue.popLast() {
            for connection in assembly.connections where connection.from.itemID == current || connection.to.itemID == current {
                connectionIDs.insert(connection.id)
                for peer in [connection.from.itemID, connection.to.itemID] where items.insert(peer).inserted { queue.append(peer) }
            }
        }
        return (items, connectionIDs)
    }

    private static func deltas(_ before: [CompatibilityFinding], _ after: [CompatibilityFinding]) -> [CheckDelta] {
        func key(_ finding: CompatibilityFinding) -> String {
            "\(finding.ruleID)|\(finding.connectionID?.uuidString ?? "")|\(finding.affectedItemIDs.map(\.uuidString).sorted().joined(separator: ","))"
        }
        let old = Dictionary(before.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        return Set(old.keys).union(new.keys).sorted().compactMap { key in
            let a = old[key], b = new[key]
            guard a?.outcome != b?.outcome || a?.inputs != b?.inputs || a?.explanation != b?.explanation || a?.sourceIDs != b?.sourceIDs else { return nil }
            return CheckDelta(id: key, before: a, after: b)
        }
    }
}

enum CompatibilityExport {
    static func markdown(_ project: HardwareProject, report: CompatibilityReport) -> String {
        let assembly = project.assemblies.first { $0.id == report.assemblyRevisionID }
        func line(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ") }
        var lines = ["# Compatibility report: \(line(project.name))", "", "Project: \(project.projectURL.absoluteString)",
            "Assembly revision: \(assembly?.name ?? "Unknown") / \(report.assemblyRevisionID)",
            "Rules: \(CompatibilityEngine.ruleVersion); checked \(ISO8601DateFormatter().string(from: report.checkedAt))",
            "Result: \(report.outcome.rawValue). \(report.coverage).", "",
            "This result covers the explicit rules and evidence below. It does not prove complete physical, RF, thermal or field suitability.", ""]
        for finding in report.findings {
            lines += ["- **\(finding.outcome.rawValue)** [\(finding.ruleID)]: \(line(finding.explanation))",
                      "  - Items: \(finding.affectedItemIDs.map(\.uuidString).joined(separator: ", ")); connection: \(finding.connectionID?.uuidString ?? "n/a")"]
            for sourceID in finding.sourceIDs {
                if let source = project.sources.first(where: { $0.id == sourceID }) {
                    lines.append("  - Source: \(line(source.title)); \(source.url); section \(line(source.section)); revision \(line(source.documentRevision)); \(source.confidence.rawValue); observed \(ISO8601DateFormatter().string(from: source.retrievedAt))")
                }
            }
            for override in project.overrides where override.findingID == finding.id {
                lines.append("  - Manual override by \(line(override.author)): \(line(override.reason)). Machine result remains \(finding.outcome.rawValue).")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
