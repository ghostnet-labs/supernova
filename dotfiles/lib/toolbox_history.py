"""Read complete, scoped local Atuin history without changing or executing it."""

import hashlib
import os
from pathlib import Path
import re
import sqlite3


MAX_COMMAND_BYTES = 1024 * 1024
JOB_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


class HistoryError(ValueError):
    """A safe error that never includes history contents."""


def scoped_paths(environ=None):
    env = os.environ if environ is None else environ
    home = Path(env.get("HOME") or Path.home())
    data = Path(env.get("XDG_DATA_HOME") or home / ".local/share")
    if not data.is_absolute():
        raise HistoryError("Atuin history requires an absolute XDG_DATA_HOME or HOME.")
    scopes = ["personal"]
    if env.get("WORK_ENV", "false") == "true":
        job = env.get("JOB", "")
        if not JOB_PATTERN.fullmatch(job):
            raise HistoryError("Work history requires a valid JOB identifier.")
        scopes.append("work-" + job)
    # ATUIN_DB_PATH may belong to another shell scope. Never consult it.
    return [(scope, data / "atuin/scopes" / scope / "history.db") for scope in scopes]


def _check_path(path):
    # A Personal path must not redirect into Work through a symbolic link.
    for component in (path, path.parent, path.parent.parent, path.parent.parent.parent):
        if component.is_symlink():
            raise HistoryError("Scoped Atuin history paths must not be symbolic links.")


def _read_scope(scope, path):
    _check_path(path)
    if not path.exists():
        return [], []
    records, notices, seen = [], [], set()
    omitted = {"larger than 1 MiB": 0, "invalid text": 0, "containing NUL bytes": 0}
    connection = None
    try:
        connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
        connection.execute("PRAGMA query_only=ON")
        connection.execute("PRAGMA temp_store=MEMORY")
        connection.execute("PRAGMA trusted_schema=OFF")
        columns = {row[1] for row in connection.execute("PRAGMA table_info(history)")}
        if "command" not in columns:
            raise HistoryError(f"Unsupported Atuin history schema for {scope}.")
        deleted = " WHERE deleted_at IS NULL" if "deleted_at" in columns else ""
        # Stream every row. Bound individual values before Python materializes
        # them, but never cap the number of commands or normalize their text.
        rows = connection.execute(
            f"SELECT typeof(command),substr(CAST(command AS BLOB),1,{MAX_COMMAND_BYTES + 1}) "
            f"FROM history{deleted}")
        for value_type, raw in rows:
            # SQLite returns NULL for substr of an empty BLOB. Empty shell
            # entries still belong to exact Atuin history coverage.
            if value_type == "text" and raw is None:
                raw = b""
            if value_type != "text" or not isinstance(raw, bytes):
                omitted["invalid text"] += 1
                continue
            if len(raw) > MAX_COMMAND_BYTES:
                omitted["larger than 1 MiB"] += 1
                continue
            if b"\0" in raw:
                omitted["containing NUL bytes"] += 1
                continue
            if raw in seen:
                continue
            seen.add(raw)
            try:
                command = raw.decode("utf-8")
            except UnicodeError:
                omitted["invalid text"] += 1
                continue
            identifier = hashlib.sha256(scope.encode() + b"\0" + raw).hexdigest()
            records.append({
                "name": f"history:{scope}:{identifier}",
                "source": "home" if scope == "personal" else scope[5:],
                "kind": "history", "location": str(path),
                "description": "History: " + command if command else "History: empty command",
                "categories": ["history", "atuin"], "argument_hint": "",
                "examples": [command], "invocation": command, "shadowed": [],
            })
    except (OSError, sqlite3.Error) as error:
        raise HistoryError(f"Could not read {scope} Atuin history; no history was changed.") from error
    finally:
        if connection is not None:
            connection.close()
    for reason, count in omitted.items():
        if count:
            notices.append(f"{scope} Atuin history: omitted {count} records {reason}.")
    # Compact IDs keep the table usable. In the unlikely event of a prefix
    # collision, retain both full digests instead of selecting ambiguously.
    prefixes = {}
    for record in records:
        prefix, digest = record["name"].rsplit(":", 1)
        short = prefix + ":" + digest[:16]
        prefixes.setdefault(short, []).append(record)
    for short, group in prefixes.items():
        if len(group) == 1:
            group[0]["name"] = short
    return records, notices


def load_history_records(environ=None):
    """Return all distinct enabled-scope commands and explicit omission notices."""
    records, notices = [], []
    for scope, path in scoped_paths(environ):
        scope_records, scope_notices = _read_scope(scope, path)
        records.extend(scope_records)
        notices.extend(scope_notices)
    return records, notices
