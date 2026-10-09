import AppKit
import SwiftUI

@main
struct HardwarePlannerApp: App {
    @StateObject private var model: PlannerModel
    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            do { try VisualFixtures.capture(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)); exit(0) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--check-build") {
            do {
                let fixture = HardwareProject.fieldNodeCandidates()
                let encoded = try ProjectFormat.encode(fixture)
                guard try ProjectFormat.decode(encoded) == fixture else { throw HardwareError.invalid("Project format check failed.") }
                print("Hardware Planner build check passed")
                exit(0)
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        _model = StateObject(wrappedValue: PlannerModel())
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Hardware Planner") {
            PlannerView(model: model)
        }.defaultSize(width: 1160, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import project…") { model.importProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Export project…") { model.export("json") }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.project == nil)
            }
        }
    }
}
