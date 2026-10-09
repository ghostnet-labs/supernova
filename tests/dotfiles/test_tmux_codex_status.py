#!/usr/bin/env python3
# setup-test: tmux Codex status
"""Tests for the tmux Codex status rollout parser."""

from __future__ import annotations

import json
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[2] / "dotfiles" / ".bin" / "tmux-codex-status"
TMUX_CONFIG = Path(__file__).parents[2] / "dotfiles" / ".tmux.conf"
SCRIPT_GLOBALS = runpy.run_path(str(SCRIPT))
LATEST_LIFECYCLE = SCRIPT_GLOBALS["latest_lifecycle"]
PANE_WAITS_FOR_APPROVAL = SCRIPT_GLOBALS["pane_waits_for_approval"]
WATCH = SCRIPT_GLOBALS["watch"]
CLEAR_UPDATER_REGISTRATION = SCRIPT_GLOBALS["clear_updater_registration"]
APPLY_NATIVE_ELAPSED = SCRIPT_GLOBALS["apply_native_elapsed"]
NATIVE_PANE = SCRIPT_GLOBALS["NativePane"]
NATIVE_STATE_CLASS = SCRIPT_GLOBALS["native_state_class"]
ROOT_ROLLOUT = SCRIPT_GLOBALS["root_rollout"]


def record(timestamp: str, record_type: str, payload: dict[str, object]) -> str:
    return json.dumps(
        {"timestamp": timestamp, "type": record_type, "payload": payload},
        separators=(",", ":"),
    )


class TmuxConfigTests(unittest.TestCase):
    def test_visible_panes_allow_terminal_passthrough(self) -> None:
        config = TMUX_CONFIG.read_text(encoding="utf-8")
        self.assertIn("set -wg allow-passthrough on", config)


class NativeElapsedTests(unittest.TestCase):
    socket_path = Path("/tmp/tmux-test.sock")

    def test_native_titles_map_to_stable_state_classes(self) -> None:
        self.assertEqual(NATIVE_STATE_CLASS("codex", "⠋ setup"), "BUSY")
        self.assertEqual(NATIVE_STATE_CLASS("codex", "[ ! ] Action Required | setup"), "ACTION")
        self.assertEqual(NATIVE_STATE_CLASS("codex", "setup"), "IDLE")
        self.assertEqual(NATIVE_STATE_CLASS("zsh", "⠋ setup"), "")

    def test_elapsed_time_persists_until_native_state_changes(self) -> None:
        panes = [
            NATIVE_PANE("%1", "codex", "⠋ setup", "BUSY", "90", "9s"),
            NATIVE_PANE("%2", "codex", "setup", "BUSY", "90", "9s"),
            NATIVE_PANE("%3", "zsh", "host", "IDLE", "90", "9s"),
        ]
        tmux = mock.Mock()
        with mock.patch.dict(
            APPLY_NATIVE_ELAPSED.__globals__,
            {"list_native_panes": mock.Mock(return_value=panes), "tmux": tmux},
        ):
            desired = APPLY_NATIVE_ELAPSED(self.socket_path, now=100)

        self.assertEqual(desired["%1"], ("BUSY", "90", "10s"))
        self.assertEqual(desired["%2"], ("IDLE", "100", "0s"))
        self.assertEqual(desired["%3"], ("", "", ""))
        tmux.assert_called_once()


