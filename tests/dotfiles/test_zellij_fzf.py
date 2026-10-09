#!/usr/bin/env python3
# setup-test: Zellij navigator
"""Regression tests for the Zellij pane and project navigator."""

from __future__ import annotations

import json
import os
import runpy
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[2] / "dotfiles" / ".bin" / "zellij-fzf"
SCRIPT_GLOBALS = runpy.run_path(str(SCRIPT))
TMUX_SCRIPT_GLOBALS = runpy.run_path(str(SCRIPT.with_name("tmux-fzf")))
PANE_RECORD = SCRIPT_GLOBALS["PaneRecord"]
PARSE_PANE_RECORDS = SCRIPT_GLOBALS["parse_pane_records"]
LIST_PANES = SCRIPT_GLOBALS["list_panes"]
SESSION_NAMES = SCRIPT_GLOBALS["session_names"]
RADAR_CODEX_STATES = SCRIPT_GLOBALS["radar_codex_states"]
ZELLIJ = SCRIPT_GLOBALS["zellij"]
JUMP_TO_PANE = SCRIPT_GLOBALS["jump_to_pane"]
PROJECT_ROOT = SCRIPT_GLOBALS["project_root"]
CLOSE_PANE = SCRIPT_GLOBALS["close_pane"]
CHOOSE_PANE = SCRIPT_GLOBALS["choose_pane"]
PANE_FZF_LINE = SCRIPT_GLOBALS["pane_fzf_line"]
PANE_PLAIN_TEXT = SCRIPT_GLOBALS["pane_plain_text"]
PANE_TABLE_LABELS = SCRIPT_GLOBALS["PANE_TABLE_LABELS"]
PANE_TABLE_HEADER = SCRIPT_GLOBALS["pane_table_header"]
PANE_TABLE_WIDTHS = SCRIPT_GLOBALS["pane_table_widths"]
PREVIEW_PANE = SCRIPT_GLOBALS["preview_pane"]
SUBSCRIBE_PANE_VIEWPORT = SCRIPT_GLOBALS["subscribe_pane_viewport"]
TMUX_PANE_TABLE_LABELS = TMUX_SCRIPT_GLOBALS["PANE_TABLE_LABELS"]


def completed(stdout: str = "", returncode: int = 0) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess([], returncode, stdout, "")


def pane_record(
    session: str = "work",
    *,
    command: str = "/usr/bin/zsh",
    codex_state: str = "",
    title: str = "Pane #7",
):
    return PANE_RECORD(
        session=session,
        pane_id="terminal_7",
        tab_id=3,
        tab_position=2,
        tab_name="agents",
        title=title,
        command=command,
        cwd=Path("/tmp/work"),
        focused=True,
        floating=False,
        codex_state=codex_state,
    )


