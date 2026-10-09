import Foundation
import CryptoKit

struct MemoryProject: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    let scope: String
    var workingDirectory: String
    var commonDirectory: String
    var isMissing: Bool { !FileManager.default.fileExists(atPath: workingDirectory) }
}

struct ManagedConversationContext: Equatable {
    let projectID: String
    let name: String
    let cwd: String
    var retrievedContext: [String] = []
}

struct MemorySource: Codable, Identifiable, Hashable {
    let id: String
    let projectID: String
    let provider: String
    let sessionID: String
    let title: String
    let path: String
}

struct SourceReference: Codable, Hashable, Identifiable {
    let id: String
    let provider: String
    let sessionID: String
    let nativeID: String
    let fileIdentity: String
    let path: String
    let byteOffset: UInt64
    let byteLength: Int
    let timestamp: String
    let fingerprint: String
    var originalURL: String? = nil
    var deepLink: URL? {
        var components = URLComponents()
        components.scheme = "agent-control-center"
        components.host = "session"
        components.path = "/" + (provider == "Claude Code" ? "claude:" : "") + sessionID
        components.queryItems = [URLQueryItem(name: "offset", value: String(byteOffset)), URLQueryItem(name: "fingerprint", value: fingerprint)]
        return components.url
    }
}

struct MemoryHit: Identifiable, Hashable {
    let id: String
    let title: String
    let role: String
    let text: String
    let source: SourceReference
}

struct IndexCoverage: Equatable {
    var sources = 0
    var complete = 0
    var indexedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var messages = 0
    var skippedRecords = 0
    var unavailable = 0
    var description: String {
        "\(complete)/\(sources) sources · \(messages) messages · \(ByteCountFormatter.string(fromByteCount: indexedBytes, countStyle: .file))/\(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) scanned" +
            (unavailable > 0 ? " · \(unavailable) unavailable" : "") + (skippedRecords > 0 ? " · \(skippedRecords) oversized or invalid records excluded" : "")
    }
}

enum DecisionStatus: String, Codable, CaseIterable { case proposed = "Proposed", accepted = "Accepted", rejected = "Rejected", superseded = "Superseded" }
enum DeliveryStatus: String, Codable, CaseIterable { case planned = "Planned", implemented = "Implemented", verified = "Verified" }
struct DecisionEvidence: Codable, Hashable, Identifiable {
    let id: String
    var kind: String // source, test, artifact, or conflict
    var detail: String
    var source: SourceReference?
}
struct ProjectDecision: Codable, Identifiable, Hashable {
    let id: String
    let projectID: String
    var title: String
    var detail: String
    var status: DecisionStatus = .proposed
    var delivery: DeliveryStatus = .planned
    var evidence: [DecisionEvidence] = []
    var acceptedByUser = false
    var verifiedAt: Date?
    var updatedAt = Date()
}

enum MemoryFingerprint {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Resolves Git metadata without invoking Git, loading a shell, or sourcing Work files.
enum MemoryRepositoryIdentity {
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    static func resolve(_ path: String) -> (root: String, common: String)? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        while directory.path != "/" {
            let marker = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                var gitDirectory = marker
                if !isDirectory.boolValue {
                    guard let pointer = try? String(contentsOf: marker, encoding: .utf8), pointer.hasPrefix("gitdir:") else { return nil }
                    let value = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDirectory = URL(fileURLWithPath: value, relativeTo: directory).standardizedFileURL
                }
                if let relative = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
                    gitDirectory = URL(fileURLWithPath: relative.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDirectory).standardizedFileURL
                }
                return (directory.path, gitDirectory.resolvingSymlinksInPath().path)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
