"""Render an inventory supplied by the live Zsh shell; never execute a helper."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import sys


def clean(text):
    """Keep source comments from injecting terminal controls or extra rows."""
    return "".join(char if char.isprintable() else " " for char in text).strip()


def metadata(filename, executable=False):
    result = {}
    pending = {}
    try:
        with open(filename, encoding="utf-8", errors="replace") as stream:
            # Headers only for executables; no arbitrary --help invocation.
            lines = stream.read(65536 if executable else 2 * 1024 * 1024).splitlines()
    except OSError:
        return result
    for line in lines:
        comment = line.strip()
        if comment.startswith("# toolbox:"):
            categories, separator, description = comment[10:].partition("|")
            pending = ({"categories": clean(categories).split(),
                        "description": clean(description), "examples": []}
                       if separator else {})
        elif pending and comment.startswith("# toolbox-example:"):
            example = comment[len("# toolbox-example:"):].strip()
            if example and all(char.isprintable() for char in example):
                pending["examples"].append(example)
        elif pending and comment.startswith("# toolbox-args:"):
            pending["argument_hint"] = clean(comment[len("# toolbox-args:"):])
        elif comment.startswith("#"):
            continue
        elif executable:
            break
        else:
            declaration = re.match(r"^\s*(?:function\s+)?([^\s()]+)\s*\(\s*\)", line)
            if pending and declaration:
                result[declaration[1]] = pending
            pending = {}
    return pending if executable else result


def inventory(data):
    fields = data.decode("utf-8", "surrogateescape").split("\0")[:-1]
    if len(fields) % 6:
        raise ValueError("incomplete shell inventory")
    grouped = {}
    for index in range(0, len(fields), 6):
        name, source, kind, location, effective_kind, effective_location = fields[index:index + 6]
        grouped.setdefault(name, []).append({
            "source": source, "kind": kind, "location": location,
            "effective_kind": effective_kind, "effective_location": effective_location,
        })
    cache = {}
    records = []
    for name, candidates in grouped.items():
        first = candidates[0]
        effective_kind, effective_location = first["effective_kind"], first["effective_location"]
        selected = next((candidate for candidate in candidates
                         if candidate["kind"] == effective_kind
                         and candidate["location"] == effective_location), None)
        primary = selected or first
        key = (primary["location"], primary["kind"])
        if key not in cache:
            cache[key] = metadata(key[0], key[1] == "executable")
        meta = cache[key] if key[1] == "executable" else cache[key].get(name, {})
        source = selected["source"] if selected else effective_kind
        record = {
            "name": name, "source": source, "kind": effective_kind,
            "location": effective_location,
            "description": meta.get("description", (
                f"Shell helper from {Path(primary['location']).name}."
                if primary["kind"] == "function" else "Managed executable.")),
            "categories": meta.get("categories", []),
            "argument_hint": meta.get("argument_hint", ""),
            "examples": meta.get("examples", []),
            "invocation": shlex.quote(name),
            "shadowed": [{key: candidate[key] for key in ("source", "kind", "location")}
                         for candidate in candidates if candidate is not selected],
        }
        # Metadata from a shadowed command must not suggest it describes the alias
        # or external implementation that would actually run.
        if selected is None:
            record.update(description=f"{effective_kind.title()} shadows managed command.",
                          examples=[], argument_hint="", categories=[])
        records.append(record)
    return sorted(records, key=lambda record: (record["source"] != "home", record["source"], record["name"]))


def catalog_records():
    """Load only the trusted sibling module, including under Python -I -S."""
    module_path = Path(__file__).resolve().with_name("toolbox_catalog.py")
    if not module_path.is_file():
        return []  # Older installations can still use the live inventory.
    spec = importlib.util.spec_from_file_location("_toolbox_catalog", module_path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    try:
        return module.load_catalog_records()
    except module.CatalogError as error:
        raise ValueError(str(error)) from error


def history_records():
    """Read local history from a trusted sibling under Python -I -S."""
    module_path = Path(__file__).resolve().with_name("toolbox_history.py")
    if not module_path.is_file():
        return [], []
    spec = importlib.util.spec_from_file_location("_toolbox_history", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.load_history_records()


def describe(record, with_examples=True):
    lines = [record["name"], f"Source: {record['source']} ({record['kind']})",
             f"Location: {record['location']}", record["description"]]
    if record["argument_hint"]:
        lines.append(f"Arguments: {record['argument_hint']}")
    if record["kind"] == "catalog":
        lines.append("Saved command: check required tools, paths, and arguments before running.")
    if record["kind"] == "history":
        lines.append("Local history: previous command text, not a verified or approved example.")
    if with_examples:
        lines += ["Examples:"] + [f"  {example}" for example in record["examples"] or [record["invocation"]]]
    if record["shadowed"]:
        lines += ["Shadowed alternatives:"] + [
            f"  {item['source']} ({item['kind']}): {item['location']}" for item in record["shadowed"]]
    return "\n".join(clean(part) for line in lines for part in line.split("\n")) + "\n"


HIDDEN_PAD = 400  # Columns of padding that push searchable example text off-screen.


def render_picker(records, directory):
    """Store inert text once; numeric selection reads it lazily from one private DB.

    One row per command. Its examples are chosen in the preview pane (see `step`),
    and are appended past HIDDEN_PAD spaces so fzf can search them without showing them.
    """
    rows = []
    path = directory / "picker.sqlite3"
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    connection = sqlite3.connect(path)
    try:
        connection.execute("PRAGMA journal_mode=OFF")
        connection.execute("CREATE TABLE choices (id INTEGER PRIMARY KEY, examples TEXT, display TEXT, header TEXT)")
        for record in records:
            examples = record["examples"] or [record["invocation"]]
            display = ["\n".join(clean(line) for line in example.split("\n")).rstrip() for example in examples]
            number = len(rows) + 1
            connection.execute("INSERT INTO choices VALUES(?,?,?,?)", (
                number, json.dumps(examples), json.dumps(display), describe(record, with_examples=False)))
            rows.append((str(number), clean(record["name"]), clean(record["source"]),
                         clean(record["description"]), " ".join(" ".join(example.split()) for example in display)))
        connection.commit()
    finally:
        connection.close()
    # Pad display columns ourselves: fzf renders tabs at tab stops, which misaligns them.
    name_width = max((len(row[1]) for row in rows), default=0)
    source_width = max((len(row[2]) for row in rows), default=0)
    visible = [f"{name:<{name_width}}  {source:<{source_width}}  {description}"
               for _, name, source, description, _ in rows]
    # Tell the shell how wide the visible part is so it can size the preview pane.
    layout = os.open(directory / "layout", os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(layout, "w") as handle:
        handle.write(str(max(map(len, visible), default=0)))
    padding = " " * HIDDEN_PAD
    print("\n".join(f"{row[0]}\t{text}{padding}{row[4]}" for row, text in zip(rows, visible)))


def load_choice(directory, number):
    if not re.fullmatch(r"[0-9]{1,12}", number):
        raise ValueError("invalid picker selection")
    try:
        connection = sqlite3.connect((directory / "picker.sqlite3").resolve().as_uri() + "?mode=ro", uri=True)
        try:
            connection.execute("PRAGMA query_only=ON")
            row = connection.execute("SELECT examples, display, header FROM choices WHERE id=?",
                                     (int(number),)).fetchone()
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise ValueError("could not read picker selection") from error
    if row is None:
        raise ValueError("unknown picker selection")
    return json.loads(row[0]), json.loads(row[1]), row[2]


def chosen_index(directory, number, count):
    """The example picked for this row; the state file only counts for the row it names."""
    try:
        row, index = (directory / "state").read_text().split()
        if row == number:
            return int(index) % count
    except (OSError, ValueError):
        pass
    return 0


def step(directory, number, delta):
    examples, _, _ = load_choice(directory, number)
    index = (chosen_index(directory, number, len(examples)) + delta) % len(examples)
    descriptor = os.open(directory / "state", os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(f"{int(number)} {index}")


def picker_text(directory, number, mode):
    examples, display, header = load_choice(directory, number)
    index = chosen_index(directory, number, len(examples))
    if mode != "preview":
        return examples[index]
    lines = [header.rstrip("\n"), "", f"Examples ({index + 1} of {len(display)}): \u2190/\u2192 choose, Enter inserts"]
    for position, example in enumerate(display):
        for offset, line in enumerate(example.split("\n")):
            lines.append(("\u25b6 " if position == index and offset == 0 else "  ") + line)
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["table", "json", "describe", "pick", "preview", "select", "step"])
    parser.add_argument("filter", nargs="?", default="")
    parser.add_argument("--directory", type=Path)
    parser.add_argument("--delta", type=int, default=1)
    parser.add_argument("--history", action="store_true", help="include local Atuin history")
    parser.add_argument("--catalog", action="store_true", help="include reviewed command catalogs")
    args = parser.parse_intermixed_args()
    if args.mode in {"preview", "select", "pick", "step"} and args.directory is None:
        parser.error("--directory is required for picker operations")
    if args.mode == "step":
        step(args.directory, args.filter, args.delta)
        return 0
    if args.mode in {"preview", "select"}:
        print(picker_text(args.directory, args.filter, args.mode), end="")
        return 0
    history, notices = history_records() if args.history else ([], [])
    for notice in notices:
        print(f"toolbox: {notice}", file=sys.stderr)
    records = inventory(sys.stdin.buffer.read()) + (catalog_records() if args.catalog else []) + history
    records.sort(key=lambda record: (record["kind"] == "history", record["kind"] == "catalog",
                                     record["source"] != "home", record["source"], record["name"]))
    if args.mode == "describe":
        records = [record for record in records if record["name"] == args.filter]
    elif args.filter:
        records = [record for record in records if args.filter.casefold() in " ".join([
            record["name"], record["source"], record["description"], *record["categories"],
            record["invocation"] if record["kind"] in {"catalog", "history"} else "",
        ]).casefold()]
    if args.mode == "json":
        print(json.dumps({"schema_version": 1, "commands": records, "warnings": notices}, ensure_ascii=True))
        return 0
    if not records:
        print(f"toolbox: no commands match: {clean(args.filter)}", file=sys.stderr)
        return 1
    if args.mode == "describe":
        print(describe(records[0]), end="")
    elif args.mode == "pick":
        render_picker(records, args.directory)
    else:
        command_width = max(7, *(len(clean(record["name"])) for record in records))
        source_width = max(6, *(len(clean(record["source"])) for record in records))
        print(f"{'COMMAND':<{command_width}} {'SOURCE':<{source_width}} DESCRIPTION")
        for record in records:
            suffix = f" [{len(record['shadowed'])} shadowed]" if record["shadowed"] else ""
            print(f"{clean(record['name']):<{command_width}} {clean(record['source']):<{source_width}} "
                  f"{clean(record['description'])}{suffix}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"toolbox: {error}", file=sys.stderr)
        sys.exit(1)
