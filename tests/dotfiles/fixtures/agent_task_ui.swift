import AppKit
import SwiftUI

/// Native render fixture. Uses only temporary SQLite state and no provider process.
@main struct TaskSnapshotFixture {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, width, dark, empty) in [("light", 1000.0, false, false), ("dark", 1000.0, true, false), ("narrow", 600.0, false, false), ("empty", 1000.0, false, true)] {
            let database = try AgentDatabase(directory: output.appendingPathComponent(name + "-state"))
            let project = try await ProjectMemoryStore(database: database).attachProject(path: output.path)
            let coordinator = Coordinator(context: ManagedConversationContext(projectID: project.id, name: "Task fixture", cwd: output.path), database: database)
            let checks = [TaskCompletionCheck(id: "check-1", description: "Document the relevant interface and evidence", kind: .outputContains, target: "Interface")]
            if !empty {
                var completed = ManagedTaskRecord(id: UUID().uuidString, projectID: project.id, parentThreadID: "parent", humanMessageID: "human", humanInstruction: "Research the hardware interface", objective: "Document the field-node interface requirements and unresolved electrical assumptions", expectedDeliverable: "A short requirements report with source references", checks: checks, mode: .research, cwd: output.path, baseCWD: output.path)
                completed.state = .completed; completed.latestUpdate = "Requirements report ready for review. Peak-current evidence still needs a manufacturer source."
                completed.deliverable = TaskDeliverable(summary: "Report complete", content: "Interface requirements are documented; physical compatibility remains unverified.", files: ["interface-review.md"], checks: [TaskCheckResult(checkID: "check-1", passed: true, evidence: "Submitted report contains the required interface section.")])
                try await coordinator.store.create(completed)
                var paused = ManagedTaskRecord(id: UUID().uuidString, projectID: project.id, parentThreadID: "parent", humanMessageID: "human", humanInstruction: "Implement bounded project search", objective: "Implement project search in a separate checkout", expectedDeliverable: "Code and focused regression checks", checks: checks, mode: .implementation, cwd: output.appendingPathComponent("worktrees/search-with-a-long-descriptive-directory-name").path, baseCWD: output.path)
                paused.state = .running; paused.nativeThreadID = "child-native-identity"; paused.nativeTurnID = "saved-turn"; paused.latestUpdate = "Saved before application quit"
                try await coordinator.store.create(paused)
                var failed = ManagedTaskRecord(id: UUID().uuidString, projectID: project.id, parentThreadID: "parent", humanMessageID: "human", humanInstruction: "Run the focused tests", objective: "Check the focused test results", expectedDeliverable: "A test summary", checks: checks, mode: .research, cwd: output.path, baseCWD: output.path)
                failed.state = .failed; failed.latestUpdate = "The provider disconnected before verification finished. Review the saved evidence before continuing."
                try await coordinator.store.create(failed)
            }
            await coordinator.load()
            let view = NSHostingView(rootView: ProjectTaskList(coordinator: coordinator).background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : .white).environment(\.colorScheme, dark ? .dark : .light))
            let rectangle = NSRect(x: 0, y: 0, width: width, height: 740)
            let window = NSWindow(contentRect: rectangle, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = rectangle; view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rectangle) else { throw AgentStorageError.invalid("Cannot allocate snapshot") }
            view.cacheDisplay(in: rectangle, to: bitmap)
            guard let image = bitmap.representation(using: .png, properties: [:]) else { throw AgentStorageError.invalid("Cannot encode snapshot") }
            try image.write(to: output.appendingPathComponent(name + ".png"))
            window.close()
        }
        print("Task snapshots rendered: light, dark, narrow 600px, empty")
    }
}
