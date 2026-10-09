import Foundation

struct MemoryIndexProgress {
    let bytesRead: Int
    let hasMore: Bool
}

private struct VisibleMemoryMessage {
    let role: String
    let text: String
    let timestamp: String
    let nativeID: String
    let representation: String
    let originalURL: String?
}

extension ProjectMemoryStore {
    /// A turn reads at most 2 MiB. Huge tool records are skipped without allocating
    /// their entire line; the discard state survives app restarts.
    func index(sourceID: String, byteBudget: Int = 2 * 1024 * 1024) async throws -> MemoryIndexProgress {
        guard indexingSources.insert(sourceID).inserted else { return MemoryIndexProgress(bytesRead:0,hasMore:false) }
        defer { indexingSources.remove(sourceID) }
        guard let state = try await database.read({ db in try db.query("SELECT * FROM sources WHERE id=?", [sourceID]).first }) else { throw AgentStorageError.invalid("Unknown transcript source.") }
        let source = Self.source(state)
        let url = URL(fileURLWithPath: source.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath:source.path), let handle = try? FileHandle(forReadingFrom:url) else {
            try await database.transaction { db in
                try db.execute("UPDATE sources SET status='Unavailable' WHERE id=?", [sourceID])
                try db.execute("UPDATE messages SET valid=0 WHERE source_id=?", [sourceID])
            }
            return MemoryIndexProgress(bytesRead:0,hasMore:false)
        }
        defer { try? handle.close() }
        let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let savedOffset = UInt64(state["offset"] ?? "0") ?? 0
        let oldSize = UInt64(state["size"] ?? "0") ?? 0
        var reset = state["status"] == "Changed" || savedOffset > size || (state["identity"] != "" && state["identity"] != identity)
        if savedOffset > 0 && !reset {
            let checkpoint = try Self.checkpoint(handle,at:savedOffset)
            reset = checkpoint != state["checkpoint"] || (size == oldSize && modified != state["modified"])
        }
        var offset: UInt64 = reset ? 0 : savedOffset
        var discarding = !reset && state["discarding"] == "1"
        var skipped = reset ? 0 : Int(state["skipped"] ?? "0") ?? 0
        try handle.seek(toOffset:offset)
        let budget = max(1024 * 1024 + 1,min(byteBudget,2 * 1024 * 1024))
        let data = try handle.read(upToCount:budget) ?? Data()
        var records: [(VisibleMemoryMessage,UInt64,Data)] = []
        var cursor = 0
        let recordLimit = 1024 * 1024
        while cursor < data.count {
            guard let newline = data[cursor...].firstIndex(of:10) else {
                if discarding || data.count - cursor >= recordLimit {
                    if !discarding { skipped += 1 }
                    discarding = true
                    cursor = data.count
                }
                break
            }
            if discarding { discarding = false; cursor = newline + 1; continue }
            let raw = Data(data[cursor..<newline])
            if raw.count > recordLimit { skipped += 1 }
            else if !raw.isEmpty {
                if let record = try? JSONSerialization.jsonObject(with:raw) as? [String:Any] {
                    if let message = Self.visibleMessage(record,provider:source.provider) { records.append((message,offset + UInt64(cursor),raw)) }
                } else { skipped += 1 }
            }
            cursor = newline + 1
        }
        offset += UInt64(cursor)
        let checkpoint = try Self.checkpoint(handle,at:offset)
        let status = offset == size && !discarding ? "Complete" : (cursor == 0 || offset == size ? "Awaiting complete record" : "Partial")
        let finalOffset = offset, finalSkipped = skipped, finalDiscarding = discarding
        try await database.transaction { db in
            if reset { try db.execute("DELETE FROM messages WHERE source_id=?", [sourceID]) }
            else { try db.execute("UPDATE messages SET valid=1 WHERE source_id=?", [sourceID]) }
            for (message,position,raw) in records {
                let fingerprint = MemoryFingerprint.hash(raw)
                let stable = message.nativeID.isEmpty ? "\(position):\(fingerprint)" : message.nativeID
                let id = MemoryFingerprint.hash(Data("\(sourceID):\(stable)".utf8))
                // Codex emits both event and response representations. Pair only the
                // adjacent opposite representation; identical later turns survive.
                let recent = try db.query("SELECT id,role,text,timestamp,representation FROM messages WHERE source_id=? ORDER BY offset DESC LIMIT 1", [sourceID]).first
                if let recent, recent["role"] == message.role, recent["text"] == message.text,
                   ["event_msg","response_item"].contains(message.representation),
                   ["event_msg","response_item"].contains(recent["representation"] ?? ""),
                   recent["representation"] != message.representation,
                   Self.near(recent["timestamp"] ?? "",message.timestamp) {
                    // Keep the already-citable representation. Mark the pair consumed
                    // so a genuine identical message in the next turn is retained.
                    try db.execute("UPDATE messages SET representation='codex_pair' WHERE id=?", [recent["id"]])
                    continue
                }
                try db.execute("INSERT INTO messages(id,source_id,project_id,role,text,timestamp,native_id,offset,length,fingerprint,representation,original_url) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET text=excluded.text,timestamp=excluded.timestamp,offset=excluded.offset,length=excluded.length,fingerprint=excluded.fingerprint,valid=1", [id,sourceID,source.projectID,message.role,message.text,message.timestamp,message.nativeID,String(position),String(raw.count),fingerprint,message.representation,message.originalURL])
            }
            try db.execute("UPDATE sources SET identity=?,offset=?,size=?,modified=?,checkpoint=?,status=?,skipped=?,discarding=? WHERE id=?", [identity,String(finalOffset),String(size),modified,checkpoint,status,String(finalSkipped),finalDiscarding ? "1":"0",sourceID])
        }
        return MemoryIndexProgress(bytesRead:data.count,hasMore:offset < size && cursor > 0)
    }

