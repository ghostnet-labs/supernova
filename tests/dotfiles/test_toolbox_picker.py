#!/usr/bin/env python3
# setup-test: Toolbox picker and metadata
"""Exercise inert metadata and the real ZLE/fzf interaction on a terminal."""

import importlib.util
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import sqlite3
import struct
import subprocess
import tempfile
import termios
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("toolbox", ROOT / "dotfiles/lib/toolbox.py")
TOOLBOX = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOLBOX)


def catalog_entry(command, description, scope="personal"):
    return {"id": hashlib.sha256((scope + "\0" + command).encode()).hexdigest(),
            "scope": scope, "command": command, "description": description, "tags": ["fixture"]}


class CatalogIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toolbox catalog integration ")
        self.directory = Path(self.temporary.name)
        self.repository = self.directory / "setup"
        self.helpers = self.repository / "dotfiles/functions"
        self.helpers.mkdir(parents=True)
        shutil.copy(ROOT / "dotfiles/functions/shell.zsh", self.helpers)
        shutil.copytree(ROOT / "dotfiles/lib", self.repository / "dotfiles/lib")
        (self.repository / "dotfiles/toolbox").mkdir()
        self.environment = dict(os.environ, HOME=str(self.directory),
                                XDG_CONFIG_HOME=str(self.directory / "config"),
                                XDG_DATA_HOME=str(self.directory / "data"))
        self.environment.pop("ATUIN_DB_PATH", None)

    def tearDown(self):
        self.temporary.cleanup()

    def run_toolbox(self, *args, work=False):
        # Scope variables deliberately aren't exported: the public helper must
        # forward the actual shell's selection rather than inherited values.
        return subprocess.run(["zsh", "-dfc",
                               'SETUP_DIR=$1; WORK_ENV=$2; JOB=fixture; '
                               'typeset +x SETUP_DIR WORK_ENV JOB; '
                               'source "$SETUP_DIR/dotfiles/functions/shell.zsh"; '
                               'shift 2; toolbox "$@"', "toolbox-test", str(self.repository),
                               str(work).lower(), *args], env=self.environment,
                              text=True, capture_output=True, check=False)

    def seed(self):
        personal = catalog_entry("printf '%s\\n' 'personal fixture'", "Personal saved command")
        work = catalog_entry("printf '%s\\n' 'work fixture'", "Work saved command", "work-fixture")
        (self.repository / "dotfiles/toolbox/personal.jsonl").write_text(json.dumps(personal) + "\n")
        work_dir = self.directory / "data/toolbox/work-fixture"
        work_dir.mkdir(parents=True)
        (work_dir / "catalog.jsonl").write_text(json.dumps(work) + "\n")
        return personal, work

    def test_catalogs_obey_shell_scope_and_search_command_text(self):
        personal, work = self.seed()
        personal_result = self.run_toolbox("--json", "fixture")
        self.assertEqual(personal_result.returncode, 0, personal_result.stderr)
        catalog = [row for row in json.loads(personal_result.stdout)["commands"] if row["kind"] == "catalog"]
        self.assertEqual([row["examples"][0] for row in catalog], [personal["command"]])
        work_result = self.run_toolbox("--json", "fixture", work=True)
        self.assertEqual(work_result.returncode, 0, work_result.stderr)
        catalog = [row for row in json.loads(work_result.stdout)["commands"] if row["kind"] == "catalog"]
        self.assertEqual([row["examples"][0] for row in catalog], [personal["command"], work["command"]])
        self.assertTrue(all(row["name"].startswith("catalog:") for row in catalog))
        description = self.run_toolbox("--describe", catalog[0]["name"])
        self.assertEqual(description.returncode, 0, description.stderr)
        self.assertIn(personal["command"], description.stdout)
        self.assertIn("Saved command", description.stdout)

    def test_catalog_arguments_remain_inert_and_scope_is_forwarded(self):
        marker = self.directory / "executed"
        backend = self.repository / "dotfiles/lib/toolbox_catalog.py"
        backend.write_text("import json, os, sys\nprint(json.dumps({'args': sys.argv[1:], "
                           "'scope': [os.environ.get('WORK_ENV'), os.environ.get('JOB')]}))\n")
        command = f"printf '%s' '$(touch {marker})'; `touch {marker}`\n\n"
        result = self.run_toolbox("--save", command, "--description", "literal $VALUE", work=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "args": ["save", "--command=" + command, "--description", "literal $VALUE"],
            "scope": ["true", "fixture"]})
        for flag, action in [("--collect-history", "collect"), ("--pending", "pending"),
                             ("--review", "review"), ("--accept", "accept"), ("--reject", "reject")]:
            with self.subTest(flag=flag):
                result = self.run_toolbox(flag, command)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["args"], [action, command])
        self.assertFalse(marker.exists())

    def test_malformed_catalog_fails_without_showing_its_contents(self):
        (self.repository / "dotfiles/toolbox/personal.jsonl").write_text("private malformed text\n")
        result = self.run_toolbox("--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("private malformed text", result.stdout + result.stderr)


class MetadataTests(unittest.TestCase):
    def test_contiguous_blocks_and_control_characters(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "helpers.zsh"
            source.write_text(
                "# toolbox: test | Description\n# toolbox-args: [VALUE]\n"
                "# toolbox-example: sample '$(touch NEVER)'\n"
                "sample() { :; }\n# toolbox: ignored | Detached\n\n"
                "detached() { :; }\n# toolbox: test | Safe\x1b[31m text\n"
                "# toolbox-example: control\x1btext\ncontrolled() { :; }\n")
            metadata = TOOLBOX.metadata(source)
            self.assertEqual(metadata["sample"]["examples"], ["sample '$(touch NEVER)'"])
            self.assertEqual(metadata["sample"]["argument_hint"], "[VALUE]")
            self.assertNotIn("detached", metadata)
            self.assertNotIn("\x1b", metadata["controlled"]["description"])
            self.assertEqual(metadata["controlled"]["examples"], [])

    def test_json_preserves_unusual_names_without_execution(self):
        name = "space quote' dollar$ backslash\\ café"
        snapshot = "\0".join([name, "home", "executable", "/missing file", "executable", "/missing file", ""])
        records = TOOLBOX.inventory(snapshot.encode())
        self.assertEqual(json.loads(json.dumps(records))[0]["name"], name)
        self.assertEqual(shlex.split(records[0]["invocation"]), [name])


@unittest.skipUnless(shutil.which("zsh") and shutil.which("fzf"), "Zsh and fzf required for PTY checks")
class PickerTests(unittest.TestCase):
    seed_toolbox_history = True

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toolbox picker ")
        self.directory = Path(self.temporary.name)
        self.repository = self.directory / "setup"
        self.marker = self.directory / "executed"
        helpers = self.repository / "dotfiles/functions"
        helpers.mkdir(parents=True)
        shutil.copy(ROOT / "dotfiles/functions/shell.zsh", helpers)
        shutil.copytree(ROOT / "dotfiles/lib", self.repository / "dotfiles/lib")
        (self.repository / "dotfiles/toolbox").mkdir()
        self.catalog_example = "printf '%s\\n' 'multilinefixture' \\\n  '$(touch NEVER)'\n\n"
        (self.repository / "dotfiles/toolbox/personal.jsonl").write_text(
            json.dumps(catalog_entry(self.catalog_example, "Multiline saved fixture")) + "\n")
        self.history_example = "printf '%s\\n' 'localhistorysample' \\\n  '$(touch NEVER)'\n\n"
        if self.seed_toolbox_history:
            history = self.directory / "data/atuin/scopes/personal/history.db"
            history.parent.mkdir(parents=True)
            with contextlib.closing(sqlite3.connect(history)) as connection, connection:
                connection.execute("CREATE TABLE history(command TEXT, deleted_at TEXT)")
                connection.execute("INSERT INTO history(command) VALUES(?)", (self.history_example,))
        self.example = "picker_fixture 'path with spaces; $(touch NEVER)'"
        (helpers / "fixture.zsh").write_text(
            "# toolbox: fixture | PTY test command.\n"
            f"# toolbox-example: {self.example}\n"
            f"picker_fixture() {{ print executed >>{shlex.quote(str(self.marker))}; }}\n")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(self.directory)
            os.environ["TERM"] = "xterm-256color"
            os.environ["HOME"] = str(self.directory)
            os.environ["XDG_CONFIG_HOME"] = str(self.directory / "config")
            os.environ["XDG_DATA_HOME"] = str(self.directory / "data")
            # A inherited fzf action must never execute during discovery/selection.
            os.environ["FZF_DEFAULT_OPTS"] = f"--bind=start:execute-silent(touch {shlex.quote(str(self.marker))})"
            os.execv(shutil.which("zsh"), ["zsh", "-dfi"])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
        self.send(
            f"SETUP_DIR={shlex.quote(str(self.repository))}; WORK_ENV=false; "
            f"source {shlex.quote(str(helpers / 'shell.zsh'))}; "
            f"source {shlex.quote(str(helpers / 'fixture.zsh'))}; "
            "bindkey -e; _toolbox_init; _toolbox_init; "
            "_capture() { print -r -- \"CAPTURE:${BUFFER}:CURSOR:${CURSOR}:END\"; zle redisplay; }; "
            "zle -N _capture; bindkey '^X^B' _capture; PROMPT='READY> '; print INITIALIZED\n")
        self.read_until(b"INITIALIZED\r\n")
        self.drain()

    def tearDown(self):
        os.kill(self.pid, signal.SIGKILL)
        os.close(self.fd)
        os.waitpid(self.pid, 0)
        self.temporary.cleanup()

    def send(self, value):
        os.write(self.fd, value.encode() if isinstance(value, str) else value)

    def read_until(self, token, timeout=6):
        output = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            readable, _, _ = select.select([self.fd], [], [], 0.1)
            if readable:
                chunk = os.read(self.fd, 65536)
                # fzf's partial-screen renderer requests the cursor position.
                if b"\x1b[6n" in chunk:
                    self.send(b"\x1b[1;1R")
                output += chunk
                if token in output:
                    return output
        self.fail(f"terminal did not contain {token!r}: {output[-5000:]!r}")

    def drain(self):
        while select.select([self.fd], [], [], 0.1)[0]:
            os.read(self.fd, 65536)

    def capture(self):
        self.drain()
        self.send(b"\x18\x02")
        return self.read_until(b":END")

    def test_widget_inserts_without_execution(self):
        self.send(b"old buffer\x18\x14")
        self.read_until(b"toolbox>")
        self.send("picker_fixture")
        self.drain()
        self.send(b"\r")
        time.sleep(0.15)
        output = self.capture()
        self.assertIn(f"CAPTURE:{self.example}:CURSOR:{len(self.example)}:END".encode(), output)
        self.assertFalse(self.marker.exists())

    def test_escape_preserves_buffer_and_cursor(self):
        self.send(b"original buffer\x02\x02\x18\x14")
        self.read_until(b"toolbox>")
        self.send(b"\x1b")
        time.sleep(0.25)
        self.assertIn(b"CAPTURE:original buffer:CURSOR:13:END", self.capture())
        self.assertFalse(self.marker.exists())

    def test_command_inserts_at_next_prompt(self):
        self.send("toolbox --pick picker_fixture\n")
        self.read_until(b"toolbox>")
        self.send(b"\r")
        time.sleep(0.15)
        self.assertIn(f"CAPTURE:{self.example}:CURSOR:{len(self.example)}:END".encode(), self.capture())
        self.assertFalse(self.marker.exists())

    def test_existing_binding_is_preserved(self):
        self.send("bindkey '^X^T' backward-char; _toolbox_init; _toolbox_init; bindkey '^X^T'\n")
        self.read_until(b'"^X^T" backward-char')

    def test_catalog_widget_preserves_multiline_and_trailing_newlines(self):
        self.send(b"old buffer\x18\x14")
        self.read_until(b"toolbox>")
        self.send("multilinefixture")
        self.drain()
        self.send(b"\r")
        time.sleep(0.15)
        output = self.capture().replace(b"\r\n", b"\n")
        self.assertIn(f"CAPTURE:{self.catalog_example}:CURSOR:{len(self.catalog_example)}:END".encode(), output)
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.directory / "NEVER").exists())

    def test_catalog_command_inserts_exact_text_at_next_prompt(self):
        self.send("toolbox --pick multilinefixture\n")
        self.read_until(b"toolbox>")
        self.send(b"\r")
        time.sleep(0.15)
        output = self.capture().replace(b"\r\n", b"\n")
        self.assertIn(f"CAPTURE:{self.catalog_example}:CURSOR:{len(self.catalog_example)}:END".encode(), output)
        self.assertFalse((self.directory / "NEVER").exists())

    def test_history_widget_preserves_exact_multiline_text_without_execution(self):
        self.send(b"old buffer\x18\x14")
        self.read_until(b"toolbox>")
        self.send("localhistorysample")
        self.drain()
        self.send(b"\r")
        time.sleep(0.15)
        output = self.capture().replace(b"\r\n", b"\n")
        self.assertIn(f"CAPTURE:{self.history_example}:CURSOR:{len(self.history_example)}:END".encode(), output)
        self.assertFalse((self.directory / "NEVER").exists())

    def test_history_command_inserts_exact_text_at_next_prompt(self):
        self.send("toolbox --pick localhistorysample\n")
        self.read_until(b"toolbox>")
        self.send(b"\r")
        time.sleep(0.15)
        output = self.capture().replace(b"\r\n", b"\n")
        self.assertIn(f"CAPTURE:{self.history_example}:CURSOR:{len(self.history_example)}:END".encode(), output)
        self.assertFalse((self.directory / "NEVER").exists())

    def test_missing_fzf_leaves_original_buffer(self):
        self.send("path=(/usr/bin /bin); rehash\n")
        self.read_until(b"READY> ")
        self.send(b"original\x18\x14")
        self.read_until(b"fzf is required")
        self.assertIn(b"CAPTURE:original:CURSOR:8:END", self.capture())


if __name__ == "__main__":
    unittest.main()
