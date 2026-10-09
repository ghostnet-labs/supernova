import Foundation

// Claude's top-level transcripts share the app's session model, but retain their own
// IDs, storage, tool payloads, and resume command. Never move them into Codex storage.
enum ClaudeData {
    static var home: URL {
        if let value = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1_000 : seconds)
        }
        return CodexData.parseDate(value)
    }

    // Return only committed JSONL records. Appending half a line never consumes it.
    @discardableResult
    static func readRecords(_ path: URL, from offset: UInt64, consume: ([String: Any], UInt64) -> Void) -> (offset: UInt64, reset: Bool, hasMore: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return (offset, false, false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset <= size ? offset : 0
        try? handle.seek(toOffset: start)
        guard let data = try? CodexData.readChunk(handle) else { return (start, start != offset, false) }
        let newlines = CodexData.newlineOffsets(data)
        guard let last = newlines.last else { return (start, start != offset, false) }
        var lineStart = 0
        for newline in newlines {
            defer { lineStart = newline + 1 }
            guard newline > lineStart,
                  let record = try? JSONSerialization.jsonObject(with: data.subdata(in: lineStart..<newline)) as? [String: Any] else { continue }
            consume(record, start + UInt64(lineStart))
        }
        return (start + UInt64(last + 1), start != offset, start + UInt64(data.count) < size)
    }

    static func blocks(_ record: [String: Any]) -> [[String: Any]] {
        guard let message = record["message"] as? [String: Any] else { return [] }
        if let text = message["content"] as? String { return [["type": "text", "text": text]] }
        return message["content"] as? [[String: Any]] ?? []
    }

    static func visibleText(_ record: [String: Any]) -> String {
        guard record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true else { return "" }
        return blocks(record).compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[Image attachment]"
            case "document": return "[Document attachment]"
            default: return nil
            }
        }.joined(separator: "\n\n")
    }

    static func readTranscript(_ path: URL, from offset: UInt64 = 0, activity: inout TimelineBuilder) -> TranscriptChunk {
        // URL resource values may be cached across appends; read a fresh size.
        let size = ((try? FileManager.default.attributesOfItem(atPath: path.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        let reset = offset > size
        if offset == 0 || reset { activity = TimelineBuilder() }
        var messages: [TranscriptMessage] = []
        let result = readRecords(path, from: reset ? 0 : offset) { record, position in
            messages += activity.consumeClaude(record, path: path, offset: position)
        }
        return TranscriptChunk(messages: messages, nextOffset: result.offset, didReset: reset, hasMore: result.hasMore)
    }

}
