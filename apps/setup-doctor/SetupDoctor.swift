import AppKit
import SwiftUI

enum FindingSeverity: String, CaseIterable {
    case fail, warning, info, pass

    var symbol: String {
        switch self {
        case .fail: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .pass: return "checkmark.circle.fill"
        }
    }
}

struct SetupFinding: Identifiable, Hashable {
    let id: String
    let section: String
    let severity: FindingSeverity
    let message: String
    var details: [String] = []

    private func count(_ kind: String) -> Int? {
        guard let range = message.range(of: "\\d+(?= \(kind)\\(s\\))", options: .regularExpression) else { return nil }
        return Int(message[range])
    }
    var failures: Int { count("failure") ?? (severity == .fail ? 1 : 0) }
    var warnings: Int { count("warning") ?? (severity == .warning ? 1 : 0) }
    var problemIDs: Set<String> {
        guard severity == .fail || severity == .warning else { return [] }
        let issues = Array(details.prefix { $0 != "Manual follow-up:" })
        return issues.isEmpty ? [id] : Set(issues.map { section + "|" + $0 })
    }

    static func parse(_ output: String) -> [SetupFinding] {
        var section = "Setup"
        var rows: [SetupFinding] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("──") {
                section = line.replacingOccurrences(of: "─", with: "").trimmingCharacters(in: .whitespaces)
                continue
            }
            let pairs: [(String, FindingSeverity)] = [("✗", .fail), ("!", .warning), ("•", .info), ("✓", .pass)]
            guard let pair = pairs.first(where: { line.hasPrefix($0.0) }) else {
                if raw.hasPrefix("   "), !rows.isEmpty { rows[rows.count - 1].details.append(line) }
                continue
            }
            let message = String(line.dropFirst(pair.0.count)).trimmingCharacters(in: .whitespaces)
            let id = "\(section)|\(message)"
            rows.append(SetupFinding(id: id, section: section, severity: pair.1, message: message))
        }
        return rows
    }
}

struct SetupSnapshot {
    let findings: [SetupFinding]
    let raw: String
    let checkedAt: Date

    var failures: Int { findings.reduce(0) { $0 + $1.failures } }
    var warnings: Int { findings.reduce(0) { $0 + $1.warnings } }
    var healthy: Bool { failures == 0 }

    func changes(from previous: Set<String>) -> (newProblems: Set<String>, fixed: Set<String>) {
        let problems = Set(findings.flatMap { $0.problemIDs })
        return (problems.subtracting(previous), previous.subtracting(problems))
    }
}

struct SetupCommandError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

