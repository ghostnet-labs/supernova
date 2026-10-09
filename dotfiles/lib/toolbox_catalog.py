"""Review reusable commands from local history before adding them to a catalog."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile

MAX_COMMAND = 32768
MAX_CATALOG = 8 * 1024 * 1024
MAX_RECORDS = 10000
MAX_CONFIG = 65536
MAX_COLLECTION_BYTES = 2 * 1024 * 1024
JOB_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


class CatalogError(ValueError):
    """A safe, user-readable failure that never includes command contents."""


def record_id(scope, command):
    return hashlib.sha256((scope + "\0" + command).encode("utf-8")).hexdigest()


def _text(value, maximum, allow_lines=False):
    if not isinstance(value, str) or not value.strip():
        raise CatalogError("A nonempty text value is required.")
    try:
        encoded = value.encode("utf-8")
    except UnicodeError as error:
        raise CatalogError("Text must be valid UTF-8.") from error
    if len(encoded) > maximum or any(
            (not char.isprintable()) and char not in ("\t\n" if allow_lines else "")
            for char in value):
        raise CatalogError("Text is too large or contains unsupported control characters.")
    return value


def make_record(scope, command, description, tags=()):
    _text(command, MAX_COMMAND, allow_lines=True)
    _text(description, 8192, allow_lines=True)
    if not isinstance(tags, (list, tuple)) or len(tags) > 20:
        raise CatalogError("Use at most 20 tags.")
    checked_tags = list(dict.fromkeys(_text(tag, 128) for tag in tags))
    return {"id": record_id(scope, command), "scope": scope, "command": command,
            "description": description, "tags": checked_tags}


def _inside(path, directory):
    return path == directory or directory in path.parents


def _absolute(value, label):
    if not isinstance(value, (str, os.PathLike)) or not str(value):
        raise CatalogError(f"{label} must be an absolute path.")
    path = Path(value)
    if not path.is_absolute():
        raise CatalogError(f"{label} must be an absolute path.")
    return path


def _no_link(path, boundary=None):
    """Reject links in managed paths without rejecting macOS's /var alias."""
    current = path
    while True:
        if current.is_symlink():
            raise CatalogError("A managed catalog or state path is a symbolic link.")
        if current == boundary or boundary is None or current.parent == current:
            break
        current = current.parent


def _json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogError("JSON contains duplicate keys.")
        result[key] = value
    return result


