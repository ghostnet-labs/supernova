import Foundation

@main struct Checks {
    static func main() throws {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { print("FAIL: \(label)"); failures += 1 }
        }
        let path = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("timeline.jsonl")
        var data = Data()
        var builder = TimelineBuilder()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var tick = 0
        func add(_ recordType: String, _ payload: [String: Any], blank: Bool = false) throws {
            if blank { data.append(0x0A) }
            let offset = UInt64(data.count)
            let record: [String: Any] = ["type": recordType, "payload": payload]
            builder.consume(record, timestamp: start.addingTimeInterval(Double(tick)), offset: offset)
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
            tick += 1
        }
        try add("event_msg", ["type": "task_started", "turn_id": "one"])
        try add("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>setup</environment_context>\nRun the tests"]]])
        try add("event_msg", ["type": "user_message", "message": "Run the tests"])
        try add("response_item", ["type": "function_call", "call_id": "call-a", "name": "exec_command", "arguments": "{\"cmd\":\"printf hello\"}"], blank: true)
        let toolID = builder.events.last!.id
        try add("event_msg", ["type": "task_started", "turn_id": "two"])
        try add("response_item", ["type": "custom_tool_call", "call_id": "call-b", "name": "apply_patch", "input": "*** Begin Patch\n*** End Patch"])
        try add("response_item", ["type": "function_call_output", "call_id": "call-a", "output": "hello\nProcess exited with code 0"])
        try add("event_msg", ["type": "task_complete", "turn_id": "one", "duration_ms": 6_500])
        try add("response_item", ["type": "message", "role": "assistant", "phase": "final", "content": [["type": "output_text", "text": "Done"]]])
        try add("event_msg", ["type": "agent_message", "phase": "final", "message": "Done"])
        try add("response_item", ["type": "custom_tool_call_output", "call_id": "call-b", "output": "Patch applied"])
        try add("event_msg", ["type": "turn_aborted", "turn_id": "two"])
        try add("event_msg", ["type": "task_started", "turn_id": "three"])
        try add("response_item", ["type": "function_call", "call_id": "call-c", "name": "exec_command", "arguments": "sleep 30"])
        try data.write(to: path)
        let turns = TimelineTurn.group(builder.events)
        check(turns.count == 3, "separate turns")
        check(turns[0].title == "Run the tests", "request title excludes environment and deduplicates")
        check(turns[0].events.filter { $0.kind == .user }.count == 1, "message event/response deduplication")
        check(turns[0].duration == 6.5, "recorded duration")
        check(!turns[0].isOpen && !turns[1].isOpen && turns[2].isOpen, "completed, interrupted, and active states")
        check(turns[1].terminal?.kind == .taskAborted, "interrupted terminal")
        check(turns[1].events.filter { $0.kind == .assistant }.count == 1, "assistant deduplication")
        check(turns[1].events.contains { $0.label == "Final reply" }, "final reply label")
        let tool = turns[0].events.first { $0.kind == .tool }!
        check(tool.id == toolID && tool.endedAt != nil, "stable identity after result arrives")
        check(tool.outputOffset != nil, "late result matches correct turn")
        let details = TimelinePayload.load(path: path, event: tool)
        check(details.input.contains("printf hello"), "lazy argument loading at byte offset after blank line")
        check(details.output?.contains("exited with code 0") == true, "lazy output loading")
        let patch = TimelinePayload.load(path: path, event: turns[1].events.first { $0.kind == .tool }!)
        check(patch.input.contains("Begin Patch") && patch.output == "Patch applied", "custom tools")
        check(turns[2].events.last!.outputOffset == nil, "unreturned tool remains pending")
        let recent = builder.recentEvents(turnLimit: 2)
        check(Set(recent.map(\.turnID)) == ["two", "three"], "retention preserves whole turns")
        check(recent.first?.kind == .taskStarted, "retention includes start marker")
        let missing = TimelinePayload.load(path: path.appendingPathExtension("missing"), event: tool)
        check(missing.input.contains("unavailable"), "missing rollout handled")
        check(timelineDuration(65) == "1m 5s" && timelineDuration(-1) == "0s", "duration formatting")
        var activity = TimelineBuilder()
        let initial = CodexData.readTranscript(path, activity: &activity)
        let originalEventIDs = activity.events.map(\.id)
        check(initial.nextOffset == UInt64(data.count), "initial reader reaches file end")
        check(activity.events.first(where: { $0.kind == .tool })?.id == toolID, "reader preserves offsets across blank lines")
        let mixed = ConversationItem.merge(messages: initial.messages, activity: activity.events)
        check(mixed.compactMap(\.message).map(\.id) == initial.messages.map(\.id), "inline merge preserves messages and search IDs")
        check(mixed.count == initial.messages.count + activity.events.filter { $0.kind != .user && $0.kind != .assistant }.count, "timeline messages are not duplicated inline")
        let ordered = mixed.map { item -> UInt64 in
            switch item {
            case .message(let message): return message.byteOffset
            case .activity(let event): return event.offset
            }
        }
        check(ordered == ordered.sorted(), "inline events follow recorded order even when timestamps match")
        let pendingID = activity.events.last!.id
        let oldRevision = activity.revision
        try add("response_item", ["type": "function_call_output", "call_id": "call-c", "output": "Finished"])
        try add("event_msg", ["type": "task_complete", "turn_id": "three", "duration_ms": 20_000])
        try data.write(to: path)
        let update = CodexData.readTranscript(path, from: initial.nextOffset, activity: &activity)
        check(update.messages.isEmpty, "tool-only updates do not add chat messages")
        check(activity.revision > oldRevision, "tool-only updates advance activity revision")
        check(activity.events.first { $0.id == pendingID }?.outputOffset != nil, "tool result pairs across refreshes")
        check(Array(activity.events.prefix(originalEventIDs.count)).map(\.id) == originalEventIDs, "refresh preserves event identity and placement")
        let updatedItems = ConversationItem.merge(messages: initial.messages, activity: activity.events)
        check(updatedItems.last?.id == "activity-\(activity.events.last!.id)", "completion appears after preceding content")
        let savedCount = activity.events.count
        let savedRevision = activity.revision
        let empty = CodexData.readTranscript(path, from: update.nextOffset, activity: &activity)
        check(empty.messages.isEmpty && activity.revision == savedRevision, "unchanged file causes no activity refresh")
        let partial = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"four\"}}".utf8)
        data.append(partial)
        try data.write(to: path)
        let unfinished = CodexData.readTranscript(path, from: update.nextOffset, activity: &activity)
        check(unfinished.nextOffset == update.nextOffset && activity.events.count == savedCount, "partial records wait for newline")
        data.append(0x0A)
        try data.write(to: path)
        let finished = CodexData.readTranscript(path, from: unfinished.nextOffset, activity: &activity)
        check(activity.events.count == savedCount + 1 && finished.nextOffset == UInt64(data.count), "completed partial record appears once")
        for n in 0..<35 {
            try add("event_msg", ["type": "task_started", "turn_id": "older-\(n)"])
            try add("event_msg", ["type": "task_complete", "turn_id": "older-\(n)"])
        }
        try data.write(to: path)
        let history = CodexData.readTranscript(path, from: finished.nextOffset, activity: &activity)
        check(activity.events.first?.id == originalEventIDs.first && TimelineTurn.group(activity.events).count > 30, "inline history retains activity beyond 30 turns")
        try Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"replacement\"}}\n".utf8).write(to: path)
        let replacement = CodexData.readTranscript(path, from: history.nextOffset, activity: &activity)
        check(replacement.didReset && activity.events.count == 1 && activity.events[0].turnID == "replacement", "truncated rollout resets activity")
        let exitCode = "Process exited with code "
        let longPath = path.deletingLastPathComponent().appendingPathComponent("long.jsonl")
        var longData = Data()
        for (n, output) in [String(repeating: "x", count: 5_000_000) + "\n\(exitCode)4", "done"].enumerated() {
            for payload in [["type": "function_call", "call_id": "c\(n)", "name": "exec_command", "arguments": "{\"cmd\":\"step \(n)\"}"],
                            ["type": "function_call_output", "call_id": "c\(n)", "output": output]] {
                longData.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload]))
                longData.append(0x0A)
            }
        }
        try longData.write(to: longPath)
        var longActivity = TimelineBuilder()
        var longChunk = CodexData.readTranscript(longPath, activity: &longActivity)
        while longChunk.hasMore { longChunk = CodexData.readTranscript(longPath, from: longChunk.nextOffset, activity: &longActivity) }
        check(longChunk.nextOffset == UInt64(longData.count) && longActivity.events.map(\.detail) == ["step 0", "step 1"]
              && longActivity.events.map(\.failed) == [true, false], "records longer than one read")
        let normal = ConversationBlock.group(mixed, verbose: false)
        let verbose = ConversationBlock.group(mixed, verbose: true)
        check(normal.count <= verbose.count, "normal mode collapses activity")
        check(normal.compactMap(\.message).map(\.id) == initial.messages.map(\.id), "groups never swallow messages or search targets")
        func flatten(_ blocks: [ConversationBlock]) -> [String] {
            blocks.flatMap { block -> [String] in
                switch block {
                case .message(let message): return [message.id]
                case .activity(let events): return events.map { "activity-\($0.id)" }
                }
            }
        }
        check(flatten(normal) == mixed.map(\.id) && flatten(verbose) == mixed.map(\.id), "both display modes preserve event order")
        let tail = ConversationBlock.group([.activity(tool), .activity(turns[1].events.first!)], verbose: false)
        check(tail.count == 2, "activity groups do not cross turn boundaries")
        check(ToolDisplay.summary(["arguments": "{\"cmd\":\"swift test\"}"]) == "swift test", "command summaries")
        check(ToolDisplay.failed(["exit_code": 2]), "explicit nonzero exit is failure")
        check(ToolDisplay.failed("Process exited with code 1"), "process result error")
        check(!ToolDisplay.failed("Documentation about an error") && !ToolDisplay.failed(["exit_code": 0]), "do not invent failures from ordinary text")
        // Rollout strings arrive bridged from JSONSerialization; native and bridged text must agree.
        func bridged(_ text: String) -> String {
            (try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: [text])) as! [String])[0]
        }
        // NSMutableString keeps a leading byte order mark that JSONSerialization strips from bridged strings.
        for wrap: (String) -> String in [{ $0 }, bridged, { NSMutableString(string: $0) as String }] {
            check(ToolDisplay.failed(wrap("Chunk ID: 1\n\(exitCode)0\nOutput:\n\(exitCode)-1")), "a later nonzero exit line fails")
            check(!ToolDisplay.failed(wrap("ok\r\n\(exitCode)1")) && !ToolDisplay.failed(wrap("ran \(exitCode)1")), "exit lines follow a newline Character")
            check(!ToolDisplay.failed(wrap("\(exitCode)1 ")) && !ToolDisplay.failed(wrap("\(exitCode)1\r\n"))
                  && !ToolDisplay.failed(wrap("\(exitCode)9223372036854775808")), "the exit code fills its line")
            check(ToolDisplay.failed(wrap("\u{FEFF}{\"exit_code\": 2}")) && ToolDisplay.failed(wrap(" {\"output\": \"\(exitCode)3\"}")), "JSON output after a byte order mark or space")
            let patch = "*** Begin Patch\n*** Update File: a.swift\n@@\n" + String(repeating: "+*** line\n", count: 10_000)
            check(ToolDisplay.summary(["input": wrap(patch)]) == "Update File: a.swift", "patch summaries name the first file")
            check(ToolDisplay.summary(["input": wrap("*** Add File:\u{301}x\n*** Delete File: b.txt")]) == "Delete File: b.txt", "file headers match whole Characters")
            check(ToolDisplay.summary(["input": wrap("\n\nconst a = 1\nconst b = 2")]) == "const a = 1", "first nonempty line")
            check(ToolDisplay.summary(["input": wrap(String(repeating: "é", count: 300))]) == String(repeating: "é", count: 180), "first line keeps 180 Characters")
            // Bridged strings don't split at a newline before a combining mark; summaries must split the same way.
            let marked = wrap("*** Begin Patch\n*** Update File: x\n\u{301}b")
            let header = marked.components(separatedBy: "\n").first { $0.hasPrefix("*** Update File:") }.map { String($0.dropFirst(4).prefix(180)) }
            check(ToolDisplay.summary(["input": marked]) == header, "patch summaries split lines as components(separatedBy:) does")
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for stamp in ["2026-07-16T21:58:49.123Z", "2024-02-29T23:59:59.999Z", "1999-12-31T00:00:00.001Z", "2026-02-29T12:00:00.000Z",
                      "1582-10-04T12:00:00.000Z", "2026-07-16T21:58:49Z", "2026-07-16T21:58:49.1Z", "2026-07-16T21:58:49.123+05:30", "July 16"] {
            let expected = fractional.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
            check(CodexData.parseDate(stamp)?.timeIntervalSinceReferenceDate.bitPattern == expected?.timeIntervalSinceReferenceDate.bitPattern,
                  "timestamp \(stamp) parses as ISO8601DateFormatter does")
        }
        check(TimelinePayload.render(["output": "argument", "other": 1], unwrapOutput: false).contains("other"), "input arguments named output remain intact")
        let wrapped = [["type": "text", "text": "{\"output\":\"hello\\nworld\",\"exit_code\":0}"]]
        check(TimelinePayload.render(wrapped) == "hello\nworld\n\nExit code: 0", "unwrap nested tool content")
        check(TimelinePayload.render(String(repeating: "x", count: 25_000)).contains("Preview truncated"), "large previews remain bounded")
        let markdown = MessageMarkdown.parse("# Title\n\nText with **bold**.\n\n- one\n  2. two\n\n> quote\n\n```swift\nif ready {\n    run()\n}\n```\n\n| Name | Result |\n| --- | --- |\n| test | pass |")
        check(markdown.contains(.heading(1, "Title")), "Markdown headings")
        check(markdown.contains(.paragraph("Text with **bold**.")), "inline formatting preserved for native renderer")
        check(markdown.contains(.listItem("•", "one", 0)) && markdown.contains(.listItem("2.", "two", 1)), "lists preserve order and nesting")
        check(markdown.contains(.quote("quote")), "quotes")
        check(markdown.contains(.code("swift", "if ready {\n    run()\n}")), "code indentation stays literal")
        check(markdown.contains(.table([["Name", "Result"], ["test", "pass"]])), "Markdown table")
        check(MessageMarkdown.parse("~~~sh\necho hi") == [.code("sh", "echo hi")], "unfinished streaming code fence")
        check(MessageMarkdown.parse("a\n\nb") == [.paragraph("a"), .paragraph("b")], "paragraph boundaries")
        check(MessageMarkdown.parse("```text\n**literal**\n``` ") == [.code("text", "**literal**")], "code never interprets Markdown")
        print("Timeline checks: \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
