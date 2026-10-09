#!/usr/bin/env bash
# setup-test: Shared Octicons
# An unknown Octicon name silently draws a dot, so check every name the apps use.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
dir="$root/apps/lib/octicons"

# Octicons.swift must embed exactly the vendored SVGs; otherwise rerun generate-octicons.py.
embedded="$(sed -n 's/^        "\([a-z0-9-]*\)": "JVBER.*/\1/p' "$dir/Octicons.swift" | LC_ALL=C sort)"
vendored="$(for svg in "$dir"/*-16.svg; do svg="${svg##*/}"; printf '%s\n' "${svg%-16.svg}"; done | LC_ALL=C sort)"
[[ -n "$embedded" ]] || fail_test "Octicons.swift embeds no icons"
differ="$(comm -3 <(printf '%s\n' "$embedded") <(printf '%s\n' "$vendored") | tr -d '\t' | paste -sd ' ' -)"
[[ -z "$differ" ]] || fail_test "Octicons.swift and the vendored SVGs differ on: $differ; rerun generate-octicons.py"
for file in LICENSE REVISION README.md generate-octicons.py; do
  [[ -f "$dir/$file" ]] || fail_test "apps/lib/octicons/$file is missing"
done

for source in "$root"/apps/*/*.swift "$root"/apps/lib/agents/*.swift "$root"/apps/lib/worktrees/*.swift; do
  names="$(grep -o 'Octicons\.[A-Za-z]*("[^"]*")' "$source" | sed 's/.*("\(.*\)")/\1/' | sort -u)" || continue
  app="$(basename -- "$(dirname -- "$source")")"
  for name in $names; do
    [[ -f "$dir/$name-16.svg" ]] || fail_test "$app uses Octicon '$name', which is not vendored"
  done
done

# Shared views also use icons, so discover consumers from the installers rather than view files.
apps=0
for app_dir in "$root"/apps/*/; do
  app="${app_dir%/}"
  app="${app##*/}"
  installer_path="$root/dotfiles/.bin/$app-app"
  [[ -f "$installer_path" ]] || installer_path="$root/dotfiles/.bin/$app"
  [[ -f "$installer_path" ]] || continue
  installer="$(<"$installer_path")"
  [[ "$installer" == *'"$source_dir/../lib/octicons/Octicons.swift"'* ]] || continue
  apps=$((apps + 1))
  assert_contains "$installer" '"$source_dir/../lib/octicons/Octicons.swift"'
  assert_contains "$installer" '"$source_dir/../lib/octicons/LICENSE" "$bundle/Contents/Resources/Octicons-LICENSE"'
done
[[ "$apps" -ge 3 ]] || fail_test "expected at least 3 apps to use Octicons, found $apps"

printf 'PASS: Shared Octicons\n'
