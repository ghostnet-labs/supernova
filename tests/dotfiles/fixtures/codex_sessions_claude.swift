import Foundation

@main struct ClaudeChecks {
    static func main() throws {
        var failures = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("claude")
        let fm = FileManager.default
        let project = home.appendingPathComponent("workspace")
        let root = home.appendingPathComponent("projects/encoded")
        let liveDir = home.appendingPathComponent("sessions")
        for dir in [project.appendingPathComponent(".git"), root, liveDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let id = "11111111-1111-4111-8111-111111111111"
        let path = root.appendingPathComponent(id + ".jsonl")
        var data = Data()
        func record(_ type: String, _ uuid: String, _ extra: [String: Any]) throws {
            var value: [String: Any] = ["type": type, "uuid": uuid, "sessionId": id,
                "timestamp": "2026-10-03T12:00:00Z", "cwd": project.path, "gitBranch": "main", "version": "2.1"]
            value.merge(extra) { _, new in new }
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            data.append(10)
        }
        func text(_ value: String) -> [String: Any] { ["type": "text", "text": value] }
        func tool(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
            ["type": "tool_use", "id": id, "name": name, "input": input]
        }
        try record("user", "u1", ["message": ["content": "Please check\nthe project."]])
        try record("assistant", "a1", ["message": ["id": "response1", "model": "claude-test", "stop_reason": "tool_use",
            "usage": ["input_tokens": 10, "cache_read_input_tokens": 20, "output_tokens": 5],
            "content": [text("Checking now."), tool("call1", "Bash", ["command": "printf héllo"]),
                        text("Then read the file."), tool("call2", "Read", ["file_path": "file.txt"])]]])
        try data.write(to: path)
        var builder = TimelineBuilder()
        let first = ClaudeData.readTranscript(path, activity: &builder)
        check(first.messages.map(\.text) == ["Please check\nthe project.", "Checking now.", "Then read the file."], "visible text and newlines")
        let ordered = ConversationItem.merge(messages: first.messages, activity: builder.events).map { item -> String in
            switch item { case .message(let m): return m.text; case .activity(let e): return e.label }
        }
        check(ordered == ["Task started", "Please check\nthe project.", "Checking now.", "Bash", "Then read the file.", "Read"], "multiple text/tool blocks keep exact order")
        let firstTool = builder.events.first { $0.kind == .tool }!
        check(TimelinePayload.load(path: path, event: firstTool).input.contains("printf héllo"), "input loaded by record and content index")
        try record("user", "results", ["message": ["content": [
            ["type": "tool_result", "tool_use_id": "call2", "content": [text("File missing")], "is_error": true],
            ["type": "tool_result", "tool_use_id": "call1", "content": "héllo\nworld"]]]])
        try record("assistant", "a2", ["message": ["id": "response1", "model": "claude-test", "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "cache_read_input_tokens": 20, "output_tokens": 8], "content": [text("## Done\n\nFinal reply.")]]])
        try record("assistant", "a2", ["message": ["content": [text("Duplicate must not appear")]]])
        try record("user", "meta", ["isMeta": true, "message": ["content": "Internal context"]])
        try record("user", "side", ["isSidechain": true, "message": ["content": "Subagent prompt"]])
        try record("ai-title", "title", ["aiTitle": "Derived title"])
        try record("custom-title", "custom", ["customTitle": "My session"])
        try data.write(to: path)
        let second = ClaudeData.readTranscript(path, from: first.nextOffset, activity: &builder)
        check(second.messages.count == 1 && second.messages[0].phase == "final", "final labels, replay deduplication, hidden meta and tool-result records")
        let tools = builder.events.filter { $0.kind == .tool }
        check(tools.map(\.id).contains(firstTool.id), "tool identity stable on append")
        check(TimelinePayload.load(path: path, event: tools[0]).output == "héllo\nworld", "out-of-order results pair by call ID")
        check(tools[1].failed && TimelinePayload.load(path: path, event: tools[1]).output == "File missing", "failure and multi-result selection")
        check(!TimelineTurn.group(builder.events)[0].isOpen, "end_turn closes activity")
        let revision = builder.revision
        let unchanged = ClaudeData.readTranscript(path, from: second.nextOffset, activity: &builder)
        check(unchanged.messages.isEmpty && revision == builder.revision, "unchanged tail does no work")
        let partial = Data("{\"type\":\"user\",\"uuid\":\"partial\",\"message\":{\"content\":\"Next\"}}".utf8)
        data.append(partial); try data.write(to: path)
        let pending = ClaudeData.readTranscript(path, from: second.nextOffset, activity: &builder)
        check(pending.nextOffset == second.nextOffset && pending.messages.isEmpty, "partial JSONL waits")
        data.append(10); try data.write(to: path)
        let finished = ClaudeData.readTranscript(path, from: pending.nextOffset, activity: &builder)
        check(finished.messages.map(\.text) == ["Next"], "completed partial record appears once")
        try Data("{\"type\":\"user\",\"uuid\":\"replacement\",\"message\":{\"content\":\"Replacement\"}}\n".utf8).write(to: path)
        let reset = ClaudeData.readTranscript(path, from: finished.nextOffset, activity: &builder)
        check(reset.didReset && reset.messages.map(\.text) == ["Replacement"] && builder.events.count == 1, "truncation resets transcript and pending calls")
        var stringInput = TimelineBuilder()
        _ = stringInput.consumeClaude(["type": "assistant", "uuid": "s1", "message": ["content": [
            ["type": "tool_use", "id": "s1", "name": "Bash", "input": "printf hi"]]]], path: path, offset: 0)
        check(stringInput.events.map(\.detail) == ["printf hi"], "tool input that is a string, not an object")
        print("Claude session checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
