#!/usr/bin/env python3
# setup-test: claude-sessions
"""Regression tests for Claude Code session discovery and the shared JSON row contract."""

from __future__ import annotations

import io
import json
import os
import runpy
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[2] / "dotfiles" / ".bin" / "claude-sessions"
# run_path returns a copy, so patch the namespace the functions actually read.
SCRIPT_GLOBALS = runpy.run_path(str(SCRIPT))["main"].__globals__
LIVE_SESSIONS = SCRIPT_GLOBALS["live_sessions"]
COLLECT_ROWS = SCRIPT_GLOBALS["collect_rows"]
SCAN_TRANSCRIPT = SCRIPT_GLOBALS["scan_transcript"]
MAIN = SCRIPT_GLOBALS["main"]
RESOLVE_SESSION = SCRIPT_GLOBALS["resolve_session"]
CONTEXT_WINDOW = SCRIPT_GLOBALS["context_window"]

ROOT_ID = "11111111-2222-3333-4444-555555555555"
OTHER_ID = "66666666-7777-8888-9999-000000000000"
PROC_START = "Fri Oct  2 21:03:37 2026"


def line(record: dict[str, object]) -> str:
    return json.dumps(record, separators=(",", ":")) + "\n"


def transcript(cwd: str) -> str:
    base = {"cwd": cwd, "gitBranch": "feature/x", "sessionId": ROOT_ID}
    return "".join(
        (
            line({"type": "user", "isMeta": True, "message": {"role": "user", "content": "<local-command-caveat>x</local-command-caveat>"}, **base}),
            line({"type": "user", "message": {"role": "user", "content": "first request"}, **base}),
            line({"type": "assistant", "message": {"id": "m1", "model": "claude-opus-5-5", "stop_reason": "tool_use", "usage": {"input_tokens": 10, "output_tokens": 5}}, **base}),
            line({"type": "assistant", "message": {"id": "m1", "model": "claude-opus-5-5", "stop_reason": "tool_use", "usage": {"input_tokens": 10, "output_tokens": 5}}, **base}),
            line({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "ok"}]}, **base}),
            line({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "second   request"}]}, **base}),
            line({"type": "assistant", "effort": "xhigh", "message": {"id": "m2", "model": "claude-opus-5-5", "stop_reason": "end_turn", "usage": {"cache_read_input_tokens": 100}}, **base}),
            line({"type": "ai-title", "aiTitle": "Readable title", "sessionId": ROOT_ID}),
        )
    )


class ClaudeHome:
    def __init__(self, root: Path) -> None:
        self.home = root / ".claude"
        self.cwd = root / "project"
        self.cwd.mkdir()
        self.project = self.home / "projects" / "-project"
        self.project.mkdir(parents=True)
        (self.home / "sessions").mkdir()
        (self.project / f"{ROOT_ID}.jsonl").write_text(transcript(str(self.cwd)))
        (self.project / f"{OTHER_ID}.jsonl").write_text(line({"type": "user", "cwd": str(self.cwd), "message": {"content": "old"}}))
        os.utime(self.project / f"{OTHER_ID}.jsonl", (time.time() - 3600, time.time() - 3600))

    def pid_file(self, pid: int, session_id: str = ROOT_ID, **extra: object) -> None:
        record = {"pid": pid, "sessionId": session_id, "cwd": str(self.cwd), "procStart": PROC_START, "status": "busy", "statusUpdatedAt": int(time.time() * 1000), **extra}
        (self.home / "sessions" / f"{pid}.json").write_text(json.dumps(record))


def ps_line(pid: int, start: str = PROC_START, environment: str = "") -> str:
    return f"{pid} {start} claude {environment}\n"


