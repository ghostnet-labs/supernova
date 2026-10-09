import Foundation

@main
struct HardwareReportChecks {
    static func require(_ valid: Bool, _ message: String) throws { if !valid { throw HardwareReportError.invalid(message) } }
    static func rejects(_ work: () async throws -> Void) async throws {
        do { try await work() } catch { return }
        throw HardwareReportError.invalid("Malformed input was accepted")
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var project = HardwareProject(name: "Selected field assembly")
        let source = EvidenceSource(title: "Exact board data", url: "https://example.com/board", section: "Power pins", documentRevision: "r3", confidence: .manufacturer)
        let privateSource = EvidenceSource(title: "Unselected private note")
        let part = PartRevision(name: "Board", sourceIDs: [source.id], unresolvedQuestions: ["Measure field endurance"])
        let unused = PartRevision(name: "Unselected alternative", sourceIDs: [privateSource.id])
        let assembly = AssemblyRevision(name: "Current", items: [AssemblyItem(partRevisionID: part.id, quantity: 2)])
        let other = AssemblyRevision(name: "Unselected", items: [AssemblyItem(partRevisionID: unused.id)])
        project.sources = [source, privateSource]; project.parts = [part, unused]; project.assemblies = [assembly, other]; project.selectedAssemblyID = assembly.id
        project.requirements = [Requirement(capability: "Endurance", evidenceNeeded: "Field measurement")]
        let now = Date()
        let report = try HardwareReportExport.selected(project, at: now)
        let data = try HardwareReportFormat.encode(report)
        try require(try HardwareReportFormat.decode(data) == report, "Report roundtrip changed IDs or provenance")
        try require(report.parts.count == 1 && report.parts[0].quantity == 2 && report.sources.map(\.id) == [source.id], "Export must include only the selected assembly and cited sources")
        try require(!String(decoding: data, as: UTF8.self).contains("Unselected"), "Unselected data leaked into report")
        try require(report.outcome == "unknown" && report.checks.contains { $0.outcome == "unknown" } && !report.requirements.isEmpty, "Unknown checks and requirements were hidden")
        try require(report.text().contains(source.id.uuidString) && report.text(maximumCharacters: 200).contains("Excerpt truncated"), "Citation or truncation notice missing")
        var bad = report; bad.schemaVersion = 2
        try await rejects { _ = try HardwareReportFormat.decode(JSONEncoder().encode(bad)) }
        bad = report; bad.evaluatedChecks += 1
        try await rejects { _ = try HardwareReportFormat.encode(bad) }
        bad = report; bad.outcome = "compatible"
        try await rejects { _ = try HardwareReportFormat.encode(bad) }
        bad = report; bad.sources[0].url = "file:///private/secret"
        try await rejects { _ = try HardwareReportFormat.encode(bad) }
        bad = report; bad.checks[0].sourceIDs = [UUID()]
        try await rejects { _ = try HardwareReportFormat.encode(bad) }
        try await rejects { _ = try HardwareReportFormat.decode(Data("{}".utf8)) }
        try await rejects { _ = try HardwareReportFormat.decode(Data(repeating: 32, count: HardwareReportFormat.maximumBytes + 1)) }
        let file = directory.appendingPathComponent("report.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file)
        try require(try HardwareReportFormat.read(file) == data, "Bounded file read changed report")

        let database = try AgentDatabase(directory: directory.appendingPathComponent("agent"))
        let personal = UUID().uuidString, work = UUID().uuidString
        try await database.transaction { db in
            for (id, scope) in [(personal, "Personal"), (work, "work:test")] {
                try db.execute("INSERT INTO projects(id,name,scope,common_dir,cwd) VALUES(?,?,?,?,?)", [id, "Test", scope, "", directory.path])
            }
        }
        let store = HardwareReportStore(database: database)
        let attached = try await store.attach(data: data, filename: "report.json", projectID: personal)
        let duplicate = try await store.attach(data: data, filename: "same.json", projectID: personal)
        try require(attached == duplicate, "Duplicate import changed historical provenance")
        try require(try await store.list(projectID: work).isEmpty, "Report leaked into Work project")
        try require(try await store.selection(projectID: personal) == nil, "Import implicitly enabled coordinator context")
        try await store.select(attached.id, projectID: personal)
        try require(try await store.selection(projectID: personal) == attached.id, "Explicit selection did not persist")
        try await rejects { try await store.select(attached.id, projectID: work) }
        try await rejects { try await store.remove(attached.id, projectID: work) }
        try await rejects { _ = try await store.attach(data: data, filename: "report.json", projectID: "missing") }
        let reloaded = HardwareReportStore(database: try AgentDatabase(directory: directory.appendingPathComponent("agent")))
        try require(try await reloaded.list(projectID: personal) == [attached], "Restart lost attachment")
        let model = HardwareReportModel()
        await model.load(projectID: personal, database: database)
        try require(model.context(projectID: personal).first?.contains(attached.fingerprint) == true, "Chosen report not supplied with hash")
        try require(model.context(projectID: work).isEmpty, "Project switch supplied previous project's context")
        await model.load(projectID: work, database: database)
        try require(model.context(projectID: work).isEmpty && model.attachments.isEmpty, "Switch failed to clear prior project")
        try await store.remove(attached.id, projectID: personal)
        try require(try await store.selection(projectID: personal) == nil, "Removal left active context")

        let link = HardwareProjectLink(projectID: project.id, assemblyID: assembly.id, sourceID: source.id)
        try require(try HardwareProjectLink(url: link.url) == link, "Stable source link failed roundtrip")
        for text in ["hardware-planner://project/\(project.id)?assembly=wrong", "hardware-planner://project/\(project.id)?source=\(source.id)&source=\(source.id)", "hardware-planner://project/\(project.id)?run=command", "hardware-planner://project/extra/\(project.id)"] {
            try await rejects { _ = try HardwareProjectLink(url: URL(string: text)!) }
        }
        let hardwareDirectory = directory.appendingPathComponent("hardware")
        let hardwareStore = try HardwareStore(directory: hardwareDirectory)
        _ = try await hardwareStore.save(project)
        let planner = PlannerModel(directory: hardwareDirectory)
        planner.openURL(link.url) // Exercises opening before the asynchronous store initialization.
        for _ in 0..<200 where planner.focusedSource == nil && planner.error == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(planner.project?.selectedAssemblyID == assembly.id && planner.focusedSource?.id == source.id && planner.error == nil, "Link did not open its exact assembly and cited source")
        let original = try await hardwareStore.load(project.id)
        try require(original?.version == 1, "Opening a link wrote to the Hardware Planner database")
        planner.openURL(HardwareProjectLink(projectID: project.id, assemblyID: UUID()).url)
        for _ in 0..<200 where planner.error == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(planner.error != nil && planner.project?.selectedAssemblyID == assembly.id, "Missing linked revision silently fell back to another assembly")
        let start = Date()
        for _ in 0..<100 { _ = try HardwareReportFormat.decode(data) }
        print("PASS: selected export, validation, project isolation, explicit context, restart, source links and native route; 100 decodes \(String(format: "%.3f", Date().timeIntervalSince(start))) s; report \(data.count) bytes")
    }
}
