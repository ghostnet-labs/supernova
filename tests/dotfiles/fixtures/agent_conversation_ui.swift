import AppKit
import SwiftUI

/// Manual native render fixture; uses isolated app state and never connects to Codex.
@main struct ConversationSnapshot {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try AgentDatabase(directory: directory.appendingPathComponent("state"))
        for (name, width, dark, empty) in [("light", 1000.0, false, false), ("dark", 1000.0, true, false), ("narrow", 640.0, false, false), ("empty", 1000.0, false, true)] {
            let context = ManagedConversationContext(projectID: name, name: "Field node prototype", cwd: directory.path)
            var record = ManagedConversationRecord(projectID: name, threadID: empty ? nil : "fixture-thread")
            if !empty {
                record.messages = [ManagedMessage(id: "user", role: "user", text: "Compare the proposed power requirements with the accepted project decisions.", turnID: "fixture-turn", isComplete: true),
                    ManagedMessage(id: "answer", role: "assistant", text: "The project decision keeps peak current separate from typical consumption. The power budget still needs documented peak demand and a measured battery capacity. I can prepare a compatibility report when those sources are attached.", turnID: "fixture-turn", isComplete: true)]
            }
            let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
            try await database.transaction { try $0.execute("INSERT OR REPLACE INTO managed_records(namespace,key,json) VALUES('conversation',?,?)", [name, json]) }
            let store = ManagedConversationRegistry.store(context: context, database: database)
            await store.load()
            if !empty {
                func emit(_ value: RPCValue) { store.client.receive(try! JSONEncoder().encode(value) + Data([10]), generation: store.client.generation) }
                emit(.object(["method": .string("turn/started"), "params": .object(["threadId": .string("fixture-thread"), "turn": .object(["id": .string("fixture-turn")])])]))
                emit(.object(["id": .number(1), "method": .string("item/commandExecution/requestApproval"), "params": .object(["threadId": .string("fixture-thread"), "turnId": .string("fixture-turn"), "command": .string("python3 check_power_budget.py --report"), "cwd": .string("/Projects/field-node"), "reason": .string("Run the project’s local compatibility check and produce a report."), "availableDecisions": .array([.string("accept"), .string("decline"), .string("cancel")])])]))
            }
            let rectangle = NSRect(x: 0, y: 0, width: width, height: 700)
            let view = NSHostingView(rootView: ProjectConversationSlot(context: context, database: database).background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color.white).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: rectangle, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = view; view.frame = rectangle
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rectangle) else { throw AgentStorageError.invalid("Could not allocate snapshot.") }
            view.cacheDisplay(in: rectangle, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw AgentStorageError.invalid("Could not encode snapshot.") }
            try png.write(to: directory.appendingPathComponent(name + ".png")); window.close()
        }
        print("PASS: native conversation light, dark, narrow and empty snapshots rendered")
    }
}