class LatestLifecycleTests(unittest.TestCase):
    def status_for(self, records: list[str]) -> tuple[str, float | None]:
        with tempfile.TemporaryDirectory() as directory:
            rollout = Path(directory) / "rollout.jsonl"
            rollout.write_text("\n".join(records) + "\n", encoding="utf-8")
            return LATEST_LIFECYCLE(rollout)

    def test_pending_input_request(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "response_item",
                    {"type": "function_call", "name": "request_user_input", "call_id": "question-1"},
                ),
            ]
        )

        self.assertEqual(status, "INPUT")
        self.assertEqual(changed_at, 1786528860.0)

    def test_answered_input_request_returns_to_busy(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "response_item",
                    {"type": "function_call", "name": "request_user_input", "call_id": "question-1"},
                ),
                record(
                    "2026-08-12T10:02:00Z",
                    "response_item",
                    {"type": "function_call_output", "call_id": "question-1"},
                ),
            ]
        )

        self.assertEqual(status, "BUSY")
        self.assertEqual(changed_at, 1786528920.0)

    def test_completed_turn_wins_after_answer(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "response_item",
                    {"type": "function_call", "name": "request_user_input", "call_id": "question-1"},
                ),
                record(
                    "2026-08-12T10:02:00Z",
                    "response_item",
                    {"type": "function_call_output", "call_id": "question-1"},
                ),
                record("2026-08-12T10:03:00Z", "event_msg", {"type": "task_complete"}),
            ]
        )

        self.assertEqual(status, "WAITING")
        self.assertEqual(changed_at, 1786528980.0)

    def test_unrelated_function_output_does_not_resolve_question(self) -> None:
        status, _ = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "response_item",
                    {"type": "function_call", "name": "request_user_input", "call_id": "question-1"},
                ),
                record(
                    "2026-08-12T10:02:00Z",
                    "response_item",
                    {"type": "function_call_output", "call_id": "another-call"},
                ),
            ]
        )

        self.assertEqual(status, "INPUT")

    def test_pending_escalated_command_is_approval_candidate(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "response_item",
                    {
                        "type": "custom_tool_call",
                        "name": "exec",
                        "call_id": "approval-1",
                        "input": 'tools.exec_command({sandbox_permissions: "require_escalated"})',
                    },
                ),
            ]
        )

        self.assertEqual(status, "APPROVAL")
        self.assertEqual(changed_at, 1786528860.0)

    def test_completed_escalated_command_returns_to_busy(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "response_item",
                    {
                        "type": "custom_tool_call",
                        "name": "exec",
                        "call_id": "approval-1",
                        "input": 'tools.exec_command({sandbox_permissions: "require_escalated"})',
                    },
                ),
                record(
                    "2026-08-12T10:02:00Z",
                    "response_item",
                    {"type": "custom_tool_call_output", "call_id": "approval-1"},
                ),
            ]
        )

        self.assertEqual(status, "BUSY")
        self.assertEqual(changed_at, 1786528920.0)

    def test_pending_connector_call_is_approval_candidate(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "response_item",
                    {
                        "type": "custom_tool_call",
                        "name": "exec",
                        "call_id": "connector-approval-1",
                        "input": "await tools.mcp__codex_apps__github_create_pull_request({})",
                    },
                ),
            ]
        )

        self.assertEqual(status, "APPROVAL")
        self.assertEqual(changed_at, 1786528860.0)

    def test_pending_structured_server_requests_need_input(self) -> None:
        methods = (
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "item/tool/requestUserInput",
            "mcpServer/elicitation/request",
            "tool/requestUserInput",
        )
        for method in methods:
            with self.subTest(method=method):
                status, changed_at = self.status_for(
                    [
                        record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                        record(
                            "2026-08-12T10:01:00Z",
                            "app_server_event",
                            {
                                "method": method,
                                "id": "request-1",
                                "params": {"itemId": "item-1"},
                            },
                        ),
                    ]
                )

                self.assertEqual(status, "INPUT")
                self.assertEqual(changed_at, 1786528860.0)

    def test_resolved_structured_request_returns_to_busy(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "app_server_event",
                    {
                        "method": "item/commandExecution/requestApproval",
                        "id": 42,
                        "params": {"itemId": "item-1"},
                    },
                ),
                record(
                    "2026-08-12T10:02:00Z",
                    "app_server_event",
                    {"method": "serverRequest/resolved", "params": {"requestId": 42}},
                ),
            ]
        )

        self.assertEqual(status, "BUSY")
        self.assertEqual(changed_at, 1786528920.0)

    def test_completed_item_resolves_structured_request(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "app_server_event",
                    {
                        "method": "item/fileChange/requestApproval",
                        "id": "request-1",
                        "params": {"itemId": "item-1"},
                    },
                ),
                record(
                    "2026-08-12T10:02:00Z",
                    "app_server_event",
                    {"method": "item/completed", "params": {"item": {"id": "item-1"}}},
                ),
            ]
        )

        self.assertEqual(status, "BUSY")
        self.assertEqual(changed_at, 1786528920.0)

    def test_older_pending_request_wins_over_newer_resolved_request(self) -> None:
        status, changed_at = self.status_for(
            [
                record("2026-08-12T10:00:00Z", "event_msg", {"type": "task_started"}),
                record(
                    "2026-08-12T10:01:00Z",
                    "app_server_event",
                    {"method": "tool/requestUserInput", "id": "pending", "params": {}},
                ),
                record(
                    "2026-08-12T10:02:00Z",
                    "app_server_event",
                    {"method": "tool/requestUserInput", "id": "answered", "params": {}},
                ),
                record(
                    "2026-08-12T10:03:00Z",
                    "app_server_event",
                    {"method": "serverRequest/resolved", "params": {"requestId": "answered"}},
                ),
            ]
        )

        self.assertEqual(status, "INPUT")
        self.assertEqual(changed_at, 1786528860.0)


