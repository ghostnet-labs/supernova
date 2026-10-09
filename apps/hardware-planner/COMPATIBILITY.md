# Compatibility and changes

The Compatibility workspace checks the selected immutable assembly revision. Each result names its rule version, inputs, source records, affected items and connection, and check time. Save Check appends a run to the project; exporting a report does not change the project. Saved Checks opens earlier runs and their original overrides; Recheck assesses current evidence freshness. Compatible means every evaluated rule has evidence and passes. Coverage reports how many checks have enough inputs and evidence. It is not a certification of the assembly.

Evidence must be recorded as manufacturer or measured, have a URL or managed attachment (measured evidence may instead contain measurement notes), and be at most 365 days old by default. The engine uses these explicit source records; it does not independently authenticate source content. Candidate records from chats, absent references, future dates beyond five minutes, and stale references produce Unknown. Each endpoint needs its own evidence. A fresh source for one endpoint cannot verify the other. Source freshness and mating tolerance are recorded in every finding's inputs.

## Electrical and physical rules

- A connection is directed from its source to its receiver. Output/bidirectional to input/bidirectional is allowed; unknown direction remains Unknown.
- Connector and key labels are compared after case and whitespace normalization, without inferring specifications from a connector name. Record `none` for a documented unkeyed interface. Supported gender pairs are male/female, plug/receptacle, and genderless/genderless.
- Interface dimensions mean mating dimensions, not the part envelope. All three dimensions must exist and agree within 0.1 mm. Clearance, manufacturing tolerance, enclosure fit and cable strain remain outside this comparison.
- The entire source voltage range must fall inside the receiver's range. Mere interval overlap is insufficient. Each linked power rail must also agree with its interface voltage record.
- Both endpoints must explicitly offer the connection's required protocol. A matching connector cannot imply a bus. All recorded pin numbers and signal/net labels must match at each physical edge. Describe crossovers through an explicit adapter and its distinct interfaces.
- Port capacity and lane capacity are checked independently. Recipient quantity consumes source resources. Ports sharing a `resourceGroup` share the same documented capacity and lane budget; unequal or missing declarations produce Unknown instead of inventing a budget. Imported arithmetic overflow produces Unknown rather than wrapping or crashing.
- Software support needs an explicit supported/unsupported record and evidence. Record an evidenced `No driver required` entry when appropriate. Nonempty software or adapter conditions produce Conditional.

## Power and adapters

Each input rail requires one explicit incoming supply path on its linked interface. An unrelated data connection does not establish power. Multiple supplies into the same input and multiple source instances require separate item rows and documented distribution; they are not assumed to share a load.

Peak demand uses the larger of explicit peak watts and maximum voltage times peak current. Typical current/power are never substituted. Supply capacity uses the smaller of explicit capacity watts and minimum voltage times capacity current. Headroom is required explicitly, including zero when deliberately chosen. Required capacity is peak load multiplied by `1 + headroomFraction`. Quantities are included; currencies are never combined.

Adapters are ordinary parts with distinct input/output interfaces and a documented transformation. Every external edge is checked independently. A voltage converter does not cure a protocol or pinout mismatch. Its input demand is its own peak consumption plus downstream demand divided by efficiency. Record zero own consumption explicitly only when supported. Adapter output current limits, each output rail, and shared rails are checked. Output rails with the same rail name share the same capacity/headroom declaration; unequal declarations remain Unknown. Cycles, missing efficiency and ambiguous distribution across multiple adapter instances stay Unknown. This is a conservative steady-state peak budget, not an electrical transient simulator.

RF, thermal, battery endurance, runtime and field requirements require measured evidence. These checks evaluate explicitly recorded requirement results; the app does not simulate these properties.

## Change preview and overrides

Preview Change selects an assembly item, replacement revision, quantity and offer. Each used old interface must map to a replacement interface. No edge is silently dropped. Impact follows both directions of the connected graph, includes scoped dependent requirements and conservatively includes unscoped requirements, compares checks, identifies new connector/voltage/protocol/pin-routing adapter needs, and shows affected adapter parts and known cost/quantity deltas. Unknown prices remain explicit, and cost changes are separate by currency. Tax and shipping remain unchanged by a part replacement.

Part, quantity, or connection changes reset affected requirement outcomes to Unknown, including measured RF and thermal claims. The prior assessment stays attached to the original assembly in saved findings, and its source observations remain intact. The general assembly editor applies the same rule. Price-only changes keep the hardware assessment valid; new hardware requires a new explicit assessment.

Accept New Revision is the only save action in the preview. Acceptance checks that the project still equals the previewed snapshot, then appends the new assembly and findings. Previous parts, assemblies, sources, offers, checks and overrides remain intact. Cancel or closing the preview makes no change. Manual overrides capture author, reason and date beside the original machine finding; they never alter outcome or coverage.

## Validation

Run `bash tests/dotfiles/test_hardware_compatibility.sh` on macOS with Swift. Fixtures cover fully documented synthetic reference parts, partial voltage overlap, missing protocol despite matching shape, wrong pins, missing peak power, missing supply paths, adapter losses and partial transformations, shared resource oversubscription, stale/candidate evidence, overflow, measurement requirements, change conflicts, explicit port mappings, currency totals, JSON round trips and immutable revision history. The suite also typechecks the native compatibility and change-preview views. Synthetic fixture data must never be used as real product specifications.
