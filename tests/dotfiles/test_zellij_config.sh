#!/usr/bin/env bash
# setup-test: Zellij config
# Verify the intentionally minimal Zellij configuration and helper behavior.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$REPO_DIR/dotfiles/zellij/config.kdl"
LAYOUT="$REPO_DIR/dotfiles/zellij/layouts/default.kdl"
CLOSE_TAB_HELPER="$REPO_DIR/dotfiles/.bin/zellij-close-tab"
OLD_TAB_PICKER="$REPO_DIR/dotfiles/.bin/zellij-tab-picker"
TAB_PICKER_DIR="$REPO_DIR/apps/zellij-tab-picker"
TAB_PICKER_MANIFEST="$TAB_PICKER_DIR/Cargo.toml"
TAB_PICKER_SOURCE="$TAB_PICKER_DIR/src/main.rs"
TAB_PICKER_LOGIC="$TAB_PICKER_DIR/src/logic.rs"
TAB_PICKER_WASM="$REPO_DIR/dotfiles/zellij/plugins/tab-picker.wasm"
ZJ_RADAR_WASM="$REPO_DIR/dotfiles/zellij/plugins/zj_radar.wasm"
ZJ_RADAR_PATCH="$REPO_DIR/apps/zj-radar/keyboard-navigation.patch"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-zellij-test.XXXXXX")"
TRAP_BIN="$TMP_ROOT/bin"
CALL_LOG="$TMP_ROOT/zellij-calls"
mkdir -p "$TRAP_BIN"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

[[ "$(grep -Fxc 'pane_frame_style "full"' "$CONFIG")" -eq 1 ]] ||
  fail_test "classic pane frame style is not configured exactly once"
[[ "$(grep -Fxc 'mouse_hover_tips false' "$CONFIG")" -eq 1 ]] ||
  fail_test "mouse hover help text is not disabled exactly once"
[[ "$(grep -Fxc 'stacked_pane_list false' "$CONFIG")" -eq 1 ]] ||
  fail_test "classic stacked pane list is not configured exactly once"
[[ "$(grep -Fxc 'stacked_resize false' "$CONFIG")" -eq 1 ]] ||
  fail_test "automatic stack changes while resizing are not disabled exactly once"
[[ "$(grep -Fxc 'theme "tokyo-night-dark-blue"' "$CONFIG")" -eq 1 ]] ||
  fail_test "custom Tokyo Night Dark theme is not configured exactly once"