def _read_json(path, maximum):
    _no_link(path)
    try:
        with path.open("rb") as stream:
            data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise CatalogError("A catalog or configuration exceeds its size limit.")
        return json.loads(data, object_pairs_hook=_json_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CatalogError("A catalog or configuration contains invalid JSON.") from error


class Context:
    def __init__(self, setup_dir=None, environ=None, scope=None):
        self.env = os.environ if environ is None else environ
        home = _absolute(self.env.get("HOME", str(Path.home())), "HOME")
        self.setup = _absolute(setup_dir or self.env.get("SETUP_DIR") or
                               Path(__file__).resolve().parents[2], "SETUP_DIR").resolve()
        if not self.setup.is_dir():
            raise CatalogError("SETUP_DIR must be an existing directory.")
        self.data = _absolute(self.env.get("XDG_DATA_HOME") or home / ".local/share", "XDG_DATA_HOME")
        self.config = _absolute(self.env.get("XDG_CONFIG_HOME") or home / ".config", "XDG_CONFIG_HOME")
        active = "personal"
        if self.env.get("WORK_ENV", "false") == "true":
            job = self.env.get("JOB", "")
            if not JOB_PATTERN.fullmatch(job):
                raise CatalogError("Work mode requires a valid JOB identifier.")
            active = "work-" + job
        self.active = active
        self.scope = scope or active
        if self.scope not in {"personal", active}:
            raise CatalogError("The requested scope is not enabled in this shell.")
        self.state_root = self.data / "toolbox"
        self.state_dir = self.state_root / self.scope
        if _inside(self.state_dir.resolve(), self.setup):
            raise CatalogError("Local catalog state must remain outside the setup repository.")
        _no_link(self.state_dir, self.state_root)

    def catalog_path(self):
        default = (self.setup / "dotfiles/toolbox/personal.jsonl" if self.scope == "personal"
                   else self.state_dir / "catalog.jsonl")
        config_path = self.config / "toolbox/config.json"
        _no_link(config_path, self.config / "toolbox")
        if config_path.exists():
            config = _read_json(config_path, MAX_CONFIG)
            if not isinstance(config, dict) or set(config) - {"catalogs"}:
                raise CatalogError("Catalog configuration must contain only a catalogs mapping.")
            catalogs = config.get("catalogs", {})
            if not isinstance(catalogs, dict):
                raise CatalogError("Catalog configuration must contain a catalogs mapping.")
            # Only the enabled scope's value is inspected or resolved. Personal
            # execution never opens another scope's catalog or state database.
            default = catalogs.get(self.scope, default)
        path = _absolute(default, "Catalog location")
        _no_link(path)
        resolved = path.resolve()
        if self.scope != "personal" and _inside(resolved, self.setup):
            raise CatalogError("Work catalogs must remain outside the setup repository.")
        return path

    def history_path(self):
        # Do not trust ATUIN_DB_PATH: it may refer to the previous shell scope.
        return self.data / "atuin/scopes" / self.scope / "history.db"

    def ensure_state(self):
        _no_link(self.state_dir, self.state_root)
        for path in (self.state_root, self.state_dir):
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
            _no_link(path)
            path.chmod(0o700)

    @contextmanager
    def state(self):
        self.ensure_state()
        path = self.state_dir / "state.sqlite3"
        _no_link(path)
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags, 0o600)
        os.fchmod(fd, 0o600)
        os.close(fd)
        connection = sqlite3.connect(path, timeout=10)
        try:
            connection.execute("PRAGMA journal_mode=DELETE")
            connection.execute("PRAGMA busy_timeout=10000")
            connection.execute("CREATE TABLE IF NOT EXISTS candidates "
                               "(id TEXT PRIMARY KEY, command TEXT NOT NULL, "
                               "status TEXT NOT NULL CHECK(status IN ('pending','accepted','rejected')))")
            connection.execute("CREATE TABLE IF NOT EXISTS cursor "
                               "(source TEXT PRIMARY KEY, identity TEXT NOT NULL, "
                               "row_id INTEGER NOT NULL, anchor TEXT NOT NULL)")
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()
            # SQLite inherits mode from the private DB; the enclosing directory
            # protects journals even with an unusually permissive process umask.
            path.chmod(0o600)

    @contextmanager
    def catalog_lock(self):
        self.ensure_state()
        path = self.state_root / ("catalog-" + hashlib.sha256(
            str(self.catalog_path().resolve()).encode("utf-8")).hexdigest() + ".lock")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            os.fchmod(fd, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def read_records(context):
    path = context.catalog_path()
    if not path.exists():
        return []
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_CATALOG + 1)
        if len(data) > MAX_CATALOG:
            raise CatalogError("Catalog exceeds its size limit.")
        result = []
        ids = set()
        for line in data.decode("utf-8").splitlines():
            if not line.strip():
                continue
            record = json.loads(line, object_pairs_hook=_json_object)
            if (not isinstance(record, dict) or set(record) !=
                    {"id", "scope", "command", "description", "tags"} or record["scope"] != context.scope):
                raise CatalogError("Catalog record has an invalid schema or scope.")
            checked = make_record(record["scope"], record["command"], record["description"], record["tags"])
            if checked != record or record["id"] in ids:
                raise CatalogError("Catalog record has an invalid or duplicate ID.")
            result.append(record)
            ids.add(record["id"])
            if len(result) > MAX_RECORDS:
                raise CatalogError("Catalog contains too many records.")
        return result
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CatalogError("Catalog contains invalid JSONL.") from error


def load_catalog_records(setup_dir=None, environ=None, scope=None):
    """Return accepted records only; never collect history or create state."""
    context = Context(setup_dir, environ, scope)
    scopes = [context.scope] if scope else ["personal"] + (
        [context.active] if context.active != "personal" else [])
    output = []
    for selected in scopes:
        scoped = Context(setup_dir, environ, selected)
        path = scoped.catalog_path()
        for record in read_records(scoped):
            output.append({**record, "catalog_id": record["id"], "catalog_path": str(path),
                           "name": f"catalog:{selected}:{record['id'][:12]}",
                           "source": "home" if selected == "personal" else selected[5:],
                           "kind": "catalog", "location": str(path),
                           "categories": ["catalog", *record["tags"]], "argument_hint": "",
                           "examples": [record["command"]], "invocation": record["command"],
                           "shadowed": []})
    return output


def scan_records(records):
    """Load only our sibling scanner, also when Python runs with -I -S."""
    try:
        path = Path(__file__).with_name("toolbox_secrets.py")
        spec = importlib.util.spec_from_file_location("toolbox_catalog_secrets", path)
        scanner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(scanner)
        scanner.scan_records(records)
    except Exception as error:
        raise CatalogError("Secret scan blocked this write; inspect scanner availability and review the command.") from error


