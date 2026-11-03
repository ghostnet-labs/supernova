"""Incremental local JSONL summaries and the session-provider stream protocol."""

from __future__ import annotations

import json
import base64
import hashlib
import os
import select
import sys
import threading
import tempfile
import time
from pathlib import Path
from queue import SimpleQueue


class CodexQueue:
    """Read desktop follow-ups once per state-file change, independently of rollouts."""

    def __init__(self, home):
        self.path = home / ".codex-global-state.json"
        self.stamp = None
        self.messages = {}

    def read(self):
        try:
            stat = self.path.stat()
            stamp = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)
            if stamp == self.stamp:
                return self.messages
            with self.path.open() as stream:
                state = json.loads(stream.read(16 * 1024 * 1024))
            queues = state.get("queued-follow-ups", {})
            if not isinstance(queues, dict):
                return self.messages
            messages = {}
            for session, rows in queues.items():
                if not isinstance(rows, list):
                    continue
                seen = set()
                for row in rows:
                    if not isinstance(row, dict) or not isinstance(row.get("id"), str) or row["id"] in seen:
                        continue
                    text = row.get("text")
                    if not isinstance(text, str):
                        continue
                    seen.add(row["id"])
                    messages.setdefault(session, []).append({
                        "id": row["id"], "text": text if text.strip() else "[Queued attachments]",
                        "created_at": row.get("createdAt"), "is_paused": row.get("pausedReason") is not None,
                    })
            self.stamp, self.messages = stamp, messages
        except FileNotFoundError:
            self.stamp, self.messages = None, {}
        except (OSError, ValueError, AttributeError):
            pass  # Keep the last complete snapshot during a partial write.
        return self.messages


class JsonlCache:
    """Keep reducer state, never transcript contents; consume only committed lines."""

    def __init__(self, directory=None, version=2):
        self.entries = {}
        self.bytes_read = 0
        self.records_read = 0
        self.directory = directory
        self.version = version

    @classmethod
    def persistent(cls, provider, home, version=2):
        base = Path(
            os.environ.get("XDG_CACHE_HOME")
            or Path.home()
            / ("Library/Caches" if sys.platform == "darwin" else ".cache")
        )
        directory = (
            base
            / "local.agent-control-center"
            / (provider + "-" + hashlib.sha256(str(home).encode()).hexdigest()[:16])
        )
        try:
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        except OSError:
            directory = None
        return cls(directory, version=version)

    def disk_path(self, path):
        return (
            self.directory / (hashlib.sha256(str(path).encode()).hexdigest() + ".json")
            if self.directory
            else None
        )

    def restore(self, path, factory):
        disk = self.disk_path(path)
        if disk is None:
            return None
        try:
            with disk.open() as stream:
                stored = json.loads(stream.read(8 * 1024 * 1024))
            if stored["version"] != self.version:
                return None
            state = factory()
            if isinstance(state, dict):
                state.update(stored["state"])
                state["seen"] = set(state["seen"])
            else:
                state.__dict__.update(stored["state"])
            return tuple(stored["stamp"]), stored["offset"], state, stored["anchor"]
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def persist(self, path, stamp, offset, state, anchor):
        disk = self.disk_path(path)
        if disk is None:
            return
        temporary = None
        try:
            payload = {
                "version": self.version,
                "stamp": stamp,
                "offset": offset,
                "anchor": anchor,
                "state": state if isinstance(state, dict) else vars(state),
            }
            with tempfile.NamedTemporaryFile(
                mode="w", dir=self.directory, delete=False
            ) as stream:
                temporary = stream.name
                json.dump(
                    payload,
                    stream,
                    default=lambda value: (
                        sorted(value) if isinstance(value, set) else None
                    ),
                    separators=(",", ":"),
                )
            os.replace(temporary, disk)
        except OSError:
            pass  # An unwritable cache must not make session history unavailable.
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)

    def read(self, path, factory, consume):
        stat = path.stat()
        stamp = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)
        previous = self.entries.get(path) or self.restore(path, factory)
        if previous and previous[0] == stamp:
            self.entries[path] = previous
            return previous[2]
        append = (
            previous and previous[0][:2] == stamp[:2] and stat.st_size > previous[0][2]
        )
        if append:
            with path.open("rb") as stream:
                append = self.anchor(stream, previous[1]) == previous[3]
        offset, state = (previous[1], previous[2]) if append else (0, factory())
        with path.open("rb") as stream:
            stream.seek(offset)
            for line in stream:
                self.bytes_read += len(line)
                if not line.endswith(b"\n"):
                    break
                position = offset
                offset += len(line)
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if isinstance(record, dict):
                    consume(state, record, position)
                    self.records_read += 1
            anchor = self.anchor(stream, offset)
        self.entries[path] = (stamp, offset, state, anchor)
        self.persist(path, stamp, offset, state, anchor)
        return state

    @staticmethod
    def anchor(stream, offset):
        stream.seek(0)
        prefix = stream.read(min(offset, 4096))
        stream.seek(max(0, offset - 4096))
        return hashlib.sha256(prefix + stream.read(min(offset, 4096))).hexdigest()

    def retain(self, paths):
        self.entries = {
            path: entry for path, entry in self.entries.items() if path in paths
        }