class PaneDiscoveryTests(unittest.TestCase):
    def test_excludes_saved_exited_sessions_before_querying_panes(self) -> None:
        output = (
            "active [Created 2m ago]\n"
            "saved [Created 1day ago] (EXITED - attach to resurrect)\n"
            "another [Created 1m ago] (current)\n"
        )
        with mock.patch.dict(
            SESSION_NAMES.__globals__, {"zellij": mock.Mock(return_value=completed(output))}
        ):
            self.assertEqual(SESSION_NAMES(), ["active", "another"])

    def test_parses_terminal_panes_and_ignores_plugins_and_exited_panes(self) -> None:
        payload = json.dumps(
            [
                {"id": 1, "is_plugin": True, "exited": False},
                {"id": 2, "is_plugin": False, "exited": True, "pane_cwd": "/tmp/old"},
                {
                    "id": 7,
                    "is_plugin": False,
                    "exited": False,
                    "is_focused": True,
                    "is_floating": False,
                    "title": "Pane #7",
                    "pane_command": "/usr/bin/zsh",
                    "pane_cwd": "/tmp/work",
                    "tab_id": 3,
                    "tab_position": 2,
                    "tab_name": "agents",
                },
            ]
        )

        self.assertEqual(PARSE_PANE_RECORDS("work", payload), [pane_record()])
        self.assertEqual(PARSE_PANE_RECORDS("work", "not json"), [])

    def test_discovers_sessions_concurrently_and_sorts_the_result(self) -> None:
        panes = {
            "zeta": [pane_record("zeta", command="codex")],
            "alpha": [pane_record("alpha")],
        }
        with mock.patch.dict(
            LIST_PANES.__globals__,
            {
                "session_names": mock.Mock(return_value=["zeta", "dead", "alpha"]),
                "list_session_panes": lambda session: panes.get(session, []),
                "radar_codex_states": mock.Mock(
                    return_value={("zeta", "terminal_7"): "⠋"}
                ),
            },
        ):
            discovered = LIST_PANES()

        self.assertEqual([record.session for record in discovered], ["alpha", "zeta"])
        self.assertEqual(discovered[1].codex_state, "⠋")

    def test_targets_zellij_actions_with_the_session_environment(self) -> None:
        run_mock = mock.Mock(return_value=completed())
        with mock.patch.dict(
            ZELLIJ.__globals__,
            {"command_path": lambda _name: "/usr/bin/zellij", "run": run_mock},
        ):
            ZELLIJ("action", "list-panes", session="work")

        command = run_mock.call_args.args[0]
        environment = run_mock.call_args.kwargs["environment"]
        self.assertEqual(command, ["/usr/bin/zellij", "action", "list-panes"])
        self.assertEqual(environment["ZELLIJ_SESSION_NAME"], "work")


class CodexStateTests(unittest.TestCase):
    def test_tmux_and_zellij_use_the_same_pane_table_columns(self) -> None:
        self.assertEqual(PANE_TABLE_LABELS, TMUX_PANE_TABLE_LABELS)

    def test_reads_fresh_codex_states_from_the_radar_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache_root = Path(directory)
            radar_cache = cache_root / "file:" / "tmp" / "zj_radar.wasm" / "plugin_cache"
            radar_cache.mkdir(parents=True)
            presence = radar_cache / "zj-radar.presence.123.json"
            presence.write_text(json.dumps({"session_name": "work"}), encoding="utf-8")
            snapshot = {
                "v": 3,
                "observations": [
                    {"pane_id": index, "source": "codex", "status": status}
                    for index, status in enumerate(
                        ("running", "pending", "done", "error", "idle"), start=1
                    )
                ]
                + [{"pane_id": 9, "source": "claude", "status": "running"}],
            }
            (radar_cache / "zj-radar.123.json").write_text(
                json.dumps(snapshot), encoding="utf-8"
            )

            now = time.time()
            os.utime(presence, (now, now))
            states = RADAR_CODEX_STATES(["work"], cache_root=cache_root, now=now)

        self.assertEqual(
            states,
            {
                ("work", "terminal_1"): "⠋",
                ("work", "terminal_2"): "!",
                ("work", "terminal_3"): ".",
                ("work", "terminal_4"): "✗",
                ("work", "terminal_5"): "💤",
            },
        )

    def test_ignores_stale_or_unrelated_session_presence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache_root = Path(directory)
            radar_cache = cache_root / "file:" / "tmp" / "zj_radar.wasm" / "plugin_cache"
            radar_cache.mkdir(parents=True)
            presence = radar_cache / "zj-radar.presence.123.json"
            presence.write_text(json.dumps({"session_name": "other"}), encoding="utf-8")
            (radar_cache / "zj-radar.123.json").write_text(
                json.dumps(
                    {
                        "v": 3,
                        "observations": [
                            {"pane_id": 1, "source": "codex", "status": "pending"}
                        ],
                    }
                ),
                encoding="utf-8",
            )
            os.utime(presence, (100, 100))

            self.assertEqual(
                RADAR_CODEX_STATES(["work"], cache_root=cache_root, now=1000), {}
            )

    def test_plain_and_fzf_rows_show_the_codex_state(self) -> None:
        record = pane_record(command="codex", codex_state="!")

        self.assertEqual(
            PANE_PLAIN_TEXT(record).split("\t"),
            ["work", "agents", "Pane #7", "codex", "!", "/tmp/work"],
        )
        widths = PANE_TABLE_WIDTHS([record])
        self.assertEqual(widths, (7, 6, 7, 7, 5))
        self.assertEqual(
            PANE_TABLE_HEADER(widths),
            "  SESSION TAB    PANE    COMMAND CODEX PATH",
        )
        line = PANE_FZF_LINE(record)
        self.assertEqual(line.count("terminal_7"), 1)
        self.assertLess(line.index("!"), line.index("/tmp/work"))


class PaneActivationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.calls: list[tuple[tuple[str, ...], dict[str, object]]] = []

    def fake_zellij(self, *arguments: str, **keywords: object):
        self.calls.append((arguments, keywords))
        return completed()

    def test_focuses_a_pane_in_the_current_session_without_switching(self) -> None:
        with mock.patch.dict(os.environ, {"ZELLIJ_SESSION_NAME": "work"}, clear=True), mock.patch.dict(
            JUMP_TO_PANE.__globals__, {"zellij": self.fake_zellij}
        ):
            JUMP_TO_PANE(pane_record())

        self.assertEqual(
            [call[0] for call in self.calls],
            [("action", "go-to-tab-by-id", "3"), ("action", "focus-pane-id", "terminal_7")],
        )

    def test_switches_directly_to_an_exact_pane_in_another_session(self) -> None:
        with mock.patch.dict(os.environ, {"ZELLIJ_SESSION_NAME": "current"}, clear=True), mock.patch.dict(
            JUMP_TO_PANE.__globals__, {"zellij": self.fake_zellij}
        ):
            JUMP_TO_PANE(pane_record())

        self.assertEqual(
            self.calls[0][0],
            (
                "action",
                "switch-session",
                "work",
                "--tab-position",
                "2",
                "--pane-id",
                "terminal_7",
            ),
        )

    def test_focuses_the_detached_target_before_attaching(self) -> None:
        attach = mock.Mock()
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.dict(
            JUMP_TO_PANE.__globals__, {"zellij": self.fake_zellij, "attach_session": attach}
        ):
            JUMP_TO_PANE(pane_record())

        self.assertEqual(self.calls[0][1]["session"], "work")
        self.assertEqual(self.calls[1][1]["session"], "work")
        attach.assert_called_once_with("work")


class PanePreviewTests(unittest.TestCase):
    def test_structured_viewport_preserves_physical_rows_and_stops_subscription(self) -> None:
        read_fd, write_fd = os.pipe()
        payload = {
            "event": "pane_update",
            "is_initial": True,
            "pane_id": "terminal_7",
            "scrollback": None,
            "viewport": ["first 18-col row", "second row", "❯"],
        }
        os.write(write_fd, (json.dumps(payload) + "\n").encode())
        os.close(write_fd)
        stdout = os.fdopen(read_fd, "rb")
        process = mock.Mock(stdout=stdout)
        process.poll.return_value = None
        process.wait.return_value = 0

        with mock.patch.object(subprocess, "Popen", return_value=process) as popen, mock.patch.dict(
            SUBSCRIBE_PANE_VIEWPORT.__globals__,
            {"command_path": lambda _name: "/usr/bin/zellij"},
        ):
            viewport = SUBSCRIBE_PANE_VIEWPORT("work", "terminal_7")

        self.assertEqual(viewport, payload["viewport"])
        self.assertEqual(
            popen.call_args.args[0],
            [
                "/usr/bin/zellij",
                "subscribe",
                "--pane-id",
                "terminal_7",
                "--format",
                "json",
            ],
        )
        self.assertEqual(popen.call_args.kwargs["env"]["ZELLIJ_SESSION_NAME"], "work")
        process.terminate.assert_called_once_with()
        process.kill.assert_not_called()

    def test_preview_prints_structured_rows_without_dumping_screen(self) -> None:
        subscription = mock.Mock(return_value=["row one", "row two"])
        zellij = mock.Mock()
        output = mock.Mock()
        with mock.patch.dict(
            PREVIEW_PANE.__globals__,
            {"subscribe_pane_viewport": subscription, "zellij": zellij},
        ), mock.patch.object(PREVIEW_PANE.__globals__["sys"], "stdout", output):
            self.assertEqual(PREVIEW_PANE("work", "terminal_7"), 0)

        output.write.assert_called_once_with("row one\nrow two\n")
        zellij.assert_not_called()

    def test_preview_falls_back_to_dump_screen_when_subscription_is_unavailable(self) -> None:
        zellij = mock.Mock(return_value=completed("fallback\n"))
        output = mock.Mock()
        with mock.patch.dict(
            PREVIEW_PANE.__globals__,
            {"subscribe_pane_viewport": mock.Mock(return_value=None), "zellij": zellij},
        ), mock.patch.object(PREVIEW_PANE.__globals__["sys"], "stdout", output):
            self.assertEqual(PREVIEW_PANE("work", "terminal_7"), 0)

        zellij.assert_called_once_with(
            "action", "dump-screen", "--pane-id", "terminal_7", session="work", check=False
        )
        output.write.assert_called_once_with("fallback\n")