def write_records(context, records):
    if len(records) > MAX_RECORDS:
        raise CatalogError("Catalog contains too many records.")
    data = "".join(json.dumps(record, ensure_ascii=True, sort_keys=True) + "\n" for record in records).encode("utf-8")
    if len(data) > MAX_CATALOG:
        raise CatalogError("Catalog exceeds its size limit.")
    path = context.catalog_path()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Full resulting catalog, including decoded multiline fields, is scanned
    # immediately before the atomic write. Scanner failure never changes it.
    scan_records(records)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb", dir=path.parent, prefix=".catalog-", delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        _no_link(path)
        os.replace(temporary, path)
        temporary = None
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def save(context, command, description, tags=(), candidate_id=None):
    record = make_record(context.scope, command, description, tags)
    with context.catalog_lock():
        records = read_records(context)
        original = next((item for item in records if item["id"] == record["id"]), None)
        if original is not None and original != record:
            raise CatalogError("This exact command is already cataloged; edit its catalog record deliberately.")
        if original is None:
            records.append(record)
        with context.state() as state:
            if candidate_id:
                candidate = state.execute("SELECT status FROM candidates WHERE id=?", (candidate_id,)).fetchone()
                if candidate != ("pending",):
                    raise CatalogError("The candidate is no longer pending.")
            write_records(context, records)
            state.execute("INSERT INTO candidates(id,command,status) VALUES(?,?,'accepted') "
                          "ON CONFLICT(id) DO UPDATE SET status='accepted'", (record["id"], command))
            if candidate_id:
                state.execute("UPDATE candidates SET status='accepted' WHERE id=?", (candidate_id,))
    return record["id"]


def collect(context, limit=200):
    if not 1 <= limit <= 5000:
        raise CatalogError("Collection limit must be between 1 and 5000.")
    source = context.history_path()
    _no_link(source, context.data / "atuin/scopes" / context.scope)
    if not source.exists():
        return {"examined": 0, "added": 0, "more": False, "reset": False}
    info = source.stat()
    identity = f"{info.st_dev}:{info.st_ino}"
    known = {record["id"] for record in read_records(context)}
    try:
        history = sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)
        history.execute("PRAGMA query_only=ON")
        history.execute("BEGIN")
        columns = {row[1] for row in history.execute("PRAGMA table_info(history)")}
        if not {"id", "command"}.issubset(columns):
            raise CatalogError("Unsupported Atuin history schema.")
        with context.state() as state:
            old = state.execute("SELECT identity,row_id,anchor FROM cursor WHERE source=?", (str(source),)).fetchone()
            cursor = old[1] if old else 0
            anchor_row = history.execute(
                "SELECT substr(CAST(id AS BLOB),1,257) FROM history WHERE rowid=?", (cursor,)
            ).fetchone() if cursor else None
            anchor = hashlib.sha256(anchor_row[0] or b"").hexdigest() if anchor_row else None
            reset = bool(old and (old[0] != identity or (cursor and anchor != old[2])))
            if reset:
                cursor = 0
            deleted = "deleted_at IS NOT NULL" if "deleted_at" in columns else "0"
            # Bound values inside SQLite before they reach Python. Streaming also
            # caps each batch's total bytes, independently of its row limit.
            rows = history.execute(
                f"SELECT rowid,substr(CAST(id AS BLOB),1,257),"
                f"substr(CAST(command AS BLOB),1,{MAX_COMMAND + 1}),{deleted} FROM history "
                "WHERE rowid>? ORDER BY rowid LIMIT ?", (cursor, limit + 1))
            added = examined = byte_count = 0
            more = False
            anchor_id = old[2] if old and not reset else ""
            for row_id, source_id, raw_command, deleted_at in rows:
                source_id = source_id or b""
                raw_command = raw_command or b""
                row_bytes = len(raw_command) + len(source_id)
                if examined >= limit or (examined and byte_count + row_bytes > MAX_COLLECTION_BYTES):
                    more = True
                    break
                byte_count += row_bytes
                examined += 1
                cursor = row_id
                anchor_id = hashlib.sha256(source_id).hexdigest()
                try:
                    command = raw_command.decode("utf-8")
                    _text(command, MAX_COMMAND, allow_lines=True)
                except (CatalogError, UnicodeError):
                    continue
                if deleted_at or not source_id or len(source_id) > 256:
                    continue
                identifier = record_id(context.scope, command)
                if identifier in known:
                    continue
                inserted = state.execute("INSERT OR IGNORE INTO candidates(id,command,status) "
                                         "VALUES(?,?,'pending')", (identifier, command))
                added += inserted.rowcount
            state.execute("INSERT INTO cursor(source,identity,row_id,anchor) VALUES(?,?,?,?) "
                          "ON CONFLICT(source) DO UPDATE SET identity=excluded.identity,"
                          "row_id=excluded.row_id,anchor=excluded.anchor",
                          (str(source), identity, cursor, anchor_id))
        return {"examined": examined, "added": added, "more": more, "reset": reset}
    except sqlite3.Error as error:
        raise CatalogError("Could not read scoped Atuin history or local catalog state.") from error
    finally:
        if "history" in locals():
            history.close()


