import Foundation

private final class ShellOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum Shell {
    static func executable(_ name: String) -> String? {
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/\(name)" }
        paths += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8, environment: [String: String]? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        let captured = ShellOutput()
        let outputFinished = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outputFinished.signal()
            } else {
                captured.append(data)
            }
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer { output.fileHandleForReading.readabilityHandler = nil }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            _ = outputFinished.wait(timeout: .now() + 1)
            return String(data: captured.data(), encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func launch(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
    }
}

enum CodexData {
    private static let dateLock = NSLock()
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSecondDateFormatter = ISO8601DateFormatter()

    static var home: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory)
    }

    static var sessionsDirectory: URL { home.appending(path: "sessions", directoryHint: .isDirectory) }
    static var archiveDirectory: URL { home.appending(path: "archived_sessions", directoryHint: .isDirectory) }

    static func readTranscript(_ path: URL, from offset: UInt64 = 0, activity: inout TimelineBuilder) -> TranscriptChunk {
        guard let handle = try? FileHandle(forReadingFrom: path) else {
            return TranscriptChunk(messages: [], nextOffset: offset)
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset <= size ? offset : 0
        if start == 0 { activity = TimelineBuilder() }
        try? handle.seek(toOffset: start)
        guard let data = try? readChunk(handle), !data.isEmpty else {
            return TranscriptChunk(messages: [], nextOffset: start, didReset: start != offset)
        }

        let newlines = newlineOffsets(data)
        guard let lastNewline = newlines.last else {
            return TranscriptChunk(messages: [], nextOffset: start, didReset: start != offset)
        }

        let completeLength = lastNewline + 1
        let fallback = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        var messages: [TranscriptMessage] = []
        var cursor = 0
        for newline in newlines {
            let absoluteOffset = start + UInt64(cursor)
            defer { cursor = newline + 1 }
            guard containsRecordType(data, cursor..<newline),
                  let record = try? JSONSerialization.jsonObject(with: data.subdata(in: cursor..<newline)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any] else { continue }
            let timestamp = parseDate(record["timestamp"]) ?? fallback
            activity.consume(record, timestamp: timestamp, offset: absoluteOffset)

            let role: String
            let message: String
            let phase: String
            if record["type"] as? String == "event_msg" {
                guard let eventType = payload["type"] as? String,
                      let eventMessage = payload["message"] as? String else { continue }
                switch eventType {
                case "user_message": role = "user"
                case "agent_message": role = "assistant"
                default: continue
                }
                message = eventMessage
                phase = payload["phase"] as? String ?? ""
            } else if record["type"] as? String == "response_item",
                      payload["type"] as? String == "message",
                      let messageRole = payload["role"] as? String,
                      messageRole == "user" || messageRole == "assistant",
                      let content = payload["content"] as? [[String: Any]] {
                role = messageRole
                let contentType = role == "user" ? "input_text" : "output_text"
                let parts = content.compactMap { item -> String? in
                    guard item["type"] as? String == contentType else { return nil }
                    return item["text"] as? String
                }
                message = parts.joined(separator: "\n\n")
                phase = payload["phase"] as? String ?? ""
            } else {
                continue
            }

            var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if role == "user" {
                for marker in ["</environment_context>", "</INSTRUCTIONS>"] {
                    if let range = text.range(of: marker, options: .backwards) {
                        text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            guard !text.isEmpty else { continue }
            messages.append(TranscriptMessage(
                id: "\(path.path)#\(absoluteOffset)",
                role: role,
                text: text,
                timestamp: timestamp,
                phase: phase,
                byteOffset: absoluteOffset
            ))
        }
        return TranscriptChunk(messages: messages, nextOffset: start + UInt64(completeLength), didReset: start != offset,
                               hasMore: start + UInt64(data.count) < size)
    }

    /// Bound temporary transcript memory; a single long record may span several chunks.
    static func readChunk(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            data.append(chunk)
            // Earlier reads had no newline, so only the new bytes need scanning.
            if chunk.isEmpty || chunk.withUnsafeBytes({ memchr($0.baseAddress, 10, $0.count) != nil }) { return data }
        }
    }

    /// Offsets of every newline; memchr is far faster than stepping through Data byte by byte.
    static func newlineOffsets(_ data: Data) -> [Int] {
        data.withUnsafeBytes { bytes in
            var offsets: [Int] = []
            var next = 0
            while next < bytes.count, let found = memchr(bytes.baseAddress! + next, 10, bytes.count - next) {
                offsets.append(bytes.baseAddress!.distance(to: UnsafeRawPointer(found)))
                next = offsets.last! + 1
            }
            return offsets
        }
    }

    private static let recordTypes = ["\"event_msg\"", "\"response_item\"", "\"turn_context\""].map { type in
        (bytes: Array(type.utf8), underscore: Array(type.utf8).firstIndex(of: 0x5F)!)
    }

    // Whether the line contains one of the quoted record types the transcript reads. Each has one underscore,
    // so a memchr pass over underscores replaces three full searches of long lines such as compaction history.
    private static func containsRecordType(_ data: Data, _ line: Range<Int>) -> Bool {
        data.withUnsafeBytes { bytes in
            var next = line.lowerBound
            while next < line.upperBound, let found = memchr(bytes.baseAddress! + next, 0x5F, line.upperBound - next) {
                let underscore = bytes.baseAddress!.distance(to: UnsafeRawPointer(found))
                for type in recordTypes {
                    let start = underscore - type.underscore
                    if start >= line.lowerBound, start + type.bytes.count <= line.upperBound,
                       memcmp(bytes.baseAddress! + start, type.bytes, type.bytes.count) == 0 { return true }
                }
                next = underscore + 1
            }
            return false
        }
    }

    static func moveArchive(_ session: CodexSession, archive: Bool) throws -> URL {
        guard session.source == .codex else {
            throw NSError(domain: "CodexSessions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Archiving is only available for Codex sessions."])
        }
        if session.isLive {
            throw NSError(
                domain: "CodexSessions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Live sessions cannot be archived."]
            )
        }
        let fm = FileManager.default
        let destination: URL
        if archive {
            try fm.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            destination = uniqueDestination(in: archiveDirectory, name: session.path.lastPathComponent)
        } else {
            let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: session.startedAt)
            let target = sessionsDirectory
                .appending(path: String(format: "%04d", parts.year ?? 1970), directoryHint: .isDirectory)
                .appending(path: String(format: "%02d", parts.month ?? 1), directoryHint: .isDirectory)
                .appending(path: String(format: "%02d", parts.day ?? 1), directoryHint: .isDirectory)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            destination = uniqueDestination(in: target, name: session.path.lastPathComponent)
        }
        try fm.moveItem(at: session.path, to: destination)
        return destination
    }

    static func projectRoots() -> [SessionProject] {
        let db = home.appending(path: "state_5.sqlite").path
        guard FileManager.default.fileExists(atPath: db), let sqlite = Shell.executable("sqlite3"),
              let output = Shell.run(sqlite, ["-readonly", "-json", db,
                "SELECT p.id, p.name, r.path FROM projects p JOIN project_roots r ON r.project_id = p.id;"]),
              let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"], let name = row["name"], let path = row["path"] else { return nil }
            return SessionProject(id: "project:" + id, name: name, path: path)
        }
    }

    private static func uniqueDestination(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appending(path: name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var number = 2
        repeat {
            let name = ext.isEmpty ? "\(stem)-\(number)" : "\(stem)-\(number).\(ext)"
            candidate = directory.appending(path: name)
            number += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        if let date = millisecondDate(raw) { return date }
        dateLock.lock()
        defer { dateLock.unlock() }
        return fractionalDateFormatter.date(from: raw) ?? wholeSecondDateFormatter.date(from: raw)
    }

    // ISO8601DateFormatter takes tens of microseconds a call. Parse the usual "2026-07-16T21:58:49.123Z" as it
    // does: ICU counts whole milliseconds since 1970, then CF divides by 1,000 and moves to the reference date.
    // ICU uses the Julian calendar before October 1582; leave that and every other form to the formatter.
    private static func millisecondDate(_ raw: String) -> Date? {
        let bytes = Array(raw.utf8.prefix(25))
        guard bytes.count == 24,
              zip(bytes, "0000-00-00T00:00:00.000Z".utf8).allSatisfy({ $1 == 48 ? (48...57).contains($0) : $0 == $1 }) else { return nil }
        func number(_ start: Int, _ count: Int) -> Int { bytes[start..<start + count].reduce(0) { $0 * 10 + Int($1 - 48) } }
        let year = number(0, 4), month = number(5, 2), day = number(8, 2)
        let hour = number(11, 2), minute = number(14, 2), second = number(17, 2)
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        guard year > 1582, (1...12).contains(month), day >= 1, day <= [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1],
              hour < 24, minute < 60, second < 60 else { return nil }
        let y = month > 2 ? year : year - 1
        let days = y * 365 + y / 4 - y / 100 + y / 400 + (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 719_469
        let milliseconds = (((days * 24 + hour) * 60 + minute) * 60 + second) * 1_000 + number(20, 3)
        return Date(timeIntervalSinceReferenceDate: Double(milliseconds) / 1_000 - 978_307_200)
    }

}
