import Foundation

struct HardwareReportAttachment: Codable, Equatable, Identifiable {
    var id: String
    var projectID: String
    var report: HardwareReport
    var fingerprint: String
    var filename: String
    var importedAt: Date
}

/// Stores only explicit imports in the current app's durable database.
struct HardwareReportStore {
    let database: AgentDatabase
    private static let namespace = "hardware-report-v1"
    private static let selectionNamespace = "hardware-report-selection-v1"
    func list(projectID: String) async throws -> [HardwareReportAttachment] {
        try await database.read { db in
            try db.query("SELECT json FROM managed_records WHERE namespace=? AND key LIKE ?", [Self.namespace, projectID + ":%"])
                .compactMap { $0["json"]?.data(using: .utf8) }
                .map { try JSONDecoder().decode(HardwareReportAttachment.self, from: $0) }
                .filter { $0.projectID == projectID }
                .sorted { $0.importedAt > $1.importedAt }
        }
    }
    func attach(data: Data, filename: String, projectID: String) async throws -> HardwareReportAttachment {
        let report = try HardwareReportFormat.decode(data)
        // Canonical content identifies an unchanged report even when JSON whitespace changes.
        let hash = HardwareReportFormat.fingerprint(try HardwareReportFormat.encode(report))
        let value = HardwareReportAttachment(id: projectID + ":" + hash, projectID: projectID, report: report,
            fingerprint: hash, filename: URL(fileURLWithPath: filename).lastPathComponent, importedAt: Date())
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return try await database.transaction { db in
            guard try db.query("SELECT id FROM projects WHERE id=?", [projectID]).count == 1 else { throw AgentStorageError.invalid("Choose an existing Agent Control Center project.") }
            if let previous = try db.query("SELECT json FROM managed_records WHERE namespace=? AND key=?", [Self.namespace, value.id]).first?["json"] {
                return try JSONDecoder().decode(HardwareReportAttachment.self, from: Data(previous.utf8))
            }
            try db.execute("INSERT INTO managed_records(namespace,key,json) VALUES(?,?,?)", [Self.namespace, value.id, json])
            return value
        }
    }
    func selection(projectID: String) async throws -> String? {
        try await database.read { db in
            try db.query("SELECT json FROM managed_records WHERE namespace=? AND key=?", [Self.selectionNamespace, projectID]).first?["json"]
        }
    }
    func select(_ id: String?, projectID: String) async throws {
        try await database.transaction { db in
            if let id {
                guard let json = try db.query("SELECT json FROM managed_records WHERE namespace=? AND key=?", [Self.namespace, id]).first?["json"],
                      try JSONDecoder().decode(HardwareReportAttachment.self, from: Data(json.utf8)).projectID == projectID else { throw AgentStorageError.invalid("That report belongs to a different project.") }
                try db.execute("INSERT OR REPLACE INTO managed_records(namespace,key,json) VALUES(?,?,?)", [Self.selectionNamespace, projectID, id])
            } else { try db.execute("DELETE FROM managed_records WHERE namespace=? AND key=?", [Self.selectionNamespace, projectID]) }
        }
    }
    func remove(_ id: String, projectID: String) async throws {
        try await database.transaction { db in
            guard let json = try db.query("SELECT json FROM managed_records WHERE namespace=? AND key=?", [Self.namespace, id]).first?["json"],
                  try JSONDecoder().decode(HardwareReportAttachment.self, from: Data(json.utf8)).projectID == projectID else { throw AgentStorageError.invalid("That report belongs to a different project.") }
            try db.execute("DELETE FROM managed_records WHERE namespace=? AND key=?", [Self.namespace, id])
            try db.execute("DELETE FROM managed_records WHERE namespace=? AND key=? AND json=?", [Self.selectionNamespace, projectID, id])
        }
    }
}