class PaneCloseTests(unittest.TestCase):
    def test_confirmation_closes_the_exact_highlighted_pane(self) -> None:
        zellij = mock.Mock(return_value=completed())
        with mock.patch("builtins.input", return_value="y"), mock.patch.dict(
            CLOSE_PANE.__globals__,
            {"list_session_panes": mock.Mock(return_value=[pane_record()]), "zellij": zellij},
        ):
            self.assertEqual(CLOSE_PANE("work", "terminal_7"), 0)

        zellij.assert_called_once_with(
            "action", "close-pane", "--pane-id", "terminal_7", session="work"
        )

    def test_default_confirmation_cancels_without_touching_zellij(self) -> None:
        zellij = mock.Mock(return_value=completed())
        with mock.patch("builtins.input", return_value=""), mock.patch.dict(
            CLOSE_PANE.__globals__,
            {"list_session_panes": mock.Mock(return_value=[pane_record()]), "zellij": zellij},
        ):
            self.assertEqual(CLOSE_PANE("work", "terminal_7"), 0)

        zellij.assert_not_called()

    def test_picker_confirms_in_place_then_closes_silently(self) -> None:
        run = mock.Mock(return_value=completed(returncode=1))
        with mock.patch.dict(
            CHOOSE_PANE.__globals__,
            {"command_path": lambda _name: "/usr/bin/fzf", "run": run},
        ):
            self.assertIsNone(CHOOSE_PANE([pane_record()]))

        command = run.call_args.args[0]
        self.assertEqual(
            run.call_args.kwargs["environment"]["TW_FZF_PANE_WIDTHS"], "7,6,7,7,5"
        )
        binding = next(argument for argument in command if argument.startswith("--bind=delete:"))
        confirm = next(argument for argument in command if argument.startswith("--bind=y:"))
        self.assertIn("change-header(", binding)
        self.assertIn(",backward-eof:change-header(", binding)
        self.assertIn("_close-pane-confirmed {1} {2}", confirm)
        self.assertIn("execute-silent(", confirm)
        self.assertIn("+reload(", confirm)
        self.assertNotIn("execute(", binding)


class ProjectRootTests(unittest.TestCase):
    def test_generic_project_root_takes_priority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            generic = Path(directory) / "generic"
            backend = Path(directory) / "backend"
            generic.mkdir()
            backend.mkdir()
            with mock.patch.dict(
                os.environ,
                {"TW_PROJECT_ROOT": str(generic), "ZELLIJ_PROJECT_ROOT": str(backend)},
                clear=True,
            ):
                self.assertEqual(PROJECT_ROOT(), generic.resolve())


if __name__ == "__main__":
    unittest.main()
