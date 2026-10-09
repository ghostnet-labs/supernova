#!/usr/bin/env python3
# setup-test: Toolbox live Atuin history
"""Keep local history complete, scoped, read-only, and inert during discovery."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"dotfiles/lib/{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


HISTORY = module("toolbox_history")
TOOLBOX = module("toolbox")


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="toolbox history ")
        self.directory = Path(self.temporary.name)
        self.environment = {"HOME": str(self.directory), "XDG_DATA_HOME": str(self.directory / "data"),
                            "XDG_CONFIG_HOME": str(self.directory / "config"), "WORK_ENV": "false",
                            "JOB": "fixture", "SETUP_DIR": str(self.directory / "setup")}
        (self.directory / "setup").mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def seed(self, scope, commands):
        path = self.directory / "data/atuin/scopes" / scope / "history.db"
        path.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.closing(sqlite3.connect(path)) as connection, connection:
            connection.execute("CREATE TABLE history (id INTEGER PRIMARY KEY, command TEXT, deleted_at TEXT)")
            connection.executemany("INSERT INTO history(command) VALUES(?)", [(command,) for command in commands])
        return path

    def load(self, work=False):
        return HISTORY.load_history_records(dict(self.environment, WORK_ENV=str(work).lower()))

    def test_personal_never_opens_work_or_stale_override(self):
        self.seed("personal", ["personal fixture"])
        work = self.seed("work-fixture", ["work fixture"])
        work.write_bytes(b"private corrupt work database")
        self.environment.update(ATUIN_DB_PATH=str(work), JOB="../../invalid")
        connect = sqlite3.connect
        with mock.patch.object(HISTORY.sqlite3, "connect", wraps=connect) as opened:
            rows, notices = self.load()
        self.assertEqual([row["invocation"] for row in rows], ["personal fixture"])
        self.assertEqual(notices, [])
        self.assertEqual(opened.call_count, 1)
        self.assertIn("/personal/history.db?mode=ro", opened.call_args.args[0])

    def test_work_includes_personal_and_active_job_only(self):
        self.seed("personal", ["shared fixture"])
        self.seed("work-fixture", ["shared fixture", "work fixture"])
        inactive = self.seed("work-other", ["inactive fixture"])
        inactive.write_bytes(b"unreadable inactive database")
        rows, notices = self.load(work=True)
        self.assertEqual([row["source"] for row in rows], ["home", "fixture", "fixture"])
        self.assertEqual(notices, [])
        self.assertEqual(len({row["name"] for row in rows}), 3)

    def test_exact_variants_deduplicate_without_normalization(self):
        commands = ["", "", "echo fixture", "echo fixture", " echo fixture", "echo  fixture", "ECHO fixture",
                    "printf fixture\n", "printf fixture\n\n", "printf 'fixture'", "printf \"fixture\""]
        path = self.seed("personal", commands + ["deleted fixture"])
        with contextlib.closing(sqlite3.connect(path)) as connection, connection:
            connection.execute("UPDATE history SET deleted_at='deleted' WHERE command='deleted fixture'")
        rows, notices = self.load()
        self.assertEqual({row["invocation"] for row in rows}, set(commands))
        self.assertEqual(len(rows), len(set(commands)))
        self.assertTrue(all(row["examples"] == [row["invocation"]] for row in rows))
        self.assertEqual(notices, [])
        again, _ = self.load()
        self.assertEqual([row["name"] for row in rows], [row["name"] for row in again])
        self.assertTrue(all(len(row["name"].rsplit(":", 1)[1]) == 16 for row in rows))

    def test_short_digest_collision_falls_back_to_full_unique_names(self):
        self.seed("personal", ["first fixture", "second fixture"])
        sha256 = HISTORY.hashlib.sha256

        def collision(value):
            digest = "0" * 16 + sha256(value).hexdigest()[16:]
            return mock.Mock(hexdigest=lambda: digest)

        with mock.patch.object(HISTORY.hashlib, "sha256", side_effect=collision):
            rows, _ = self.load()
        self.assertEqual(len({row["name"] for row in rows}), 2)
        self.assertTrue(all(len(row["name"].rsplit(":", 1)[1]) == 64 for row in rows))

    def test_missing_database_does_not_create_state(self):
        before = list(self.directory.rglob("*"))
        self.assertEqual(self.load(), ([], []))
        self.assertEqual(list(self.directory.rglob("*")), before)

    def test_readonly_uri_query_only_and_unchanged_database(self):
        path = self.seed("personal", ["readonly fixture"])
        before, modified = path.read_bytes(), path.stat().st_mtime_ns
        files = set(self.directory.rglob("*"))
        connect, queries = sqlite3.connect, []

        def traced(*args, **kwargs):
            self.assertIn("?mode=ro", args[0])
            self.assertTrue(kwargs["uri"])
            connection = connect(*args, **kwargs)
            connection.set_trace_callback(queries.append)
            return connection

        with mock.patch.object(HISTORY.sqlite3, "connect", side_effect=traced):
            self.load()
        self.assertIn("PRAGMA query_only=ON", queries)
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(path.stat().st_mtime_ns, modified)
        self.assertEqual(set(self.directory.rglob("*")), files)

    def test_corrupt_or_unsupported_database_reports_safe_error(self):
        path = self.seed("personal", ["private fixture contents"])
        path.write_bytes(b"private fixture contents")
        with self.assertRaisesRegex(HISTORY.HistoryError, "Could not read personal") as error:
            self.load()
        self.assertNotIn("private fixture contents", str(error.exception))
        path.unlink()
        with contextlib.closing(sqlite3.connect(path)) as connection, connection:
            connection.execute("CREATE TABLE unrelated(value TEXT)")
        with self.assertRaisesRegex(HISTORY.HistoryError, "Unsupported Atuin history schema"):
            self.load()

    def test_scope_symlinks_cannot_redirect_personal_into_work(self):
        work = self.seed("work-fixture", ["work fixture"])
        personal = work.parent.parent / "personal"
        personal.symlink_to(work.parent, target_is_directory=True)
        with self.assertRaisesRegex(HISTORY.HistoryError, "symbolic links"):
            self.load()

    def test_invalid_scope_rejected_only_when_work_is_active(self):
        self.environment["JOB"] = "../../outside"
        self.assertEqual(self.load(), ([], []))
        with self.assertRaisesRegex(HISTORY.HistoryError, "valid JOB"):
            self.load(work=True)

    def test_pathological_fields_have_explicit_content_free_notices(self):
        path = self.seed("personal", ["normal fixture", "nul\0fixture", "x" * (HISTORY.MAX_COMMAND_BYTES + 1)])
        with contextlib.closing(sqlite3.connect(path)) as connection, connection:
            connection.execute("INSERT INTO history(command) VALUES(CAST(X'FF' AS TEXT))")
            connection.execute("INSERT INTO history(command) VALUES(NULL)")
        rows, notices = self.load()
        self.assertEqual([row["invocation"] for row in rows], ["normal fixture"])
        self.assertEqual(len(notices), 3)
        self.assertIn("omitted 2 records invalid text", " ".join(notices))
        self.assertIn("larger than 1 MiB", " ".join(notices))
        self.assertIn("containing NUL bytes", " ".join(notices))
        self.assertNotIn("normal fixture", " ".join(notices))

    def test_no_silent_row_cap_and_new_commands_appear_immediately(self):
        path = self.seed("personal", [f"printf fixture-{index}" for index in range(6501)])
        rows, notices = self.load()
        self.assertEqual(len(rows), 6501)
        self.assertEqual(notices, [])
        with contextlib.closing(sqlite3.connect(path)) as connection, connection:
            connection.execute("INSERT INTO history(command) VALUES('printf newly-added-fixture')")
        updated, _ = self.load()
        self.assertEqual(len(updated), 6502)

    def test_control_text_is_preserved_in_data_but_sanitized_on_display(self):
        command = "printf '\x1b[31mfixture\r'\n\n"
        self.seed("personal", [command])
        rows, _ = self.load()
        self.assertEqual(rows[0]["invocation"], command)
        self.assertNotIn("\x1b", TOOLBOX.describe(rows[0]))
        self.assertNotIn("\r", TOOLBOX.describe(rows[0]))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            TOOLBOX.render_picker(rows, self.directory)
        self.assertNotIn("\x1b", output.getvalue())
        self.assertNotIn("\r", output.getvalue())
        self.assertEqual(TOOLBOX.picker_text(self.directory, "1", "select"), command)

    def test_renderer_filters_history_and_does_not_execute_it(self):
        marker = self.directory / "NEVER"
        command = f"printf historyneedle; $(touch '{marker}'); `touch '{marker}'`\n\n"
        self.seed("personal", [command, "printf unrelated"])
        environment = dict(os.environ, **self.environment)
        result = subprocess.run(["python3", "-I", "-S", str(ROOT / "dotfiles/lib/toolbox.py"), "json",
                                 "historyneedle"], input="", text=True, capture_output=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)["commands"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["kind"], "history")
        self.assertEqual(rows[0]["invocation"], command)
        self.assertFalse(marker.exists())

    def test_renderer_puts_helpers_first_and_table_sanitizes_history(self):
        self.seed("personal", ["printf 'displayneedle\x1b[31m'\nnext line"])
        snapshot = "\0".join(["work_fixture", "fixture", "function", "/missing", "function", "/missing", ""])
        environment = dict(os.environ, **self.environment)
        invocation = ["python3", "-I", "-S", str(ROOT / "dotfiles/lib/toolbox.py")]
        result = subprocess.run([*invocation, "json"], input=snapshot, text=True,
                                capture_output=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(result.stdout)["commands"]
        self.assertEqual([row["kind"] for row in rows], ["function", "history"])
        table = subprocess.run([*invocation, "table", "displayneedle"], input=snapshot, text=True,
                               capture_output=True, env=environment)
        self.assertEqual(table.returncode, 0, table.stderr)
        self.assertIn("displayneedle", table.stdout)
        self.assertNotIn("\x1b", table.stdout)
        self.assertEqual(len(table.stdout.splitlines()), 2)

    def test_json_surfaces_omissions_and_corruption_without_history_contents(self):
        path = self.seed("personal", ["bad\0private fixture"])
        environment = dict(os.environ, **self.environment)
        invocation = ["python3", "-I", "-S", str(ROOT / "dotfiles/lib/toolbox.py"), "json"]
        result = subprocess.run(invocation, input="", text=True, capture_output=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["warnings"]), 1)
        self.assertIn("containing NUL bytes", result.stderr)
        path.write_bytes(b"private broken database fixture")
        broken = subprocess.run(invocation, input="", text=True, capture_output=True, env=environment)
        self.assertNotEqual(broken.returncode, 0)
        self.assertIn("Could not read personal Atuin history", broken.stderr)
        self.assertNotIn("private", broken.stdout + broken.stderr)

    def test_picker_uses_one_private_file_and_validates_numeric_selection(self):
        self.seed("personal", ["printf 'single fixture'", "printf 'multiline\nfixture'\n\n"])
        rows, _ = self.load()
        with contextlib.redirect_stdout(io.StringIO()):
            TOOLBOX.render_picker(rows * 3500, self.directory)
        files = list(self.directory.glob("picker*"))
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(TOOLBOX.picker_text(self.directory, "7000", "select"), rows[1]["invocation"])
        for number in ("../1", "1;touch NEVER", "-1", "$(touch NEVER)", "9999999999999999999999"):
            with self.subTest(number=number), self.assertRaises(ValueError):
                TOOLBOX.picker_text(self.directory, number, "select")
        with self.assertRaisesRegex(ValueError, "unknown picker"):
            TOOLBOX.picker_text(self.directory, "7001", "select")


if __name__ == "__main__":
    unittest.main()