def read_transcript(command, sessions):
    """Read a bounded chunk from a discovered session, never an arbitrary path."""
    reply = {"type": "transcript", "request_id": command.get("request_id")}
    try:
        row = sessions.get(command.get("session_id"))
        if row is None:
            raise ValueError("Session is no longer available; refresh its host.")
        offset = command.get("offset", 0)
        if type(offset) is not int or offset < 0:
            raise ValueError("Invalid transcript offset")
        with open(row["transcript_path"], "rb") as stream:
            info = os.fstat(stream.fileno())
            identity = f"{info.st_dev}:{info.st_ino}"
            reset = command.get("file_identity") != identity or offset > info.st_size
            if command.get("file_size") == info.st_size and command.get("file_modified_ns") != str(info.st_mtime_ns):
                reset = True
            if offset and not reset:
                stream.seek(max(0, offset - 64))
                anchor = base64.b64encode(stream.read(min(64, offset))).decode()
                reset = anchor != command.get("anchor")
            if reset:
                offset = 0
            stream.seek(offset)
            data = stream.read(4 * 1024 * 1024)
        reply.update(offset=offset, data=base64.b64encode(data).decode(),
                     file_identity=identity, file_size=info.st_size, file_modified_ns=str(info.st_mtime_ns),
                     has_more=offset + len(data) < info.st_size)
    except (OSError, ValueError, TypeError) as error:
        reply["error"] = str(error)
    return reply


