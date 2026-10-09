#!/usr/bin/env python3
# setup-test: Agent session streams
"""Provider protocol, incremental cache, and browser metadata regression tests."""

import io
import json
import os
from pathlib import Path
import runpy
import select
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
CODEX = runpy.run_path(str(ROOT / "dotfiles/.bin/codex-sessions"))["main"].__globals__
CLAUDE = runpy.run_path(str(ROOT / "dotfiles/.bin/claude-sessions"))["main"].__globals__
Cache = CODEX["JsonlCache"]


def line(value):
    return (json.dumps(value) + "\n").encode()


def rollout(path, identity="root", source="user", parent=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    meta = {
        "id": identity,
        "session_id": parent or identity,
        "thread_source": source,
        "cwd": str(path.parent),
        "timestamp": "2026-10-04T12:00:00Z",
    }
    if parent:
        meta["parent_thread_id"] = parent
    path.write_bytes(
        line({"type": "session_meta", "payload": meta})
        + line(
            {
                "type": "event_msg",
                "timestamp": "2026-10-04T12:00:00Z",
                "payload": {"type": "task_started", "turn_id": "t"},
            }
        )
    )
    return meta


class CacheTests(unittest.TestCase):
    def test_unchanged_append_partial_replacement_and_truncate_regrow(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "records.jsonl"
            path.write_bytes(line({"n": 1}))
            cache = Cache()

            def consume(state, record, offset):
                state.append(record["n"])

            self.assertEqual(cache.read(path, list, consume), [1])
            count = cache.bytes_read
            self.assertEqual(cache.read(path, list, consume), [1])
            self.assertEqual(cache.bytes_read, count)
            with path.open("ab") as stream:
                stream.write(b'{"n":2}')
            self.assertEqual(cache.read(path, list, consume), [1])
            with path.open("ab") as stream:
                stream.write(b"\n")
            self.assertEqual(cache.read(path, list, consume), [1, 2])
            old = path.stat()
            replacement = path.with_suffix(".new")
            replacement.write_bytes(path.read_bytes().replace(b"1", b"9"))
            os.utime(replacement, ns=(old.st_atime_ns, old.st_mtime_ns))
            replacement.replace(path)
            self.assertEqual(cache.read(path, list, consume), [9, 2])
            path.write_bytes(line({"n": 7}) * 5)
            self.assertEqual(cache.read(path, list, consume), [7] * 5)
            path.write_bytes(line({"n": 4}))
            self.assertEqual(cache.read(path, list, consume), [4])

    def test_disk_cache_restores_without_parsing_and_tolerates_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "records.jsonl"
            path.write_bytes(
                line({"type": "user", "uuid": "a", "message": {"content": "hello"}})
            )
            directory = Path(temporary) / "cache"
            directory.mkdir()
            first = Cache(directory)
            state = CLAUDE["scan_transcript"](path, first)
            second = Cache(directory)
            self.assertEqual(CLAUDE["scan_transcript"](path, second), state)
            self.assertEqual(second.records_read, 0)
            second.disk_path(path).write_text("broken")
            third = Cache(directory)
            self.assertEqual(CLAUDE["scan_transcript"](path, third), state)
            self.assertEqual(third.records_read, 1)

    def test_reducer_version_rebuilds_old_summaries_then_reuses_new_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "records.jsonl"
            path.write_bytes(line({"type": "user", "message": {"content": "hello"}}))
            old = Cache(Path(temporary))
            old.read(path, CLAUDE["claude_summary"], lambda *args: None)
            updated = Cache(Path(temporary), version=3)
            self.assertEqual(CLAUDE["scan_transcript"](path, updated)["first"], "hello")
            self.assertEqual(updated.records_read, 1)
            restored = Cache(Path(temporary), version=3)
            self.assertEqual(CLAUDE["scan_transcript"](path, restored)["first"], "hello")
            self.assertEqual(restored.records_read, 0)


class SnapshotTests(unittest.TestCase):
    def codex_snapshot(self, home, exercise, live=None):
        def run(_provider, _interval, collect):
            return exercise(collect)

        with (
            mock.patch.dict(
                os.environ,
                {"CODEX_HOME": str(home), "XDG_CACHE_HOME": str(home / "cache")},
            ),
            mock.patch.dict(
                CODEX, {"run_stream": run, "live_rollouts": lambda *a, **k: live or {}}
            ),
        ):
            return CODEX["stream_snapshots"](CODEX["ReportOptions"]())

    def test_all_history_archives_titles_names_refresh_and_active_subagents(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            for i in range(12):
                rollout(home / "sessions" / f"rollout-{i}.jsonl", str(i))
            archive = home / "archived_sessions/rollout-archive.jsonl"
            rollout(archive, "archive")
            agent = home / "sessions/rollout-agent.jsonl"
            rollout(agent, "agent", "subagent", "0")
            (home / "session_index.jsonl").write_bytes(
                line({"id": "0", "thread_name": "Saved title"})
            )

            def exercise(collect):
                first = collect()
                self.assertEqual(first["health"], "ok")
                self.assertEqual(len(first["sessions"]), 13)
                rows = {r["session_id"]: r for r in first["sessions"]}
                self.assertTrue(rows["archive"]["archived"])
                self.assertEqual(rows["0"]["title"], "Saved title")
                self.assertTrue(rows["0"]["file_identity"])
                self.assertEqual(
                    rows["0"]["transcript_path"], str(home / "sessions/rollout-0.jsonl")
                )
                self.assertEqual(first["active_subagents"][0]["parent_thread_id"], "0")
                (home / "session_index.jsonl").write_bytes(
                    line({"id": "0", "thread_name": "Renamed"})
                )
                second = collect()
                self.assertEqual(
                    next(r for r in second["sessions"] if r["session_id"] == "0")[
                        "title"
                    ],
                    "Renamed",
                )
                with agent.open("ab") as f:
                    f.write(
                        line(
                            {
                                "type": "event_msg",
                                "payload": {"type": "task_complete", "turn_id": "t"},
                            }
                        )
                    )
                self.assertEqual(collect()["active_subagents"], [])

            self.codex_snapshot(
                home, exercise, {agent.resolve(): CODEX["LiveRollout"](pid=1)}
            )

    def test_rollouts_from_before_thread_source_stream_as_roots(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            # Codex 0.128 and older wrote no thread_source; only its subagents
            # had an object source. A Desktop fork is still the user's session.
            spawned = {"subagent": {"thread_spawn": {"parent_thread_id": "cli"}}}
            for directory, identity, fields in [
                ("sessions", "cli", {"source": "cli"}),
                ("sessions", "fork", {"source": "vscode", "forked_from_id": "cli"}),
                ("archived_sessions", "old", {"source": "cli"}),
                ("sessions", "agent", {"source": spawned, "forked_from_id": "cli"}),
            ]:
                path = home / directory / f"rollout-{identity}.jsonl"
                path.parent.mkdir(parents=True, exist_ok=True)
                meta = {"id": identity, "cwd": temporary, **fields}
                path.write_bytes(line({"type": "session_meta", "payload": meta}))
            rollout(
                home / "sessions/rollout-review.jsonl",
                "review",
                "guardian_review",
                "cli",
            )

            def exercise(collect):
                rows = collect()["sessions"]
                self.assertEqual(
                    {
                        r["session_id"]: (r["thread_source"], r["archived"], r["cwd"])
                        for r in rows
                    },
                    {
                        "cli": ("user", False, temporary),
                        "fork": ("user", False, temporary),
                        "old": ("user", True, temporary),
                    },
                )

            self.codex_snapshot(home, exercise)

    def test_codex_incremental_metrics_and_only_small_last_record_is_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "rollout.jsonl"
            meta = rollout(path)
            cache = Cache()

            def scan():
                return CODEX["scan_rollout"](
                    {"path": path, "stat": path.stat(), "metadata": meta},
                    {},
                    CODEX["Counter"](),
                    cache,
                )

            first = scan()
            count = cache.records_read
            self.assertEqual(scan()["records"], first["records"])
            self.assertEqual(cache.records_read, count)
            with path.open("ab") as f:
                f.write(
                    line(
                        {
                            "type": "event_msg",
                            "payload": {
                                "type": "token_count",
                                "info": {
                                    "total_token_usage": {"total_tokens": 99},
                                    "last_token_usage": {"total_tokens": 20},
                                    "model_context_window": 100,
                                },
                            },
                        }
                    )
                )
            result = scan()
            self.assertEqual(
                (
                    result["tokens_total"],
                    result["context_used_tokens"],
                    result["context_window_tokens"],
                ),
                (99, 20, 100),
            )
            self.assertEqual(cache.records_read, count + 1)
            with path.open("ab") as f:
                f.write(
                    line(
                        {
                            "type": "response_item",
                            "payload": {
                                "type": "function_call_output",
                                "output": "x" * 100000,
                            },
                        }
                    )
                )
            scan()
            self.assertLess(
                len(json.dumps(vars(cache.entries[path][2])["last_record"])), 150
            )

    def test_provider_errors_are_not_empty_successes(self):
        with mock.patch.dict(
            CODEX,
            {
                "linux_live_rollouts": lambda _: None,
                "darwin_live_rollouts": lambda _: None,
                "open_codex_rollout_paths": lambda _: None,
            },
        ):
            with self.assertRaises(RuntimeError):
                CODEX["live_rollouts"](Path("/missing"), strict=True)
        with mock.patch(
            "subprocess.run", side_effect=subprocess.TimeoutExpired("ps", 5)
        ):
            with self.assertRaises(RuntimeError):
                CLAUDE["process_contexts"]([123], strict=True)

    def test_claude_native_semantics_and_estimates(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "root.jsonl"
            cache = Cache()
            records = [
                {
                    "type": "user",
                    "uuid": "u",
                    "message": {
                        "content": [
                            {"type": "text", "text": "one"},
                            {"type": "text", "text": "two"},
                            {"type": "image"},
                        ]
                    },
                },
                {
                    "type": "assistant",
                    "uuid": "a",
                    "message": {
                        "id": "m",
                        "model": "claude-opus-5-5",
                        "usage": {
                            "input_tokens": 10,
                            "cache_creation_input_tokens": 50000,
                            "cache_read_input_tokens": 250000,
                            "output_tokens": 8,
                        },
                        "content": [
                            {"type": "text", "text": "reply"},
                            {"type": "thinking"},
                            {"type": "tool_use"},
                        ],
                        "stop_reason": "end_turn",
                    },
                },
                {"type": "assistant", "uuid": "a", "message": {"content": "duplicate"}},
                {
                    "type": "user",
                    "uuid": "side",
                    "isSidechain": True,
                    "message": {"content": "hidden"},
                },
                {"type": "custom-title", "customTitle": "Custom"},
                {"type": "ai-title", "aiTitle": "AI"},
            ]
            path.write_bytes(b"".join(map(line, records)))
            row = CLAUDE["session_row"](path, None, cache)
            self.assertEqual(row["title"], "Custom")
            self.assertEqual(
                row["last_user_request"], "one\n\ntwo\n\n[Image attachment]"
            )
            self.assertEqual(
                (
                    row["tokens_total"],
                    row["context_used_tokens"],
                    row["context_window_tokens"],
                ),
                (300018, 300010, 1000000),
            )
            self.assertTrue(row["context_window_is_estimated"])
            self.assertEqual(
                (
                    row["user_turns"],
                    row["assistant_messages"],
                    row["tool_calls"],
                    row["reasoning_items"],
                    row["task_completes"],
                ),
                (1, 1, 1, 1, 1),
            )
            for model, capacity in [
                ("claude-opus-4-6", None),
                ("claude-opus-4-6[1m]", 1000000),
                ("claude-haiku-4-5-20251001", 200000),
                ("claude-opus-50", None),
            ]:
                self.assertEqual(CLAUDE["stream_context_window"](model), capacity)
            with path.open("ab") as f:
                f.write(
                    line({"type": "system", "subtype": "compact_boundary"})
                    + line(
                        {
                            "type": "assistant",
                            "uuid": "synthetic",
                            "message": {
                                "model": "<synthetic>",
                                "usage": {"input_tokens": 0},
                            },
                        }
                    )
                )
            row = CLAUDE["session_row"](path, None, cache)
            self.assertIsNone(row["context_used_tokens"])
            self.assertEqual(row["tokens_total"], 300018)
            self.assertEqual(row["model"], "claude-opus-5-5")


class ProtocolTests(unittest.TestCase):
    def test_both_streams_start_refresh_coalesce_and_exit_on_owner_close(self):
        for provider, variable in [
            ("codex", "CODEX_HOME"),
            ("claude", "CLAUDE_CONFIG_DIR"),
        ]:
            with (
                self.subTest(provider=provider),
                tempfile.TemporaryDirectory() as temporary,
            ):
                env = {
                    **os.environ,
                    variable: temporary + "/missing",
                    "XDG_CACHE_HOME": temporary + "/cache",
                    "PYTHONDONTWRITEBYTECODE": "1",
                }
                child = subprocess.Popen(
                    [
                        str(ROOT / "dotfiles/.bin" / f"{provider}-sessions"),
                        "--stream-json",
                        "--interval",
                        "60",
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=env,
                )
                try:

                    def read():
                        self.assertTrue(
                            select.select([child.stdout], [], [], 5)[0],
                            "stream timeout",
                        )
                        return json.loads(child.stdout.readline())

                    first = read()
                    self.assertEqual(
                        (first["version"], first["health"]), (1, "unavailable")
                    )
                    child.stdin.write(
                        b"bad command\n"
                        + b"".join(
                            line({"command": "refresh", "request_id": str(i)})
                            for i in range(10)
                        )
                    )
                    child.stdin.flush()
                    second = read()
                    self.assertEqual(
                        set(second["refresh_ids"]), set(map(str, range(10)))
                    )
                    self.assertEqual(second["sequence"], 2)
                    self.assertFalse(select.select([child.stdout], [], [], 0.2)[0])
                    child.stdin.close()
                    child.wait(timeout=3)
                    self.assertEqual(child.returncode, 0)
                    self.assertIn(b"invalid stdin command", child.stderr.read())
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                    child.stdout.close()
                    child.stderr.close()

    def test_stream_recovers_after_snapshot_exception(self):
        module = CODEX["run_stream"].__globals__
        # Real pipe allows select/os.read while the reducer fails once and then recovers.
        read_fd, write_fd = os.pipe()
        calls = 0

        def snapshot():
            nonlocal calls
            calls += 1
            if calls == 1:
                raise RuntimeError("fixture failure")
            os.close(write_fd)
            return {"health": "ok", "sessions": [], "active_subagents": []}

        with (
            os.fdopen(read_fd) as stdin,
            mock.patch.dict(
                module, {"sys": mock.Mock(stdin=stdin, stderr=io.StringIO())}
            ),
            mock.patch("builtins.print") as output,
            mock.patch("os.setpgid"),
        ):
            CODEX["run_stream"]("codex", 0.01, snapshot)
        frames = [
            json.loads(call.args[0])
            for call in output.call_args_list
            if isinstance(call.args[0], str) and call.args[0].startswith("{")
        ]
        self.assertEqual(frames[0]["health"], "error")
        self.assertEqual(calls, 2)


if __name__ == "__main__":
    unittest.main()