class ClaudeSessionsTests(unittest.TestCase):
    def test_scan_skips_meta_and_tool_results_and_dedupes_usage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            summary = SCAN_TRANSCRIPT(claude.project / f"{ROOT_ID}.jsonl")
        self.assertEqual(summary["first"], "first request")
        self.assertEqual(summary["last"], "second request")
        self.assertEqual(summary["model"], "claude-opus-5-5")
        self.assertEqual(summary["branch"], "feature/x")
        self.assertEqual(summary["title"], "Readable title")
        self.assertEqual(summary["tokens"], 115)
        self.assertEqual(summary["stop"], "end_turn")
        self.assertEqual(summary["effort"], "xhigh")  # the newest response's effort wins

    def test_context_comes_from_the_newest_response_and_the_model_window(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            summary = SCAN_TRANSCRIPT(claude.project / f"{ROOT_ID}.jsonl")
        self.assertEqual(summary["context"], 100)  # the last response read 100 cached tokens
        windows = {model: CONTEXT_WINDOW(model) for model in (
            "claude-opus-5-5", "claude-sonnet-4-6", "claude-fable-5-1", "claude-opus-4-5-20251101",
            "claude-sonnet-4-5-20250929[1m]", "claude-haiku-4-5", "", "gpt-6")}
        self.assertEqual(windows, {
            "claude-opus-5-5": 1_000_000, "claude-sonnet-4-6": 1_000_000, "claude-fable-5-1": 1_000_000,
            "claude-opus-4-5-20251101": 200_000, "claude-sonnet-4-5-20250929[1m]": 1_000_000,
            "claude-haiku-4-5": 200_000, "": None, "gpt-6": None})

    def test_live_sessions_reject_reused_pids_and_parse_multiplexer_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            claude.pid_file(100)
            claude.pid_file(200, OTHER_ID)
            output = ps_line(100, environment="TMUX=/tmp/tmux-501/default,9,0 TMUX_PANE=%7 ZELLIJ_PANE_ID=3") + ps_line(200, "Sat Oct  3 01:00:00 2026")
            live = LIVE_SESSIONS(claude.home, output)
        self.assertEqual(set(live), {ROOT_ID})
        self.assertEqual(live[ROOT_ID].tmux_socket, "/tmp/tmux-501/default")
        self.assertEqual(live[ROOT_ID].tmux_pane, "%7")
        self.assertEqual(live[ROOT_ID].zellij_pane_id, "3")

    def test_live_json_rows_follow_codex_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            claude.pid_file(100, status="idle", entrypoint="claude-desktop")
            with mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda pids, _=None: {100: (PROC_START, {})}}):
                rows = COLLECT_ROWS(claude.home, live_only=True, include_subagents=True, limit=200)
        self.assertEqual(len(rows), 1)
        row = rows[0]
        for key in ("session_id", "cwd", "status", "state", "state_elapsed", "last_user_request", "git_branch", "model",
                    "liveness", "root_session_id", "parent_thread_id", "thread_source", "table_detail", "tokens_total",
                    "tmux_pane", "zellij_pane_id"):
            self.assertIn(key, row)
        self.assertEqual((row["agent"], row["liveness"], row["status"], row["client_type"]), ("claude", "OPEN", "WAITING", "APP"))
        self.assertEqual(row["last_user_request"], "second request")

    def test_title_prefers_user_names_over_ai_titles_and_ignores_derived_names(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            contexts = {100: (PROC_START, {})}
            titles = []
            for source in ("derived", "user"):
                claude.pid_file(100, name="apps-99" if source == "derived" else "Release notes", nameSource=source)
                with mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda pids, _=None: contexts}):
                    titles.append(COLLECT_ROWS(claude.home, live_only=True, include_subagents=False, limit=10)[0]["title"])
        self.assertEqual(titles, ["Readable title", "Release notes"])

    def test_busy_with_pending_prompt_is_waiting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            claude.pid_file(100, waitingFor="permission")
            with mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda pids, _=None: {100: (PROC_START, {})}}):
                rows = COLLECT_ROWS(claude.home, live_only=True, include_subagents=False, limit=10)
        self.assertEqual(rows[0]["status"], "WAITING")

    def test_shell_status_is_busy_and_new_sessions_without_transcripts_are_listed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            claude.pid_file(100, status="shell")
            claude.pid_file(200, "99999999-0000-0000-0000-000000000000", status="idle", name="setup-42")
            contexts = {100: (PROC_START, {}), 200: (PROC_START, {"ZELLIJ_PANE_ID": "5"})}
            with mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda pids, _=None: contexts}):
                rows = {row["session_id"]: row for row in COLLECT_ROWS(claude.home, live_only=True, include_subagents=True, limit=10)}
        self.assertEqual(rows[ROOT_ID]["status"], "BUSY")
        fresh = rows["99999999-0000-0000-0000-000000000000"]
        # A derived name ("setup-42") is neither a title nor a request.
        self.assertEqual((fresh["status"], fresh["zellij_pane_id"], fresh["last_user_request"], fresh["title"]), ("WAITING", "5", "-", "-"))

    def test_active_subagents_nest_under_live_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            claude.pid_file(100)
            subagents = claude.project / ROOT_ID / "subagents"
            subagents.mkdir(parents=True)
            (subagents / "agent-abc.jsonl").write_text(line({"type": "assistant", "message": {"model": "claude-haiku-4-5", "stop_reason": "tool_use"}}))
            (subagents / "agent-abc.meta.json").write_text(json.dumps({"agentType": "Explore", "description": "Find callers"}))
            (subagents / "agent-done.jsonl").write_text(line({"type": "assistant", "message": {"stop_reason": "end_turn"}}))
            with mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda pids, _=None: {100: (PROC_START, {})}}):
                rows = COLLECT_ROWS(claude.home, live_only=True, include_subagents=True, limit=10)
        self.assertEqual([row["session_id"] for row in rows], [ROOT_ID, "abc"])
        child = rows[1]
        self.assertEqual((child["thread_source"], child["parent_thread_id"], child["status"]), ("subagent", ROOT_ID, "BUSY"))
        self.assertEqual((child["last_user_request"], child["table_detail"]), ("Find callers", "Explore"))

    def test_sidechain_subagents_for_desktop_and_cli_keep_metadata_and_completion(self) -> None:
        for entrypoint in ("cli", "claude-desktop"):
            with self.subTest(entrypoint=entrypoint), tempfile.TemporaryDirectory() as temporary:
                claude = ClaudeHome(Path(temporary))
                claude.pid_file(100, entrypoint=entrypoint)
                directory = claude.project / ROOT_ID / "subagents"
                directory.mkdir(parents=True)
                path = directory / "agent-worker.jsonl"
                path.write_text(line({"type": "user", "isSidechain": True, "uuid": "u", "message": {"content": "Find callers"}})
                    + line({"type": "assistant", "isSidechain": True, "uuid": "a", "message": {
                        "id": "m", "model": "claude-haiku-4-5", "stop_reason": "tool_use",
                        "usage": {"input_tokens": 10, "output_tokens": 5}}}))
                cache = SCRIPT_GLOBALS["JsonlCache"]()
                with mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda *a, **k: {100: (PROC_START, {})}}):
                    rows = COLLECT_ROWS(claude.home, True, True, None, cache)
                    child = rows[1]
                    self.assertEqual((rows[0]["client_type"], child["root_session_id"]),
                                     ("APP" if entrypoint == "claude-desktop" else "CLI", ROOT_ID))
                    self.assertEqual((child["last_user_request"], child["model"], child["tokens_total"]),
                                     ("Find callers", "claude-haiku-4-5", 15))
                    count = cache.bytes_read
                    COLLECT_ROWS(claude.home, True, True, None, cache)
                    self.assertEqual(cache.bytes_read, count, "unchanged subagents reuse the incremental cache")
                    with path.open("a") as stream:
                        stream.write(line({"type": "assistant", "isSidechain": True, "uuid": "done",
                                           "message": {"stop_reason": "end_turn"}}))
                    rows = COLLECT_ROWS(claude.home, True, True, None, cache)
                    self.assertEqual([row["session_id"] for row in rows], [ROOT_ID])

    def test_subagent_ids_resolve_to_their_root_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            subagents = claude.project / ROOT_ID / "subagents"
            subagents.mkdir(parents=True)
            (subagents / "agent-abc.jsonl").write_text("")
            self.assertEqual(RESOLVE_SESSION(claude.home, "abc"), (ROOT_ID, [claude.project / f"{ROOT_ID}.jsonl"]))
            self.assertEqual(RESOLVE_SESSION(claude.home, ROOT_ID), (ROOT_ID, [claude.project / f"{ROOT_ID}.jsonl"]))
            self.assertEqual(RESOLVE_SESSION(claude.home, "missing"), ("missing", []))

    def test_stream_keeps_idle_and_finished_children_for_both_clients(self) -> None:
        for entrypoint in ("cli", "claude-desktop"):
            with self.subTest(entrypoint=entrypoint), tempfile.TemporaryDirectory() as temporary:
                claude = ClaudeHome(Path(temporary))
                claude.pid_file(100, entrypoint=entrypoint)
                directory = claude.project / ROOT_ID / "subagents"
                directory.mkdir(parents=True)
                path = directory / "agent-worker.jsonl"
                path.write_text(line({"type": "user", "isSidechain": True, "uuid": "u",
                                      "message": {"content": "Check the implementation"}}))
                contexts = {100: (PROC_START, {})}

                def exercise(_provider, _interval, collect):
                    first = collect()
                    self.assertEqual(first["active_subagents"][0]["status"], "BUSY")
                    old = time.time() - 600
                    os.utime(path, (old, old))
                    idle = collect()
                    self.assertEqual(idle["active_subagents"][0]["status"], "IDLE")
                    self.assertEqual(idle["subagents"][0]["session_id"], "worker")
                    with path.open("a") as stream:
                        stream.write(line({"type": "assistant", "isSidechain": True, "uuid": "done",
                                           "message": {"stop_reason": "end_turn"}}))
                    done = collect()
                    self.assertEqual(done["active_subagents"], [])
                    self.assertEqual((done["subagents"][0]["status"], done["subagents"][0]["liveness"]), ("CLOSED", "CLOSED"))
                    contexts.clear()
                    history = collect()
                    self.assertEqual(history["active_subagents"], [])
                    self.assertEqual(history["subagents"][0]["root_session_id"], ROOT_ID)
                    return 0

                with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(claude.home), "XDG_CACHE_HOME": temporary + "/cache"}), \
                     mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda *a, **k: contexts, "run_stream": exercise}):
                    self.assertEqual(MAIN(["--stream-json"]), 0)

    def test_history_lists_closed_sessions_newest_first(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(claude.home)}), \
                 mock.patch.dict(SCRIPT_GLOBALS, {"process_contexts": lambda pids, _=None: {}}):
                stream = io.StringIO()
                with redirect_stdout(stream):
                    self.assertEqual(MAIN(["--json", "--limit", "5"]), 0)
        rows = json.loads(stream.getvalue())
        self.assertEqual([row["session_id"] for row in rows], [ROOT_ID, OTHER_ID])
        self.assertTrue(all(row["status"] == "CLOSED" for row in rows))

    def test_jump_resumes_closed_session_only_in_the_first_ghostty_window(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            claude = ClaudeHome(Path(temporary))
            run = mock.Mock()
            with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(claude.home), "SHELL": "/bin/zsh"}), \
                 mock.patch.dict(SCRIPT_GLOBALS, {
                     "live_sessions": lambda home: {}, "command_path": lambda name: "/bin/claude",
                     "sys": mock.Mock(platform="darwin"), "subprocess": mock.Mock(run=run),
                 }):
                self.assertEqual(MAIN(["--jump", ROOT_ID]), 0)
        args = run.call_args.args[0]
        self.assertEqual(args[:4], ["/usr/bin/open", "-na", "Ghostty.app", "--args"])
        self.assertIn("--window-save-state=never", args)
        # --command= would make every later window and tab of that instance resume the session too.
        self.assertIn("--quit-after-last-window-closed=true", args)
        self.assertIn(f"--working-directory={claude.cwd}", args)
        self.assertFalse(any(arg.startswith("--command=") for arg in args))
        self.assertEqual(args[-1], f"--initial-command=/bin/zsh -lic 'cd {claude.cwd} && exec /bin/claude --resume {ROOT_ID}'")


if __name__ == "__main__":
    unittest.main()
