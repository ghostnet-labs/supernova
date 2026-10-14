#!/usr/bin/env bash
# Run inside a dedicated ARM64 macOS guest, not on the personal host.
set -euo pipefail
usage() {
  printf '%s\n' 'Usage:
  guest-runner.sh --url URL --name NAME

Description:
  Install one macOS ARM64 runner inside a dedicated VM. Read a short-lived
  registration token privately from stdin. Install test tools beforehand.

Options:
  --url URL       GitHub organization or repository URL.
  --name NAME     Distinct registration name.
  -h, --help      Show this help.

Examples:
  guest-runner.sh --url https://github.com/OWNER --name macos-vm-1

Environment:
  RUNNER_VERSION  Pinned runner version (default 2.338.0).
  RUNNER_ROOT     Guest runner directory (default ~/actions-runner).
'
}
url= name=
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --url) url="${2:?}"; shift 2 ;;
    --name) name="${2:?}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf '%s\n' 'This installer requires an ARM64 macOS guest.' >&2; exit 1;
}
[[ "$url" =~ ^https://github.com/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ && -n "$name" ]] || {
  usage >&2; exit 2;
}
runner_root="${RUNNER_ROOT:-$HOME/actions-runner}"
[[ ! -e "$runner_root/.runner" ]] || {
  printf '%s\n' 'An existing registration is present; refusing to overwrite it.' >&2; exit 1;
}
version="${RUNNER_VERSION:-2.338.0}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
mkdir -p "$runner_root"
chmod 0700 "$runner_root"
cd "$runner_root"
asset="actions-runner-osx-arm64-${version}.tar.gz"
curl -fsSL "https://github.com/actions/runner/releases/download/v${version}/$asset" -o "$asset"
# The published checksum must be supplied independently from release metadata.
: "${RUNNER_SHA256:?Set the SHA256 from the official release asset digest}"
printf '%s  %s\n' "$RUNNER_SHA256" "$asset" | shasum -a 256 --check
tar -xzf "$asset"
printf '%s' 'Registration token: ' >&2
IFS= read -r -s token
printf '\n' >&2
./config.sh --unattended --url "$url" --token "$token" --name "$name" \
  --labels macos-vm --work _work
unset token
./svc.sh install
./svc.sh start

