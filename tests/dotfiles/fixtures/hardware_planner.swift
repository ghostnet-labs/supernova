import Foundation
import SQLite3

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
struct HardwarePlannerCases {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = try HardwareStore(directory: root.appendingPathComponent("original"))
        var project = HardwareProject(name: "Test BOM")
        let evidence = EvidenceSource(title: "Synthetic datasheet", url: "https://example.com/test", confidence: .manufacturer)
        let port = InterfaceSpec(name: "Port", connector: "Synthetic", protocols: ["Test bus"], voltage: NumericRange(minimum: 3, maximum: 3.3), sourceIDs: [evidence.id])
        let part = PartRevision(name: "=UNTRUSTED(\"x,y\")", manufacturer: "Example", interfaces: [port], sourceIDs: [evidence.id])
        let unknown = PartRevision(name: "Unknown price")
        let euro = PartRevision(name: "Euro part")
        let offer = Offer(partRevisionID: part.id, seller: "Seller", unitPrice: Decimal(string: "2.25"))
        let euroOffer = Offer(partRevisionID: euro.id, seller: "Euro seller", currency: "EUR", unitPrice: 3)
        var assembly = AssemblyRevision(name: "Assembly", items: [AssemblyItem(partRevisionID: part.id, quantity: 3, offerID: offer.id), AssemblyItem(partRevisionID: unknown.id, quantity: 2), AssemblyItem(partRevisionID: euro.id, offerID: euroOffer.id)])
        let endpoint = ConnectionEndpoint(itemID: assembly.items[0].id, interfaceID: port.id)
        assembly.connections = [HardwareConnection(name: "Synthetic loop", from: endpoint, to: endpoint)]
        let attachment = ManagedAttachment(filename: "../../evidence.txt", content: Data("Evidence contents".utf8))
        var attachedSource = EvidenceSource(title: "Attachment")
        attachedSource.attachmentID = attachment.id
        project.parts = [part, unknown, euro]; project.sources = [evidence, attachedSource]
        project.attachments = [attachment]; project.offers = [offer, euroOffer]
        project.assemblies = [assembly]; project.selectedAssemblyID = assembly.id
        project.requirements = [Requirement(capability: "Known capability", affectedItemIDs: [assembly.items[0].id], sourceIDs: [evidence.id])]
        project.decisions = [HardwareDecision(choice: "Candidate", reason: "Test", sourceIDs: [evidence.id])]
        project.findings = [CompatibilityFinding(ruleID: "synthetic", ruleVersion: "1", assemblyRevisionID: assembly.id, outcome: .unknown, explanation: "Fixture only", affectedItemIDs: [assembly.items[0].id], connectionID: assembly.connections[0].id, sourceIDs: [evidence.id])]
        project.overrides = [FindingOverride(findingID: project.findings[0].id, reason: "Fixture", author: "Test")]

