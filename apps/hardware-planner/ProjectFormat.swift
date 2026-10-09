import Foundation

struct ProjectEnvelope: Codable, Equatable {
    var format = "hardware-planner-project"
    var schemaVersion = 1
    var project: HardwareProject
}

enum ProjectFormat {
    static func readFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw HardwareError.invalid("The selected file exceeds the \(maximumBytes / (1024 * 1024)) MB size limit.")
        }
        return data
    }

    static func encode(_ project: HardwareProject) throws -> Data {
        try validate(project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ProjectEnvelope(project: project))
    }

    static func decode(_ data: Data) throws -> HardwareProject {
        guard data.count <= 50 * 1024 * 1024 else { throw HardwareError.invalid("Project exceeds the 50 MB import limit.") }
        let envelope = try JSONDecoder().decode(ProjectEnvelope.self, from: data)
        guard envelope.format == "hardware-planner-project", envelope.schemaVersion == 1 else {
            throw HardwareError.invalid("Unsupported project format or schema version. The original file was not changed.")
        }
        try validate(envelope.project)
        return envelope.project
    }

    static func validate(_ project: HardwareProject) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw HardwareError.invalid(message) }
        }
        func unique<T: Identifiable>(_ values: [T], _ name: String) throws where T.ID: Hashable {
            try require(Set(values.map(\.id)).count == values.count, "Duplicate IDs in \(name).")
        }
        func number(_ value: Double?, _ name: String) throws {
            if let value { try require(value.isFinite && value >= 0, "\(name) must be finite and nonnegative.") }
        }
        func range(_ value: NumericRange?) throws {
            if let value {
                try number(value.minimum, "Minimum voltage"); try number(value.maximum, "Maximum voltage")
                try require(value.minimum <= value.maximum, "Minimum voltage exceeds maximum voltage.")
            }
        }
        func dimensions(_ value: Dimensions?) throws {
            try number(value?.widthMM, "Width"); try number(value?.lengthMM, "Length"); try number(value?.heightMM, "Height")
        }
        func money(_ value: Decimal?) throws {
            if let value { try require(!value.isNaN && value >= 0, "Money must be nonnegative.") }
        }
        func currency(_ value: String) throws {
            try require(value.count == 3 && value.unicodeScalars.allSatisfy { (65...90).contains($0.value) }, "Currency must be a three-letter uppercase code.")
        }
        func webURL(_ value: String) throws {
            if !value.isEmpty {
                let url = URL(string: value)
                try require(["https", "http"].contains(url?.scheme?.lowercased() ?? "") && url?.host?.isEmpty == false, "Source and offer URLs must use HTTP or HTTPS and include a host.")
            }
        }
        try require(!project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Project needs a name.")
        try require(project.version >= 0, "Invalid project version.")
        try unique(project.parts, "parts"); try unique(project.assemblies, "assemblies")
        try unique(project.sources, "sources"); try unique(project.attachments, "attachments")
        try unique(project.offers, "offers"); try unique(project.requirements, "requirements")
        try unique(project.decisions, "decisions"); try unique(project.findings, "findings"); try unique(project.overrides, "overrides")
        let sourceIDs = Set(project.sources.map(\.id)), partIDs = Set(project.parts.map(\.id))
        func sources(_ ids: [UUID]) throws { try require(Set(ids).isSubset(of: sourceIDs), "A specification references a missing source.") }
        var partVersions = Set<String>()
        for part in project.parts {
            try require(part.revision > 0 && !part.name.isEmpty, "Part needs a name and positive revision.")
            try require(partVersions.insert("\(part.partID):\(part.revision)").inserted, "Duplicate part revision number.")
            try unique(part.interfaces, "interfaces"); try unique(part.power, "power rails")
            try unique(part.adapters, "adapter mappings"); try unique(part.software, "software support")
            try sources(part.sourceIDs); try dimensions(part.dimensions)
            let portIDs = Set(part.interfaces.map(\.id))
            for port in part.interfaces {
                try range(port.voltage); try dimensions(port.dimensions); try sources(port.sourceIDs)
                if let lanes = port.lanes { try require(lanes >= 0, "Lane count cannot be negative.") }
                if let capacity = port.capacity { try require(capacity >= 0, "Port capacity cannot be negative.") }
            }
            for rail in part.power {
                try range(rail.voltage); try sources(rail.sourceIDs)
                if let id = rail.interfaceID { try require(portIDs.contains(id), "Power rail references a missing interface.") }
                for value in [rail.typicalCurrentA, rail.peakCurrentA, rail.capacityCurrentA, rail.typicalPowerW,
                              rail.peakPowerW, rail.capacityPowerW, rail.headroomFraction] { try number(value, "Power rating") }
                if let value = rail.efficiency { try require(value.isFinite && value > 0 && value <= 1, "Efficiency must be greater than zero and at most one.") }
            }
            for adapter in part.adapters {
                try require(portIDs.contains(adapter.inputInterfaceID) && portIDs.contains(adapter.outputInterfaceID), "Adapter references missing interfaces.")
                try range(adapter.outputVoltage); try number(adapter.capacityCurrentA, "Adapter capacity"); try sources(adapter.sourceIDs)
                if let value = adapter.efficiency { try require(value.isFinite && value > 0 && value <= 1, "Adapter efficiency must be greater than zero and at most one.") }
            }
            for software in part.software { try sources(software.sourceIDs) }
        }
        for attachment in project.attachments {
            try require(!attachment.filename.isEmpty && attachment.content.count <= 20 * 1024 * 1024, "Invalid attachment or attachment larger than 20 MB.")
        }
        for source in project.sources {
            if let id = source.attachmentID { try require(project.attachments.contains { $0.id == id }, "Source attachment is missing.") }
            try webURL(source.url)
        }
        for offer in project.offers {
            try require(partIDs.contains(offer.partRevisionID), "Offer references a missing part revision.")
            try require(offer.minimumQuantity > 0, "Minimum offer quantity must be positive.")
            try currency(offer.currency); try webURL(offer.url)
            try money(offer.unitPrice)
        }
        var assemblyVersions = Set<String>()
        for assembly in project.assemblies {
            try require(assembly.revision > 0 && !assembly.name.isEmpty, "Assembly needs a name and positive revision.")
            try require(assemblyVersions.insert("\(assembly.assemblyID):\(assembly.revision)").inserted, "Duplicate assembly revision number.")
            try unique(assembly.items, "assembly items"); try unique(assembly.connections, "connections")
            try money(assembly.tax); try money(assembly.shipping); try currency(assembly.costCurrency)
            for item in assembly.items {
                try require(item.quantity > 0 && item.quantity <= 1_000_000, "Item quantity must be between 1 and 1,000,000.")
                try require(partIDs.contains(item.partRevisionID) && Set(item.alternativeRevisionIDs).isSubset(of: partIDs), "Assembly references a missing part revision.")
                if let id = item.offerID {
                    try require(project.offers.contains { $0.id == id && $0.partRevisionID == item.partRevisionID }, "Selected offer does not belong to the selected part revision.")
                }
            }
            for connection in assembly.connections {
                for endpoint in [connection.from, connection.to] {
                    let item = assembly.items.first { $0.id == endpoint.itemID }
                    let part = item.flatMap { project.part($0.partRevisionID) }
                    try require(part?.interfaces.contains { $0.id == endpoint.interfaceID } == true, "Connection references a missing item or interface.")
                }
                if let lanes = connection.lanesRequired { try require(lanes > 0, "Required lane count must be positive.") }
                try sources(connection.sourceIDs)
            }
        }
        if let selected = project.selectedAssemblyID { try require(project.assemblies.contains { $0.id == selected }, "Selected assembly is missing.") }
        let allItemIDs = Set(project.assemblies.flatMap { $0.items.map(\.id) })
        for requirement in project.requirements {
            try sources(requirement.sourceIDs)
            try require(Set(requirement.affectedItemIDs).isSubset(of: allItemIDs), "Requirement references a missing assembly item.")
        }
        for decision in project.decisions { try sources(decision.sourceIDs) }
        for finding in project.findings {
            try sources(finding.sourceIDs)
            guard let assembly = project.assemblies.first(where: { $0.id == finding.assemblyRevisionID }) else { throw HardwareError.invalid("Finding references a missing assembly revision.") }
            try require(Set(finding.affectedItemIDs).isSubset(of: Set(assembly.items.map(\.id))), "Finding references an item outside its assembly revision.")
            if let id = finding.connectionID { try require(assembly.connections.contains { $0.id == id }, "Finding references a connection outside its assembly revision.") }
        }
        for override in project.overrides { try require(project.findings.contains { $0.id == override.findingID }, "Override references a missing finding.") }
    }

    // Historical specifications, offers and assembly snapshots remain reproducible.
    static func validateRevisionHistory(_ next: HardwareProject, previous: HardwareProject) throws {
        for part in previous.parts where next.parts.first(where: { $0.id == part.id }) != part {
            throw HardwareError.invalid("Saved part revisions are immutable. Create a new revision of \(part.name).")
        }
        for assembly in previous.assemblies where next.assemblies.first(where: { $0.id == assembly.id }) != assembly {
            throw HardwareError.invalid("Saved assemblies are immutable. Create a new revision of \(assembly.name).")
        }
        for offer in previous.offers where next.offers.first(where: { $0.id == offer.id }) != offer {
            throw HardwareError.invalid("Saved offers are immutable. Record a new observation.")
        }
        for source in previous.sources where next.sources.first(where: { $0.id == source.id }) != source {
            throw HardwareError.invalid("Saved evidence is immutable. Add a new source observation.")
        }
        for attachment in previous.attachments where next.attachments.first(where: { $0.id == attachment.id }) != attachment {
            throw HardwareError.invalid("Saved attachment contents are immutable. Import a new document observation.")
        }
        for finding in previous.findings where next.findings.first(where: { $0.id == finding.id }) != finding {
            throw HardwareError.invalid("Saved compatibility findings are immutable. Add a new evaluation.")
        }
        for override in previous.overrides where next.overrides.first(where: { $0.id == override.id }) != override {
            throw HardwareError.invalid("Saved overrides are immutable. Add a new annotated override.")
        }
    }
}