def pending(context):
    path = context.state_dir / "state.sqlite3"
    _no_link(path, context.state_root)
    if not path.exists():
        return []
    with context.state() as state:
        return [{"id": row[0], "command": row[1], "scope": context.scope}
                for row in state.execute("SELECT id,command FROM candidates WHERE status='pending' ORDER BY rowid LIMIT 1000")]


def reject(context, identifier):
    with context.state() as state:
        changed = state.execute("UPDATE candidates SET status='rejected' WHERE id=? AND status='pending'", (identifier,))
        if not changed.rowcount:
            raise CatalogError("No pending candidate matches that ID.")


def accept(context, identifier, description, tags=(), command=None):
    with context.state() as state:
        row = state.execute("SELECT command FROM candidates WHERE id=? AND status='pending'", (identifier,)).fetchone()
    if row is None:
        raise CatalogError("No pending candidate matches that ID.")
    return save(context, row[0] if command is None else command, description, tags, identifier)


def _preview(command, limit=1200):
    rendered = json.dumps(command, ensure_ascii=True)
    if limit is not None and len(rendered) > limit:
        return rendered[:limit] + " ... [truncated; use --pending --json for full command]"
    return rendered


def review(context):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise CatalogError("Review requires an interactive terminal; use pending --json and accept instead.")
    entries = pending(context)
    if not entries:
        print("No pending commands. Run toolbox --collect-history first.")
        return
    print(f"Reviewing {context.scope}. History scope is not proof a command belongs in that catalog.")
    for entry in entries:
        print(f"\n{entry['id']}\n{_preview(entry['command'], limit=None)}")
        choice = input("[a]ccept, [e]dit, [r]eject, [s]kip, [q]uit: ").strip().lower()
        if choice in {"q", "quit"}:
            break
        if choice in {"r", "reject"}:
            reject(context, entry["id"])
        elif choice in {"a", "accept", "e", "edit"}:
            command = input("Replacement command (single line): ") if choice in {"e", "edit"} else None
            description = input("Description: ")
            tags = input("Tags (comma-separated, optional): ")
            accept(context, entry["id"], description,
                   [tag.strip() for tag in tags.split(",") if tag.strip()], command)
            print("Saved after secret scan. Git publication is a separate step.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Examples: collect --limit 200; pending --json; save --command 'git status' "
        "--description 'Inspect the current checkout'; review. "
        "Environment: WORK_ENV/JOB select scope; SETUP_DIR and XDG_CONFIG_HOME/XDG_DATA_HOME select paths."))
    commands = parser.add_subparsers(dest="operation", required=True)
    for operation in ("collect", "pending", "save", "accept", "reject", "review"):
        command = commands.add_parser(operation)
        command.add_argument("--scope", help="personal or the active work-JOB scope")
        if operation == "collect":
            command.add_argument("--limit", type=int, default=200)
            command.add_argument("--quiet", action="store_true")
        if operation == "pending":
            command.add_argument("--json", action="store_true")
        if operation in {"accept", "reject"}:
            command.add_argument("id")
        if operation in {"save", "accept"}:
            command.add_argument("--command", required=operation == "save")
            command.add_argument("--description", required=True)
            command.add_argument("--tag", action="append", default=[])
    args = parser.parse_args(argv)
    context = Context(scope=args.scope)
    if args.operation == "collect":
        result = collect(context, args.limit)
        if not args.quiet or result["added"]:
            print(f"Examined {result['examined']} rows; queued {result['added']} new commands in {context.scope}."
                  + (" More history remains; run toolbox --collect-history again." if result["more"] else "")
                  + (" Review with toolbox --review." if result["added"] else ""))
    elif args.operation == "pending":
        rows = pending(context)
        if args.json:
            print(json.dumps(rows, ensure_ascii=True))
        else:
            for row in rows:
                print(f"{row['id']}  {_preview(row['command'])}")
            print(f"{len(rows)} pending commands shown (up to 1000) in {context.scope}.")
    elif args.operation == "save":
        identifier = save(context, args.command, args.description, args.tag)
        print(f"Saved {identifier} in {context.scope} after secret scan.")
    elif args.operation == "accept":
        identifier = accept(context, args.id, args.description, args.tag, args.command)
        print(f"Saved {identifier} in {context.scope} after secret scan.")
    elif args.operation == "reject":
        reject(context, args.id)
        print("Candidate rejected locally.")
    else:
        review(context)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (CatalogError, OSError, sqlite3.Error, EOFError) as error:
        message = str(error) if isinstance(error, CatalogError) else "Local catalog operation failed; no command was executed."
        print(f"toolbox catalog: {message}", file=sys.stderr)
        sys.exit(1)
