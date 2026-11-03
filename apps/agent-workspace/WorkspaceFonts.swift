import AppKit
import CoreText
import SwiftUI

enum WorkspaceFont: String, CaseIterable, Identifiable {
    case system = "System", rounded = "Rounded", serif = "Serif", monospaced = "Monospaced"
    case chatgpt = "ChatGPT", claude = "Claude", claudeUI = "Claude UI", github = "GitHub"
    var id: String { rawValue }
    var design: Font.Design? {
        switch self {
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        default: nil
        }
    }
    var typeface: String {
        switch self {
        case .chatgpt: "OpenAI Sans"
        case .claude: "Anthropic Serif"
        case .claudeUI: "Anthropic Sans"
        case .github: "Mona Sans"
        default: rawValue
        }
    }
    var postscriptName: String? {
        switch self {
        case .chatgpt: "OpenAISans-Regular"
        case .claude: "AnthropicSerifVariable-TextRegular"
        case .claudeUI: "AnthropicSansVariable-TextRegular"
        case .github: "MonaSansVF-Regular"
        default: nil
        }
    }
}

/// Register fonts only for this process. No font discovery or disk work occurs in view bodies.
enum WorkspaceFontLoader {
    static func load(_ font: WorkspaceFont) -> String? {
        guard let name = font.postscriptName else { return nil }
        if NSFont(name: name, size: 13) != nil { return name }
        switch font {
        case .github:
            let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts/MonaSansVF.ttf")
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fonts/MonaSansVF.ttf")
            register(bundled ?? source)
            if NSFont(name: name, size: 13) == nil { register(source) }
        case .claude, .claudeUI:
            let prefix = font == .claude ? "AnthropicSerif-" : "AnthropicSans-"
            for app in appLocations("Claude", identifiers: ["com.anthropic.claudefordesktop"]) {
                let directory = app.appendingPathComponent("Contents/Resources/fonts")
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "ttf" { register(file) }
                if NSFont(name: name, size: 13) != nil { break }
            }
        case .chatgpt:
            for app in appLocations("ChatGPT", identifiers: ["com.openai.chat", "com.openai.codex"]) {
                registerOpenAISans(in: app.appendingPathComponent("Contents/Resources/app.asar"))
                if NSFont(name: name, size: 13) != nil { break }
            }
        default: break
        }
        return NSFont(name: name, size: 13) == nil ? nil : name
    }

    private static func register(_ url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private static func appLocations(_ name: String, identifiers: [String]) -> [URL] {
        var paths = identifiers.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        paths += [URL(fileURLWithPath: "/Applications/\(name).app"),
                  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name).app")]
        var seen: Set<String> = []
        return paths.filter { seen.insert($0.path).inserted }
    }

    private static func registerOpenAISans(in archive: URL) {
        // Read the archive index and three small font ranges, never the whole app archive.
        guard let file = try? FileHandle(forReadingFrom: archive) else { return }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 16), header.count == 16 else { return }
        func uint32(_ offset: Int) -> UInt64 {
            header.withUnsafeBytes { UInt64(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
        }
        let headerSize = uint32(4), jsonSize = uint32(12)
        guard jsonSize > 0, jsonSize <= 16_000_000, headerSize >= jsonSize + 8,
              let json = try? file.read(upToCount: Int(jsonSize)),
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let children = root["files"] as? [String: Any], let webview = children["webview"] as? [String: Any],
              let webFiles = webview["files"] as? [String: Any], let assets = webFiles["assets"] as? [String: Any],
              let files = assets["files"] as? [String: [String: Any]],
              let length = try? file.seekToEnd() else { return }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Workspace/Fonts")
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, entry) in files where name.hasPrefix("OpenAISans-") && name.hasSuffix(".woff2") {
                guard name == (name as NSString).lastPathComponent,
                      let raw = entry["offset"] as? String, let offset = UInt64(raw),
                      let size = entry["size"] as? Int, size > 0, size <= 2_000_000,
                      offset < length, headerSize + 8 <= length - offset,
                      UInt64(size) <= length - offset - headerSize - 8 else { continue }
                let destination = cache.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try file.seek(toOffset: headerSize + 8 + offset)
                    guard let data = try file.read(upToCount: size), data.count == size else { continue }
                    try data.write(to: destination, options: .atomic)
                }
                register(destination)
            }
        } catch { return }
    }
}