struct BOMRow: Identifiable {
    var id: UUID
    var part: PartRevision
    var quantity: Int
    var role: String
    var offer: Offer?
    var extendedPrice: Decimal? {
        guard let offer, quantity >= offer.minimumQuantity, let price = offer.unitPrice else { return nil }
        return price * Decimal(quantity)
    }
}

enum BOMExport {
    static func rows(_ project: HardwareProject, assembly: AssemblyRevision) -> [BOMRow] {
        assembly.items.compactMap { item in
            guard let part = project.part(item.partRevisionID) else { return nil }
            return BOMRow(id: item.id, part: part, quantity: item.quantity, role: item.role,
                          offer: project.offers.first { $0.id == item.offerID })
        }
    }
    static func totals(_ rows: [BOMRow]) -> [String: Decimal] {
        rows.reduce(into: [:]) { totals, row in
            if let value = row.extendedPrice, let currency = row.offer?.currency { totals[currency, default: 0] += value }
        }
    }
    static func money(_ value: Decimal?) -> String { value.map { NSDecimalNumber(decimal: $0).stringValue } ?? "Unknown" }
    // Spreadsheet formula escaping affects CSV only. JSON retains exact original values.
    static func cell(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true || value.first == "\t" || value.first == "\r" ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    static func csv(_ project: HardwareProject, assembly: AssemblyRevision) -> String {
        let header = ["Assembly revision ID", "Part revision ID", "Name", "Manufacturer", "Part number", "Board revision", "Revision", "Quantity", "Role", "Seller", "URL", "Currency", "Unit price", "Extended price", "Observed at", "Availability"]
        let formatter = ISO8601DateFormatter()
        let values = rows(project, assembly: assembly).map { row in
            [assembly.id.uuidString, row.part.id.uuidString, row.part.name, row.part.manufacturer, row.part.partNumber,
             row.part.boardRevision, String(row.part.revision), String(row.quantity), row.role, row.offer?.seller ?? "",
             row.offer?.url ?? "", row.offer?.currency ?? "", money(row.offer?.unitPrice), money(row.extendedPrice),
             row.offer.map { formatter.string(from: $0.observedAt) } ?? "", row.offer?.availability ?? "Unknown"]
        }
        return ([header] + values).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
    static func markdown(_ project: HardwareProject, assembly: AssemblyRevision) -> String {
        func escape(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
        let items = rows(project, assembly: assembly)
        var lines = ["# \(project.name)", "", "Project: \(project.projectURL.absoluteString)", "Assembly: \(assembly.name), revision \(assembly.revision) (\(assembly.id))", "", "| Part | Revision | Quantity | Currency | Extended price |", "| --- | --- | ---: | --- | ---: |"]
        lines += items.map { "| \(escape($0.part.name)) | \($0.part.revision) | \($0.quantity) | \($0.offer?.currency ?? "Unknown") | \(money($0.extendedPrice)) |" }
        lines += ["", "Known subtotals (unknown prices excluded):"]
        lines += totals(items).sorted { $0.key < $1.key }.map { "- \($0.key): \(money($0.value))" }
        lines += ["- Unpriced lines: \(items.filter { $0.extendedPrice == nil }.count)", "- Tax (\(assembly.costCurrency)): \(money(assembly.tax))", "- Shipping (\(assembly.costCurrency)): \(money(assembly.shipping))", "", "## Requirements", ""]
        lines += project.requirements.map { "- \(escape($0.capability)): \(escape($0.threshold)); evidence: \(escape($0.evidenceNeeded)); status: \($0.satisfied.map { $0 ? "Satisfied" : "Unsatisfied" } ?? "Unknown")" }
        lines += ["", "## Compatibility evidence", ""]
        let findings = project.findings.filter { $0.assemblyRevisionID == assembly.id }
        lines += findings.isEmpty ? ["Not evaluated. No compatibility claim is implied by this BOM."] : findings.map { "- \($0.outcome.rawValue): \(escape($0.explanation)) [\($0.ruleID) v\($0.ruleVersion)]" }
        lines += ["", "## Sources", ""]
        lines += project.sources.map { "- \(escape($0.title)) — \($0.url), section \(escape($0.section)), document revision \(escape($0.documentRevision)); \($0.confidence.rawValue); retrieved \(ISO8601DateFormatter().string(from: $0.retrievedAt))" }
        return lines.joined(separator: "\n") + "\n"
    }
}
