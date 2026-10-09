import Foundation
import CryptoKit

/// Explicit interchange only: neither consumer opens the other app's database.
struct HardwareReport: Codable, Equatable, Identifiable {
    var format = "hardware-planner-report"
    var schemaVersion = 1
    var id = UUID()
    var exportedAt = Date()
    var projectID: UUID
    var projectName: String
    var projectVersion: Int
    var assemblyID: UUID
    var assemblyName: String
    var assemblyRevision: Int
    var ruleVersion: String
    var evaluatedChecks: Int
    var outcome: String
    var parts: [Part]
    var connections: [String]
    var requirements: [String]
    var checks: [Check]
    var sources: [Source]
    struct Part: Codable, Equatable, Identifiable {
        var id: UUID
        var revisionID: UUID
        var name: String
        var revision: Int
        var quantity: Int
        var details: String
        var questions: [String]
    }
    struct Check: Codable, Equatable, Identifiable {
        var id: UUID
        var rule: String
        var outcome: String
        var explanation: String
        var sourceIDs: [UUID]
    }
    struct Source: Codable, Equatable, Identifiable {
        var id: UUID
        var title: String
        var url: String
        var section: String
        var revision: String
        var retrievedAt: Date
        var confidence: String
        var notes: String
    }
    var link: HardwareProjectLink { HardwareProjectLink(projectID: projectID, assemblyID: assemblyID) }
    var coverage: String { "\(evaluatedChecks) of \(checks.count) checks have sufficient inputs and evidence" }

    func text(maximumCharacters: Int? = nil) -> String {
        var lines = ["Hardware report \(id) · exported \(exportedAt.formatted(.iso8601))", "\(projectName) · project version \(projectVersion)", "\(assemblyName) · assembly revision \(assemblyRevision) [\(assemblyID)]", link.url.absoluteString,
            "Outcome: \(outcome). \(coverage). Rule version \(ruleVersion).",
            "This is an imported snapshot, not a live compatibility claim. Propose changes with report/source citations; Hardware Planner must preview and accept any assembly change.", "", "Selected parts:"]
        lines += parts.map { "[part:\($0.revisionID)] \($0.name) r\($0.revision) × \($0.quantity). \($0.details)\($0.questions.isEmpty ? "" : " Questions: " + $0.questions.joined(separator: "; "))" }
        lines += ["", "Explicit connections:"] + connections
        lines += ["", "Requirements and unresolved evidence:"] + requirements
        lines += ["", "Sources:"] + sources.map { "[source:\($0.id)] \($0.title) · \($0.url) · \($0.section) · document \($0.revision) · \($0.confidence) · observed \($0.retrievedAt.formatted(.iso8601)). \($0.notes)" }
        lines += ["", "Deterministic checks:"] + checks.map { "[check:\($0.id)] \($0.rule): \($0.outcome). \($0.explanation) Sources: \($0.sourceIDs.map(\.uuidString).joined(separator: ", "))" }
        let value = lines.joined(separator: "\n")
        guard let maximumCharacters, value.count > maximumCharacters else { return value }
        return String(value.prefix(maximumCharacters)) + "\n[Excerpt truncated. Open the attached report for all checks and source citations.]"
    }
}

