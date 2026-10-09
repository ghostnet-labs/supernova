#!/usr/bin/env python3
# setup-test: Atuin interactive picker
"""Check the real Atuin picker and Toolbox together in an isolated Zsh PTY."""

from pathlib import Path
import os
import select
import shlex
import shutil
import time
import unittest

import test_toolbox_picker as picker


class HistoryTerminal(picker.PickerTests):
    # Atuin owns this database and must initialize its complete migration schema.
    seed_toolbox_history = False

    def drain(self):
        # Atuin also asks for cursor position when restoring its inline UI.
        while select.select([self.fd], [], [], 0.1)[0]:
            chunk = os.read(self.fd, 65536)
            if b"\x1b[6n" in chunk:
                self.send(b"\x1b[1;1R")


@unittest.skipUnless(all(shutil.which(name) for name in ("zsh", "fzf", "atuin")),
                     "Zsh, fzf, and Atuin required for PTY checks")
class HistoryPickerTests(unittest.TestCase):
    def setUp(self):
        self.terminal = HistoryTerminal(methodName="runTest")
        self.terminal.setUp()
        terminal = self.terminal
        self.example = f"touch {shlex.quote(str(terminal.marker))} # ATUIN_PICKER_FIXTURE"
        source = Path(__file__).resolve().parents[2] / "dotfiles/functions/atuin.zsh"
        terminal.send(
            f"XDG_CONFIG_HOME={shlex.quote(str(terminal.directory / 'config'))}; "
            f"XDG_DATA_HOME={shlex.quote(str(terminal.directory / 'data'))}; "
            "export XDG_CONFIG_HOME XDG_DATA_HOME; "
            f"source {shlex.quote(str(source))}; _setup_atuin_init; "
            f"id=$(atuin history start -- {shlex.quote(self.example)}); "
            "atuin history end --exit 0 --duration=1 -- $id; print HISTORY_READY\n")
        terminal.read_until(b"HISTORY_READY\r\n")
        terminal.drain()

    def tearDown(self):
        self.terminal.tearDown()

    def test_enter_inserts_without_execution(self):
        terminal = self.terminal
        terminal.send(b"ATUIN_PICKER_FIXTURE\x12")
        terminal.read_until(b"GLOBAL")
        time.sleep(0.15)
        terminal.send(b"\r")
        time.sleep(0.15)
        self.assertIn(f"CAPTURE:{self.example}:CURSOR:{len(self.example)}:END".encode(), terminal.capture())
        self.assertFalse(terminal.marker.exists())

    def test_escape_restores_cursor_and_toolbox_still_works(self):
        terminal = self.terminal
        terminal.send(b"original buffer\x02\x02\x12")
        terminal.read_until(b"GLOBAL")
        terminal.send(b"\x1b")
        time.sleep(0.25)
        self.assertIn(b"CAPTURE:original buffer:CURSOR:13:END", terminal.capture())
        terminal.send(b"\x18\x14")
        terminal.read_until(b"toolbox>")
        terminal.send("picker_fixture")
        terminal.drain()
        terminal.send(b"\r")
        time.sleep(0.15)
        self.assertIn(f"CAPTURE:{terminal.example}:CURSOR:{len(terminal.example)}:END".encode(), terminal.capture())
        self.assertFalse(terminal.marker.exists())


if __name__ == "__main__":
    unittest.main(defaultTest="HistoryPickerTests")