    private static func checkpoint(_ handle: FileHandle, at offset: UInt64) throws -> String {
        let length = min(offset,256)
        try handle.seek(toOffset:0)
        let prefix = try handle.read(upToCount:Int(length)) ?? Data()
        try handle.seek(toOffset:offset - length)
        return MemoryFingerprint.hash(prefix + (try handle.read(upToCount:Int(length)) ?? Data()))
    }

    private static func near(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let first = formatter.date(from:lhs), second = formatter.date(from:rhs)
        if let first, let second { return abs(first.timeIntervalSince(second)) < 5 }
        return false
    }

    private static func visibleMessage(_ record: [String:Any], provider: String) -> VisibleMemoryMessage? {
        var role = "", text = "", nativeID = "", representation = ""
        let timestamp: String
        if let number = record["timestamp"] as? NSNumber {
            let seconds = number.doubleValue
            timestamp = ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:seconds > 1e11 ? seconds / 1000:seconds))
        } else { timestamp = record["timestamp"] as? String ?? "" }
        if provider == "Codex" {
            guard let payload = record["payload"] as? [String:Any] else { return nil }
            guard payload["phase"] as? String != "analysis", record["channel"] as? String != "analysis" else { return nil }
            representation = record["type"] as? String ?? ""
            if representation == "event_msg" {
                switch payload["type"] as? String {
                case "user_message": role = "user"
                case "agent_message": role = "assistant"
                default: return nil
                }
                text = payload["message"] as? String ?? ""
                nativeID = payload["id"] as? String ?? payload["item_id"] as? String ?? ""
            } else if representation == "response_item", payload["type"] as? String == "message" {
                role = payload["role"] as? String ?? ""
                // Analysis/internal reasoning must never enter searchable memory.
                guard payload["channel"] as? String != "analysis" else { return nil }
                let type = role == "user" ? "input_text":"output_text"
                text = (payload["content"] as? [[String:Any]] ?? []).filter { $0["type"] as? String == type }.compactMap { $0["text"] as? String }.joined(separator:"\n\n")
                nativeID = payload["id"] as? String ?? ""
            } else { return nil }
            if role == "user" {
                for marker in ["</environment_context>","</INSTRUCTIONS>"] {
                    if let end = text.range(of:marker,options:.backwards)?.upperBound { text = String(text[end...]) }
                }
            }
        } else if provider == "Claude Code" {
            guard record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String:Any] else { return nil }
            role = message["role"] as? String ?? record["type"] as? String ?? ""
            nativeID = record["uuid"] as? String ?? message["id"] as? String ?? ""
            if let content = message["content"] as? String { text = content }
            else { text = (message["content"] as? [[String:Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator:"\n\n") }
            representation = "claude"
        } else {
            role = record["role"] as? String ?? ""
            text = record["text"] as? String ?? ""
            nativeID = record["id"] as? String ?? ""
            representation = "import"
        }
        text = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard ["user","assistant"].contains(role), !text.isEmpty else { return nil }
        return VisibleMemoryMessage(role:role,text:text,timestamp:timestamp,nativeID:nativeID,representation:representation,originalURL:record["original_url"] as? String)
    }
}
