#!/usr/bin/env bash
# Parameters supplied by the checked-in platform configuration.
set -euo pipefail
: "${K3S_VERSION:?}"
: "${K3S_CONFIG_JSON:?}"
: "${K3S_UNIT:?}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
url="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}"
curl --fail --location --retry 3 "$url/k3s-arm64" -o "$work/k3s-arm64"
curl --fail --location --retry 3 "$url/sha256sum-arm64.txt" -o "$work/sha256sum-arm64.txt"
(cd "$work" && sha256sum --ignore-missing --check sha256sum-arm64.txt)
install -m 0755 "$work/k3s-arm64" /usr/local/bin/k3s
install -d -m 0700 /etc/rancher/k3s
printf '%s\n' "$K3S_CONFIG_JSON" >/etc/rancher/k3s/config.yaml
chmod 0600 /etc/rancher/k3s/config.yaml
printf '%s\n' "$K3S_UNIT" >/etc/systemd/system/k3s.service
systemctl daemon-reload
systemctl enable --now k3s

