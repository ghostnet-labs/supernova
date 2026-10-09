#!/usr/bin/env python3
# setup-test: Toolbox secret gates
"""Credential values are synthesized at runtime, never stored as fixtures."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "dotfiles/lib"))
import toolbox_secrets as secrets

SAFE = {"command": "git status --short", "description": "Inspect local changes", "tags": ["git"]}


class SecretChecks(unittest.TestCase):
    def test_absent_scanner_blocks_without_printing_candidate(self):
        output = io.StringIO()
        with mock.patch.object(secrets.shutil, "which", return_value=None), contextlib.redirect_stderr(output), contextlib.redirect_stdout(output):
            with self.assertRaisesRegex(secrets.SecretScanError, "not installed"):
                secrets.scan_records([SAFE])
        self.assertEqual(output.getvalue(), "")

    def scanner_result(self, report, status=0, *, extra=None):
        def run(args, **kwargs):
            root = Path(kwargs["cwd"])
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            self.assertFalse(any(key.upper().startswith("GITLEAKS_") for key in kwargs["env"]))
            self.assertIn("--ignore-gitleaks-allow", args)
            self.assertIn("--redact=100", args)
            config = Path(args[args.index("--config") + 1])
            self.assertEqual(config.read_text(), "[extend]\nuseDefault = true\n")
            self.assertEqual(Path(args[args.index("--gitleaks-ignore-path") + 1]).read_text(), "")
            if report is not None:
                Path(args[args.index("--report-path") + 1]).write_text(report)
            if extra:
                extra(args)
            return subprocess.CompletedProcess(args, status)
        return run

    def test_config_environment_cannot_suppress_scanning(self):
        with mock.patch.dict(os.environ, {"GITLEAKS_CONFIG": "/ignored", "GITLEAKS_CONFIG_TOML": "disable everything", "GITLEAKS_EXTRA": "ignored"}), mock.patch.object(secrets.shutil, "which", return_value="/scanner"), mock.patch.object(secrets.subprocess, "run", side_effect=self.scanner_result("[]")):
            secrets.scan_records([SAFE])

    def test_missing_invalid_nonempty_or_failed_reports_block(self):
        for report, status in [(None, 0), ("not JSON", 0), ("null", 0), ("{}", 0), ("[{}]", 0), ("[]", 2)]:
            with self.subTest(report=report, status=status), mock.patch.object(secrets.shutil, "which", return_value="/scanner"), mock.patch.object(secrets.subprocess, "run", side_effect=self.scanner_result(report, status)):
                with self.assertRaises(secrets.SecretScanError):
                    secrets.scan_records([SAFE])

    def test_timeout_is_generic(self):
        with mock.patch.object(secrets.shutil, "which", return_value="/scanner"), mock.patch.object(secrets.subprocess, "run", side_effect=subprocess.TimeoutExpired("scanner", 1, output="sensitive diagnostic")):
            with self.assertRaises(secrets.SecretScanError) as caught:
                secrets.scan_records([SAFE])
            self.assertNotIn("sensitive", str(caught.exception))

    def test_serialized_and_decoded_multiline_values_are_both_scanned(self):
        command = "printf 'first\\n'\nprintf 'second\\n'"
        record = dict(SAFE, command=command, description="first line\nsecond line")
        def check_files(args):
            target = Path(args[2])
            self.assertEqual(json.loads((target / "records.jsonl").read_text()), record)
            self.assertIn(command, (target / "commands.txt").read_text())
            self.assertIn(record["description"], (target / "commands.txt").read_text())
        with mock.patch.object(secrets.shutil, "which", return_value="/scanner"), mock.patch.object(secrets.subprocess, "run", side_effect=self.scanner_result("[]", extra=check_files)):
            secrets.scan_records([record])

    def test_conservative_credentials_in_all_fields(self):
        literal = "unreviewed" + "-credential-value"
        values = ["export SERVICE_" + "TOKEN=" + literal,
                  "curl --password " + literal,
                  'curl -H "Authorization: Bearer ' + literal + '" https://example.test',
                  "curl https://user:" + literal + "@example.test"]
        for value in values:
            for field in ("command", "description", "tags"):
                record = dict(SAFE, **{field: [value] if field == "tags" else value})
                with self.subTest(field=field), self.assertRaises(secrets.SecretScanError) as caught:
                    secrets.scan_records([record])
                self.assertNotIn(literal, str(caught.exception))

    def test_inline_allow_comment_is_blocked(self):
        with self.assertRaisesRegex(secrets.SecretScanError, "suppression"):
            secrets.scan_records([dict(SAFE, command="git status # gitleaks:" + "allow")])

    def test_unknown_placeholders_are_not_broadly_allowlisted(self):
        with self.assertRaises(secrets.SecretScanError):
            secrets.scan_records([dict(SAFE, command="TOKEN=" + "MY_EXAMPLE_SECRET")])

    def test_program_specific_literal_password_options(self):
        literal = "runtime" + "-credential-value"
        credentials = "user:" + literal
        commands = [" ".join(parts) for parts in [
            ["curl", "-u", shlex.quote(credentials), "https://example.test"],
            ["curl", "--user=" + credentials, "https://example.test"],
            ["curl", "--proxy-user", shlex.quote(credentials), "https://example.test"],
            ["sshpass", "-p", shlex.quote(literal), "ssh", "example.test"],
            ["sshpass", "-p" + literal, "ssh", "example.test"],
            ["mysql", "-p" + literal],
            ["mysql", "--password", literal],
        ]]
        for command in commands:
            with self.subTest(command_type=command.split()[0]), self.assertRaises(secrets.SecretScanError):
                secrets.scan_records([dict(SAFE, command=command)])

    def test_password_option_placeholders_and_prompts(self):
        commands = ['curl --user "$USER:$PASSWORD" https://example.test',
                    'curl -u "username:${PASSWORD}" https://example.test',
                    'sshpass -p "$PASSWORD" ssh example.test',
                    'mysql -p"${PASSWORD}"', 'mysql -p database_name',
                    'curl --user username https://example.test', 'printf -pvalue']
        with mock.patch.object(secrets, "_scan"):
            for command in commands:
                secrets.scan_records([dict(SAFE, command=command)])

    def test_nested_json_credential_strings(self):
        literal = "runtime" + "-credential-value"
        payload = json.dumps({"payload": json.dumps({"password": literal})})
        command = "curl --data " + shlex.quote(payload) + " https://example.test"
        with self.assertRaises(secrets.SecretScanError):
            secrets.scan_records([dict(SAFE, command=command)])

    @unittest.skipUnless(shutil.which("gitleaks"), "real Gitleaks is not installed")
    def test_real_scanner_accepts_environment_placeholders(self):
        secrets.scan_records([dict(SAFE, command='curl -H "Authorization: Bearer ${SERVICE_TOKEN}" https://example.test')])
        secrets.scan_records([dict(SAFE, command="curl --password '${PASSWORD}' https://example.test")])

    @unittest.skipUnless(shutil.which("gitleaks"), "real Gitleaks is not installed")
    def test_real_scanner_finds_synthetic_key_in_description_and_tags(self):
        synthetic = "gh" + "p_" + "0123456789" * 3 + "ABCDEF"
        for field in ("command", "description", "tags"):
            value = "printf " + synthetic
            with self.subTest(field=field), self.assertRaises(secrets.SecretScanError):
                secrets.scan_records([dict(SAFE, **{field: [value] if field == "tags" else value})])

    @unittest.skipUnless(shutil.which("gitleaks"), "real Gitleaks is not installed")
    def test_real_scanner_finds_decoded_multiline_private_key(self):
        import base64
        body = base64.b64encode(bytes(range(64))).decode()
        key = "-----BEGIN " + "RSA PRIVATE KEY-----\n" + body + "\n-----END " + "RSA PRIVATE KEY-----"
        with self.assertRaises(secrets.SecretScanError):
            secrets.scan_records([dict(SAFE, command="printf '" + key + "'")])

    def test_staged_catalog_reads_index_instead_of_working_tree(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            catalog = root / "dotfiles/toolbox/personal.jsonl"
            catalog.parent.mkdir(parents=True)
            catalog.write_text(json.dumps(SAFE) + "\n")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            catalog.write_text("invalid working tree JSON")
            with mock.patch.object(secrets, "_scan") as scan, mock.patch.object(secrets, "scan_records") as records:
                secrets.scan_staged(root)
            scan.assert_called_once_with("git", root.resolve(), staged=True)
            records.assert_called_once_with([SAFE])

    @unittest.skipUnless(shutil.which("gitleaks"), "real Gitleaks is not installed")
    def test_real_staged_scan_and_complete_catalog_guard(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            catalog = root / "dotfiles/toolbox/personal.jsonl"
            catalog.parent.mkdir(parents=True)
            catalog.write_text(json.dumps(SAFE) + "\n")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            secrets.scan_staged(root)
            catalog.write_text('{"command":"first","command":"second"}\n')
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            with self.assertRaisesRegex(secrets.SecretScanError, "invalid JSON"):
                secrets.scan_staged(root)


if __name__ == "__main__":
    unittest.main()
