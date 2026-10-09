import Foundation

@main struct HardwareCompatibilityTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func reference() -> HardwareProject {
        var project = HardwareProject(name: "Synthetic verified reference")
        let evidence = EvidenceSource(title: "Synthetic fixture, not a real part specification", retrievedAt: now, confidence: .measured, notes: "Controlled test fixture")
        project.sources = [evidence]
        func port(_ name: String, _ direction: PortDirection, _ gender: String) -> InterfaceSpec {
            InterfaceSpec(name: name, connector: "synthetic-dc", key: "none", gender: gender, protocols: ["dc"],
                voltage: NumericRange(minimum: 5, maximum: 5), direction: direction, pinMapping: ["1": "+", "2": "ground"],
                lanes: 2, capacity: 2, dimensions: Dimensions(widthMM: 1, lengthMM: 2, heightMM: 3), sourceIDs: [evidence.id])
        }
        let out = port("Supply", .output, "male"), input = port("Load", .input, "female")
        let software = SoftwareSupport(name: "No driver required", supported: true, sourceIDs: [evidence.id])
        var source = PartRevision(name: "Supply", interfaces: [out], software: [software])
        source.power = [PowerSpec(rail: "output", interfaceID: out.id, direction: .output, voltage: out.voltage,
            capacityCurrentA: 4, capacityPowerW: 20, headroomFraction: 0.2, sourceIDs: [evidence.id])]
        var sink = PartRevision(name: "Load", interfaces: [input], software: [software])
        sink.power = [PowerSpec(rail: "input", interfaceID: input.id, direction: .input, voltage: input.voltage,
            typicalPowerW: 2, peakPowerW: 5, sourceIDs: [evidence.id])]
        project.parts = [source, sink]
        let supplyItem = AssemblyItem(partRevisionID: source.id), loadItem = AssemblyItem(partRevisionID: sink.id)
        let edge = HardwareConnection(name: "Supply to load", from: ConnectionEndpoint(itemID: supplyItem.id, interfaceID: out.id),
            to: ConnectionEndpoint(itemID: loadItem.id, interfaceID: input.id), requiredProtocol: "dc", lanesRequired: 1)
        let assembly = AssemblyRevision(name: "Reference", items: [supplyItem, loadItem], connections: [edge])
        project.assemblies = [assembly]; project.selectedAssemblyID = assembly.id
        return project
    }
    static func report(_ project: HardwareProject) -> CompatibilityReport {
        CompatibilityEngine.evaluate(project, assembly: project.selectedAssembly!, at: now)
    }
    static func finding(_ project: HardwareProject, _ rule: String) -> CompatibilityFinding {
        report(project).findings.first { $0.ruleID.hasPrefix(rule) }!
    }
    static func adapterReference() -> HardwareProject {
        var project = reference()
        let evidence = project.sources[0].id
        project.parts[0].interfaces[0].voltage = NumericRange(minimum: 24, maximum: 24)
        project.parts[0].power[0].voltage = NumericRange(minimum: 24, maximum: 24)
        project.parts[0].power[0].capacityPowerW = 20
        project.parts[0].power[0].headroomFraction = 0
        var input = project.parts[1].interfaces[0]; input.id = UUID(); input.name = "24 V input"; input.voltage = NumericRange(minimum: 24, maximum: 24)
        var output = project.parts[0].interfaces[0]; output.id = UUID(); output.name = "5 V output"; output.voltage = NumericRange(minimum: 5, maximum: 5)
        let mapping = AdapterMapping(inputInterfaceID: input.id, outputInterfaceID: output.id, inputProtocol: "dc", outputProtocol: "dc",
            outputVoltage: output.voltage, capacityCurrentA: 3, efficiency: 0.8, sourceIDs: [evidence])
        let adapter = PartRevision(name: "Synthetic converter", interfaces: [input, output],
            power: [PowerSpec(rail: "own consumption", interfaceID: input.id, direction: .input, voltage: input.voltage, peakPowerW: 0, sourceIDs: [evidence]),
                    PowerSpec(rail: "output", interfaceID: output.id, direction: .output, voltage: output.voltage, capacityPowerW: 10, headroomFraction: 0, sourceIDs: [evidence])],
            adapters: [mapping], software: project.parts[0].software)
        project.parts.append(adapter)
        let item = AssemblyItem(partRevisionID: adapter.id)
        project.assemblies[0].items.append(item)
        let oldSink = project.assemblies[0].connections[0].to
        project.assemblies[0].connections[0].to = ConnectionEndpoint(itemID: item.id, interfaceID: input.id)
        project.assemblies[0].connections.append(HardwareConnection(name: "Converter to load", from: ConnectionEndpoint(itemID: item.id, interfaceID: output.id), to: oldSink, requiredProtocol: "dc", lanesRequired: 1))
        return project
    }
    static func main() throws {
        let good = reference()
        require(report(good).outcome == .compatible, "fully documented reference must pass: \(report(good).findings.filter { $0.outcome != .compatible }.map(\.explanation))")
        var project = good
        project.parts[0].interfaces[0].voltage = NumericRange(minimum: 4, maximum: 6)
        project.parts[1].interfaces[0].voltage = NumericRange(minimum: 4, maximum: 5)
        require(finding(project, "connection.voltage").outcome == .incompatible, "range overlap must not pass full voltage containment")
        require(finding(project, "connection.connector").outcome == .compatible, "voltage mismatch fixture retains matching shape")
        project = good; project.parts[1].interfaces[0].protocols = ["pcie"]
        require(finding(project, "connection.protocol").outcome == .incompatible, "connector fit cannot manufacture a missing bus")
        project = good; project.parts[1].power[0].peakPowerW = nil
        require(finding(project, "power.budget").outcome == .unknown, "typical demand must not substitute for peak")
        project = good
        var disconnected = project.parts[1].interfaces[0]; disconnected.id = UUID(); disconnected.name = "Unconnected power input"
        project.parts[1].interfaces.append(disconnected); project.parts[1].power[0].interfaceID = disconnected.id
        require(finding(project, "power.input_path").outcome == .unknown, "a data connection cannot satisfy a disconnected power rail")
        project = good; project.assemblies[0].connections[0].lanesRequired = Int.max; project.assemblies[0].items[1].quantity = 2
        require(finding(project, "resource.lanes.\(project.parts[0].interfaces[0].id)").outcome == .unknown, "overflowing imported lane demand must not trap or pass")
        project = good; project.assemblies[0].items[1].quantity = 3
        require(finding(project, "resource.ports.\(project.parts[0].interfaces[0].id)").outcome == .incompatible, "quantity must consume port capacity")
        require(finding(project, "power.budget").inputs["peakWatts"] == "15.0", "quantities aggregate peak power")
        project = good; project.sources[0].retrievedAt = now.addingTimeInterval(-366 * 86400)
        require(report(project).outcome == .unknown && report(project).evaluatedCount == 0, "stale evidence cannot pass")
        project = good; project.sources[0].confidence = .candidate
        require(report(project).outcome == .unknown, "chat candidate facts cannot pass")
        project = good; project.sources[0].confidence = .manufacturer
        require(report(project).outcome == .unknown, "manufacturer evidence needs a document location")
        project.sources[0].url = "https://example.invalid/synthetic-fixture"
        require(report(project).outcome == .compatible, "manufacturer document metadata supports non-field checks")
        project = good; project.parts[1].interfaces[0].sourceIDs = []
        require(finding(project, "connection.connector").outcome == .unknown, "one endpoint's source cannot verify the other endpoint")
        project = good; project.parts[1].interfaces[0].pinMapping["1"] = "ground"
        require(finding(project, "connection.pinmap").outcome == .incompatible, "wrong signal pins are rejected")
        project = good; project.parts[1].interfaces[0].dimensions?.heightMM = nil
        require(finding(project, "connection.mating_dimensions").outcome == .unknown, "missing mating dimension stays unknown")
        project = good; project.parts[1].software[0].conditions = "Requires firmware 2"
        require(report(project).outcome == .conditional, "conditions remain visible")
        project = good; project.parts[1].power[0].operatingConditions = "Only below 40 C ambient"
        require(finding(project, "power.budget").outcome == .conditional, "power assumptions must remain conditional")
        project = adapterReference()
        require(report(project).outcome == .compatible, "documented adapter chain passes: \(report(project).findings.filter { $0.outcome != .compatible }.map(\.explanation))")
        require(finding(project, "power.budget.\(project.parts[0].power[0].id)").inputs["peakWatts"] == "6.25", "adapter losses included upstream")
        project.parts[0].power[0].capacityPowerW = 6
        require(finding(project, "power.budget.\(project.parts[0].power[0].id)").outcome == .incompatible, "losses exceed upstream supply")
        project = adapterReference(); project.parts[1].interfaces[0].protocols = ["pcie"]
        require(report(project).findings.contains { $0.ruleID == "connection.protocol" && $0.outcome == .incompatible }, "voltage conversion must not erase protocol mismatch")
        project = adapterReference(); project.parts[2].adapters[0].efficiency = nil
        require(finding(project, "power.budget.\(project.parts[0].power[0].id)").outcome == .unknown, "unknown adapter efficiency prevents power pass")
        project = good
        var extraPort = project.parts[0].interfaces[0]; extraPort.id = UUID()
        project.parts[0].interfaces[0].resourceGroup = "shared"; project.parts[0].interfaces[0].capacity = 1; project.parts[0].interfaces[0].lanes = 1
        extraPort.resourceGroup = "shared"; extraPort.capacity = 1; extraPort.lanes = 1
        project.parts[0].interfaces.append(extraPort)
        var extraItem = project.assemblies[0].items[1]; extraItem.id = UUID(); project.assemblies[0].items.append(extraItem)
        project.assemblies[0].connections.append(HardwareConnection(name: "Second load", from: ConnectionEndpoint(itemID: project.assemblies[0].items[0].id, interfaceID: extraPort.id), to: ConnectionEndpoint(itemID: extraItem.id, interfaceID: project.parts[1].interfaces[0].id), requiredProtocol: "dc", lanesRequired: 1))
        require(finding(project, "resource.ports.group:shared").outcome == .incompatible, "separate ports must consume shared capacity")
        require(finding(project, "resource.lanes.group:shared").outcome == .incompatible, "separate ports must consume shared lanes")
        project = good; project.requirements = [Requirement(capability: "RF range", sourceIDs: [project.sources[0].id], satisfied: true)]
        project.sources[0].confidence = .manufacturer
        require(finding(project, "requirement.").outcome == .unknown, "RF requirement needs measured evidence")
        project = good
        let firstReport = report(project); project.findings = firstReport.findings
        project.overrides = [FindingOverride(findingID: firstReport.findings[0].id, reason: "Fixture annotation", author: "Test")]
        let offer = Offer(partRevisionID: project.parts[1].id, seller: "Fixture", unitPrice: 10)
        project.offers = [offer]; project.assemblies[0].items[1].offerID = offer.id
        let original = project
        let preview = try HardwareChangeImpact.preview(project, itemID: project.assemblies[0].items[1].id,
            replacementRevisionID: project.parts[1].id, quantity: 3, offerID: offer.id, interfaceMap: [:], at: now)
        require(project == original, "preview must not mutate project")
        require(preview.after.outcome == .incompatible, "preview reveals quantity oversubscription")
        require(preview.quantityDelta == 2 && preview.costDelta["USD"] == 20, "cost and quantity deltas")
        require(preview.affectedItemIDs.count == 2 && preview.affectedConnectionIDs.count == 1, "graph impact traverses dependencies")
        require(!preview.changedChecks.isEmpty, "preview lists changed checks")
        let accepted = try preview.accepting(current: project)
        require(accepted.assemblies[0] == project.assemblies[0] && accepted.assemblies.count == 2, "old assembly stays immutable")
        require(accepted.overrides == project.overrides && accepted.findings.starts(with: project.findings), "historical checks and overrides remain intact")
        require(tryRoundTrip(accepted), "JSON preserves all rule evidence and immutable revisions")
        var changed = project; changed.name = "Concurrent edit"
        do { _ = try preview.accepting(current: changed); require(false, "stale preview must reject") } catch HardwareError.conflict { }
        var invalid = accepted; invalid.assemblies[0].items[0].quantity = 9
        do { try ProjectFormat.validateRevisionHistory(invalid, previous: accepted); require(false, "immutable history must reject mutation") } catch { }
        var other = project.parts[1].revised(); other.interfaces[0].id = UUID(); other.power[0].interfaceID = other.interfaces[0].id
        project.parts.append(other)
        do {
            _ = try HardwareChangeImpact.preview(project, itemID: project.assemblies[0].items[1].id, replacementRevisionID: other.id, quantity: 1, offerID: nil, interfaceMap: [:], at: now)
            require(false, "unmapped interfaces must not silently drop edges")
        } catch { }
        other.interfaces[0].voltage = NumericRange(minimum: 3, maximum: 3)
        other.power[0].voltage = other.interfaces[0].voltage
        project.parts[project.parts.count - 1] = other
        let voltagePreview = try HardwareChangeImpact.preview(project, itemID: project.assemblies[0].items[1].id,
            replacementRevisionID: other.id, quantity: 1, offerID: nil,
            interfaceMap: [good.parts[1].interfaces[0].id: other.interfaces[0].id], at: now)
        require(voltagePreview.newAdapterNeeds.first?.transformations.contains("voltage regulation") == true, "new voltage conflict identifies required adapter function")
        require(CompatibilityExport.markdown(original, report: firstReport).contains("Machine result remains"), "report keeps overrides separate")
        var alternateCurrency = original
        let euro = Offer(partRevisionID: original.parts[1].id, seller: "EUR fixture", currency: "EUR", unitPrice: 12)
        alternateCurrency.offers.append(euro)
        let currencyPreview = try HardwareChangeImpact.preview(alternateCurrency, itemID: original.assemblies[0].items[1].id,
            replacementRevisionID: original.parts[1].id, quantity: 1, offerID: euro.id, interfaceMap: [:], at: now)
        require(currencyPreview.costDelta["USD"] == -10 && currencyPreview.costDelta["EUR"] == 12, "currency changes are separate, never implicitly converted")
        var measured = good
        let measuredItem = measured.assemblies[0].items[1]
        measured.requirements = [Requirement(capability: "RF range", threshold: "1 km", affectedItemIDs: [measuredItem.id], sourceIDs: [measured.sources[0].id], satisfied: true)]
        let measuredOriginal = measured
        var replacement = measured.parts[1].revised(); replacement.name = "Untested replacement"
        measured.parts.append(replacement)
        let measuredPreview = try HardwareChangeImpact.preview(measured, itemID: measuredItem.id,
            replacementRevisionID: replacement.id, quantity: 1, offerID: nil, interfaceMap: [:], at: now)
        let requirementRule = "requirement.\(measured.requirements[0].id)"
        require(measuredPreview.before.findings.first { $0.ruleID == requirementRule }?.outcome == .compatible, "original measured claim remains compatible")
        require(measuredPreview.after.findings.first { $0.ruleID == requirementRule }?.outcome == .unknown, "replacement cannot inherit the old hardware's measured claim")
        require(measuredPreview.changedChecks.contains { $0.after?.ruleID == requirementRule }, "requirement invalidation must appear in change impact")
        let measuredAccepted = try measuredPreview.accepting(current: measured)
        require(measuredAccepted.requirements[0].satisfied == nil && measuredAccepted.requirements[0].sourceIDs == measured.requirements[0].sourceIDs, "accepting resets the outcome but retains evidence references")
        require(measuredAccepted.assemblies[0] == measuredOriginal.assemblies[0] && measuredAccepted.sources == measuredOriginal.sources, "replacement preserves original assembly and measured source")
        require(measuredAccepted.findings.contains { $0.assemblyRevisionID == measuredOriginal.selectedAssemblyID && $0.ruleID == requirementRule && $0.outcome == .compatible }, "original measured assessment is saved with its assembly revision")
        let quantityPreview = try HardwareChangeImpact.preview(measured, itemID: measuredItem.id,
            replacementRevisionID: measuredItem.partRevisionID, quantity: 2, offerID: nil, interfaceMap: [:], at: now)
        require(quantityPreview.proposedProject.requirements[0].satisfied == nil, "quantity changes also invalidate measured assembly claims")
        let unchangedPreview = try HardwareChangeImpact.preview(measured, itemID: measuredItem.id,
            replacementRevisionID: measuredItem.partRevisionID, quantity: 1, offerID: nil, interfaceMap: [:], at: now)
        require(unchangedPreview.proposedProject.requirements[0].satisfied == true, "unchanged hardware retains its assessment")
        var editorProject = measured
        var editorAssembly = measured.selectedAssembly!.revised(); editorAssembly.items[1].partRevisionID = replacement.id
        HardwareChangeImpact.invalidateRequirements(in: &editorProject, replacing: measured.selectedAssembly!, with: editorAssembly)
        require(editorProject.requirements[0].satisfied == nil, "the general assembly editor uses the same invalidation boundary")
        let started = Date()
        for _ in 0..<200 { _ = report(good) }
        print(String(format: "PASS: compatibility, adapters, power, resources, evidence, change impact and revisions; 200 reference evaluations %.3f s", Date().timeIntervalSince(started)))
        var large = good; large.assemblies[0].items = []; large.assemblies[0].connections = []
        for _ in 0..<250 {
            let supply = AssemblyItem(partRevisionID: good.parts[0].id), load = AssemblyItem(partRevisionID: good.parts[1].id)
            large.assemblies[0].items += [supply, load]
            large.assemblies[0].connections.append(HardwareConnection(name: "Independent pair", from: ConnectionEndpoint(itemID: supply.id, interfaceID: good.parts[0].interfaces[0].id),
                to: ConnectionEndpoint(itemID: load.id, interfaceID: good.parts[1].interfaces[0].id), requiredProtocol: "dc", lanesRequired: 1))
        }
        let largeStarted = Date(), largeReport = report(large)
        require(largeReport.outcome == .compatible, "500-item assembly stays compatible")
        print(String(format: "PERF: 500 items / 250 connections / %d checks: %.3f s", largeReport.findings.count, Date().timeIntervalSince(largeStarted)))
    }
    static func tryRoundTrip(_ project: HardwareProject) -> Bool {
        (try? ProjectFormat.decode(ProjectFormat.encode(project))) == project
    }
}