        let start = Date()
        let saved = try await store.save(project)
        check(saved.version == 1, "first save version")
        let reopened = try HardwareStore(directory: root.appendingPathComponent("original"))
        let reloaded = try await reopened.load(saved.id)
        check(reloaded == saved, "durable reload")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("original/Attachments/\(project.id)/\(attachment.id)").path), "managed attachment exists without filename traversal")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("evidence.txt").path), "untrusted filename cannot escape attachment directory")

        let document = try ProjectFormat.encode(saved)
        let decoded = try ProjectFormat.decode(document)
        check(decoded == saved, "lossless JSON roundtrip")
        let importedStore = try HardwareStore(directory: root.appendingPathComponent("imported"))
        let imported = try await importedStore.importProject(document)
        check(imported == saved, "lossless database import preserves IDs, dates, version and evidence")
        do { _ = try await importedStore.importProject(document); fatalError("duplicate import accepted") } catch {}

        var mutated = saved; mutated.parts[0].name = "Changed in place"
        do { _ = try await store.save(mutated); fatalError("mutated part revision accepted") } catch {}
        mutated = saved; mutated.assemblies[0].items[0].quantity = 4
        do { _ = try await store.save(mutated); fatalError("mutated assembly revision accepted") } catch {}
        mutated = saved; mutated.offers[0].unitPrice = 9
        do { _ = try await store.save(mutated); fatalError("mutated offer accepted") } catch {}
        mutated = saved; mutated.sources[0].confidence = .measured
        do { _ = try await store.save(mutated); fatalError("mutated source accepted") } catch {}
        mutated = saved; mutated.attachments[0].content = Data("Changed evidence".utf8)
        do { _ = try await store.save(mutated); fatalError("mutated attachment accepted") } catch {}
        mutated = saved; mutated.findings[0].outcome = .compatible
        do { _ = try await store.save(mutated); fatalError("mutated historical finding accepted") } catch {}
        var revised = saved
        var updatedPart = part.revised(); updatedPart.notes = "New specification"
        revised.parts.append(updatedPart)
        var updatedAssembly = assembly.revised(); updatedAssembly.items[0].partRevisionID = updatedPart.id; updatedAssembly.items[0].offerID = nil
        revised.assemblies.append(updatedAssembly); revised.selectedAssemblyID = updatedAssembly.id
        let second = try await store.save(revised)
        check(second.version == 2, "second save version")
        let previousVersion = try await store.load(saved.id, version: 1)
        check(previousVersion == saved, "prior project history preserved")
        do { _ = try await store.save(saved); fatalError("stale write accepted") } catch {}

        let rows = BOMExport.rows(saved, assembly: assembly)
        check(BOMExport.totals(rows)["USD"] == Decimal(string: "6.75"), "quantity pricing")
        check(BOMExport.totals(rows)["EUR"] == 3, "currencies remain separate")
        check(rows[1].extendedPrice == nil, "unknown price not zero")
        var bulk = saved; bulk.offers[0].minimumQuantity = 5
        check(BOMExport.rows(bulk, assembly: assembly)[0].extendedPrice == nil, "quantity break cannot underprice small order")
        let csv = BOMExport.csv(saved, assembly: assembly)
        check(csv.contains("\"'=UNTRUSTED(\"\"x,y\"\")\""), "CSV quote and formula escaping")
        check(csv.contains(assembly.id.uuidString) && csv.contains("Unknown"), "CSV reproducible IDs and unknown price")
        let markdown = BOMExport.markdown(saved, assembly: assembly)
        check(markdown.contains("Unpriced lines: 1") && markdown.contains("Tax (USD): Unknown"), "report identifies incomplete totals")
        check(markdown.contains(saved.projectURL.absoluteString), "stable project link")

        func invalid(_ modify: (inout HardwareProject) -> Void, _ label: String) {
            var draft = saved; modify(&draft)
            do { try ProjectFormat.validate(draft); fatalError("Invalid \(label) accepted") } catch {}
        }
        invalid({ $0.parts.append($0.parts[0]) }, "duplicate ID")
        invalid({ $0.parts[0].interfaces[0].voltage = NumericRange(minimum: 5, maximum: 3) }, "range")
        invalid({ $0.parts[0].interfaces[0].voltage = NumericRange(minimum: .nan, maximum: 3) }, "NaN")
        invalid({ $0.assemblies[0].items[0].quantity = 0 }, "quantity")
        invalid({ $0.assemblies[0].items[0].offerID = euroOffer.id }, "wrong offer")
        invalid({ $0.assemblies[0].connections[0].from.interfaceID = UUID() }, "missing endpoint")
        invalid({ $0.requirements[0].affectedItemIDs = [UUID()] }, "missing requirement item")
        invalid({ $0.findings[0].connectionID = UUID() }, "missing finding connection")
        invalid({ $0.findings[0].affectedItemIDs = [UUID()] }, "missing finding item")
        invalid({ $0.sources[0].url = "file:///private/secret" }, "source scheme")
        invalid({ $0.offers[0].url = "javascript:alert(1)" }, "offer scheme")
        invalid({ $0.assemblies[0].costCurrency = "???" }, "assembly currency")
        invalid({ $0.offers[0].unitPrice = -1 }, "negative money")
        var envelope = ProjectEnvelope(project: saved); envelope.schemaVersion = 9
        do { _ = try ProjectFormat.decode(JSONEncoder().encode(envelope)); fatalError("future JSON schema accepted") } catch {}
        let importFile = root.appendingPathComponent("bounded-import.json")
        let importData = try ProjectFormat.encode(saved)
        try importData.write(to: importFile)
        let boundedData = try ProjectFormat.readFile(importFile, maximumBytes: importData.count)
        check(boundedData == importData, "bounded file read preserves exact bytes")
        do { _ = try ProjectFormat.readFile(importFile, maximumBytes: importData.count - 1); fatalError("oversized file read accepted") } catch {}

        let backup = try await store.backup()
        var backupDB: OpaquePointer?
        check(sqlite3_open_v2(backup.path, &backupDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "backup opens")
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(backupDB, "PRAGMA integrity_check", -1, &statement, nil)
        check(prepareStatus == SQLITE_OK, "prepare backup check: \(prepareStatus) / \(String(cString: sqlite3_errmsg(backupDB)))")
        let integrityStatus = sqlite3_step(statement)
        let integrityText = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "no result"
        check(integrityStatus == SQLITE_ROW && integrityText == "ok", "backup integrity: \(integrityStatus) / \(integrityText)")
        sqlite3_finalize(statement); sqlite3_close(backupDB)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("original/Backups").path)
        check(backups.contains { $0.hasPrefix("before-schema-1-") }, "migration backup")
        let futureDirectory = root.appendingPathComponent("future")
        try FileManager.default.createDirectory(at: futureDirectory, withIntermediateDirectories: true)
        var futureDB: OpaquePointer?
        sqlite3_open(futureDirectory.appendingPathComponent("projects.sqlite3").path, &futureDB)
        sqlite3_exec(futureDB, "PRAGMA user_version=999", nil, nil, nil); sqlite3_close(futureDB)
        do { _ = try HardwareStore(directory: futureDirectory); fatalError("future database schema accepted") } catch {}
        let seed = HardwareProject.fieldNodeCandidates()
        check(seed.parts.count >= 10 && seed.parts.allSatisfy { $0.interfaces.isEmpty && $0.power.isEmpty }, "seed has honest unknown specs")
        check(seed.sources.allSatisfy { $0.confidence == .candidate }, "chat claims remain candidates")
        print(String(format: "PASS: Hardware Planner storage, revision, import/export, graph validation and BOM fixtures (%.3f s)", Date().timeIntervalSince(start)))
    }
}