def run_stream(provider, interval, snapshot):
    """NDJSON on stdout; coalesce refresh requests, exit when the owner closes stdin."""
    # The application can terminate this group, including a ps/lsof child in flight.
    try:
        os.setpgid(0, 0)
    except OSError:
        pass
    pending = b""
    sequence = 0
    results = SimpleQueue()
    active = False
    initialized = False
    deadline = 0
    heartbeat = time.monotonic() + 1
    requested = set()
    submitted = set()
    sessions = {}

    def collect():
        try:
            results.put(snapshot())
        except Exception as error:
            print(f"{provider}: {error}", file=sys.stderr, flush=True)
            results.put(
                {
                    "health": "error",
                    "error": str(error),
                    "sessions": [],
                    "active_subagents": [],
                }
            )

    def emit(state, refresh_ids=()):
        nonlocal sequence
        sequence += 1
        message = {
            "version": 1,
            "provider": provider,
            "sequence": sequence,
            "generated_at": time.time(),
            "refresh_ids": sorted(refresh_ids),
            **state,
        }
        print(json.dumps(message, separators=(",", ":")), flush=True)

    while True:
        try:
            now = time.monotonic()
            if not active and now >= deadline:
                active = True
                submitted, requested = requested, set()
                threading.Thread(target=collect, daemon=True).start()
            if not results.empty():
                state = results.get()
                if state.get("health") == "ok":
                    sessions = {
                        row["session_id"]: row
                        for key in ("sessions", "active_subagents", "subagents")
                        for row in state.get(key, [])
                    }
                elif state.get("health") in ("error", "unavailable"):
                    sessions = {}
                emit(state, submitted)
                initialized = True
                active = False
                deadline = now + (0.05 if requested else interval)
            elif not initialized and now >= heartbeat:
                emit({"health": "loading", "sessions": [], "active_subagents": []})
                heartbeat = now + 5
        except BrokenPipeError:
            return 0
        ready, _, _ = select.select([sys.stdin], [], [], 0.1)
        if ready:
            data = os.read(sys.stdin.fileno(), 65536)
            if not data:
                return 0
            pending += data
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                try:
                    command = json.loads(line)
                    if isinstance(command, dict) and command.get("command") == "read_transcript":
                        emit(read_transcript(command, sessions))
                    if (
                        isinstance(command, dict)
                        and command.get("command") == "refresh"
                    ):
                        request_id = command.get("request_id", "refresh")
                        if isinstance(request_id, str) and len(request_id) <= 128:
                            requested.add(request_id)
                            if not active:
                                deadline = min(deadline, time.monotonic() + 0.05)
                except ValueError:
                    print(
                        f"{provider}: invalid stdin command",
                        file=sys.stderr,
                        flush=True,
                    )
            if len(pending) > 65536:
                pending = b""


def file_metadata(path):
    try:
        info = path.stat()
    except FileNotFoundError:
        return {"file_bytes": 0, "file_identity": "", "file_modified_ns": 0}
    return {
        "file_bytes": info.st_size,
        "file_identity": f"{info.st_dev}:{info.st_ino}",
        "file_modified_ns": info.st_mtime_ns,
    }


def claude_summary():
    return {
        "first": "",
        "last": "",
        "model": "",
        "branch": "",
        "title": "",
        "custom_title": "",
        "cwd": "",
        "stop": "",
        "tokens": None,
        "context": None,
        "effort": "",
        "version": "",
        "started": None,
        "usage": {},
        "seen": set(),
        "turn_open": False,
        "queued": [],
        "queue_consumed": {},
        "records": 0,
        "user_turns": 0,
        "assistant_messages": 0,
        "tool_calls": 0,
        "reasoning_items": 0,
        "task_starts": 0,
        "task_completes": 0,
        "aborted_turns": 0,
        "tokens_cached": None,
        "tokens_output": None,
    }


def consume_claude_queue(summary, record, offset):
    attachment = record.get("attachment")
    delivered = (record.get("type") == "attachment" and isinstance(attachment, dict)
                 and attachment.get("type") == "queued_command")
    if record.get("type") != "queue-operation" and not delivered:
        return False
    queued = summary["queued"]
    operation = "delivered" if delivered else record.get("operation")
    content = attachment.get("prompt") if delivered else record.get("content")
    if operation == "enqueue":
        text = content if isinstance(content, str) else "[Queued message preview unavailable]"
        if text.lstrip().startswith(("<task-notification>", "<teammate-message>")):
            text = ""
        queued.append({"id": str(offset), "content": content, "text": text,
                       "created_at": record.get("timestamp")})
    elif operation == "dequeue" and queued:
        queued.pop(0)
    elif operation in {"remove", "delivered"}:
        identifiers = (attachment.get("delivery_id"), attachment.get("source_uuid")) if delivered else (
            record.get("deliveryId"), record.get("commandUuid"))
        keys = [prefix + value for prefix, value in zip(("delivery:", "command:"), identifiers)
                if isinstance(value, str) and value]
        consumed = summary["queue_consumed"]
        acknowledged = any(key in consumed for key in keys)
        consumed.update(dict.fromkeys(keys, True))
        # An attachment and its remove record acknowledge one delivery in either order.
        # Keep these IDs across cache restores, just like message UUID deduplication.
        if acknowledged:
            return True
        if delivered and isinstance(record.get("uuid"), str):
            uuid = record["uuid"]
            if uuid in summary["seen"]:
                return True
            summary["seen"].add(uuid)
        timestamp = attachment.get("timestamp") if delivered else None
        index = next((i for i, item in enumerate(queued) if timestamp and item["created_at"] == timestamp), None)
        if index is None and isinstance(content, str):
            index = next((i for i, item in enumerate(queued) if item["content"] == content), None)
        # Claude can omit enqueue content but include it when cancelling or delivering.
        # If no recorded identity matches, consume one unknown entry, never a different known prompt.
        if index is None:
            index = next((i for i, item in enumerate(queued) if item["content"] is None), None)
        if index is not None:
            queued.pop(index)
    return True


