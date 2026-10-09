import AppKit
import SwiftUI

// Render app-owned synthetic views. This opens no database and captures no other app.
@MainActor
enum VisualFixtures {
    static func capture(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        var fixture = HardwareProject.fieldNodeCandidates()
        fixture.version = 1
        fixture.notes += " Visual QA fixture: no compatibility assessment. A long project note checks wrapping without changing stored user data."
        let assembly = AssemblyRevision(name: "Candidate POC — unverified", items: fixture.parts.prefix(5).map { AssemblyItem(partRevisionID: $0.id, quantity: $0.name == "GW16167" ? 2 : 1) })
        fixture.assemblies = [assembly]; fixture.selectedAssemblyID = assembly.id
        func render<Content: View>(_ view: Content, name: String, width: CGFloat, height: CGFloat, dark: Bool) throws {
            application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).background(dark ? Color(red: 0.12, green: 0.12, blue: 0.12) : Color.white))
            let rectangle = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: rectangle, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.title = "Hardware Planner — isolated visual fixture"
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host
            host.frame = rectangle
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rectangle) else { throw HardwareError.invalid("Fixture bitmap unavailable.") }
            host.cacheDisplay(in: rectangle, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw HardwareError.invalid("Fixture PNG encoding failed.") }
            try data.write(to: directory.appendingPathComponent(name + "-partial.png"))
            print("LIMITATION: \(name) uses an offscreen NSView capture; layer-backed controls need interactive visual verification.")
            window.close()
        }
        try render(PlannerView(model: PlannerModel(preview: fixture)), name: "project-light", width: 1160, height: 800, dark: false)
        try render(PlannerView(model: PlannerModel(preview: fixture)), name: "project-dark", width: 1160, height: 800, dark: true)
        try render(PlannerView(model: PlannerModel(preview: nil)), name: "empty", width: 800, height: 560, dark: false)
        try render(PlannerView(model: PlannerModel(preview: fixture), section: .bom), name: "bom-narrow", width: 800, height: 560, dark: true)
        try render(PlannerView(model: PlannerModel(preview: fixture), section: .alternatives), name: "alternatives", width: 1160, height: 800, dark: false)
        try render(PartEditor(project: fixture, original: fixture.parts.first, save: { _ in }), name: "part-editor", width: 720, height: 820, dark: false)
        try render(AssemblyEditor(project: fixture, original: assembly, save: { _ in }), name: "assembly-editor", width: 740, height: 820, dark: true)
        print("Rendered seven isolated Hardware Planner fixture views; inspect capture limitations above.")
    }
}
