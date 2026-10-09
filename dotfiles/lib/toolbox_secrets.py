#!/usr/bin/env python3
"""Fail-closed secret checks for reviewed command catalogs and staged changes.

Findings and scanner diagnostics never reach stdout/stderr. Scanner reports and
decoded commands exist only in a mode-0700 temporary directory, removed on exit.
This detects credentials, not all confidential information: human scope review
is still required for internal hostnames, project names, and personal data.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


SCAN_TIMEOUT = 30
MAX_SCAN_BYTES = 32 * 1024 * 1024


class SecretScanError(Exception):
    """A generic, safe-to-display failure; never includes candidate text."""


_PLACEHOLDER = re.compile(
    r"(?:\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}|"
    r"<[A-Z][A-Z0-9_ -]*>|\{\{[A-Z][A-Z0-9_]*\}\}|REPLACE_ME)\Z"
)
_ASSIGNMENT = re.compile(
    r"(?i)(?<![\w-])(?:[A-Z0-9_]*[_-])?"
    r"(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|credential)"
    r"(?:[_-][A-Z0-9_]+)?[\"']?\s*(?:=|:)\s*"
    r"(?:\"([^\"\r\n]*)\"|'([^'\r\n]*)'|([^\s;&|]+))"
)
_AUTH = re.compile(
    r"(?i)\b(?:authorization|proxy-authorization)\s*:\s*"
    r"(?:bearer|basic|token)\s+([^\s\"']+)"
)
_FLAG = re.compile(
    r"(?i)(?<!\S)--(?:password|passwd|token|api-key|secret|access-key)"
    r"(?:=|\s+)(?:\"([^\"\r\n]*)\"|'([^'\r\n]*)'|([^\s;&|]+))"
)
_URL_AUTH = re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://([^\s/@]+)@")


def _placeholder(value):
    return bool(_PLACEHOLDER.fullmatch(value.strip().strip("\"'")))


def _check_transport_options(words):
    """Recognize password-bearing options only for their specific programs."""
    programs = {"curl", "sshpass", "mysql", "mysqldump", "mysqladmin",
                "mariadb", "mariadb-dump", "mariadb-admin"}
    for index, word in enumerate(words):
        program = word.rsplit("/", 1)[-1]
        if program not in programs:
            continue
        for position in range(index + 1, len(words)):
            option = words[position]
            if option == "--" or option in {";", "&&", "||", "|", "&", "(", ")"}:
                break
            literal = None
            if program == "curl":
                if option in {"-u", "--user", "--proxy-user", "-U"}:
                    literal = words[position + 1] if position + 1 < len(words) else None
                elif option.startswith(("--user=", "--proxy-user=")):
                    literal = option.split("=", 1)[1]
                elif option.startswith(("-u", "-U")) and len(option) > 2:
                    literal = option[2:]
                # A username without ':' makes curl prompt for the password.
                if literal is not None:
                    literal = literal.split(":", 1)[1] if ":" in literal else None
            elif option == "-p" and program == "sshpass":
                literal = words[position + 1] if position + 1 < len(words) else None
            elif option.startswith("-p") and len(option) > 2:
                literal = option[2:]
            if literal and not _placeholder(literal):
                raise SecretScanError("Literal password option detected; replace it with an environment-variable placeholder.")


def _check_text(value, depth=0):
    if "gitleaks:allow" in value.lower():
        raise SecretScanError("Secret-scan suppression comments are not allowed in catalogs.")
    for pattern in (_ASSIGNMENT, _FLAG, _AUTH):
        for match in pattern.finditer(value):
            literal = next(item for item in match.groups() if item is not None)
            if literal and not _placeholder(literal):
                raise SecretScanError("Possible credential detected; replace it with an environment-variable placeholder.")
    for match in _URL_AUTH.finditer(value):
        if not all(_placeholder(part) for part in match.group(1).split(":")):
            raise SecretScanError("URL credentials detected; replace them with environment-variable placeholders.")
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        lexer.commenters = ""
        words = list(lexer)
    except ValueError:
        words = []
    _check_transport_options(words)
    # Shell quoting and JSON embedded inside JSON can hide credential assignment
    # syntax. Decode bounded string layers without evaluating any shell syntax.
    if depth < 5:
        for candidate in dict.fromkeys([value, *words]):
            try:
                decoded = json.loads(candidate)
            except (ValueError, TypeError):
                continue
            if isinstance(decoded, (dict, list)):
                serialized = json.dumps(decoded, ensure_ascii=False)
                if serialized != candidate:
                    _check_text(serialized, depth + 1)
                for inner in _strings(decoded):
                    _check_text(inner, depth + 1)
            elif isinstance(decoded, str) and decoded != candidate:
                _check_text(decoded, depth + 1)


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from _strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _strings(item)


def _private_write(path, text):
    with path.open("x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        stream.write(text)


def _scan(mode, target, *, staged=False):
    scanner = shutil.which("gitleaks")
    if not scanner:
        raise SecretScanError("gitleaks is not installed; secret checking needs gitleaks 8.29.0 or newer "
                              "(brew install gitleaks) before saving or committing.")
    scanner = str(Path(scanner).resolve())
    env = {key: value for key, value in os.environ.items() if not key.upper().startswith("GITLEAKS_")}
    try:
        with tempfile.TemporaryDirectory(prefix="toolbox-secret-scan-") as scratch:
            root = Path(scratch)
            config = root / "default-rules.toml"
            ignored = root / "empty-ignore"
            report = root / "report.json"
            _private_write(config, "[extend]\nuseDefault = true\n")
            _private_write(ignored, "")
            args = [scanner, mode]
            if staged:
                args += ["--pre-commit", "--staged"]
            args += [str(target), "--config", str(config),
                     "--gitleaks-ignore-path", str(ignored), "--ignore-gitleaks-allow",
                     "--redact=100", "--no-banner", "--no-color", "--log-level", "error",
                     "--report-format", "json", "--report-path", str(report),
                     "--exit-code", "1", "--timeout", str(SCAN_TIMEOUT),
                     "--max-decode-depth", "5", "--max-target-megabytes", "0"]
            result = subprocess.run(args, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=SCAN_TIMEOUT + 2, check=False)
            if not report.is_file() or report.stat().st_size > MAX_SCAN_BYTES:
                raise SecretScanError("Secret scanner did not produce a valid report; operation blocked.")
            findings = json.loads(report.read_text(encoding="utf-8"))
            if not isinstance(findings, list):
                raise SecretScanError("Secret scanner returned an invalid report; operation blocked.")
            if findings:
                raise SecretScanError("Secret scanner detected a possible secret; operation blocked. Review locally and replace sensitive values.")
            if result.returncode:
                raise SecretScanError("Secret scanner failed; operation blocked.")
    except SecretScanError:
        raise
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SecretScanError("Secret scanner could not complete; operation blocked.") from None


def scan_records(records):
    """Check the complete proposed catalog before writing accepted records.

    The JSON representation and every decoded string are scanned, including
    multiline shell commands whose escaping can defeat a JSON-only scanner.
    """
    try:
        records = list(records)
        if any(not isinstance(record, dict) for record in records):
            raise ValueError("invalid record")
        serialized = "\n".join(json.dumps(record, ensure_ascii=False, allow_nan=False) for record in records) + "\n"
        decoded = "\n\n".join(_strings(records)) + "\n"
        if len(serialized.encode("utf-8")) + len(decoded.encode("utf-8")) > MAX_SCAN_BYTES:
            raise SecretScanError("Catalog exceeds the secret scanner size limit; operation blocked.")
        for value in _strings(records):
            _check_text(value)
        with tempfile.TemporaryDirectory(prefix="toolbox-catalog-scan-") as scratch:
            root = Path(scratch)
            _private_write(root / "records.jsonl", serialized)
            _private_write(root / "commands.txt", decoded)
            _scan("dir", root)
    except SecretScanError:
        raise
    except (OSError, ValueError, TypeError, UnicodeError):
        raise SecretScanError("Catalog could not be checked safely; operation blocked.") from None


def _git(repo, args):
    try:
        result = subprocess.run(["git", "-C", str(repo), *args],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=SCAN_TIMEOUT, check=False)
        if result.returncode:
            raise SecretScanError("Could not read the staged catalog; commit blocked.")
        return result.stdout
    except (OSError, subprocess.SubprocessError):
        raise SecretScanError("Could not inspect staged changes; commit blocked.") from None


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def scan_staged(repo):
    """Scan staged changes plus complete index contents of staged catalogs."""
    repo = Path(repo).resolve()
    _scan("git", repo, staged=True)
    paths = _git(repo, ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z", "--"])
    for raw in paths.split(b"\0"):
        if not raw:
            continue
        path = os.fsdecode(raw)
        if not path.startswith("dotfiles/toolbox/") or not path.endswith(".jsonl"):
            continue
        raw_records = _git(repo, ["show", ":" + path])
        if len(raw_records) > MAX_SCAN_BYTES:
            raise SecretScanError("Staged catalog exceeds the scanner size limit; commit blocked.")
        try:
            records = [json.loads(line, object_pairs_hook=_unique_object)
                       for line in raw_records.decode("utf-8").splitlines() if line.strip()]
        except (ValueError, UnicodeError):
            raise SecretScanError("Staged catalog contains invalid JSON; commit blocked.") from None
        scan_records(records)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check complete staged command catalogs and staged changes for secrets.")
    parser.add_argument("--staged", metavar="REPOSITORY", required=True, help="scan the Git index using required Gitleaks checks")
    args = parser.parse_args(argv)
    try:
        scan_staged(args.staged)
    except SecretScanError as exc:
        print("pre-commit: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