[[ "$(grep -Fxc '        frame_selected { base 158 206 106; background 0; emphasis_0 255 158 100; emphasis_1 42 195 222; emphasis_2 187 154 247; emphasis_3 0; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "normal active pane frame is not Tokyo Night green"
[[ "$(grep -Fxc '        frame_highlight { base 122 162 247; background 0; emphasis_0 187 154 247; emphasis_1 255 158 100; emphasis_2 255 158 100; emphasis_3 255 158 100; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "mode-highlighted pane frame is not Tokyo Night medium blue"
[[ "$(grep -Fxc '        bind "Ctrl a" { SwitchToMode "Tmux"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "Ctrl+A does not enter tmux mode exactly once"
[[ "$(grep -Fxc '        bind "Ctrl a" { Write 1; SwitchToMode "Normal"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "Ctrl+A Ctrl+A does not send a literal Ctrl+A exactly once"
[[ "$(grep -Fxc '        unbind "Ctrl b"' "$CONFIG")" -eq 2 ]] ||
  fail_test "Ctrl+B is not removed from the prefix bindings"
[[ "$(grep -Fxc '        bind "|" { NewPane "Right"; SwitchToMode "Normal"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tmux-style split-right binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "-" { NewPane "Down"; SwitchToMode "Normal"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tmux-style split-down binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "<" { GoToPreviousTab; SwitchToMode "Normal"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tmux-style previous-tab binding is not configured exactly once"
[[ "$(grep -Fxc '        bind ">" { GoToNextTab; SwitchToMode "Normal"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tmux-style next-tab binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "r" { SwitchToMode "RenameTab"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tmux-style rename-tab binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "p" { SwitchToMode "RenamePane"; PaneNameInput 0; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tmux-style rename-pane binding is not configured exactly once"
[[ "$(grep -Fxc '            LaunchOrFocusPlugin "session-manager" { floating true; move_to_focused_tab true; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tmux-style session-manager binding is not configured exactly once"
[[ "$(grep -Fxc '            LaunchOrFocusPlugin "file:~/.config/zellij/plugins/tab-picker.wasm" { floating true; move_to_focused_tab true; skip_plugin_cache true; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "native-styled tab-picker binding is not configured exactly once"
[[ "$(grep -Fxc '            Run "tmux-git-popup" { floating true; close_on_exit true; width "90%"; height "80%"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "floating Git-status binding is not configured exactly once"
[[ "$(grep -Fxc '            Run "bash" "-lc" "exec codex-sessions --tui" { direction "Right"; close_on_exit true; name "Codex Messages"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "tiled Codex transcript binding is not configured exactly once"
[[ "$(grep -Fxc '            Run "zellij-close-tab" { floating true; close_on_exit true; width 44; height 5; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "confirmed close-tab binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "Ctrl Shift Left" { MoveTab "Left"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "move-tab-left binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "Ctrl Shift Right" { MoveTab "Right"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "move-tab-right binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "Alt Left" { MoveFocus "Left"; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "Alt+Left pane-or-radar binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "Alt Right" { MoveFocus "Right"; MessagePlugin "radar" { name "zj_radar.nav.v1"; payload "exit"; }; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "Alt+Right radar-or-pane binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "Alt Up" { MessagePlugin "radar" { name "zj_radar.nav.v1"; payload "previous"; }; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "Alt+Up pane-or-previous-tab binding is not configured exactly once"
[[ "$(grep -Fxc '        bind "Alt Down" { MessagePlugin "radar" { name "zj_radar.nav.v1"; payload "next"; }; }' "$CONFIG")" -eq 1 ]] ||
  fail_test "Alt+Down pane-or-next-tab binding is not configured exactly once"
[[ "$(grep -Ev '^[[:space:]]*(//|$)' "$CONFIG" | wc -l | tr -d ' ')" -eq 75 ]] ||
  fail_test "Zellij config contains settings beyond the intended overrides"
[[ "$(grep -Fxc '    radar location="file:~/.config/zellij/plugins/zj_radar.wasm" {' "$CONFIG")" -eq 1 ]] ||
  fail_test "zj-radar plugin alias is not configured exactly once"
[[ "$(grep -Fxc '        density "compact"' "$CONFIG")" -eq 1 ]] ||
  fail_test "zj-radar compact topology density is not configured exactly once"
[[ "$(grep -Fxc '        keyboard_navigation true' "$CONFIG")" -eq 1 ]] ||
  fail_test "zj-radar keyboard navigation is not enabled exactly once"
[[ "$(grep -Fxc '        pane_titles false' "$CONFIG")" -eq 1 ]] ||
  fail_test "zj-radar does not default to stock Codex pane titles exactly once"

[[ -f "$LAYOUT" ]] || fail_test "zj-radar default layout is missing"
[[ "$(grep -Fxc '                plugin location="radar"' "$LAYOUT")" -eq 3 ]] ||
  fail_test "zj-radar sidebar is not present in all three tab templates"
[[ "$(grep -Fxc '            pane size=34 name="Radar" {' "$LAYOUT")" -eq 3 ]] ||
  fail_test "zj-radar sidebar does not use the named full frame in all three tab templates"
! grep -Fq 'borderless=true' "$LAYOUT" || fail_test "zj-radar sidebar frame is disabled"
! grep -Fq 'plugin location="zellij:status-bar"' "$LAYOUT" ||
  fail_test "built-in status bars still consume rows in the default layout"
grep -Fq '    swap_tiled_layout name="stacked" {' "$LAYOUT" || fail_test "stacked swap layout is missing"
grep -Fq '                pane stacked=true { children; }' "$LAYOUT" || fail_test "stacked swap layout no longer stacks panes"

[[ -f "$ZJ_RADAR_WASM" ]] || fail_test "zj-radar WebAssembly plugin is missing"
[[ "$(od -An -tx1 -N4 "$ZJ_RADAR_WASM" | tr -d '[:space:]')" == "0061736d" ]] ||
  fail_test "zj-radar artifact is not WebAssembly"
grep -aFq '_start' "$ZJ_RADAR_WASM" || fail_test "zj-radar artifact is missing its WASI entry point"
grep -aFq 'zj_radar.nav.v1' "$ZJ_RADAR_WASM" || fail_test "zj-radar artifact is missing keyboard navigation"
grep -aFq 'zj_radar.pane_titles.v1' "$ZJ_RADAR_WASM" || fail_test "zj-radar artifact is missing composite Codex pane titles"
[[ "$(wc -c <"$ZJ_RADAR_WASM")" -lt 1572864 ]] || fail_test "zj-radar artifact exceeds 1.5 MiB"
[[ -f "$ZJ_RADAR_PATCH" ]] || fail_test "zj-radar keyboard-navigation source patch is missing"
grep -Fq 'Subject: [setup] add focus-aware radar navigation, pane roster' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar keyboard-navigation patch has no provenance header"
grep -Fq 'const NAV_PIPE: &str = "zj_radar.nav.v1";' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar keyboard-navigation patch does not match the configured pipe"
grep -Fq 'static PANE_TITLES_MARKER: [u8; 23] = *b"zj_radar.pane_titles.v1";' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch has no composite pane-title provenance marker"
grep -Fq 'pane_titles: false,' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not default to stock Codex pane titles"
grep -Fq 'const FAST_FRAMES_PER_DOMAIN_TICK: u8 = 10;' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not preserve one-second domain timing at 10 FPS"
grep -Fq 'Cadence::Fast => 0.1,' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not schedule smooth 10 FPS animation"
grep -Fq 'fn spinner_keeps_the_full_cycle_for_long_runners()' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not keep long-running glyphs on the full cycle"
grep -Fq 'fn closing_the_last_terminal_closes_its_radar_only_tab()' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not verify radar-only tab retirement"
grep -Fq 'Effect::RenamePane { pane_id, name } => rename_terminal_pane(pane_id, &name)' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not apply composite titles to terminal panes"
grep -Fq 'zellij-tile = "=0.45.0"' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not pin the installed Zellij 0.45 API"
grep -Fq 'Every live terminal pane earns a line in the rail' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not preserve the full terminal-pane roster"
grep -Fq 'fn canonical_roster_matches_session_manager_membership_and_order()' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not pin native session-manager ordering"
grep -Fq 'session_navigation_needs_roster()' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not query the canonical roster on session navigation"
if grep -Fq 'roster_poller' "$ZJ_RADAR_PATCH"; then
  fail_test "zj-radar source patch still contains an idle canonical-roster poller"
fi
if grep -Fq 'EventType::SessionUpdate' "$ZJ_RADAR_PATCH"; then
  fail_test "zj-radar source patch still subscribes sibling tabs to canonical session updates"
fi
grep -Fq 'label.push_str(" (EXITED)");' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not render resurrectable sessions"
grep -Fq 'fn header_is_title_only_regardless_of_tab_attention()' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not keep the Radar heading title-only"
grep -Fq 'fn ledger_entries_click_exact_pane_then_fall_back_to_tab_or_inert()' "$ZJ_RADAR_PATCH" ||
  fail_test "zj-radar source patch does not preserve exact-pane ledger navigation"
source "$REPO_DIR/setup/dependencies.sh"
[[ "$(setup_file_sha256 "$ZJ_RADAR_WASM")" == "$SETUP_ZJ_RADAR_WASM_SHA256" ]] ||
  fail_test "zj-radar WebAssembly checksum does not match the pinned release"

[[ -x "$CLOSE_TAB_HELPER" ]] || fail_test "close-tab confirmation helper is not executable"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"$ZELLIJ_TEST_CALL_LOG"\n' >"$TRAP_BIN/zellij"
chmod +x "$TRAP_BIN/zellij"

cancel_output="$(printf '\n' | env PATH="$TRAP_BIN:/usr/bin:/bin" ZELLIJ_TEST_CALL_LOG="$CALL_LOG" "$CLOSE_TAB_HELPER")"
[[ "$cancel_output" == "Close current tab? [y/N] " ]] || fail_test "close-tab cancellation prompt changed"
[[ ! -e "$CALL_LOG" ]] || fail_test "close-tab cancellation invoked Zellij"

confirm_output="$(printf 'y\n' | env PATH="$TRAP_BIN:/usr/bin:/bin" ZELLIJ_TEST_CALL_LOG="$CALL_LOG" "$CLOSE_TAB_HELPER")"
[[ "$confirm_output" == "Close current tab? [y/N] " ]] || fail_test "close-tab confirmation prompt changed"
[[ "$(<"$CALL_LOG")" == "action close-tab" ]] || fail_test "close-tab confirmation invoked the wrong Zellij action"

[[ ! -e "$OLD_TAB_PICKER" ]] || fail_test "old fzf tab-picker helper still exists"
[[ -f "$TAB_PICKER_MANIFEST" ]] || fail_test "native tab-picker Cargo manifest is missing"
[[ -f "$TAB_PICKER_SOURCE" ]] || fail_test "native tab-picker source is missing"
[[ -f "$TAB_PICKER_LOGIC" ]] || fail_test "native tab-picker logic is missing"
[[ -f "$TAB_PICKER_WASM" ]] || fail_test "compiled native tab-picker plugin is missing"
[[ "$(od -An -tx1 -N4 "$TAB_PICKER_WASM" | tr -d '[:space:]')" == "0061736d" ]] ||
  fail_test "native tab-picker artifact is not WebAssembly"
grep -aFq '_start' "$TAB_PICKER_WASM" || fail_test "native tab-picker artifact is missing its WASI entry point"
[[ "$(wc -c <"$TAB_PICKER_WASM")" -lt 1572864 ]] || fail_test "native tab-picker artifact exceeds 1.5 MiB"
grep -Fxq 'zellij-tile = "=0.45.0"' "$TAB_PICKER_MANIFEST" || fail_test "tab picker does not pin the Zellij 0.45 API"
grep -Fxq 'unicode-width = "=0.2.2"' "$TAB_PICKER_MANIFEST" || fail_test "tab picker does not use terminal-aware responsive widths"
grep -Fq 'print_table_with_coordinates(' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not use Zellij's native table renderer"
grep -Fq 'let content_width = cols.min(90);' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not match the session manager's centered 90-column layout"
grep -Fq '"Help: {arrows} - {}, {enter} - {}, {tab} - {}"' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not use session-manager-style help text"
grep -Fq 'format!("{arrows}/{enter}/{tab}")' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not compact its help like the session manager"
grep -Fq 'EventType::TabUpdate' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not subscribe to native tab updates"
grep -Fq 'EventType::ModeUpdate' "$TAB_PICKER_SOURCE" || fail_test "tab picker cannot render the session manager's themed prompt cursor"
grep -Fq 'selected: Option<usize>' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not match the session manager's initially unselected cursor"
grep -Fq 'format!("\u{1b}[1m{}_\u{1b}[22m", self.query)' "$TAB_PICKER_SOURCE" || fail_test "tab picker input cursor is not bold like the session manager"
grep -Fq 'let tab_header_full = "<TAB> Complete";' "$TAB_PICKER_SOURCE" || fail_test "tab picker is missing the session manager's completion column"
grep -Fq '.filter(|tab| !tab.active)' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not treat the current tab like the session manager treats the current session"
grep -Fq 'viewport_range(self.rows.len(), data_rows, self.selected)' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not use the session manager's selected-row viewport"
grep -Fq 'compute_reduction_tier(' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not responsively abbreviate its table"
grep -Fq 'EventType::PermissionRequestResult' "$TAB_PICKER_SOURCE" || fail_test "tab picker does not wait for title-renaming permission"
[[ "$(grep -Fc 'rename_plugin_pane(get_plugin_ids().plugin_id, "Tab Manager");' "$TAB_PICKER_SOURCE")" -eq 2 ]] || fail_test "tab picker does not set and confirm its native pane title"
! grep -Fq 'No matching tabs' "$TAB_PICKER_SOURCE" || fail_test "tab picker adds an empty-state message absent from the session manager"
! grep -Fq '<CURRENT>' "$TAB_PICKER_SOURCE" || fail_test "tab picker adds a current-row marker absent from the session manager"
! grep -Fq 'show_cursor(' "$TAB_PICKER_SOURCE" || fail_test "tab picker uses an unsafe render-time cursor host command"
grep -Fq 'subsequence_indices' "$TAB_PICKER_LOGIC" || fail_test "tab picker fuzzy filtering is missing"
grep -Fq 'pub fn compute_reduction_tier(' "$TAB_PICKER_LOGIC" || fail_test "tab picker responsive-width logic is missing"
grep -Fq 'pub fn viewport_range(' "$TAB_PICKER_LOGIC" || fail_test "tab picker viewport logic is missing"
! rg -q '(^|[^[:alnum:]_-])fzf([^[:alnum:]_-]|$)' "$TAB_PICKER_DIR" || fail_test "native tab picker still depends on fzf"

if command -v zellij >/dev/null 2>&1; then
  check_output="$(zellij --config "$CONFIG" --config-dir "$REPO_DIR/dotfiles/zellij" setup --check 2>&1)" || {
    printf '%s\n' "$check_output" >&2
    fail_test "Zellij rejected the config"
  }
fi

printf '[PASS] Zellij configuration checks\n'