struct HardwareProjectLink: Equatable {
    var projectID: UUID
    var assemblyID: UUID? = nil
    var sourceID: UUID? = nil
    var url: URL {
        var value = URLComponents()
        value.scheme = "hardware-planner"; value.host = "project"; value.path = "/\(projectID)"
        var items: [URLQueryItem] = []
        if let assemblyID { items.append(URLQueryItem(name: "assembly", value: assemblyID.uuidString)) }
        if let sourceID { items.append(URLQueryItem(name: "source", value: sourceID.uuidString)) }
        value.queryItems = items.isEmpty ? nil : items
        return value.url!
    }
    init(projectID: UUID, assemblyID: UUID? = nil, sourceID: UUID? = nil) {
        self.projectID = projectID; self.assemblyID = assemblyID; self.sourceID = sourceID
    }
    init(url: URL) throws {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false), value.scheme == "hardware-planner", value.host == "project",
              value.user == nil, value.password == nil, value.port == nil, value.fragment == nil,
              value.path.split(separator: "/").count == 1, let project = UUID(uuidString: String(value.path.dropFirst())) else { throw HardwareReportError.invalid("Invalid Hardware Planner project link.") }
        let query = value.queryItems ?? []
        guard query.allSatisfy({ ["assembly", "source"].contains($0.name) && UUID(uuidString: $0.value ?? "") != nil }), Set(query.map(\.name)).count == query.count else { throw HardwareReportError.invalid("Invalid assembly or source in Hardware Planner link.") }
        projectID = project
        assemblyID = query.first { $0.name == "assembly" }.flatMap { UUID(uuidString: $0.value!) }
        sourceID = query.first { $0.name == "source" }.flatMap { UUID(uuidString: $0.value!) }
    }
}

enum HardwareReportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum HardwareReportFormat {
    static let maximumBytes = 2 * 1024 * 1024
    static func read(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw HardwareReportError.invalid("Hardware report exceeds the 2 MB limit.") }
        return data
    }
    static func encode(_ report: HardwareReport) throws -> Data {
        try validate(report)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        guard data.count <= maximumBytes else { throw HardwareReportError.invalid("Hardware report exceeds the 2 MB limit.") }
        return data
    }
    static func decode(_ data: Data) throws -> HardwareReport {
        guard data.count <= maximumBytes else { throw HardwareReportError.invalid("Hardware report exceeds the 2 MB limit.") }
        let report = try JSONDecoder().decode(HardwareReport.self, from: data)
        try validate(report); return report
    }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ report: HardwareReport) throws {
        func require(_ valid: Bool, _ message: String) throws { if !valid { throw HardwareReportError.invalid(message) } }
        try require(report.format == "hardware-planner-report" && report.schemaVersion == 1, "Unsupported hardware report format or version.")
        try require(report.projectVersion >= 0 && report.assemblyRevision > 0 && !report.projectName.isEmpty && !report.assemblyName.isEmpty && !report.ruleVersion.isEmpty, "Incomplete project or assembly identity.")
        let outcomes = ["compatible", "conditional", "incompatible", "unknown"]
        try require(outcomes.contains(report.outcome) && report.checks.allSatisfy { outcomes.contains($0.outcome) }, "Invalid compatibility outcome.")
        try require(Set(report.parts.map(\.id)).count == report.parts.count && Set(report.checks.map(\.id)).count == report.checks.count && Set(report.sources.map(\.id)).count == report.sources.count, "Duplicate report identifiers.")
        try require(report.parts.allSatisfy { $0.quantity > 0 && $0.quantity <= 1_000_000 && $0.revision > 0 }, "Invalid part revision or quantity.")
        try require(report.evaluatedChecks == report.checks.filter { $0.outcome != "unknown" }.count, "Report coverage does not match its checks.")
        let expected = report.checks.contains { $0.outcome == "incompatible" } ? "incompatible" : report.checks.isEmpty || report.checks.contains { $0.outcome == "unknown" } ? "unknown" : report.checks.contains { $0.outcome == "conditional" } ? "conditional" : "compatible"
        try require(report.outcome == expected, "Report outcome does not match its checks.")
        let sources = Set(report.sources.map(\.id))
        try require(report.checks.allSatisfy { Set($0.sourceIDs).isSubset(of: sources) }, "A report check cites a missing source.")
        for source in report.sources where !source.url.isEmpty {
            let url = URL(string: source.url)
            try require(["http", "https"].contains(url?.scheme?.lowercased() ?? "") && url?.host?.isEmpty == false, "Report sources must use HTTP or HTTPS URLs.")
        }
    }
}
