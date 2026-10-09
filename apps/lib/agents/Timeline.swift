import Foundation

struct TimelineTurn: Identifiable {
    let id: String
    let events: [TimelineEvent]

    var title: String {
        events.first(where: { $0.kind == .user })?.detail ?? "Turn"
    }
    var startedAt: Date { events.first!.timestamp }
    var terminal: TimelineEvent? {
        events.last { $0.kind == .taskCompleted || $0.kind == .taskAborted }
    }
    var isOpen: Bool { terminal == nil && events.contains { $0.kind == .taskStarted } }
    var toolCount: Int { events.filter { $0.kind == .tool }.count }
    var duration: TimeInterval? {
        terminal.map { $0.duration ?? $0.timestamp.timeIntervalSince(startedAt) }
    }

    static func group(_ events: [TimelineEvent]) -> [TimelineTurn] {
        var order: [String] = []
        var groups: [String: [TimelineEvent]] = [:]
        for event in events {
            if groups[event.turnID] == nil { order.append(event.turnID) }
            groups[event.turnID, default: []].append(event)
        }
        return order.map { TimelineTurn(id: $0, events: groups[$0]!) }
    }
}

// Keep only summaries and file offsets in session caches. Read large payloads on demand.
struct TimelineBuilder {
    private(set) var events: [TimelineEvent] = []
    private(set) var revision = 0
    private var currentTurn = "earlier"
    private var calls: [String: Int] = [:]
    private var lastMessage: (turn: String, role: String, text: String, source: String)?
    private var claudeRecords: Set<String> = []
    private var claudeTurnOpen = false

