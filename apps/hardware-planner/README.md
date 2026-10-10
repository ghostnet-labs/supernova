# Hardware Planner

Native macOS 14+ project, part-revision and BOM workspace. Start with `hardware-planner --install`, then `hardware-planner --open`. No login service is installed. `reinstall-apps` discovers the app through its Info.plist.

For a step-by-step parts, BOM, compatibility, and coordinator-report walkthrough,
see [Your tooling guide](../../docs/tooling-guide.md).

Create a project, add source observations, add parts with their exact board revisions and documented interfaces/power rails, record optional price observations, then create an assembly. Select an exact part revision and quantity for each line; create connections using the actual item/interface endpoints. Inspect alternatives before saving a new assembly revision. The selected assembly drives the BOM and reports.

All ordinary editing uses native controls: specifications, pin mappings, dimensions, adapters, software/driver support, evidence URLs/documents, requirements, decisions, offers, quantities, connections, and alternatives. A blank numerical specification or price means unknown. Interface dimensions describe mating geometry; part dimensions describe the overall envelope. Explicit `none` keys and `genderless` mating types describe documented absence, while blank fields remain unknown.

The optional field-node worksheet contains candidate names and citations from the earlier board/BOM conversations. Electrical, mechanical and software ratings are deliberately blank. It preserves conflicting carrier preferences; no candidate is a verified purchase selection. No websites are fetched automatically.

## Local storage and reproducibility

The app uses a serialized SQLite store under `~/Library/Application Support/Hardware Planner`, overridden for isolated use by `HARDWARE_PLANNER_DATA_DIR`. Writes use immediate transactions, optimistic project versions, WAL and full synchronization. Schema migrations take a SQLite online backup first; future schema versions are rejected without migration. Manual backups are portable standalone SQLite files in `Backups/`.

Each save keeps a complete project history snapshot. Existing part revisions, assembly revisions, source observations, price observations, compatibility findings and overrides cannot be altered in place or removed by a later save. Revising a part or assembly creates a new ID and revision number; old assemblies continue to reference the original part/offer IDs. Requirements and decision edits remain recoverable in the project save history. Historical save lookup is available through `HardwareStore.load(_:version:)`; the current UI shows part/assembly history. Restoring an entire older project currently requires a separate data directory.

Imported source documents are copied to app-owned attachment paths using generated IDs; original filenames cannot select filesystem paths. Their bytes are also embedded in the authoritative JSON so database backups and project exports remain self-contained. Attachments are limited to 20 MB each and entire projects to 50 MB. The first release is intended for a project catalog, not an unbounded attachment archive.

## Export contract

- JSON: UTF-8 `ProjectEnvelope`, `format = "hardware-planner-project"`, `schemaVersion = 1`, and a complete `project`. UUIDs, exact Decimal money, dates, all revisions, evidence, findings, notes and attachment bytes round-trip without loss. Dates use Foundation Codable seconds since 2001-01-01 UTC. Files contain their schema version; unsupported future schemas are rejected. Import refuses to replace an existing project ID.
- CSV: purchasing view of the selected assembly, with revision IDs, quantities, selected dated offers, currencies and unknown values. Spreadsheet formula prefixes are escaped. CSV does not preserve the graph; use JSON for transfer and backup.
- Markdown: selected BOM, separate known subtotals per currency, count of unpriced lines, tax/shipping as known or unknown, requirements, compatibility findings and source observations.
- Stable navigation: `hardware-planner://project/UUID` opens an existing local project; it grants no write or execution authority. Export consumers must not open the live SQLite database.
- Coordinator report JSON: choose an assembly, then Export → Coordinator report JSON. The `hardware-planner-report` v1 snapshot contains only that assembly's parts and connections, project requirements, a fresh deterministic compatibility evaluation, coverage and cited source observations. It omits unselected parts, other assemblies and source-document bytes. Reports are limited to 2 MB. Agent Control Center's project Hardware tab attaches the selected report and lets the user choose one snapshot for the next coordinator message; importing alone does not enable it as context.

Report links include optional `assembly=UUID` and `source=UUID` query parameters. Opening a link selects that exact local assembly and opens its cited source observation without saving a new version. Missing revisions/sources produce an error rather than choosing newer content; transfer the lossless project JSON to the other Mac first. An attached report is a historical snapshot even when the linked Planner project has changed. Coordinator prose cannot modify Planner data; use Compatibility's deterministic change preview and explicitly accept a new assembly revision.

Totals only use selected offers whose minimum quantity is satisfied. Different currencies are never added, and unpriced lines never become zero. Tax and shipping stay separate with an explicit currency. A saved BOM does not establish compatibility.

## Build and verification

`hardware-planner --build /tmp/HardwarePlanner.app` builds an isolated bundle, checks its ad-hoc signature and runs `--check-build`, without installing or opening it. Install builds and validates before quitting the running app, keeps the previous bundle until the replacement has been launched, and rolls back on failure. Uninstall keeps all project data. `--status` checks signature and the source SHA-256 manifest.

Run `bash tests/dotfiles/test_hardware_planner.sh` for storage, immutable revisions, stale-writer rejection, lossless import/export, attachment containment, graph validation, backups, unknown/mixed-currency prices, help and UI typechecking. `bash tests/dotfiles/test_hardware_planner_installer.sh` verifies isolated install, signature, manifest, rollback and data-preserving uninstall.

`bash tests/dotfiles/test_hardware_reports.sh` checks report roundtrips, invalid versions and references, selected-data export, project isolation, explicit context selection, durable provenance, bounded reads, strict links and asynchronous native deep-link routing. The report consumer uses its own app-owned database and never reads Hardware Planner's live database.

The built executable accepts `--snapshot DIRECTORY` for seven app-owned fixture images (light/dark, empty, narrow BOM, alternatives, part editor and assembly editor). This mode creates no database, uses no real projects, and captures only its own views. It is for visual QA, not a second management CLI. When the system cannot capture the fixture window, a `-partial.png` fallback is explicitly reported; native layer-backed controls still need interactive visual verification.

The implemented **Compatibility** workspace evaluates the selected assembly,
saves immutable checks, and previews replacements through **Preview change…**.
**Accept new revision** saves a reviewed replacement while preserving the original
assembly. See [Compatibility and changes](COMPATIBILITY.md) for evidence,
coverage, power, adapter, and change-impact rules.