class RootRolloutTests(unittest.TestCase):
    def test_rollouts_from_before_thread_source_are_roots_unless_spawned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "rollout-root.jsonl"
            agent = Path(directory) / "rollout-agent.jsonl"
            # Codex 0.128 and older wrote no thread_source; only its subagents had an object source.
            root.write_text(
                record("2026-04-23T15:06:58Z", "session_meta", {"id": "root", "source": "cli"}) + "\n",
                encoding="utf-8",
            )
            agent.write_text(
                record("2026-04-23T15:07:00Z", "session_meta", {"id": "agent", "source": {"subagent": {"thread_spawn": {}}}}) + "\n",
                encoding="utf-8",
            )

            self.assertEqual(ROOT_ROLLOUT([root, agent]), root)
            self.assertIsNone(ROOT_ROLLOUT([agent]))


class ApprovalPromptTests(unittest.TestCase):
    socket_path = Path("/tmp/tmux-test.sock")

    def test_visible_approval_prompt_waits_for_input(self) -> None:
        tmux = mock.Mock(return_value="Would you like to run this?\nPress enter to confirm\n or esc to cancel\n")
        with mock.patch.dict(PANE_WAITS_FOR_APPROVAL.__globals__, {"tmux": tmux}):
            self.assertTrue(PANE_WAITS_FOR_APPROVAL(self.socket_path, "%1"))

    def test_visible_connector_approval_prompt_waits_for_input(self) -> None:
        tmux = mock.Mock(return_value="Allow GitHub to create a pull request?\nenter to submit | esc to cancel\n")
        with mock.patch.dict(PANE_WAITS_FOR_APPROVAL.__globals__, {"tmux": tmux}):
            self.assertTrue(PANE_WAITS_FOR_APPROVAL(self.socket_path, "%1"))

    def test_running_command_is_not_waiting_for_input(self) -> None:
        tmux = mock.Mock(return_value="Running tests\nWorking (12s)\n")
        with mock.patch.dict(PANE_WAITS_FOR_APPROVAL.__globals__, {"tmux": tmux}):
            self.assertFalse(PANE_WAITS_FOR_APPROVAL(self.socket_path, "%1"))


class WatcherOwnershipTests(unittest.TestCase):
    socket_path = Path("/tmp/tmux-test.sock")

    def watcher_globals(self, **replacements: object) -> mock._patch_dict:
        return mock.patch.dict(WATCH.__globals__, replacements)

    def test_superseded_watcher_exits_before_updating(self) -> None:
        apply_native_elapsed = mock.Mock()
        clear_registration = mock.Mock()
        with self.watcher_globals(
            apply_native_elapsed=apply_native_elapsed,
            await_updater_registration=mock.Mock(return_value=True),
            clear_updater_registration=clear_registration,
            configured_interval=mock.Mock(return_value=10.0),
            owns_updater_registration=mock.Mock(return_value=False),
            signal=mock.Mock(SIGINT=2, SIGTERM=15),
        ):
            self.assertEqual(WATCH(self.socket_path), 0)

        apply_native_elapsed.assert_not_called()
        clear_registration.assert_called_once_with(self.socket_path)

    def test_owner_updates_once_then_exits_when_superseded(self) -> None:
        apply_native_elapsed = mock.Mock()
        clock = mock.Mock()
        clock.monotonic.side_effect = [10.0, 10.0]
        clear_registration = mock.Mock()
        with self.watcher_globals(
            apply_native_elapsed=apply_native_elapsed,
            await_updater_registration=mock.Mock(return_value=True),
            clear_updater_registration=clear_registration,
            configured_interval=mock.Mock(return_value=10.0),
            owns_updater_registration=mock.Mock(side_effect=[True, False]),
            signal=mock.Mock(SIGINT=2, SIGTERM=15),
            time=clock,
        ):
            self.assertEqual(WATCH(self.socket_path), 0)

        apply_native_elapsed.assert_called_once_with(self.socket_path)
        clock.sleep.assert_called_once_with(10.0)
        clear_registration.assert_called_once_with(self.socket_path)

    def test_cleanup_scopes_unregister_to_current_process(self) -> None:
        tmux = mock.Mock()
        process = mock.Mock()
        process.getpid.return_value = 12345
        with mock.patch.dict(CLEAR_UPDATER_REGISTRATION.__globals__, {"os": process, "tmux": tmux}):
            CLEAR_UPDATER_REGISTRATION(self.socket_path)

        tmux.assert_called_once_with(
            self.socket_path,
            "if-shell",
            "-F",
            "#{==:#{@codex_status_updater_pid},12345}",
            "set-option -guq @codex_status_updater_pid",
            allow_empty_failure=True,
        )


if __name__ == "__main__":
    unittest.main()
