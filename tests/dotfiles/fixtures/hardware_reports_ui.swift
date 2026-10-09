import AppKit
import SwiftUI

@main
struct HardwareReportVisuals {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, width, dark, empty) in [("light", 1000.0, false, false), ("dark", 1000.0, true, false), ("narrow", 640.0, false, false), ("empty", 800.0, false, true)] {
            let report = HardwareReport(projectID: UUID(), projectName: "Field node with dual radios and carrier alternatives", projectVersion: 7,
                assemblyID: UUID(), assemblyName: "Mobile field station", assemblyRevision: 3, ruleVersion: "1", evaluatedChecks: 0,
                outcome: "unknown", parts: [], connections: [], requirements: ["Measure radio coexistence and battery endurance"],
                checks: [HardwareReport.Check(id: UUID(), rule: "power.coverage", outcome: "unknown", explanation: "Document the peak demand and source capacity", sourceIDs: [])], sources: [])
            let model = HardwareReportModel()
            let attachment = HardwareReportAttachment(id: "fixture", projectID: "fixture", report: report, fingerprint: String(repeating: "a", count: 64), filename: "field.hardware-report.json", importedAt: Date())
            model.attachments = empty ? [] : [attachment]; model.selectedID = empty ? nil : attachment.id
            let size = NSSize(width: width, height: 620)
            let host = NSHostingView(rootView: HardwareReportView(model: model).padding(24).frame(width: width, height: size.height).environment(\.colorScheme, dark ? .dark : .light).background(dark ? Color(nsColor: NSColor(white: 0.12, alpha: 1)) : Color.white))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HardwareReportError.invalid("No bitmap representation") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw HardwareReportError.invalid("No PNG representation") }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        print("Captured native hardware attachment light, dark, narrow and empty fixtures")
    }
}
