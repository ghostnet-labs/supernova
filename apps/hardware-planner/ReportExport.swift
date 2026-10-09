import Foundation

enum HardwareReportExport {
    static func selected(_ project: HardwareProject, at date: Date = Date()) throws -> HardwareReport {
        try ProjectFormat.validate(project)
        guard let assembly = project.selectedAssembly else { throw HardwareError.invalid("Select an assembly before exporting a coordinator report.") }
        let checks = CompatibilityEngine.evaluate(project, assembly: assembly, at: date)
        let selectedParts = assembly.items.compactMap { project.part($0.partRevisionID) }
        let sourceIDs = Set(checks.findings.flatMap(\.sourceIDs) + selectedParts.flatMap(\.sourceIDs) + project.requirements.flatMap(\.sourceIDs) + assembly.connections.flatMap(\.sourceIDs))
        let report = HardwareReport(exportedAt: date, projectID: project.id, projectName: project.name, projectVersion: project.version,
            assemblyID: assembly.id, assemblyName: assembly.name, assemblyRevision: assembly.revision, ruleVersion: CompatibilityEngine.ruleVersion,
            evaluatedChecks: checks.evaluatedCount, outcome: checks.outcome.rawValue,
            parts: assembly.items.compactMap { item in
                guard let part = project.part(item.partRevisionID) else { return nil }
                return HardwareReport.Part(id: item.id, revisionID: part.id, name: part.name, revision: part.revision, quantity: item.quantity,
                    details: "\(part.manufacturer) \(part.partNumber) · board \(part.boardRevision) · \(item.role)", questions: part.unresolvedQuestions)
            }, connections: assembly.connections.map { "\($0.name) [\($0.id)]: item \($0.from.itemID)/port \($0.from.interfaceID) → item \($0.to.itemID)/port \($0.to.interfaceID)" },
            requirements: project.requirements.map { "[requirement:\($0.id)] \($0.capability): \($0.threshold); condition: \($0.operatingCondition); evidence needed: \($0.evidenceNeeded); recorded status: \($0.satisfied.map { $0 ? "Satisfied" : "Unsatisfied" } ?? "Unknown"). Sources: \($0.sourceIDs.map(\.uuidString).joined(separator: ", "))" },
            checks: checks.findings.map { HardwareReport.Check(id: $0.id, rule: $0.ruleID, outcome: $0.outcome.rawValue, explanation: $0.explanation, sourceIDs: $0.sourceIDs) },
            sources: project.sources.filter { sourceIDs.contains($0.id) }.map { HardwareReport.Source(id: $0.id, title: $0.title, url: $0.url, section: $0.section, revision: $0.documentRevision, retrievedAt: $0.retrievedAt, confidence: $0.confidence.rawValue, notes: $0.notes) })
        try HardwareReportFormat.validate(report)
        return report
    }
}
