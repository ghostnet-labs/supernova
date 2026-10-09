#!/usr/bin/env python3
# setup-test: tmux navigator
"""Regression tests for destructive tmux pane-picker actions."""

from __future__ import annotations

import runpy
import subprocess
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[2] / "dotfiles" / ".bin" / "tmux-fzf"
SCRIPT_GLOBALS = runpy.run_path(str(SCRIPT))
PANE_RECORD = SCRIPT_GLOBALS["PaneRecord"]
CLOSE_PANE = SCRIPT_GLOBALS["close_pane"]
CHOOSE_PANE = SCRIPT_GLOBALS["choose_pane"]
PANE_FZF_LINE = SCRIPT_GLOBALS["pane_fzf_line"]
PANE_PLAIN_TEXT = SCRIPT_GLOBALS["pane_plain_text"]
PANE_CODEX_STATE = SCRIPT_GLOBALS["pane_codex_state"]
PANE_TABLE_HEADER = SCRIPT_GLOBALS["pane_table_header"]
PANE_TABLE_WIDTHS = SCRIPT_GLOBALS["pane_table_widths"]


def completed(returncode: int = 0) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess([], returncode, "", "")


def pane_record(*, command: str = "zsh", title: str = "shell", custom_label: str = ""):
    return PANE_RECORD(
        pane_id="%7",
        session="work",
        window_id="@3",
        window_index=2,
        window_name="agents",
        pane_index=1,
        command=command,
        cwd=Path("/tmp/work"),
        title=title,
        custom_label=custom_label,
        pane_active=True,
        window_active=True,
        session_attached=True,
    )


class TmuxPaneTableTests(unittest.TestCase):
    def test_pane_column_uses_the_visible_label_or_index(self) -> None:
        self.assertEqual(PANE_PLAIN_TEXT(pane_record()).split("\t")[2], "1")
        self.assertEqual(
            PANE_PLAIN_TEXT(pane_record(custom_label="logs")).split("\t")[2], "logs"
        )

    def test_codex_state_never_includes_title_text(self) -> None:
        busy = pane_record(command="codex", title="⠇ nightly-build-report...")
        unknown = pane_record(command="codex", title="codex")

        self.assertEqual(PANE_CODEX_STATE(busy), "⡇")
        self.assertEqual(PANE_CODEX_STATE(unknown), "")

    def test_codex_state_is_a_column_before_the_path(self) -> None:
        record = pane_record(command="codex", title="[ ! ] Action Required")

        self.assertEqual(
            PANE_PLAIN_TEXT(record).split("\t"),
            ["work", "agents", "1", "codex", "!", "/tmp/work"],
        )
        widths = PANE_TABLE_WIDTHS([record])
        self.assertEqual(widths, (7, 6, 4, 7, 5))
        self.assertEqual(PANE_TABLE_HEADER(widths), "  SESSION TAB    PANE COMMAND CODEX PATH")
        line = PANE_FZF_LINE(record)
        self.assertEqual(line.count("%7"), 1)
        self.assertLess(line.index("!"), line.index("/tmp/work"))


class TmuxPaneCloseTests(unittest.TestCase):
    def test_confirmation_closes_the_exact_highlighted_pane(self) -> None:
        tmux = mock.Mock(return_value=completed())
        with mock.patch("builtins.input", return_value="yes"), mock.patch.dict(
            CLOSE_PANE.__globals__, {"list_panes": mock.Mock(return_value=[pane_record()]), "tmux": tmux}
        ):
            self.assertEqual(CLOSE_PANE("%7"), 0)

        tmux.assert_called_once_with("kill-pane", "-t", "%7")

    def test_default_confirmation_cancels_without_touching_tmux(self) -> None:
        tmux = mock.Mock(return_value=completed())
        with mock.patch("builtins.input", return_value=""), mock.patch.dict(
            CLOSE_PANE.__globals__, {"list_panes": mock.Mock(return_value=[pane_record()]), "tmux": tmux}
        ):
            self.assertEqual(CLOSE_PANE("%7"), 0)

        tmux.assert_not_called()

    def test_picker_confirms_in_place_then_closes_silently(self) -> None:
        run = mock.Mock(return_value=completed(1))
        with mock.patch.dict(
            CHOOSE_PANE.__globals__,
            {"command_path": lambda _name: "/usr/bin/fzf", "run": run},
        ):
            self.assertIsNone(CHOOSE_PANE([pane_record()]))

        command = run.call_args.args[0]
        self.assertEqual(
            run.call_args.kwargs["environment"]["TW_FZF_PANE_WIDTHS"], "7,6,4,7,5"
        )
        binding = next(argument for argument in command if argument.startswith("--bind=delete:"))
        confirm = next(argument for argument in command if argument.startswith("--bind=y:"))
        self.assertIn("change-header(", binding)
        self.assertIn(",backward-eof:change-header(", binding)
        self.assertIn("_close-pane-confirmed {1}", confirm)
        self.assertIn("execute-silent(", confirm)
        self.assertIn("+reload(", confirm)
        self.assertNotIn("execute(", binding)


if __name__ == "__main__":
    unittest.main()