def consume_claude(summary, record, offset, prompt):
    kind = record.get("type")
    if kind == "ai-title":
        summary["title"] = record.get("aiTitle") or summary["title"]
    if kind == "custom-title":
        summary["custom_title"] = record.get("customTitle") or summary["custom_title"]
    if record.get("isSidechain"):
        return
    if consume_claude_queue(summary, record, offset):
        return
    if kind == "system" and record.get("subtype") == "compact_boundary":
        summary["context"] = None
    if kind not in {"user", "assistant"}:
        return
    uuid = record.get("uuid") or str(offset)
    if uuid in summary["seen"]:
        return
    summary["seen"].add(uuid)
    summary["records"] += 1
    for key, name in (("cwd", "cwd"), ("branch", "gitBranch"), ("version", "version")):
        summary[key] = record.get(name) or summary[key]
    summary["started"] = summary["started"] or record.get("timestamp")
    message = record.get("message") if isinstance(record.get("message"), dict) else {}
    content = message.get("content") or []
    blocks = (
        content if isinstance(content, list) else [{"type": "text", "text": content}]
    )
    if kind == "user":
        text = prompt(record)
        if text:
            summary["first"] = summary["first"] or text
            summary["last"] = text
            summary["user_turns"] += 1
            summary["task_starts"] += 1
            summary["aborted_turns"] += int(summary["turn_open"])
            summary["turn_open"] = True
        summary["stop"] = ""
        return
    summary["assistant_messages"] += int(
        any(
            b.get("type") in {"text", "image", "document"}
            for b in blocks
            if isinstance(b, dict)
        )
    )
    summary["tool_calls"] += sum(
        b.get("type") == "tool_use" for b in blocks if isinstance(b, dict)
    )
    summary["reasoning_items"] += sum(
        b.get("type") == "thinking" for b in blocks if isinstance(b, dict)
    )
    summary["stop"] = message.get("stop_reason") or ""
    if summary["turn_open"] and summary["stop"] == "end_turn":
        summary["task_completes"] += 1
        summary["turn_open"] = False
    summary["effort"] = record.get("effort") or summary["effort"]
    model = message.get("model")
    if model == "<synthetic>":
        return
    if model and model != summary["model"]:
        summary["model"] = model
        summary["context"] = None
    usage = message.get("usage")
    if isinstance(usage, dict) and any(
        key in usage
        for key in (
            "input_tokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
        )
    ):
        cached = int(usage.get("cache_read_input_tokens") or 0)
        inputs = (
            int(usage.get("input_tokens") or 0)
            + int(usage.get("cache_creation_input_tokens") or 0)
            + cached
        )
        output = int(usage.get("output_tokens") or 0)
        summary["usage"][message.get("id") or uuid] = (inputs + output, cached, output)
        summary["context"] = inputs
        summary["tokens"], summary["tokens_cached"], summary["tokens_output"] = map(
            sum, zip(*summary["usage"].values())
        )
