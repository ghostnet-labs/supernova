import AppKit
import SwiftUI

/// Manual render fixture. It never starts history providers or opens user data.
@main
struct ProjectMemorySnapshot {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let defaults = UserDefaults(suiteName:"ProjectMemoryRenderFixture")!
        let store = SessionStore(startProviders:false,defaults:defaults)
        for (name,width,dark,empty) in [("light",1000.0,false,false),("dark",1000.0,true,false),("narrow",760.0,false,false),("empty",1000.0,false,true)] {
            let model = ProjectWorkspaceModel(automaticLoad:false)
            if !empty {
                let project = MemoryProject(id:"fixture",name:"Field node prototype",scope:"Personal",workingDirectory:output.path,commonDirectory:"")
                model.projects = [project]; model.project = project
                model.coverage = IndexCoverage(sources:120,complete:50,indexedBytes:25_000_000,totalBytes:190_000_000,messages:950,skippedRecords:2)
                model.decisions = [ProjectDecision(id:"decision",projectID:project.id,title:"Keep peak current separate from typical consumption",detail:"Use documented peak demand for the power budget. Unknown ratings stay unresolved until a manufacturer source or measurement supports them.",status:.accepted,delivery:.planned)]
                model.summary = "Accepted; Planned\nPeak demand still requires evidence."
            }
            let view = NSHostingView(rootView:ProjectWorkspaceView(sessionStore:store,model:model).background(dark ? Color(red:0.12,green:0.12,blue:0.12):Color.white).environment(\.colorScheme,dark ? .dark:.light))
            let rectangle = NSRect(x:0,y:0,width:width,height:650)
            let window = NSWindow(contentRect:rectangle,styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.appearance = NSAppearance(named:dark ? .darkAqua:.aqua)
            view.frame = rectangle
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:200_000_000)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:rectangle) else { throw AgentStorageError.invalid("Could not allocate view snapshot") }
            view.cacheDisplay(in:rectangle,to:bitmap)
            guard let data = bitmap.representation(using:.png,properties:[:]) else { throw AgentStorageError.invalid("Could not encode view snapshot") }
            try data.write(to:output.appendingPathComponent(name + ".png"))
            window.close()
        }
        defaults.removePersistentDomain(forName:"ProjectMemoryRenderFixture")
        print("Project memory native snapshots rendered")
    }
}
