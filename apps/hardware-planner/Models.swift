import Foundation

// All electrical quantities use volts, amperes, watts and millimetres. nil means unknown.
struct NumericRange: Codable, Equatable {
    var minimum: Double
    var maximum: Double
}

struct Dimensions: Codable, Equatable {
    var widthMM: Double? = nil
    var lengthMM: Double? = nil
    var heightMM: Double? = nil
}

enum EvidenceConfidence: String, Codable, CaseIterable {
    case candidate, manufacturer, measured
}

struct EvidenceSource: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var url = ""
    var section = ""
    var documentRevision = ""
    var retrievedAt = Date()
    var confidence: EvidenceConfidence = .candidate
    var attachmentID: UUID? = nil
    var notes = ""
}

struct ManagedAttachment: Codable, Equatable, Identifiable {
    var id = UUID()
    var filename: String
    var content: Data
}

enum PortDirection: String, Codable, CaseIterable { case input, output, bidirectional, unknown }

struct InterfaceSpec: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var connector: String? = nil
    var key: String? = nil
    var gender: String? = nil
    var protocols: [String] = []
    var voltage: NumericRange? = nil
    var direction: PortDirection = .unknown
    var pinMapping: [String: String] = [:]
    var lanes: Int? = nil
    var capacity: Int? = nil
    var resourceGroup: String? = nil
    var dimensions: Dimensions? = nil
    var sourceIDs: [UUID] = []
    var notes = ""
}

struct PowerSpec: Codable, Equatable, Identifiable {
    var id = UUID()
    var rail: String
    var interfaceID: UUID? = nil
    var direction: PortDirection = .unknown
    var voltage: NumericRange? = nil
    var typicalCurrentA: Double? = nil
    var peakCurrentA: Double? = nil
    var capacityCurrentA: Double? = nil
    var typicalPowerW: Double? = nil
    var peakPowerW: Double? = nil
    var capacityPowerW: Double? = nil
    var efficiency: Double? = nil
    var headroomFraction: Double? = nil
    var operatingConditions = ""
    var sourceIDs: [UUID] = []
}

struct AdapterMapping: Codable, Equatable, Identifiable {
    var id = UUID()
    var inputInterfaceID: UUID
    var outputInterfaceID: UUID
    var inputProtocol: String? = nil
    var outputProtocol: String? = nil
    var outputVoltage: NumericRange? = nil
    var capacityCurrentA: Double? = nil
    var efficiency: Double? = nil
    var sourceIDs: [UUID] = []
    var conditions = ""
}

struct SoftwareSupport: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var version = ""
    var driver = ""
    var supported: Bool? = nil
    var sourceIDs: [UUID] = []
    var conditions = ""
}

struct PartRevision: Codable, Equatable, Identifiable {
    var id = UUID()
    var partID = UUID()
    var revision = 1
    var createdAt = Date()
    var name: String
    var manufacturer = ""
    var partNumber = ""
    var boardRevision = ""
    var category = ""
    var dimensions: Dimensions? = nil
    var interfaces: [InterfaceSpec] = []
    var power: [PowerSpec] = []
    var adapters: [AdapterMapping] = []
    var software: [SoftwareSupport] = []
    var sourceIDs: [UUID] = []
    var unresolvedQuestions: [String] = []
    var notes = ""

    func revised() -> PartRevision {
        var copy = self
        copy.id = UUID(); copy.revision += 1; copy.createdAt = Date()
        return copy
    }
}

struct Offer: Codable, Equatable, Identifiable {
    var id = UUID()
    var partRevisionID: UUID
    var seller: String
    var url = ""
    var currency = "USD"
    var unitPrice: Decimal? = nil
    var minimumQuantity = 1
    var availability = "Unknown"
    var observedAt = Date()
}

struct AssemblyItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var partRevisionID: UUID
    var quantity = 1
    var role = ""
    var offerID: UUID? = nil
    var alternativeRevisionIDs: [UUID] = []
    var notes = ""
}

struct ConnectionEndpoint: Codable, Equatable {
    var itemID: UUID
    var interfaceID: UUID
}

struct HardwareConnection: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var from: ConnectionEndpoint
    var to: ConnectionEndpoint
    var requiredProtocol: String? = nil
    var lanesRequired: Int? = nil
    var sourceIDs: [UUID] = []
    var notes = ""
}

struct AssemblyRevision: Codable, Equatable, Identifiable {
    var id = UUID()
    var assemblyID = UUID()
    var revision = 1
    var name: String
    var createdAt = Date()
    var items: [AssemblyItem] = []
    var connections: [HardwareConnection] = []
    var tax: Decimal? = nil
    var shipping: Decimal? = nil
    var costCurrency = "USD"
    var notes = ""

    func revised() -> AssemblyRevision {
        var copy = self
        copy.id = UUID(); copy.revision += 1; copy.createdAt = Date()
        return copy
    }
}

