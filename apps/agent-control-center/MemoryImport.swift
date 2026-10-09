import Foundation

struct MemoryImportConversation: Identifiable, Hashable {
    let id: String
    let title: String
}

enum MemoryImport {
    static let maximumBytes = 32 * 1024 * 1024
    static func read(_ url: URL) throws -> Data {
        let size = ((try FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size <= maximumBytes else { throw AgentStorageError.invalid("Select an individual conversation or document smaller than 32 MB.") }
        let handle = try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount:maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw AgentStorageError.invalid("Select an individual conversation or document smaller than 32 MB.") }
        return data
    }
    static func conversations(_ url: URL) throws -> [[String:Any]] {
        let value = try JSONSerialization.jsonObject(with:read(url))
        if let records = value as? [[String:Any]] { return records }
        if let record = value as? [String:Any], record["mapping"] != nil { return [record] }
        throw AgentStorageError.invalid("Choose a ChatGPT conversations JSON export.")
    }
    static func preview(_ url: URL) throws -> [MemoryImportConversation] {
        try conversations(url).compactMap { record in
            guard let id = record["id"] as? String ?? record["conversation_id"] as? String else { return nil }
            return MemoryImportConversation(id:id,title:record["title"] as? String ?? "Imported conversation")
        }
    }
}

extension ProjectMemoryStore {
    /// Imports only user-selected conversations into an immutable local snapshot.
    func importChatGPT(url: URL, selectedIDs: Set<String>, projectID: String) async throws -> [MemorySource] {
        guard !selectedIDs.isEmpty else { return [] }
        let conversations = try MemoryImport.conversations(url)
        var sources: [MemorySource] = []
        for conversation in conversations {
            guard let id = conversation["id"] as? String ?? conversation["conversation_id"] as? String, selectedIDs.contains(id),
                  let mapping = conversation["mapping"] as? [String:[String:Any]] else { continue }
            let title = conversation["title"] as? String ?? "Imported conversation"
            var nodes: [[String:Any]] = []
            // Follow the selected branch; alternatives are not silently synthesized.
            if var current = conversation["current_node"] as? String {
                var visited: Set<String> = []
                while visited.insert(current).inserted, let node = mapping[current] {
                    nodes.append(node)
                    guard let parent = node["parent"] as? String else { break }
                    current = parent
                }
                nodes.reverse()
            } else { nodes = mapping.keys.sorted().compactMap { mapping[$0] }.sorted { Self.importDate($0) < Self.importDate($1) } }
            let rows: [[String:Any]] = nodes.compactMap { node in
                guard let message = node["message"] as? [String:Any], let author = message["author"] as? [String:Any],
                      let role = author["role"] as? String, ["user","assistant"].contains(role),
                      message["channel"] as? String != "analysis", let content = message["content"] as? [String:Any] else { return nil }
                if (message["metadata"] as? [String:Any])?["is_visually_hidden_from_conversation"] as? Bool == true { return nil }
                if let type = content["content_type"] as? String, !["text","multimodal_text"].contains(type) { return nil }
                let text = (content["parts"] as? [Any] ?? []).compactMap { $0 as? String }.joined(separator:"\n\n")
                guard !text.isEmpty else { return nil }
                return ["id":message["id"] as? String ?? node["id"] as? String ?? UUID().uuidString,"role":role,"text":text,"timestamp":ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:(message["create_time"] as? NSNumber)?.doubleValue ?? 0)),"original_url":"https://chatgpt.com/c/\(id)"]
            }
            let path = try await writeImport(rows:rows)
            let source = try await registerSource(projectID:projectID,provider:"ChatGPT import",sessionID:id,title:title,path:path.path)
            sources.append(source)
        }
        return sources
    }

    func importDocument(url: URL, projectID: String) async throws -> MemorySource {
        let data = try MemoryImport.read(url)
        guard let text = String(data:data,encoding:.utf8) else { throw AgentStorageError.invalid("Choose a UTF-8 text or Markdown document.") }
        let contentID = MemoryFingerprint.hash(data)
        var rows: [[String:Any]] = []
        var section = "Document", buffer = "", lineStart = 1
        func append() {
            guard !buffer.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
            rows.append(["id":"\(contentID):\(lineStart)","role":"user","text":"\(section) (source line \(lineStart))\n\(buffer)","timestamp":ISO8601DateFormatter().string(from:Date()),"original_url":url.absoluteString + "#line-\(lineStart)"])
            buffer = ""
        }
        for (index,line) in text.components(separatedBy:"\n").enumerated() {
            if line.hasPrefix("#") || buffer.utf8.count + line.utf8.count > 64 * 1024 { append(); lineStart = index + 1; if line.hasPrefix("#") { section = line } }
            guard line.utf8.count < 1024 * 1024 else { throw AgentStorageError.invalid("A document line exceeds 1 MB; split the document into sections first.") }
            buffer += line + "\n"
        }
        append()
        let path = try await writeImport(rows:rows)
        return try await registerSource(projectID:projectID,provider:"Document import",sessionID:contentID,title:url.lastPathComponent,path:path.path)
    }

    private func writeImport(rows: [[String:Any]]) async throws -> URL {
        let directory = database.url.deletingLastPathComponent().appendingPathComponent("imports",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let path = directory.appendingPathComponent(UUID().uuidString + ".jsonl")
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])); data.append(10) }
        try data.write(to:path,options:.atomic)
        return path
    }
    private static func importDate(_ node: [String:Any]) -> Double { ((node["message"] as? [String:Any])?["create_time"] as? NSNumber)?.doubleValue ?? 0 }
}
