import Foundation

@main
struct ProjectMemoryChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AgentStorageError.invalid(message) }
    }
    static func rejects(_ message: String, _ work: () async throws -> Void) async throws {
        do { try await work() } catch { return }
        throw AgentStorageError.invalid(message)
    }
    static func line(_ record: [String:Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]); data.append(10); return data
    }
    static func codex(_ text: String, role: String = "user", kind: String = "event_msg", time: String = "2026-10-07T12:00:00.000Z", id: String = "") throws -> Data {
        let payload: [String:Any] = kind == "event_msg" ? ["type":role == "user" ? "user_message":"agent_message","message":text] : ["type":"message","role":role,"id":id,"content":[["type":role == "user" ? "input_text":"output_text","text":text]]]
        return try line(["type":kind,"timestamp":time,"payload":payload])
    }
    static func main() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let repo = root.appendingPathComponent("repo"), worktree = root.appendingPathComponent("worktree"), dataDirectory = root.appendingPathComponent("state")
        let git = repo.appendingPathComponent(".git"), metadata = git.appendingPathComponent("worktrees/test")
        try FileManager.default.createDirectory(at:metadata,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:worktree,withIntermediateDirectories:true)
        try Data("gitdir: \(metadata.path)\n".utf8).write(to:worktree.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to:metadata.appendingPathComponent("commondir"))
        let database = try AgentDatabase(directory:dataDirectory)
        let memory = ProjectMemoryStore(database:database)
        let personal = try await memory.attachProject(path:repo.path)
        let linked = try await memory.attachProject(path:worktree.path)
        try require(personal.id == linked.id,"Worktrees must share stable project identity")
        let work = try await memory.attachProject(path:repo.path,scope:"work:test")
        try require(work.id != personal.id,"Personal and Work cannot merge")
        let personalList = try await memory.projects()
        try require(personalList.count == 1,"Personal must not expose Work records")
        let membership = try await memory.contains(project:personal,cwd:worktree.path)
        try require(membership,"Worktree must resolve through common Git directory")
        let nested = repo.appendingPathComponent("independent")
        try FileManager.default.createDirectory(at:nested.appendingPathComponent(".git"),withIntermediateDirectories:true)
        let nestedProject = try await memory.attachProject(path:nested.path)
        let nestedMembership = try await memory.contains(project:personal,cwd:nested.path)
        try require(nestedProject.id != personal.id && !nestedMembership,"A nested independent repository must not enter its parent project's memory")
        try FileManager.default.removeItem(at:nested)
        let missingMembership = try await memory.contains(project:nestedProject,cwd:nested.path)
        try require(missingMembership,"A deleted nested checkout retains its recorded project association for history")
        let ordinary = repo.appendingPathComponent("ordinary/subdirectory")
        try FileManager.default.createDirectory(at:ordinary,withIntermediateDirectories:true)
        let ordinaryMembership = try await memory.contains(project:personal,cwd:ordinary.path)
        try require(ordinaryMembership,"Ordinary subdirectories remain inside their repository project")
        let file = root.appendingPathComponent("not-directory"); try Data().write(to:file)
        try await rejects("Regular files must not be projects") { _ = try await memory.attachProject(path:file.path) }

        let path = root.appendingPathComponent("session.jsonl")
        let first = try codex("Use the copper connector")
        try first.write(to:path)
        let source = try await memory.registerSource(projectID:personal.id,provider:"Codex",sessionID:"native-session",title:"Connector decision",path:path.path)
        _ = try await memory.index(sourceID:source.id,byteBudget:4)
        var hits = try await memory.search(projectID:personal.id,query:"copper")
        try require(hits.count == 1,"Known project decision searchable")
        let citation = hits[0].source
        let proposal = try await memory.proposeDecision(projectID:personal.id,title:"Connector",detail:"Copper",sources:[citation])
        var combined = first
        combined.append(try codex("Use the copper connector",kind:"response_item",id:"item-1"))
        combined.append(try codex("Use the copper connector"))
        combined.append(try codex("Use the copper connector",kind:"response_item",id:"item-2"))
        combined.append(try line(["type":"response_item","payload":["type":"reasoning","text":"secret internal reasoning"]]))
        combined.append(try line(["type":"response_item","payload":["type":"message","role":"assistant","channel":"analysis","content":[["type":"output_text","text":"secret internal reasoning"]]]]))
        combined.append(try line(["type":"response_item","payload":["type":"function_call_output","output":"bulk tool secret"]]))
        combined.append(Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-07\",\"payload\":{\"type\":\"agent_message\",\"message\":\"partial result\"}}".utf8))
        let writer = try FileHandle(forWritingTo:path); try writer.seekToEnd(); try writer.write(contentsOf:combined.dropFirst(first.count)); try writer.close()
        _ = try await memory.index(sourceID:source.id)
        hits = try await memory.search(projectID:personal.id,query:"copper")
        try require(hits.count == 2,"Duplicate representations dedupe while identical real turns survive")
        _ = try await memory.resolve(citation)
        let secrets = try await memory.search(projectID:personal.id,query:"secret")
        let partial = try await memory.search(projectID:personal.id,query:"partial")
        try require(secrets.isEmpty && partial.isEmpty,"No reasoning, bulk tools, or partial line may be indexed")
        let checkpoint = try await memory.coverage(projectID:personal.id)
        let secondDatabase = try AgentDatabase(directory:dataDirectory)
        let resumed = ProjectMemoryStore(database:secondDatabase)
        let append = try FileHandle(forWritingTo:path); try append.seekToEnd(); try append.write(contentsOf:Data([10])); try append.close()
        _ = try await resumed.index(sourceID:source.id)
        let resumedHits = try await resumed.search(projectID:personal.id,query:"partial")
        try require(resumedHits.count == 1,"Restart must resume at the uncommitted line")
        let after = try await resumed.coverage(projectID:personal.id)
        try require(after.indexedBytes > checkpoint.indexedBytes,"Checkpoint advances only on complete records")
        let noWork = try await memory.search(projectID:work.id,query:"copper")
        try require(noWork.isEmpty,"Search cannot cross scope")

        var accepted = proposal; accepted.status = .accepted
        let acceptedValue = accepted
        try await rejects("Model cannot accept decisions") { try await memory.saveDecision(acceptedValue,userAction:false) }
        try await memory.saveDecision(accepted,userAction:true)
        accepted.delivery = .verified
        let unproven = accepted
        try await rejects("A claim must not become verified") { try await memory.saveDecision(unproven,userAction:true) }
        accepted.evidence.append(DecisionEvidence(id:"test",kind:"test",detail:"Inspected explicit verification fixture",source:citation))
        try await memory.saveDecision(accepted,userAction:true)
        let history = try await memory.decisionHistory(id:proposal.id)
        try require(history.count == 3 && history[0].verifiedAt != nil,"Decision revisions and verification date persist")
        var rewrite = accepted; rewrite.detail = "model rewrite"
        let rewriteValue = rewrite
        try await rejects("Model cannot rewrite accepted verified decisions") { try await memory.saveDecision(rewriteValue,userAction:false) }
        let hijack = ProjectDecision(id:proposal.id,projectID:work.id,title:"Wrong scope",detail:"")
        try await rejects("Decision IDs cannot move projects") { try await memory.saveDecision(hijack,userAction:true) }
        let summary = try await memory.summary(projectID:personal.id)
        try require(summary.contains("Accepted; Verified"),"Summary reflects independent decision and delivery status")

        let archived = root.appendingPathComponent("archived.jsonl")
        try FileManager.default.moveItem(at:path,to:archived)
        _ = try await memory.registerSource(projectID:personal.id,provider:"Codex",sessionID:"native-session",title:"Archived",path:archived.path)
        _ = try await memory.index(sourceID:source.id)
        let relocated = try await memory.resolve(citation)
        try require(relocated.path == archived.path,"Archive moves relocate citations by source identity")
        try Data("{}\n".utf8).write(to:archived)
        _ = try await memory.index(sourceID:source.id)
        let stale = try await memory.search(projectID:personal.id,query:"copper")
        try require(stale.isEmpty,"Truncation invalidates indexed messages")
        try await rejects("Replaced content cannot reuse an old citation") { _ = try await memory.resolve(citation) }

        let rewrittenPath = root.appendingPathComponent("rewritten.jsonl")
        let filler = try codex("unchanged " + String(repeating:"padding ",count:100))
        let rewriteData = try codex("alpha") + filler
        try rewriteData.write(to:rewrittenPath)
        let rewrittenSource = try await memory.registerSource(projectID:personal.id,provider:"Codex",sessionID:"rewritten",title:"Rewrite fixture",path:rewrittenPath.path)
        _ = try await memory.index(sourceID:rewrittenSource.id)
        func rewriteFixture(_ data: Data, at path: URL) throws {
            let writer = try FileHandle(forWritingTo:path); try writer.seek(toOffset:0)
            try writer.write(contentsOf:data); try writer.truncate(atOffset:UInt64(data.count)); try writer.close()
        }
        let rewritten = Data(String(decoding:rewriteData,as:UTF8.self).replacingOccurrences(of:"alpha",with:"bravo").utf8) + (try codex("appended"))
        try rewriteFixture(rewritten,at:rewrittenPath)
        _ = try await memory.index(sourceID:rewrittenSource.id)
        let prefixHits = try await memory.search(projectID:personal.id,query:"bravo")
        try require(prefixHits.count == 1,"Prefix rewrite plus growth must rebuild instead of preserving obsolete content")

        let interiorPath = root.appendingPathComponent("interior.jsonl")
        let interiorData = filler + (try codex("interioralpha")) + filler
        try interiorData.write(to:interiorPath)
        let interiorSource = try await memory.registerSource(projectID:personal.id,provider:"Codex",sessionID:"interior",title:"Interior fixture",path:interiorPath.path)
        _ = try await memory.index(sourceID:interiorSource.id)
        let interiorNew = Data(String(decoding:interiorData,as:UTF8.self).replacingOccurrences(of:"interioralpha",with:"interiorbravo").utf8) + (try codex("growth"))
        try rewriteFixture(interiorNew,at:interiorPath)
        let incremental = try await memory.index(sourceID:interiorSource.id)
        try require(incremental.bytesRead == interiorNew.count - interiorData.count,"Routine append checking must remain incremental")
        let invalidated = try await memory.search(projectID:personal.id,query:"interioralpha")
        try require(invalidated.isEmpty,"Search must fingerprint-check an interior mutation missed by boundary checkpoints")
        _ = try await memory.index(sourceID:interiorSource.id)
        let rebuilt = try await memory.search(projectID:personal.id,query:"interiorbravo")
        try require(rebuilt.count == 1,"A changed search hit must schedule a complete source rebuild")

        let largePath = root.appendingPathComponent("large.jsonl")
        var large = try codex("oversized " + String(repeating:"x",count:3 * 1024 * 1024))
        large.append(try codex("reachable after huge tool record"))
        try large.write(to:largePath)
        let largeSource = try await memory.registerSource(projectID:personal.id,provider:"Codex",sessionID:"large",title:"Large records",path:largePath.path)
        let batch = try await memory.index(sourceID:largeSource.id)
        try require(batch.bytesRead <= 2 * 1024 * 1024 && batch.hasMore,"Batch memory must be bounded")
        let restart = ProjectMemoryStore(database:try AgentDatabase(directory:dataDirectory))
        var more = true
        while more { more = try await restart.index(sourceID:largeSource.id).hasMore }
        let reachable = try await restart.search(projectID:personal.id,query:"reachable")
        try require(reachable.count == 1,"Oversized line discard must survive restart")
        let largeCoverage = try await restart.coverage(projectID:personal.id)
        try require(largeCoverage.skippedRecords == 1,"Oversized records must be reported")

        let boundedPath = root.appendingPathComponent("bounded.jsonl")
        try codex("needle " + String(repeating:"longtext ",count:80_000)).write(to:boundedPath)
        let boundedSource = try await memory.registerSource(projectID:personal.id,provider:"Codex",sessionID:"bounded",title:"Long visible message",path:boundedPath.path)
        _ = try await memory.index(sourceID:boundedSource.id,byteBudget:4096)
        let boundedHits = try await memory.search(projectID:personal.id,query:"needle")
        try require(boundedHits.count == 1 && boundedHits[0].text.count <= 4000,"Search must return bounded excerpts of long messages")
        let original = try await memory.openSource(boundedHits[0].source)
        try require(original.text.count > 600_000,"Cited open must preserve original message content")

        let claudePath = root.appendingPathComponent("claude.jsonl")
        var claude = try line(["type":"assistant","uuid":"claude-id","timestamp":"2026-10-07T12:00:00Z","message":["role":"assistant","content":[["type":"thinking","thinking":"secret"],["type":"text","text":"Claude visible finding"]]]])
        claude.append(try line(["type":"user","uuid":"tool","message":["role":"user","content":[["type":"tool_result","content":"hidden tool payload"]]]]))
        try claude.write(to:claudePath)
        let claudeSource = try await memory.registerSource(projectID:personal.id,provider:"Claude Code",sessionID:"claude-session",title:"Claude fixture",path:claudePath.path)
        _ = try await memory.index(sourceID:claudeSource.id)
        let claudeHits = try await memory.search(projectID:personal.id,query:"Claude visible")
        try require(claudeHits.count == 1 && claudeHits[0].source.nativeID == "claude-id","Claude visible text and IDs retained")

        let export = root.appendingPathComponent("conversations.json")
        func conversation(_ id: String,_ text: String) -> [String:Any] { ["id":id,"title":id,"current_node":"node","mapping":["node":["id":"node","message":["id":"message-" + id,"author":["role":"user"],"content":["parts":[text]],"create_time":1_800_000_000]]]] }
        try JSONSerialization.data(withJSONObject:[conversation("chosen","chosen imported knowledge"),conversation("excluded","excluded private material")]).write(to:export)
        let previews = try MemoryImport.preview(export)
        try require(previews.count == 2,"Import must preview selections")
        let imported = try await memory.importChatGPT(url:export,selectedIDs:["chosen"],projectID:personal.id)
        try require(imported.count == 1,"Import only explicitly selected conversations")
        _ = try await memory.index(sourceID:imported[0].id)
        let importedHits = try await memory.search(projectID:personal.id,query:"chosen")
        try require(importedHits.count == 1 && importedHits[0].source.originalURL == "https://chatgpt.com/c/chosen","Imported citation retains original conversation URL")
        let document = root.appendingPathComponent("decision.md")
        try Data("# Verified test\nEvidence in a document\n".utf8).write(to:document)
        let importedDocument = try await memory.importDocument(url:document,projectID:personal.id)
        _ = try await memory.index(sourceID:importedDocument.id)
        let documents = try await memory.search(projectID:personal.id,query:"Evidence document")
        try require(documents.count == 1 && documents[0].source.originalURL?.contains("line-1") == true,"Document citations retain section line")
        try FileManager.default.removeItem(at:document)
        _ = try await memory.resolve(documents[0].source)

        try await database.transaction { db in try db.execute("INSERT INTO managed_records(namespace,key,json) VALUES(?,?,?)", ["fixture","nul","before\0after"]) }
        let nul = try await database.read { db in try db.query("SELECT json FROM managed_records WHERE namespace='fixture'").first?["json"] }
        try require(nul == "before\0after","SQLite must preserve embedded NUL")
        let backup = try await database.backup()
        try require(FileManager.default.fileExists(atPath:backup.path),"Database backup created")

        try FileManager.default.removeItem(at:repo)
        let retained = try await memory.projects()
        try require(retained.first { $0.id == personal.id }?.isMissing == true,"Missing directory retains stable project")
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at:moved,withIntermediateDirectories:true)
        let relinked = try await memory.relink(project:personal,path:moved.path)
        try require(relinked.id == personal.id && !relinked.isMissing,"Explicit relink preserves project ID")

        let started = Date()
        for _ in 0..<30 { _ = try await memory.search(projectID:personal.id,query:"visible") }
        let average = Date().timeIntervalSince(started) / 30 * 1000
        print(String(format:"Project memory checks passed; warm fixture search %.2f ms (30 searches)",average))
    }
}
