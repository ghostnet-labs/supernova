import Foundation

@main struct DoctorChecks {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            if !value() { print("FAIL: " + message); exit(1) }
        }
        let report = """
        ✗  Dependencies — 2 failure(s), 1 warning(s), 1 manual follow-up(s)
           missing first tool
           missing second tool
           old optional tool
           Manual follow-up:
           sign in manually
        !  Paths — 2 warning(s), 0 manual follow-up(s)
           first path
           second path
        ✓  Work Environment

        [SUMMARY] 2 failure(s), 3 warning(s), 1 manual follow-up(s)
        """
        let rows = SetupFinding.parse(report)
        let snapshot = SetupSnapshot(findings: rows, raw: report, checkedAt: Date())
        check(rows.count == 3 && rows[0].details.count == 5, "retain report details without turning the summary into a finding")
        check(snapshot.failures == 2 && snapshot.warnings == 3, "count findings rather than failing groups")
        check(!snapshot.healthy, "failing report is unhealthy")
        let baseline = Set(rows.flatMap { $0.problemIDs })
        check(baseline.count == 5, "manual follow-up is not a new failure")
        let changed = report.replacingOccurrences(of: "missing second tool", with: "missing third tool")
        let next = SetupSnapshot(findings: SetupFinding.parse(changed), raw: changed, checkedAt: Date())
        let delta = next.changes(from: baseline)
        check(delta.newProblems == ["Setup|missing third tool"] && delta.fixed == ["Setup|missing second tool"], "track individual changes within a group")
        let legacy = SetupFinding.parse("── Tools\n✗ Missing tool\n! Old tool\n✓ Ready")
        let old = SetupSnapshot(findings: legacy, raw: "", checkedAt: Date())
        check(old.failures == 1 && old.warnings == 1 && legacy[0].section == "Tools", "keep legacy marker reports supported")

        let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = scratch.appendingPathComponent("project's directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shell = scratch.appendingPathComponent("shell's path")
        try FileManager.default.createSymbolicLink(at: shell, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        let command = "printf '%s\\n' \"$PWD\" 'a b' '$(literal)' \"x'y\""
        let arguments = GhosttyLaunch.arguments(directory: directory.path, command: command, shell: shell.path)
        check(arguments.prefix(4) == ["-na", "Ghostty.app", "--args", "--window-save-state=never"], "disable saved-window replay")
        check(arguments.contains("--working-directory=" + directory.path), "set terminal directory")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", String(arguments.last!.dropFirst("--initial-command=".count))]
        process.currentDirectoryURL = scratch
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let lines = text.split(separator: "\n").map(String.init)
        check(process.terminationStatus == 0 && lines.count == 4, "execute quoted command")
        check(URL(fileURLWithPath: lines[0]).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path, "launch in the requested directory")
        check(Array(lines.dropFirst()) == ["a b", "$(literal)", "x'y"], "preserve literal arguments")
        print("PASS: Setup Doctor counts, details, drift, and shared Ghostty command execution")
    }
}