struct Requirement: Codable, Equatable, Identifiable {
    var id = UUID()
    var capability: String
    var threshold: String = ""
    var operatingCondition = ""
    var evidenceNeeded = ""
    var affectedItemIDs: [UUID] = []
    var sourceIDs: [UUID] = []
    var satisfied: Bool? = nil
    var notes = ""
}

struct HardwareDecision: Codable, Equatable, Identifiable {
    var id = UUID()
    var choice: String
    var reason = ""
    var alternatives = ""
    var sourceIDs: [UUID] = []
    var createdAt = Date()
}

enum CheckOutcome: String, Codable, CaseIterable { case compatible, conditional, incompatible, unknown }

struct CompatibilityFinding: Codable, Equatable, Identifiable {
    var id = UUID()
    var ruleID: String
    var ruleVersion: String
    var assemblyRevisionID: UUID
    var outcome: CheckOutcome
    var explanation: String
    var affectedItemIDs: [UUID] = []
    var connectionID: UUID? = nil
    var sourceIDs: [UUID] = []
    var inputs: [String: String] = [:]
    var checkedAt = Date()
}

struct FindingOverride: Codable, Equatable, Identifiable {
    var id = UUID()
    var findingID: UUID
    var reason: String
    var author: String
    var createdAt = Date()
}

struct HardwareProject: Codable, Equatable, Identifiable {
    var id = UUID()
    var version = 0
    var name: String
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()
    var parts: [PartRevision] = []
    var assemblies: [AssemblyRevision] = []
    var selectedAssemblyID: UUID? = nil
    var sources: [EvidenceSource] = []
    var attachments: [ManagedAttachment] = []
    var offers: [Offer] = []
    var requirements: [Requirement] = []
    var decisions: [HardwareDecision] = []
    var findings: [CompatibilityFinding] = []
    var overrides: [FindingOverride] = []

    var selectedAssembly: AssemblyRevision? { assemblies.first { $0.id == selectedAssemblyID } }
    var projectURL: URL { URL(string: "hardware-planner://project/\(id.uuidString)")! }
    func part(_ id: UUID) -> PartRevision? { parts.first { $0.id == id } }

    static func fieldNodeCandidates() -> HardwareProject {
        var project = HardwareProject(name: "Field node — candidate worksheet")
        project.notes = "Candidate worksheet from earlier field-node planning. Carrier preference changed between discussions; neither preference is an accepted purchase decision. All interface, voltage, current, software and mechanical claims remain unknown until the exact board revision is documented."
        let source = EvidenceSource(title: "Board Comparison Analysis", url: "https://example.com/notes/board-comparison", section: "Architecture checkpoint and carrier alternatives", notes: "Conversation context only. Prior assistant claims are unverified.")
        let newer = EvidenceSource(title: "Updated BOM Links", url: "https://example.com/notes/updated-bom-links", section: "Dual HaLow and carrier comparisons", notes: "Candidate revisions and conflicting carrier rankings require confirmation.")
        project.sources = [source, newer]
        let candidates = [("CM5 Wireless", "Raspberry Pi", "Compute"), ("GW16167", "Gateworks", "HaLow radio"),
                          ("GW16170", "Gateworks", "HaLow alternative"), ("QCA6174 module — exact vendor TBD", "", "High-band radio"),
                          ("CM5-IO-WIRELESS-BASE", "Waveshare", "Carrier candidate"), ("TOFU5+", "Oratek", "Carrier alternative"),
                          ("CMX2", "BentoIO", "Carrier alternative"), ("CM5-NANO-B", "Waveshare", "Carrier alternative"),
                          ("CM5-IO-BASE-A", "Waveshare", "Carrier alternative"), ("GNSS / PPS module TBD", "", "Position and timing"),
                          ("BMS / power telemetry TBD", "", "Power"), ("Cables, radio carriers and regulators TBD", "", "Adapters")]
        project.parts = candidates.map { name, manufacturer, category in
            PartRevision(name: name, manufacturer: manufacturer, category: category, sourceIDs: [source.id, newer.id], unresolvedQuestions: ["Confirm exact part number and board revision", "Verify interface, power and mechanical specifications against manufacturer documentation"])
        }
        project.requirements = ["Dual HaLow radios", "Local client wireless access", "Gateway loss and recovery", "Disconnected mesh groups reconnect", "DHCP isolation", "Multicast delivery", "GNSS / PPS", "BMS and power telemetry", "RF coexistence", "Thermal behavior", "Battery endurance"].map {
            Requirement(capability: $0, evidenceNeeded: "Documented requirement and measured field result")
        }
        return project
    }
}

enum HardwareError: LocalizedError {
    case invalid(String), database(String), conflict
    var errorDescription: String? {
        switch self {
        case .invalid(let text), .database(let text): return text
        case .conflict: return "This project changed since it was opened. Reload before saving."
        }
    }
}
