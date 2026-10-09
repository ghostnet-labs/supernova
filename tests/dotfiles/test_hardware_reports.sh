#!/usr/bin/env bash
# setup-test: Hardware report attachments and project links
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: native hardware report fixtures require macOS and Swift\n'
  exit 0
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/hardware-reports.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$scratch/clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$scratch/swift-cache}"
hardware="$root/apps/hardware-planner"
agent="$root/apps/agent-control-center"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$root/apps/lib/HardwareReport.swift" "$agent/AgentDatabase.swift" "$agent/HardwareReportStore.swift" \
  "$agent/HardwareReportView.swift" "$hardware/Models.swift" "$hardware/ProjectFormat.swift" \
  "$hardware/CompatibilityEngine.swift" "$hardware/ReportExport.swift" "$hardware/HardwareStore.swift" \
  "$hardware/PlannerModel.swift" "$root/tests/dotfiles/fixtures/hardware_reports.swift" -lsqlite3 -o "$scratch/check-hardware-reports"
"$scratch/check-hardware-reports" "$scratch/data"
