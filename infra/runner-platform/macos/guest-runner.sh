#!/usr/bin/env bash
# Run inside a dedicated ARM64 macOS guest, not on the personal host.
set -euo pipefail
usage() {
  printf '%s\n' 'Usage:
  guest-runner.sh --url URL --name NAME

Description:
  Run one ephemeral macOS ARM64 runner inside a dedicated, provisioned Lima VM.
  Read a short-lived registration token privately from stdin. Install test
  tools beforehand. The root-owned /etc/ci-runner-vm marker is required.

Options:
  --url URL       GitHub organization or repository URL.
  --name NAME     Distinct registration name.
  -h, --help      Show this help.

Examples:
  guest-runner.sh --url https://github.com/OWNER --name macos-vm-1

Environment:
  RUNNER_VERSION  Pinned runner version (default 2.338.0).
  RUNNER_ROOT     Guest runner directory (default ~/actions-runner).
  RUNNER_SHA256   Official SHA256 digest of the pinned release asset.
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
[[ -f /etc/ci-runner-vm && ! -L /etc/ci-runner-vm ]] \
  && [[ "$(cat /etc/ci-runner-vm)" == runner-platform-macos-v1 ]] \
  && [[ "$(stat -f '%u' /etc/ci-runner-vm)" == 0 ]] \
  && [[ "$(stat -f '%Lp' /etc/ci-runner-vm)" =~ ^(400|444|600|644)$ ]] || {
  printf '%s\n' 'Refusing installation outside a provisioned CI guest; the root-owned VM marker is missing or unsafe.' >&2
  exit 1
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
# Validate required input before creating files or downloading the runner.
: "${RUNNER_SHA256:?Set the SHA256 from the official release asset digest}"
[[ "$RUNNER_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || {
  printf '%s\n' 'RUNNER_SHA256 must be exactly 64 hexadecimal characters.' >&2; exit 2;
}
mkdir -p "$runner_root"
chmod 0700 "$runner_root"
cd "$runner_root"
asset="actions-runner-osx-arm64-${version}.tar.gz"
curl -fsSL "https://github.com/actions/runner/releases/download/v${version}/$asset" -o "$asset"
# The published checksum must be supplied independently from release metadata.
printf '%s  %s\n' "$RUNNER_SHA256" "$asset" | shasum -a 256 --check
tar -xzf "$asset"
printf '%s' 'Registration token: ' >&2
IFS= read -r -s token
printf '\n' >&2
[[ -n "$token" ]] || { printf '%s\n' 'Registration token is empty.' >&2; exit 2; }
export ACTIONS_RUNNER_INPUT_TOKEN="$token"
unset token
cleanup() {
  unset ACTIONS_RUNNER_INPUT_TOKEN
  rm -rf -- _work
  rm -f -- .runner .credentials .credentials_rsaparams
}
trap cleanup EXIT
./config.sh --unattended --url "$url" --name "$name" \
  --no-default-labels --labels macos-vm --work _work --ephemeral
unset ACTIONS_RUNNER_INPUT_TOKEN
./run.sh

