#!/usr/bin/env python3
# setup-test: Toolbox command catalog
"""Exercise catalog scope, history replay, publication gates, and exact commands."""

import concurrent.futures
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "dotfiles/lib/toolbox_catalog.py"
SPEC = importlib.util.spec_from_file_location("toolbox_catalog_tests_target", SCRIPT)
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.setup = self.directory / "setup"
        self.setup.mkdir()
        self.home = self.directory / "home"
        self.home.mkdir()
        self.env = {"HOME": str(self.home), "SETUP_DIR": str(self.setup),
                    "XDG_DATA_HOME": str(self.home / "data"),
                    "XDG_CONFIG_HOME": str(self.home / "config"), "WORK_ENV": "false"}
        self.context = catalog.Context(environ=self.env)
        self.scanner = mock.patch.object(catalog, "scan_records")
        self.scan = self.scanner.start()
        self.addCleanup(self.scanner.stop)

    @contextmanager
    def source(self, context=None):
        context = context or self.context
        path = context.history_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        database = sqlite3.connect(path)
        database.execute("CREATE TABLE IF NOT EXISTS history "
                         "(id TEXT PRIMARY KEY, timestamp INTEGER, command TEXT, deleted_at TEXT)")
        database.commit()
        try:
            yield database
            database.commit()
        finally:
            database.close()

    def add_history(self, records, context=None):
        with self.source(context) as history:
            history.executemany("INSERT INTO history(id,timestamp,command,deleted_at) VALUES(?,?,?,?)", records)

    def write_catalog(self, records, context=None):
        context = context or self.context
        path = context.catalog_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(record) + "\n" for record in records))
        return path

    def work(self, job="example"):
        return catalog.Context(environ={**self.env, "WORK_ENV": "true", "JOB": job})

    def test_help_and_empty_inventory_create_no_local_files(self):
        for options in (["--help"], ["save", "--help"], ["pending", "--json"]):
            result = subprocess.run([sys.executable, "-I", "-S", str(SCRIPT), *options],
                                    env=self.env, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(catalog.load_catalog_records(environ=self.env), [])
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertFalse((self.setup / "dotfiles").exists())

    def test_exact_dedup_preserves_whitespace_and_multiline(self):
        commands = ["printf '%s\\n' 'a b'", "printf  '%s\\n' 'a b'", "printf 'one'\nprintf 'two'\n"]
        for command in commands:
            catalog.save(self.context, command, "Example", ["shell"])
        catalog.save(self.context, commands[0], "Example", ["shell"])
        records = catalog.read_records(self.context)
        self.assertEqual([record["command"] for record in records], commands)
        self.assertEqual(len({record["id"] for record in records}), 3)
        self.assertEqual(set(records[0]), {"id", "scope", "command", "description", "tags"})
        inventory = catalog.load_catalog_records(environ=self.env)
        self.assertEqual(inventory[2]["examples"], [commands[2]])
        self.assertEqual(inventory[0]["kind"], "catalog")
        self.assertEqual(inventory[0]["source"], "home")

    def test_collect_bounded_replay_old_timestamps_and_deleted_rows(self):
        self.add_history([("a", 100, "git status", None), ("b", 200, "git status", None),
                          ("c", 300, "git diff", None), ("deleted", 400, "deleted command", "today")])
        first = catalog.collect(self.context, 2)
        self.assertEqual(first, {"examined": 2, "added": 1, "more": True, "reset": False})
        second = catalog.collect(self.context, 2)
        self.assertEqual(second["added"], 1)
        self.assertFalse(second["more"])
        self.add_history([("old-import", 1, "git log", None)])
        self.assertEqual(catalog.collect(self.context)["added"], 1)
        self.assertEqual(catalog.collect(self.context)["examined"], 0)
        self.assertEqual({record["command"] for record in catalog.pending(self.context)},
                         {"git status", "git diff", "git log"})
        self.assertFalse(self.context.catalog_path().exists())

    def test_oversized_history_and_byte_budget_resume(self):
        self.add_history([("huge", 1, "x" * (catalog.MAX_COMMAND * 3), None),
                          ("valid", 2, "git status", None)])
        first = catalog.collect(self.context)
        self.assertEqual(first["examined"], 2)
        self.assertEqual(first["added"], 1)
        self.add_history([(str(i), i, "printf '" + str(i) + "x" * 200 + "'", None) for i in range(3, 10)])
        with mock.patch.object(catalog, "MAX_COLLECTION_BYTES", 500):
            second = catalog.collect(self.context, 5000)
            self.assertEqual(second["examined"], 2)
            self.assertTrue(second["more"])
            counts = [second["added"]]
            while second["more"]:
                second = catalog.collect(self.context, 5000)
                counts.append(second["added"])
        self.assertEqual(sum(counts), 7)
        self.assertEqual(len(catalog.pending(self.context)), 8)

    def test_null_source_id_does_not_break_next_incremental_collection(self):
        self.add_history([(None, 1, "malformed identifier", None)])
        self.assertEqual(catalog.collect(self.context)["added"], 0)
        self.assertEqual(catalog.collect(self.context)["examined"], 0)
        self.add_history([("valid", 2, "git status", None)])
        self.assertEqual(catalog.collect(self.context)["added"], 1)

    def test_review_displays_entire_long_command_before_accepting(self):
        command = "printf '" + "x" * 2000 + " tail-to-inspect'"
        self.add_history([("long", 1, command, None)])
        catalog.collect(self.context)
        with mock.patch.object(catalog.sys.stdin, "isatty", return_value=True), \
                mock.patch.object(catalog.sys.stdout, "isatty", return_value=True), \
                mock.patch("builtins.input", return_value="q"), mock.patch("builtins.print") as printed:
            catalog.review(self.context)
        output = "\n".join(str(call.args[0]) for call in printed.call_args_list)
        self.assertIn("tail-to-inspect", output)
        self.assertIn("truncated", catalog._preview(command))

    def test_cursor_reset_after_file_replacement_or_reused_rowids(self):
        self.add_history([("old", 100, "old command", None)])
        catalog.collect(self.context)
        path = self.context.history_path()
        path.rename(path.with_suffix(".old"))
        self.add_history([("new", 1, "new command", None)])
        replaced = catalog.collect(self.context)
        self.assertTrue(replaced["reset"])
        self.assertEqual(replaced["added"], 1)
        with self.source() as history:
            history.execute("DELETE FROM history")
            history.execute("INSERT INTO history VALUES('reused',0,'reused row',NULL)")
        reused = catalog.collect(self.context)
        self.assertTrue(reused["reset"])
        self.assertEqual(reused["added"], 1)

    def test_rejections_and_acceptance_survive_source_rescan(self):
        self.add_history([("a", 1, "git status", None), ("b", 2, "git diff", None)])
        catalog.collect(self.context)
        entries = catalog.pending(self.context)
        catalog.reject(self.context, entries[0]["id"])
        catalog.accept(self.context, entries[1]["id"], "Inspect changes", command="git diff --stat")
        self.assertEqual(catalog.pending(self.context), [])
        with self.context.state() as state:
            state.execute("DELETE FROM cursor")
        self.assertEqual(catalog.collect(self.context)["added"], 0)
        self.assertEqual(catalog.read_records(self.context)[0]["command"], "git diff --stat")

    def test_existing_catalog_omitted_from_candidates(self):
        record = catalog.make_record("personal", "git status", "Inspect checkout")
        self.write_catalog([record])
        self.add_history([("existing", 1, "git status", None)])
        self.assertEqual(catalog.collect(self.context)["added"], 0)
        self.assertEqual(catalog.pending(self.context), [])

    def test_personal_never_resolves_work_catalog(self):
        config = self.home / "config/toolbox/config.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"catalogs": {"work-example": {"malformed": "do not inspect"}}}))
        personal = catalog.make_record("personal", "git status", "Checkout")
        self.write_catalog([personal])
        with mock.patch.object(Path, "open", wraps=None) as opened:
            opened.side_effect = AssertionError("No file should be opened in disallowed scope")
            with self.assertRaises(catalog.CatalogError):
                catalog.Context(environ=self.env, scope="work-example")
        self.assertEqual(catalog.load_catalog_records(environ=self.env)[0]["scope"], "personal")
        self.assertFalse((self.home / "data").exists())

    def test_scope_specific_history_and_inventory(self):
        work = self.work()
        personal = catalog.make_record("personal", "git status", "Checkout")
        work_record = catalog.make_record("work-example", "synthetic_job_tool", "Work fixture")
        self.write_catalog([personal])
        self.write_catalog([work_record], work)
        self.add_history([("p", 1, "personal candidate", None)])
        self.add_history([("w", 1, "work candidate", None)], work)
        catalog.collect(self.context)
        self.assertFalse((work.state_dir / "state.sqlite3").exists())
        catalog.collect(work)
        self.assertEqual([item["command"] for item in catalog.pending(self.context)], ["personal candidate"])
        self.assertEqual([item["command"] for item in catalog.pending(work)], ["work candidate"])
        self.assertEqual([item["scope"] for item in catalog.load_catalog_records(environ=work.env)],
                         ["personal", "work-example"])
        self.assertEqual(len(catalog.load_catalog_records(environ=self.env)), 1)
        for environment, scope in ((self.env, "work-example"), (work.env, "work-other"),
                                   ({**self.env, "WORK_ENV": "true", "JOB": "../escape"}, None)):
            with self.assertRaises(catalog.CatalogError):
                catalog.Context(environ=environment, scope=scope)

    def test_work_catalog_cannot_point_into_setup_including_alias(self):
        work = self.work()
        config = self.home / "config/toolbox/config.json"
        config.parent.mkdir(parents=True)
        alias = self.directory / "alias"
        alias.symlink_to(self.setup, target_is_directory=True)
        for target in (self.setup / "work.jsonl", alias / "work.jsonl"):
            config.write_text(json.dumps({"catalogs": {work.scope: str(target)}}))
            with self.assertRaises(catalog.CatalogError):
                work.catalog_path()
        self.assertFalse((self.setup / "work.jsonl").exists())

    def test_local_state_rejects_repo_location_and_symlinks(self):
        with self.assertRaises(catalog.CatalogError):
            catalog.Context(environ={**self.env, "XDG_DATA_HOME": str(self.setup)})
        self.context.state_dir.parent.mkdir(parents=True)
        self.context.state_dir.symlink_to(self.setup, target_is_directory=True)
        with self.assertRaises(catalog.CatalogError):
            catalog.Context(environ=self.env)

    def test_catalog_file_symlink_and_cross_scope_records_rejected(self):
        path = self.context.catalog_path()
        path.parent.mkdir(parents=True)
        path.symlink_to(self.directory / "elsewhere")
        with self.assertRaises(catalog.CatalogError):
            catalog.read_records(self.context)
        path.unlink()
        self.write_catalog([catalog.make_record("work-example", "synthetic", "Fixture")])
        with self.assertRaises(catalog.CatalogError):
            catalog.read_records(self.context)

    def test_bad_schema_duplicate_keys_ids_and_oversized_files_rejected(self):
        path = self.context.catalog_path()
        path.parent.mkdir(parents=True)
        record = catalog.make_record("personal", "git status", "Checkout")
        malformed = ["{", "{\"id\":1,\"id\":2}", json.dumps({**record, "timestamp": 0}),
                     json.dumps({**record, "id": "wrong"}), json.dumps(record) + "\n" + json.dumps(record),
                     "x" * (catalog.MAX_CATALOG + 1)]
        for content in malformed:
            path.write_text(content)
            with self.subTest(content_length=len(content)), self.assertRaises(catalog.CatalogError):
                catalog.read_records(self.context)
        for command in ("", "\x1b[31m", "x" * (catalog.MAX_COMMAND + 1), "nul\0byte"):
            with self.assertRaises(catalog.CatalogError):
                catalog.save(self.context, command, "Invalid")
        self.scan.assert_not_called()

    def test_scanner_failure_changes_neither_catalog_nor_pending_status(self):
        existing = catalog.make_record("personal", "git status", "Checkout")
        path = self.write_catalog([existing])
        before = path.read_bytes()
        self.add_history([("a", 1, "candidate command", None)])
        catalog.collect(self.context)
        candidate = catalog.pending(self.context)[0]
        self.scan.side_effect = catalog.CatalogError("Secret scan blocked this write.")
        with self.assertRaises(catalog.CatalogError):
            catalog.accept(self.context, candidate["id"], "Review candidate")
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(catalog.pending(self.context), [candidate])
        checked = self.scan.call_args.args[0]
        self.assertEqual(checked[0], existing)
        self.assertEqual(checked[1]["command"], candidate["command"])
        self.assertEqual(list(path.parent.glob(".catalog-*")), [])

    def test_missing_scanner_fails_closed(self):
        self.scanner.stop()
        with mock.patch.object(catalog.importlib.util, "spec_from_file_location", side_effect=FileNotFoundError):
            with self.assertRaises(catalog.CatalogError):
                catalog.save(self.context, "git status", "Inspect checkout")
        self.assertFalse(self.context.catalog_path().exists())

    def test_failed_atomic_replace_preserves_previous_catalog(self):
        path = self.write_catalog([catalog.make_record("personal", "git status", "Checkout")])
        original = path.read_bytes()
        with mock.patch.object(catalog.os, "replace", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                catalog.save(self.context, "git diff", "Changes")
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(list(path.parent.glob(".catalog-*")), [])

    def test_permissions_and_concurrent_writers_keep_both_records(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(catalog.save, catalog.Context(environ=self.env),
                                   command, "Concurrent fixture") for command in ("git status", "git diff")]
            for future in futures:
                future.result(timeout=15)
        self.assertEqual(len(catalog.read_records(self.context)), 2)
        for path in (self.context.state_root, self.context.state_dir):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700)
        for path in (self.context.catalog_path(), self.context.state_dir / "state.sqlite3",
                     *self.context.state_root.glob("catalog-*.lock")):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_collect_ignores_stale_external_atuin_override(self):
        env = {**self.env, "ATUIN_DB_PATH": str(self.directory / "work-history.db")}
        context = catalog.Context(environ=env)
        self.assertEqual(catalog.collect(context)["examined"], 0)
        self.assertFalse(context.state_dir.exists())

    def test_unsupported_history_schema_fails_without_catalog(self):
        path = self.context.history_path()
        path.parent.mkdir(parents=True)
        connection = sqlite3.connect(path)
        try:
            connection.execute("CREATE TABLE history(unrecognized TEXT)")
            connection.commit()
        finally:
            connection.close()
        with self.assertRaises(catalog.CatalogError):
            catalog.collect(self.context)
        self.assertFalse(self.context.catalog_path().exists())

    def test_cli_does_not_execute_command_text_or_start_review_without_tty(self):
        marker = self.directory / "must-not-exist"
        command = "touch " + str(marker)
        self.add_history([("inert", 1, command, None)])
        result = subprocess.run([sys.executable, "-I", "-S", str(SCRIPT), "collect", "--quiet"],
                                env=self.env, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("queued 1 new commands", result.stdout)
        self.assertNotIn(command, result.stdout)
        self.assertFalse(marker.exists())
        result = subprocess.run([sys.executable, "-I", "-S", str(SCRIPT), "review"],
                                env=self.env, text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interactive terminal", result.stderr)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