    mutating func consumeClaude(_ record: [String: Any], path: URL, offset: UInt64) -> [TranscriptMessage] {
        guard record["isSidechain"] as? Bool != true else { return [] }
        let type = record["type"] as? String ?? ""
        guard type == "user" || type == "assistant" || type == "system" else { return [] }
        let uuid = record["uuid"] as? String ?? String(offset)
        guard claudeRecords.insert(uuid).inserted else { return [] }
        let timestamp = ClaudeData.date(record["timestamp"]) ?? .distantPast
        func event(_ kind: TimelineKind, _ label: String, _ index: Int) -> TimelineEvent {
            TimelineEvent(id: "claude-\(offset)-\(index)", timestamp: timestamp, kind: kind, label: label,
                          detail: "", turnID: currentTurn, offset: offset, source: .claude, contentIndex: index)
        }
        let visible = ClaudeData.visibleText(record)
        if type == "user", !visible.isEmpty {
            if claudeTurnOpen { events.append(event(.taskAborted, "Turn ended before a final reply was recorded", -2)) }
            currentTurn = uuid
            claudeTurnOpen = true
            events.append(event(.taskStarted, "Task started", -1))
            revision += 1
        }
        let message = record["message"] as? [String: Any] ?? [:]
        var messages: [TranscriptMessage] = []
        for (index, block) in ClaudeData.blocks(record).enumerated() {
            switch block["type"] as? String {
            case "text", "image", "document":
                guard !visible.isEmpty else { continue }
                let text = block["text"] as? String ?? (block["type"] as? String == "image" ? "[Image attachment]" : "[Document attachment]")
                guard !text.isEmpty else { continue }
                messages.append(TranscriptMessage(id: "\(path.path)#\(offset)-\(index)", role: type, text: text,
                    timestamp: timestamp, phase: message["stop_reason"] as? String == "end_turn" ? "final" : "commentary",
                    byteOffset: offset, contentIndex: index))
            case "tool_use":
                guard let call = block["id"] as? String else { continue }
                let input = block["input"] ?? [:]
                // data(withJSONObject:) raises an Objective-C exception, which try? cannot catch, for a string input.
                let data = JSONSerialization.isValidJSONObject(input) ? try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) : nil
                let detail = ToolDisplay.summary(["arguments": data.flatMap { String(data: $0, encoding: .utf8) } ?? (input as? String) ?? ""])
                calls[call] = events.count
                events.append(TimelineEvent(id: "claude-\(offset)-\(index)", timestamp: timestamp, kind: .tool,
                    label: block["name"] as? String ?? "Tool", detail: detail, turnID: currentTurn, offset: offset,
                    source: .claude, contentIndex: index))
                revision += 1
            case "tool_result":
                guard let call = block["tool_use_id"] as? String, let target = calls.removeValue(forKey: call) else { continue }
                events[target].outputOffset = offset
                events[target].outputContentIndex = index
                events[target].endedAt = timestamp
                events[target].failed = block["is_error"] as? Bool == true || ToolDisplay.failed(block["content"])
                revision += 1
            default: break
            }
        }
        if claudeTurnOpen, message["stop_reason"] as? String == "end_turn" || record["subtype"] as? String == "turn_duration" {
            var completed = event(.taskCompleted, "Task completed", Int.max)
            completed.duration = (record["durationMs"] as? NSNumber).map { $0.doubleValue / 1_000 }
            events.append(completed)
            claudeTurnOpen = false
            revision += 1
        }
        return messages
    }

    mutating func consume(_ record: [String: Any], timestamp: Date, offset: UInt64) {
        guard let payload = record["payload"] as? [String: Any] else { return }
        let recordType = record["type"] as? String ?? ""
        let type = payload["type"] as? String ?? ""
        if recordType == "turn_context" {
            currentTurn = payload["turn_id"] as? String ?? currentTurn
            return
        }
        var kind: TimelineKind
        var label: String
        var detail = ""
        var turn = payload["turn_id"] as? String ?? currentTurn
        if recordType == "event_msg" {
            switch type {
            case "task_started":
                turn = payload["turn_id"] as? String ?? "turn-\(offset)"
                currentTurn = turn
                kind = .taskStarted; label = "Task started"
            case "task_complete": kind = .taskCompleted; label = "Task completed"
            case "turn_aborted": kind = .taskAborted; label = "Turn interrupted"
            case "user_message": kind = .user; label = "You"
            case "agent_message":
                kind = .assistant
                label = payload["phase"] as? String == "final" ? "Final reply" : "Update"
            default: return
            }
        } else if recordType == "response_item" {
            switch type {
            case "message":
                guard let role = payload["role"] as? String, role == "user" || role == "assistant" else { return }
                kind = role == "user" ? .user : .assistant
                label = role == "user" ? "You" : (payload["phase"] as? String == "final" ? "Final reply" : "Update")
            case "function_call", "custom_tool_call":
                kind = .tool
                label = payload["name"] as? String ?? "Tool"
                detail = ToolDisplay.summary(payload)
                if let call = payload["call_id"] as? String { calls[call] = events.count }
            case "function_call_output", "custom_tool_call_output":
                guard let call = payload["call_id"] as? String, let index = calls.removeValue(forKey: call) else { return }
                events[index].outputOffset = offset
                events[index].endedAt = timestamp
                events[index].failed = ToolDisplay.failed(payload["output"])
                revision += 1
                return
            default: return
            }
        } else { return }
        if kind == .user || kind == .assistant {
            let text = Self.messageText(payload)
            guard !text.isEmpty else { return }
            let role = kind == .user ? "user" : "assistant"
            if let last = lastMessage, last.turn == turn, last.role == role,
               last.text == text, last.source != recordType {
                lastMessage = nil
                return
            }
            lastMessage = (turn, role, text, recordType)
            detail = String(text.prefix(240)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        events.append(TimelineEvent(
            id: String(offset), timestamp: timestamp, kind: kind, label: label, detail: detail,
            turnID: turn, offset: offset,
            duration: (payload["duration_ms"] as? NSNumber).map { $0.doubleValue / 1_000 }
        ))
        revision += 1
    }

    // Retain complete recent turns, including a start marker and outstanding calls.
    func recentEvents(turnLimit: Int = 30) -> [TimelineEvent] {
        TimelineTurn.group(events).suffix(turnLimit).flatMap(\.events)
    }

    static func messageText(_ payload: [String: Any]) -> String {
        var text = payload["message"] as? String ?? (payload["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        if payload["role"] as? String == "user" || payload["type"] as? String == "user_message" {
            for marker in ["</environment_context>", "</INSTRUCTIONS>"] {
                if let range = text.range(of: marker, options: .backwards) { text = String(text[range.upperBound...]) }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ConversationItem: Identifiable {
    case message(TranscriptMessage)
    case activity(TimelineEvent)

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .activity(let event): return "activity-\(event.id)"
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let message): return message.timestamp
        case .activity(let event): return event.timestamp
        }
    }

    var message: TranscriptMessage? {
        if case .message(let message) = self { return message }
        return nil
    }

    // Both streams arrive in file order. Merge in linear time, preserving message IDs for search.
    static func merge(messages: [TranscriptMessage], activity: [TimelineEvent]) -> [ConversationItem] {
        var items: [ConversationItem] = []
        items.reserveCapacity(messages.count + activity.count)
        var index = 0
        for event in activity where event.kind != .user && event.kind != .assistant {
            while index < messages.count, messages[index].byteOffset < event.offset ||
                (messages[index].byteOffset == event.offset && messages[index].contentIndex < event.contentIndex) {
                items.append(.message(messages[index]))
                index += 1
            }
            items.append(.activity(event))
        }
        items.append(contentsOf: messages[index...].map(ConversationItem.message))
        return items
    }
}

enum ConversationBlock: Identifiable {
    case message(TranscriptMessage)
    case activity([TimelineEvent])

    var id: String {
        switch self {
        case .message(let message): return message.id
        case .activity(let events): return "activity-\(events[0].id)"
        }
    }
    var timestamp: Date {
        switch self {
        case .message(let message): return message.timestamp
        case .activity(let events): return events[0].timestamp
        }
    }
    var message: TranscriptMessage? {
        if case .message(let message) = self { return message }
        return nil
    }

    static func group(_ items: [ConversationItem], verbose: Bool) -> [ConversationBlock] {
        var result: [ConversationBlock] = []
        var pending: [TimelineEvent] = []
        func flush() {
            if !pending.isEmpty { result.append(.activity(pending)); pending = [] }
        }
        for item in items {
            switch item {
            case .message(let message): flush(); result.append(.message(message))
            case .activity(let event):
                if verbose || pending.last?.turnID != event.turnID { flush() }
                pending.append(event)
            }
        }
        flush()
        return result
    }
}

enum ToolDisplay {
    static func title(_ name: String) -> String {
        switch name.split(separator: ".").last.map(String.init) ?? name {
        case "exec_command", "shell_command", "shell": return "Run command"
        case "exec": return "Run tool script"
        case "apply_patch": return "Edit files"
        case "write_stdin": return "Check command"
        case "wait": return "Wait for result"
        case "spawn_agent": return "Start agent"
        case "view_image": return "View image"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func summary(_ payload: [String: Any]) -> String {
        let raw = payload["arguments"] as? String ?? payload["input"] as? String ?? ""
        let object = (mayBeJSON(raw) ? raw.data(using: .utf8) : nil).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        for key in ["cmd", "command", "description", "query", "pattern", "path", "file_path"] {
            if let value = object?[key] as? String { return String(value.prefix(180)).replacingOccurrences(of: "\n", with: " ") }
        }
        if let file = patchFileLine(raw) { return String(file.dropFirst(4).prefix(180)) }
        // The first nonempty line, as raw.split(separator: "\n").first, without splitting the whole input.
        // Stepping through Characters of a string bridged from JSON is slow, so decode a native copy first.
        let text = raw.data(using: .utf8).map { String(decoding: $0, as: UTF8.self) } ?? raw
        return String(text.drop { $0 == "\n" }.prefix(180).prefix { $0 != "\n" })
    }

    // Only explicit tool error fields and process exit records indicate failure.
    static func failed(_ value: Any?, depth: Int = 0) -> Bool {
        guard depth < 6, let value else { return false }
        if let object = value as? [String: Any] {
            if object["isError"] as? Bool == true { return true }
            if let code = object["exit_code"] as? Int, code != 0 { return true }
            return ["output", "content", "text"].contains { failed(object[$0], depth: depth + 1) }
        }
        if let items = value as? [Any] { return items.contains { failed($0, depth: depth + 1) } }
        if let text = value as? String {
            if mayBeJSON(text), let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                return failed(object, depth: depth + 1)
            }
            return exitedWithError(text)
        }
        return false
    }

    // JSONSerialization only parses an object or array after JSON whitespace, though a byte order mark or
    // NUL-padded UTF-16 may come first. Skip encoding and parsing text that starts any other way.
    private static func mayBeJSON(_ text: String) -> Bool {
        guard let first = text.utf8.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[") || first < 0x21 || first > 0x7E
    }

    // True when a text.split(separator: "\n") line is "Process exited with code N" with N != 0. Tool output
    // bridged from JSON is slow to walk by Character, so find the literal and check its line instead:
    // "\r\n" is one Character, so its "\n" never starts a line, and N must fill the rest of the line.
    private static func exitedWithError(_ text: String) -> Bool {
        let text = text as NSString
        var location = 0
        while true {
            let found = text.range(of: "Process exited with code ", options: .literal,
                                   range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { return false }
            let start = found.location
            location = NSMaxRange(found)
            guard start == 0 || text.character(at: start - 1) == 10 && (start == 1 || text.character(at: start - 2) != 13) else { continue }
            var end = location
            while end < text.length, "+-0123456789".utf16.contains(text.character(at: end)) { end += 1 }
            if end == text.length || text.character(at: end) == 10,
               let code = Int(text.substring(with: NSRange(location: location, length: end - location))), code != 0 { return true }
        }
    }

    // raw.components(separatedBy: "\n").first(where: isPatchFileLine) without copying every line of a large
    // patch. Bridged strings don't split at a newline beside a combining mark, so a deciding newline with a
    // non-ASCII neighbour falls back to that original search.
    private static func patchFileLine(_ raw: String) -> String? {
        let text = raw as NSString
        func ascii(_ index: Int) -> Bool { index < 0 || index >= text.length || text.character(at: index) < 0x80 }
        var location = 0
        while true {
            let found = text.range(of: "*** ", options: .literal, range: NSRange(location: location, length: text.length - location))
            guard found.location != NSNotFound else { return nil }
            let start = found.location
            location = start + 1
            guard start == 0 || text.character(at: start - 1) == 10 else { continue }
            let newline = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: text.length - start)).location
            guard ascii(start - 2), newline == NSNotFound || ascii(newline - 1) && ascii(newline + 1) else {
                return raw.components(separatedBy: "\n").first(where: isPatchFileLine)
            }
            let line = text.substring(with: NSRange(location: start, length: (newline == NSNotFound ? text.length : newline) - start))
            if isPatchFileLine(line) { return line }
        }
    }

    private static func isPatchFileLine(_ line: String) -> Bool {
        line.hasPrefix("*** Update File:") || line.hasPrefix("*** Add File:") || line.hasPrefix("*** Delete File:")
    }
}

struct TimelinePayload {
    let input: String
    let output: String?

    static func load(path: URL, event: TimelineEvent) -> TimelinePayload {
        if event.source == .claude {
            let inputBlocks = record(path: path, offset: event.offset).map(ClaudeData.blocks) ?? []
            let input = inputBlocks.indices.contains(event.contentIndex) ? inputBlocks[event.contentIndex]["input"] : nil
            let output: String? = event.outputOffset.map { offset in
                let blocks = record(path: path, offset: offset).map(ClaudeData.blocks) ?? []
                return render(blocks.indices.contains(event.outputContentIndex) ? blocks[event.outputContentIndex]["content"] : nil)
            }
            return TimelinePayload(input: render(input, unwrapOutput: false), output: output)
        }
        let payload = record(path: path, offset: event.offset)
        let input: String
        if event.kind == .tool {
            input = render(payload?["arguments"] ?? payload?["input"], unwrapOutput: false)
        } else {
            input = payload.map { Self.render(TimelineBuilder.messageText($0)) } ?? render(nil)
        }
        let output = event.outputOffset.map { render(record(path: path, offset: $0)?["output"]) }
        return TimelinePayload(input: input, output: output)
    }

    private static func record(path: URL, offset: UInt64) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            var data = Data()
            // Bound malformed or exceptionally large records; never read the entire rollout.
            while data.count < 8 * 1_024 * 1_024 {
                guard let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty else { break }
                if let newline = chunk.firstIndex(of: 0x0A) {
                    data.append(chunk.prefix(upTo: newline))
                    break
                }
                data.append(chunk)
            }
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["payload"] as? [String: Any] ?? object
        } catch { return nil }
    }

    static func render(_ value: Any?, depth: Int = 0, unwrapOutput: Bool = true) -> String {
        guard let value else { return "Details unavailable in this rollout." }
        var text: String
        if unwrapOutput, depth < 6, let blocks = value as? [[String: Any]], !blocks.isEmpty,
           blocks.allSatisfy({ $0["text"] is String }) {
            text = blocks.map { render($0["text"], depth: depth + 1) }.joined(separator: "\n\n")
        } else if unwrapOutput, depth < 6, let object = value as? [String: Any], let output = object["output"] {
            text = render(output, depth: depth + 1)
            if let code = object["exit_code"] as? Int { text += "\n\nExit code: \(code)" }
            if let error = object["error"] as? String { text += "\n\n" + error }
        } else if let string = value as? String {
            if let data = string.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(json), depth < 6 {
                text = render(json, depth: depth + 1, unwrapOutput: unwrapOutput)
            } else { text = string }
        } else if JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
                  let formatted = String(data: data, encoding: .utf8) {
            text = formatted
        } else { text = String(describing: value) }
        let limit = 24_000
        return text.count > limit ? String(text.prefix(limit)) + "\n\n[Preview truncated; full details are in the rollout file.]" : text
    }
}

func timelineDuration(_ seconds: TimeInterval) -> String {
    let seconds = max(0, Int(seconds))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m"
}
