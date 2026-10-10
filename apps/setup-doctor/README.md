# Setup Doctor

Setup Doctor is a native macOS dashboard over this repository's existing setup health and repair system. It does not replace `setup.sh`; it visualizes the same read-only checks and hands repairs back to the guarded interactive CLI.

## Killer features

- **Drift radar:** remembers the previous problem set and labels newly broken and recovered findings.
- **Health dashboard:** failure, warning, new-drift, and recovered counts at a glance.
- **Severity filtering:** quickly isolate failures or warnings without rereading the full shell report.
- **Repair preview:** shows the exact output of `./setup.sh --fix --dry-run` in a native sheet.
- **Safe fix handoff:** opens `./setup.sh --fix` in Ghostty so typed confirmation, sudo handling, repair locks, and final rechecks remain owned by the CLI.
- **Copyable report:** copy the complete plain-text health scan for an issue or agent session.

## Architecture

The app runs `./setup.sh --check` with `NO_COLOR=1 TERM=dumb` and parses only the stable semantic markers used by setup:

- `✓` pass
- `!` warning
- `✗` failure
- `•` information
- `──` section

It finds `setup.sh` through `SETUP_DOCTOR_SETUP_SH`, then `SETUP_DIR`, then the default checkout. To compute drift between scans it saves only the finding IDs (and a baseline format version) in `UserDefaults`.

## Install

```sh
setup-doctor --install
```

Use `setup-doctor --open`, `--status`, or `--uninstall` afterward.

## Safety

Setup Doctor never performs repair steps directly. Preview is read-only, and the Fix button launches the repository's normal interactive `./setup.sh --fix` flow in Ghostty.