enum SetupRunner {
    static func setupURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["SETUP_DOCTOR_SETUP_SH"],
            env["SETUP_DIR"].map { "\($0)/setup.sh" },
            "\(NSHomeDirectory())/dev/supernova/setup.sh"
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw SetupCommandError("setup.sh was not found; set SETUP_DOCTOR_SETUP_SH or SETUP_DIR")
        }
        return URL(fileURLWithPath: path)
    }

    static func run(_ arguments: [String]) async throws -> String {
        let setup = try setupURL()
        let process = Process()
        process.executableURL = setup
        process.arguments = arguments
        process.currentDirectoryURL = setup.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        // A health check may return non-zero specifically because it found drift.
        if text.isEmpty && process.terminationStatus != 0 {
            throw SetupCommandError("setup.sh exited \(process.terminationStatus) without output")
        }
        return text
    }

    static func openFixInGhostty() {
        guard let setup = try? setupURL() else { return }
        let command = "cd \(shellQuote(setup.deletingLastPathComponent().path)) && ./setup.sh --fix"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        shell.arguments = GhosttyLaunch.arguments(directory: setup.deletingLastPathComponent().path, command: command)
        try? shell.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class DoctorModel: ObservableObject {
    @Published private(set) var snapshot: SetupSnapshot?
    @Published private(set) var repairPreview = ""
    @Published private(set) var newProblems: Set<String> = []
    @Published private(set) var fixedProblems: Set<String> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var running = false
    @Published var filter: FindingSeverity?

    private let defaults = UserDefaults.standard
    private let baselineKey = "SetupDoctorPreviousProblems"

    var visibleFindings: [SetupFinding] {
        guard let snapshot else { return [] }
        guard let filter else { return snapshot.findings }
        return snapshot.findings.filter { $0.severity == filter }
    }

    init() {
        check()
    }

    func check() {
        guard !running else { return }
        running = true
        Task {
            do {
                let output = try await SetupRunner.run(["--check"])
                let next = SetupSnapshot(findings: SetupFinding.parse(output), raw: output, checkedAt: Date())
                guard !next.findings.isEmpty else { throw SetupCommandError("setup.sh returned no recognizable health findings") }
                // Old versions stored group summaries rather than individual issues.
                // Establish a fresh baseline once so migration does not invent drift.
                let currentProblems = Set(next.findings.flatMap { $0.problemIDs })
                let previous = defaults.integer(forKey: "SetupDoctorBaselineVersion") == 2
                    ? Set(defaults.stringArray(forKey: baselineKey) ?? []) : currentProblems
                let delta = next.changes(from: previous)
                snapshot = next
                newProblems = delta.newProblems
                fixedProblems = delta.fixed
                defaults.set(Array(currentProblems), forKey: baselineKey)
                defaults.set(2, forKey: "SetupDoctorBaselineVersion")
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            running = false
        }
    }

    func previewRepair() {
        guard !running else { return }
        repairPreview = ""
        errorMessage = nil
        running = true
        Task {
            do {
                repairPreview = try await SetupRunner.run(["--fix", "--dry-run"])
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            running = false
        }
    }

    func copyReport() {
        guard let snapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.raw, forType: .string)
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct FindingRow: View {
    let finding: SetupFinding
    let isNew: Bool
    let isFixed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.severity.symbol)
                .foregroundStyle(finding.severity == .fail ? Color.red : finding.severity == .warning ? Color.orange : Color.gray)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(finding.message)
                    if isNew {
                        Text("NEW").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.red.opacity(0.15), in: Capsule())
                    }
                    if isFixed {
                        Text("FIXED").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.green.opacity(0.15), in: Capsule())
                    }
                }
                Text(finding.section).font(.caption).foregroundStyle(.secondary)
                ForEach(finding.details, id: \.self) { detail in
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

struct SetupDoctorView: View {
    @StateObject private var model = DoctorModel()
    @State private var showingPreview = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup Doctor").font(.largeTitle.bold())
                    Text("Managed machine health and drift").foregroundStyle(.secondary)
                }
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Check Now") { model.check() }
                Button("Preview Repair") {
                    model.previewRepair()
                    showingPreview = true
                }
                Button("Fix in Ghostty") { SetupRunner.openFixInGhostty() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            if let snapshot = model.snapshot {
                HStack(spacing: 12) {
                    SummaryCard(title: "Failures", value: "\(snapshot.failures)", symbol: "xmark.octagon")
                    SummaryCard(title: "Warnings", value: "\(snapshot.warnings)", symbol: "exclamationmark.triangle")
                    SummaryCard(title: "New drift", value: "\(model.newProblems.count)", symbol: "clock.arrow.circlepath")
                    SummaryCard(title: "Recovered", value: "\(model.fixedProblems.count)", symbol: "wrench.and.screwdriver")
                }
                .padding(20)

                Picker("Filter", selection: $model.filter) {
                    Text("All").tag(nil as FindingSeverity?)
                    ForEach(FindingSeverity.allCases, id: \.self) { severity in
                        Text(severity.rawValue.capitalized).tag(Optional(severity))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                List(model.visibleFindings) { finding in
                    FindingRow(finding: finding,
                               isNew: !model.newProblems.isDisjoint(with: finding.problemIDs),
                               isFixed: finding.severity == .pass && model.fixedProblems.contains(finding.id))
                }
            } else if let error = model.errorMessage {
                ContentUnavailableView("Health check failed", systemImage: "stethoscope", description: Text(error))
            } else {
                ContentUnavailableView("Checking setup", systemImage: "stethoscope")
            }

            if model.snapshot != nil, let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(12)
            }
            Divider()
            HStack {
                if let snapshot = model.snapshot {
                    Text("Last checked \(snapshot.checkedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Report") { model.copyReport() }.buttonStyle(.borderless)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 620)
        .sheet(isPresented: $showingPreview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Repair Preview").font(.title2.bold())
                Text("Read-only output from ./setup.sh --fix --dry-run").foregroundStyle(.secondary)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                ScrollView {
                    Text(model.repairPreview.isEmpty ? "Building repair plan…" : model.repairPreview)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Run Fix in Ghostty") { SetupRunner.openFixInGhostty() }
                    Button("Close") { showingPreview = false }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 760, height: 540)
        }
    }
}

@main
struct SetupDoctorApp: App {
    var body: some Scene {
        WindowGroup("Setup Doctor") {
            SetupDoctorView()
        }
        .defaultSize(width: 920, height: 680)
    }
}
