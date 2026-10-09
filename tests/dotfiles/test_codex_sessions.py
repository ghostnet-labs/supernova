#!/usr/bin/env python3
# setup-test: codex-sessions transcripts
"""Focused regression tests for Codex session transcript discovery and rendering."""

from __future__ import annotations

import asyncio
import io
import json
import os
import runpy
import sqlite3
import subprocess
import tempfile
import time
import unittest
from contextlib import closing
from datetime import datetime
from pathlib import Path
from unittest import mock

try:
    import textual.app  # noqa: F401
except ImportError:
    TEXTUAL_AVAILABLE = False
else:
    TEXTUAL_AVAILABLE = True


SCRIPT = Path(__file__).parents[2] / "dotfiles" / ".bin" / "codex-sessions"
SCRIPT_GLOBALS = runpy.run_path(str(SCRIPT))
BUILD_TUI_APP = SCRIPT_GLOBALS["build_tui_app"]
DISCOVER_SESSIONS = SCRIPT_GLOBALS["discover_transcript_sessions"]
LIVE_ROLLOUT = SCRIPT_GLOBALS["LiveRollout"]
PARSE_OPTIONS = SCRIPT_GLOBALS["parse_report_options"]
READ_TRANSCRIPT = SCRIPT_GLOBALS["read_transcript"]
REPORT_OPTIONS = SCRIPT_GLOBALS["ReportOptions"]
TRANSCRIPT_SESSION = SCRIPT_GLOBALS["TranscriptSession"]
USAGE_ERROR = SCRIPT_GLOBALS["UsageError"]


def record(timestamp: str, record_type: str, payload: dict[str, object]) -> bytes:
    return (json.dumps({"timestamp": timestamp, "type": record_type, "payload": payload}) + "\n").encode()


def session_metadata(session_id: str, cwd: str, thread_source: str = "user") -> bytes:
    return record(
        "2026-09-02T12:00:00Z",
        "session_meta",
        {
            "id": session_id,
            "session_id": session_id,
            "cwd": cwd,
            "timestamp": "2026-09-02T12:00:00Z",
            "thread_source": thread_source,
        },
    )


class ClientTypeTests(unittest.TestCase):
    def test_desktop_and_terminal_clients(self) -> None:
        for source in ("Codex Desktop", "codex_work_desktop", "vscode"):
            self.assertEqual(SCRIPT_GLOBALS["client_type"](source), "APP")
        self.assertEqual(SCRIPT_GLOBALS["client_type"]("codex-tui"), "CLI")


class HeaderDetailsTests(unittest.TestCase):
    header_details = staticmethod(SCRIPT_GLOBALS["header_details"])

    def test_long_paths_shorten_and_the_other_parts_stay_whole(self) -> None:
        parts = ["git:main", "gpt-5.6-codex", "high reasoning", "1h 5m elapsed", "zellij:12", "abc12345…ef90"]
        details = self.header_details("/private/tmp/some/very/long/worktree/path/for/setup", parts, 110)
        self.assertLessEqual(len(details), 110)
        self.assertTrue(details.endswith(" · ".join(parts)), details)
        self.assertTrue(details.startswith("…") and "/for/setup · git:main" in details, details)
        # When even the other parts don't fit, the path shrinks first and only the tail is cut.
        tight = self.header_details("/private/tmp/some/very/long/worktree/path/for/setup", parts, 80)
        self.assertLessEqual(len(tight), 80)
        self.assertIn("1h 5m elapsed", tight)

    def test_short_paths_and_missing_parts_are_unchanged(self) -> None:
        self.assertEqual(self.header_details("~/dev/supernova", ["git:main", "", "1h elapsed"], 80),
                         "~/dev/supernova · git:main · 1h elapsed")
        self.assertEqual(self.header_details("", ["git:main"], 80), "git:main")

    def test_a_narrow_header_still_fits_its_width(self) -> None:
        details = self.header_details("/a/long/path/to/project", ["git:main", "gpt-5.6-codex", "high reasoning"], 30)
        self.assertLessEqual(len(details), 30)


class TranscriptParsingTests(unittest.TestCase):
    def test_reads_visible_messages_incrementally_and_waits_for_complete_lines(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "rollout-test.jsonl"
            prefix = b"".join(
                (
                    session_metadata("root", temporary),
                    record(
                        "2026-09-02T12:01:00Z",
                        "event_msg",
                        {"type": "user_message", "message": "Please inspect this."},
                    ),
                    record(
                        "2026-09-02T12:02:00Z",
                        "event_msg",
                        {"type": "agent_message", "message": "Working on it.", "phase": "commentary"},
                    ),
                )
            )
            final = record(
                "2026-09-02T12:03:00Z",
                "event_msg",
                {"type": "agent_message", "message": "Done.", "phase": "final_answer"},
            )
            split = len(final) // 2
            path.write_bytes(prefix + final[:split])

            messages, offset = READ_TRANSCRIPT(path)
            self.assertEqual([message.text for message in messages], ["Please inspect this.", "Working on it."])
            self.assertEqual(offset, len(prefix))

            with path.open("ab") as stream:
                stream.write(final[split:])
            messages, new_offset = READ_TRANSCRIPT(path, offset)
            self.assertEqual([message.text for message in messages], ["Done."])
            self.assertEqual(messages[0].phase, "final_answer")
            self.assertEqual(new_offset, path.stat().st_size)


class TranscriptDiscoveryTests(unittest.TestCase):
    def test_defaults_to_root_sessions_and_marks_exact_open_rollout_live(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            codex_home = Path(temporary)
            sessions_dir = codex_home / "sessions" / "2026" / "09" / "02"
            sessions_dir.mkdir(parents=True)
            root = sessions_dir / "rollout-root.jsonl"
            child = sessions_dir / "rollout-child.jsonl"
            root.write_bytes(session_metadata("root", "/tmp/project"))
            child.write_bytes(session_metadata("child", "/tmp/project", "subagent"))
            live = LIVE_ROLLOUT(pid=123, zellij_session="work", zellij_pane_id="7")

            with mock.patch.dict(
                DISCOVER_SESSIONS.__globals__,
                {
                    "live_rollouts": mock.Mock(return_value={root.resolve(): live}),
                    "load_thread_index": mock.Mock(
                        return_value={
                            "root": {"model": "gpt-5.6-codex", "reasoning_effort": "high", "git_branch": "main"}
                        }
                    ),
                },
            ):
                roots = DISCOVER_SESSIONS(codex_home)
                all_sessions = DISCOVER_SESSIONS(codex_home, include_subagents=True)

            self.assertEqual([session.session_id for session in roots], ["root"])
            self.assertEqual(roots[0].live, live)
            self.assertEqual((roots[0].model, roots[0].reasoning_effort, roots[0].git_branch),
                             ("gpt-5.6-codex", "high", "main"))
            self.assertEqual({session.session_id for session in all_sessions}, {"root", "child"})

    def test_rollouts_from_before_thread_source_are_roots_unless_spawned(self) -> None:
        report = SCRIPT_GLOBALS["report"]
        root_id = "019c3395-58a3-70b0-a107-03f103f423fe"
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            sessions = home / "sessions"
            sessions.mkdir()
            # Codex 0.128 and older wrote no thread_source; only its subagents had an object source.
            (sessions / "rollout-root.jsonl").write_bytes(record("2026-02-06T15:32:31Z", "session_meta", {
                "id": root_id, "cwd": temporary, "timestamp": "2026-02-06T15:32:31Z",
                "originator": "codex_cli_rs", "source": "cli",
            }))
            (sessions / "rollout-agent.jsonl").write_bytes(record("2026-02-06T15:33:00Z", "session_meta", {
                "id": "agent", "forked_from_id": root_id, "cwd": temporary, "timestamp": "2026-02-06T15:33:00Z",
                "originator": "codex_cli_rs", "source": {"subagent": {"thread_spawn": {"parent_thread_id": root_id}}},
            }))
            output, errors = io.StringIO(), io.StringIO()
            with mock.patch.dict(os.environ, {"CODEX_HOME": temporary}), mock.patch.dict(
                report.__globals__, {"live_rollouts": mock.Mock(return_value={})}
            ):
                result = report(PARSE_OPTIONS(["--json"]), output, errors, False)
                discovered = DISCOVER_SESSIONS(home)
            rows = json.loads(output.getvalue())
            self.assertEqual((result, [row["session_id"] for row in rows]), (0, [root_id]))
            self.assertEqual([session.session_id for session in discovered], [root_id])
            self.assertEqual((rows[0]["thread_source"], rows[0]["client_type"], rows[0]["status"]), ("user", "CLI", "CLOSED"))
            url = SCRIPT_GLOBALS["resume_url"](rows[0], "", "")
            self.assertEqual(SCRIPT_GLOBALS["parse_resume_url"](url)[:2], (root_id, home))

    def test_darwin_live_rollouts_reads_multiplexer_environment(self) -> None:
        darwin_live_rollouts = SCRIPT_GLOBALS["darwin_live_rollouts"]
        with tempfile.TemporaryDirectory() as temporary:
            sessions_dir = Path(temporary).resolve()
            rollout = sessions_dir / "rollout-root.jsonl"
            rollout.write_bytes(session_metadata("root", "/tmp/project"))
            outputs = [
                mock.Mock(returncode=0, stdout="42 ttys001 Wed Sep  2 12:00:00 2026 codex resume TMUX=/private/tmp/tmux-501/default,9,0 TMUX_PANE=%7 ZELLIJ_SESSION_NAME=work\n"),
                mock.Mock(returncode=0, stdout=f"p42\nfcwd\nn/tmp/project\nf20\nn{rollout}\n"),
            ]
            with mock.patch("sys.platform", "darwin"), \
                 mock.patch("subprocess.run", side_effect=outputs):
                live = darwin_live_rollouts(sessions_dir)
        context = live[rollout]
        self.assertEqual((context.tmux_socket, context.tmux_pane, context.zellij_session),
                         ("/private/tmp/tmux-501/default", "%7", "work"))

    def test_daemon_held_rollouts_are_credited_to_the_tui_showing_them(self) -> None:
        darwin_live_rollouts = SCRIPT_GLOBALS["darwin_live_rollouts"]
        started = time.strftime("%a %b %d %H:%M:%S %Y", time.localtime(datetime.fromisoformat("2026-09-02T12:00:03+00:00").timestamp()))
        with tempfile.TemporaryDirectory() as temporary:
            sessions_dir = Path(temporary).resolve()
            root = sessions_dir / "rollout-root.jsonl"
            child = sessions_dir / "rollout-child.jsonl"
            root.write_bytes(session_metadata("root", "/tmp/project"))
            child.write_bytes(record("2026-09-02T12:00:00Z", "session_meta",
                                     {"id": "child", "session_id": "root", "cwd": "/tmp/project", "thread_source": "subagent"}))
            outputs = [
                mock.Mock(returncode=0, stdout=(
                    "7 ?? Tue Sep  1 08:00:00 2026 /x/bin/codex app-server --listen unix://\n"
                    f"42 ttys004 {started} codex TMUX=/private/tmp/tmux-501/default,9,0 TMUX_PANE=%7\n"
                )),
                mock.Mock(returncode=0, stdout=f"p7\nf20\nn{root}\nf21\nn{child}\np42\nfcwd\nn/tmp/project\n"),
            ]
            with mock.patch("sys.platform", "darwin"), \
                 mock.patch("subprocess.run", side_effect=outputs):
                live = darwin_live_rollouts(sessions_dir)
        self.assertEqual((live[root].pid, live[root].tmux_pane), (42, "%7"))
        self.assertEqual(live[child].pid, 42)

    def test_rows_carry_the_thread_title_on_one_line(self) -> None:
        scan_rollout = SCRIPT_GLOBALS["scan_rollout"]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "rollout-root.jsonl"
            path.write_bytes(session_metadata("root", "/tmp/project"))
            info = {"path": path, "stat": path.stat(), "metadata": {"id": "root", "session_id": "root", "cwd": "/tmp/project"}}
            titled = scan_rollout(info, {"root": {"title": "fix the\n  popover"}}, SCRIPT_GLOBALS["Counter"]())
            untitled = scan_rollout(info, {}, SCRIPT_GLOBALS["Counter"]())
        self.assertEqual((titled["title"], untitled["title"]), ("fix the popover", "-"))

    def test_rows_report_the_context_window_fill(self) -> None:
        scan_rollout = SCRIPT_GLOBALS["scan_rollout"]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "rollout-root.jsonl"

            def usage(total: int) -> dict[str, object]:
                return {"total_token_usage": {"total_tokens": 900}, "last_token_usage": {"total_tokens": total}, "model_context_window": 258400}

            path.write_bytes(session_metadata("root", "/tmp/project")
                             + record("2026-09-02T12:00:01Z", "event_msg", {"type": "token_count", "info": usage(5000)})
                             + record("2026-09-02T12:00:02Z", "event_msg", {"type": "token_count", "info": usage(7000)}))
            info = {"path": path, "stat": path.stat(), "metadata": {"id": "root", "session_id": "root", "cwd": "/tmp/project"}}
            row = scan_rollout(info, {}, SCRIPT_GLOBALS["Counter"]())
        self.assertEqual((row["context_used_tokens"], row["context_window_tokens"]), (7000, 258400))

    def test_daemon_attribution_needs_an_unambiguous_tui(self) -> None:
        attribute = SCRIPT_GLOBALS["attribute_daemon_rollouts"]
        codex_tui = SCRIPT_GLOBALS["CodexTui"]
        daemon = LIVE_ROLLOUT(pid=7)
        metadata = {
            Path("/r/a"): {"id": "a", "cwd": "/one", "timestamp": "2026-09-02T12:00:00Z", "thread_source": "user"},
            Path("/r/b"): {"id": "b", "cwd": "/two", "timestamp": "2026-09-02T12:00:00Z", "thread_source": "user"},
            Path("/r/c"): {"id": "c", "cwd": "/three", "timestamp": "2026-09-02T12:00:00Z", "thread_source": "user"},
        }
        tuis = {
            10: codex_tui(LIVE_ROLLOUT(pid=10), "codex", "/one", 0),
            20: codex_tui(LIVE_ROLLOUT(pid=20), "codex", "/two", 0),
            21: codex_tui(LIVE_ROLLOUT(pid=21), "codex", "/two", 0),
            30: codex_tui(LIVE_ROLLOUT(pid=30), "codex resume c", "/elsewhere", 0),
        }
        live = attribute({path: daemon for path in metadata}, tuis, metadata.get)
        # Only TUI in /one; two TUIs in /two stay ambiguous; `resume c` names its session.
        self.assertEqual({path.name: context.pid for path, context in live.items()}, {"a": 10, "b": 7, "c": 30})


class SessionTitleTests(unittest.TestCase):
    def test_saved_names_precede_prompt_titles_and_preserve_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "state_5.sqlite"
            with closing(sqlite3.connect(path)) as connection, connection:
                connection.execute("CREATE TABLE threads (id TEXT, name TEXT, title TEXT, first_user_message TEXT, model TEXT)")
                connection.executemany("INSERT INTO threads VALUES (?, ?, ?, ?, ?)", [
                    ("named", " Current\tname\n", "Long request", "Long request", "model-test"),
                    ("indexed", " \n", "Long request", "Long request", "model-test"),
                    ("custom", None, "Custom title", "Long request", "model-test"),
                    ("untitled", None, "Long\trequest", "Long request", "model-test"),
                ])
            entries = [
                {"id": "named", "thread_name": "Stale index name"},
                {"id": "indexed", "thread_name": "Original name"},
                {"id": "indexed", "thread_name": " Updated\n name "},
                {"id": "indexed", "thread_name": " "},
                {"id": "indexed", "thread_name": 42},
                {"id": [], "thread_name": "Invalid ID"},
                None, [],
            ]
            index_path = path.with_name("session_index.jsonl")
            index_path.write_bytes(("\n".join(json.dumps(entry) for entry in entries) + "\n").encode()
                                   + b"\xff\n{incomplete")
            before = (path.read_bytes(), index_path.read_bytes())
            index = SCRIPT_GLOBALS["load_thread_index"](path)
            titles = {key: SCRIPT_GLOBALS["session_title"](row) for key, row in index.items()}
            self.assertEqual(titles, {"named": "Current name", "indexed": "Updated name", "custom": "Custom title", "untitled": ""})
            self.assertTrue(all(row["model"] == "model-test" for row in index.values()))
            self.assertEqual((path.read_bytes(), index_path.read_bytes()), before)

    def test_index_names_work_with_legacy_missing_or_unreadable_databases(self) -> None:
        for mode in ("legacy", "missing", "corrupt", "no_table"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "state_5.sqlite"
                if mode in ("legacy", "no_table"):
                    with closing(sqlite3.connect(path)) as connection, connection:
                        if mode == "legacy":
                            connection.execute("CREATE TABLE threads (id TEXT, title TEXT, first_user_message TEXT)")
                            connection.execute("INSERT INTO threads VALUES ('root', 'Long request', 'Long request')")
                elif mode == "corrupt":
                    path.write_text("invalid SQLite")
                path.with_name("session_index.jsonl").write_text(json.dumps({"id": "root", "thread_name": "Short title"}) + "\n")
                index = SCRIPT_GLOBALS["load_thread_index"](path)
                self.assertEqual(SCRIPT_GLOBALS["session_title"](index["root"]), "Short title")
                if mode == "missing":
                    self.assertFalse(path.exists())
                path.with_name("session_index.jsonl").unlink()
                index = SCRIPT_GLOBALS["load_thread_index"](path)
                self.assertEqual(SCRIPT_GLOBALS["session_title"](index.get("root", {})), "")

    def test_names_reach_live_json_and_transcript_browser(self) -> None:
        report = SCRIPT_GLOBALS["report"]
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            sessions = home / "sessions"
            sessions.mkdir()
            rollout = sessions / "rollout-root.jsonl"
            rollout.write_bytes(session_metadata("root", "/tmp/project")
                                + record("2026-09-02T12:01:00Z", "response_item", {
                                    "type": "message", "role": "user",
                                    "content": [{"type": "input_text", "text": "The entire initial request"}],
                                }))
            (home / "session_index.jsonl").write_text(json.dumps({"id": "root", "thread_name": "Readable title"}) + "\n")
            output, errors = io.StringIO(), io.StringIO()
            with mock.patch.dict(os.environ, {"CODEX_HOME": temporary}), mock.patch.dict(
                report.__globals__, {"live_rollouts": mock.Mock(return_value={rollout.resolve(): LIVE_ROLLOUT(pid=123)})}
            ):
                result = report(PARSE_OPTIONS(["--json", "--live", "--all", "--limit", "200"]), output, errors, False)
                discovered = DISCOVER_SESSIONS(home)
            self.assertEqual((result, errors.getvalue()), (0, ""))
            rows = json.loads(output.getvalue())
            self.assertEqual((rows[0]["title"], discovered[0].title), ("Readable title", "Readable title"))
            self.assertEqual(rows[0]["first_user_request"], "The entire initial request")

    def test_cached_rollouts_refresh_names_without_rescanning_transcripts(self) -> None:
        cached_scan = SCRIPT_GLOBALS["cached_scan_rollout"]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "rollout-root.jsonl"
            path.write_bytes(session_metadata("root", "/tmp/project"))
            info = {"path": path, "stat": path.stat(), "metadata": {"id": "root", "session_id": "root"}}
            index = {"root": {"title": "Long request", "first_user_message": "Long request"}}
            cache = SCRIPT_GLOBALS["ReportCache"](rows={})
            scan = mock.Mock(wraps=SCRIPT_GLOBALS["scan_rollout"])
            with mock.patch.dict(cached_scan.__globals__, {"scan_rollout": scan}):
                unnamed = cached_scan(info, index, SCRIPT_GLOBALS["Counter"](), cache)
                index["root"]["name"] = "Generated title"
                named = cached_scan(info, index, SCRIPT_GLOBALS["Counter"](), cache)
                index["root"]["name"] = "Renamed title"
                renamed = cached_scan(info, index, SCRIPT_GLOBALS["Counter"](), cache)
            self.assertEqual([row["title"] for row in (unnamed, named, renamed)], ["-", "Generated title", "Renamed title"])
            scan.assert_called_once()


class SessionJumpTests(unittest.TestCase):
    def test_closed_and_daemon_sessions_resume_in_recorded_directory(self) -> None:
        jump = SCRIPT_GLOBALS["jump_to_session"]
        launch = SCRIPT_GLOBALS["launch_resume"]
        namespace = jump.__globals__
        with tempfile.TemporaryDirectory() as temporary:
            cwd = Path(temporary) / "project's directory"
            cwd.mkdir()
            executable = cwd / "fake codex"
            executable.write_text('#!/bin/sh\npwd\nprintf \'%s\\n\' "$@"\n')
            executable.chmod(0o700)
            for mode in ("closed", "daemon", "url"):
                with self.subTest(mode=mode):
                    session = mock.Mock(session_id="root", cwd=str(cwd), live=LIVE_ROLLOUT(pid=42) if mode == "daemon" else None)
                    run = mock.Mock(return_value=mock.Mock(returncode=0, stdout="??\n"))
                    with mock.patch.dict(namespace, discover_transcript_sessions=mock.Mock(return_value=[session]),
                                         command_path=mock.Mock(return_value=str(executable)),
                                         parse_resume_url=mock.Mock(return_value=("root", cwd, "", ""))), \
                         mock.patch.object(namespace["sys"], "platform", "darwin"), \
                         mock.patch.object(namespace["subprocess"], "run", run), \
                         mock.patch.dict(os.environ, SHELL="/bin/sh"):
                        self.assertEqual(launch("unused") if mode == "url" else jump("root"), 0)
                    command = run.call_args.args[0]
                    self.assertEqual(command[:6], ["/usr/bin/open", "-na", "Ghostty.app", "--args", "--window-save-state=never", f"--working-directory={cwd}"])
                    # Execute the generated command from the wrong directory: it must
                    # reach the saved directory and preserve the resume arguments.
                    result = subprocess.run(["/bin/sh", "-c", command[-1].removeprefix("--initial-command=")], cwd=temporary, capture_output=True, text=True, check=True)
                    output = result.stdout.splitlines()
                    self.assertEqual(Path(output[0]).resolve(), cwd.resolve())
                    self.assertEqual(output[1:], ["resume", "root"])

    def test_attached_terminal_is_focused_without_resuming(self) -> None:
        jump = SCRIPT_GLOBALS["jump_to_session"]
        namespace = jump.__globals__
        session = mock.Mock(session_id="root", cwd="/project", live=LIVE_ROLLOUT(pid=42))
        focus = mock.Mock()
        with mock.patch.dict(namespace, discover_transcript_sessions=mock.Mock(return_value=[session]), show_terminal=focus), \
             mock.patch.object(namespace["subprocess"], "run", return_value=mock.Mock(returncode=0, stdout="ttys001\n")) as run:
            self.assertEqual(jump("root"), 0)
        focus.assert_called_once_with(42, "/project")
        self.assertEqual(run.call_count, 1)


class TranscriptCliTests(unittest.TestCase):
    def test_live_json_mode_is_explicit(self) -> None:
        options = PARSE_OPTIONS(["--json", "--live", "--all"])
        self.assertTrue(options.json_output)
        self.assertTrue(options.live_only)
        self.assertTrue(options.include_subagents)
        with self.assertRaises(USAGE_ERROR):
            PARSE_OPTIONS(["--live"])

    def test_live_rollout_carries_multiplexer_targets(self) -> None:
        live = LIVE_ROLLOUT(
            pid=123,
            zellij_session="work",
            zellij_pane_id="7",
            tmux_socket="/tmp/tmux-501/default",
            tmux_pane="%4",
        )
        self.assertEqual(live.zellij_pane_id, "7")
        self.assertEqual(live.tmux_pane, "%4")

    def test_tui_mode_is_explicit_and_rejects_output_modes(self) -> None:
        self.assertTrue(PARSE_OPTIONS(["--tui"]).tui)
        for incompatible in ("--watch", "--json", "--verbose"):
            with self.subTest(incompatible=incompatible), self.assertRaises(USAGE_ERROR):
                PARSE_OPTIONS(["--tui", incompatible])

    @unittest.skipUnless(TEXTUAL_AVAILABLE, "Textual is installed only in the work Python environment")
    def test_textual_app_mounts_with_a_real_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "rollout-root.jsonl"
            other_path = Path(temporary) / "rollout-other.jsonl"
            history_path = Path(temporary) / "rollout-history.jsonl"
            archived_path = Path(temporary) / "rollout-archived.jsonl"
            path.write_bytes(
                session_metadata("root", temporary)
                + record(
                    "2026-09-02T12:01:00Z",
                    "event_msg",
                    {
                        "type": "user_message",
                        "message": "**Hello** `viewer`.\n\n"
                        + ("This transcript line must reflow when its pane gets wider. " * 40)
                        + "\n\n```python\nplain_name = custom_value\nprint(\"ok\")\n```",
                    },
                )
                + record(
                    "2026-09-02T12:02:00Z",
                    "event_msg",
                    {"type": "agent_message", "message": "Checking the viewer.", "phase": "commentary"},
                )
                + record(
                    "2026-09-02T12:03:00Z",
                    "event_msg",
                    {"type": "agent_message", "message": "Viewer ready.", "phase": "final_answer"},
                )
            )
            other_path.write_bytes(session_metadata("other", temporary))
            history_path.write_bytes(session_metadata("history", temporary))
            archived_path.write_bytes(session_metadata("archived", temporary))
            summary = TRANSCRIPT_SESSION(
                session_id="root",
                path=path,
                cwd=str(Path.cwd()),
                title="Hello viewer",
                updated_at=path.stat().st_mtime,
                live=LIVE_ROLLOUT(pid=123, zellij_session="work", zellij_pane_id="7"),
                archived=False,
                thread_source="user",
                model="gpt-5.6-codex",
                reasoning_effort="high",
                git_branch="main",
                started_at=time.time() - 3600,
            )
            other = TRANSCRIPT_SESSION(
                session_id="other",
                path=other_path,
                cwd=temporary,
                title="Other live work",
                updated_at=other_path.stat().st_mtime,
                live=LIVE_ROLLOUT(pid=456, zellij_session="work", zellij_pane_id="8"),
                archived=False,
                thread_source="user",
            )
            history = TRANSCRIPT_SESSION(
                session_id="history",
                path=history_path,
                cwd=temporary,
                title="Earlier work",
                updated_at=history_path.stat().st_mtime,
                live=None,
                archived=False,
                thread_source="user",
            )
            archived = TRANSCRIPT_SESSION(
                session_id="archived",
                path=archived_path,
                cwd=temporary,
                title="Archived work",
                updated_at=archived_path.stat().st_mtime,
                live=None,
                archived=True,
                thread_source="user",
            )

            async def resize(app, pilot, width: int, height: int) -> None:
                # Resizes reflow the transcript on a debounce timer and restore the scroll
                # position after later refreshes; wait for that instead of a fixed pause.
                await pilot.resize_terminal(width, height)
                for _ in range(100):
                    await pilot.pause(0.05)
                    if app.layout_width == width and app.transcript_resize_timer is None:
                        break
                await pilot.pause()
                await pilot.pause()

            async def mount() -> None:
                with mock.patch.dict(
                    BUILD_TUI_APP.__globals__,
                    {"discover_transcript_sessions": mock.Mock(return_value=[archived, history, other, summary])},
                ):
                    app = BUILD_TUI_APP(REPORT_OPTIONS(tui=True))
                    async with app.run_test(size=(120, 36)) as pilot:
                        await pilot.pause()
                        self.assertEqual(app.theme, "tokyo-night")
                        self.assertNotIn("Theme", [command.title for command in app.get_system_commands(app.screen)])
                        self.assertEqual(app.scroll_sensitivity_y, 1.0)
                        self.assertEqual(len(app.query("Header")), 0)
                        self.assertEqual(app.selected.session_id if app.selected else None, "root")
                        self.assertEqual(app.selected_offset, path.stat().st_size)
                        self.assertEqual(
                            [item.section for item in app.query(".session-section")],
                            ["LIVE", "HISTORY", "ARCHIVED"],
                        )
                        self.assertEqual(app.query_one(".session-section").styles.color.hex, "#7F849C")
                        self.assertEqual(app.query_one("#sidebar").region.width, 36)
                        self.assertEqual(app.query_one("#main").region.width, 84)
                        selected_item = next(
                            item for item in app.query(".session-item") if item.session.session_id == "root"
                        )
                        self.assertEqual(selected_item.styles.background.hex, "#2E3654")
                        self.assertEqual(app.query_one("#session-header").region.height, 3)
                        session_header = str(app.query_one("#session-header").content)
                        self.assertIn("● LIVE", session_header)
                        self.assertIn("git:main", session_header)
                        self.assertIn("gpt-5.6-codex", session_header)
                        self.assertIn("high reasoning", session_header)
                        self.assertIn("elapsed", session_header)
                        transcript = app.query_one("#transcript")
                        self.assertEqual(transcript.min_width, 1)
                        transcript_text = "\n".join(line.text for line in transcript.lines)
                        self.assertIn("│", transcript_text)
                        self.assertIn("╭", transcript_text)
                        self.assertIn("╰", transcript_text)
                        self.assertIn("CODEX · UPDATE", transcript_text)
                        self.assertIn("CODEX · FINAL", transcript_text)
                        final_frame = "\n".join(line.text for line in transcript.lines[-4:])
                        self.assertNotIn("╮", final_frame)
                        self.assertNotIn("╯", final_frame)
                        rendered_styles = [str(segment.style).lower() for line in transcript.lines for segment in line]
                        for old_background in ("#211c2d", "#1b2337", "#1d2a29"):
                            self.assertFalse(any(f"on {old_background}" in style for style in rendered_styles))
                        for accent in ("#bb9af7", "#7aa2f7", "#9ece6a"):
                            self.assertTrue(
                                any("╭" in segment.text and accent in str(segment.style).lower()
                                    for line in transcript.lines for segment in line)
                            )
                        code_border_styles = [
                            segment.style
                            for line in transcript.lines
                            for segment in line
                            if "╭" in segment.text and "#5f668f" in str(segment.style).lower()
                        ]
                        self.assertTrue(code_border_styles)
                        self.assertTrue(all("on #16161e" not in str(style).lower() for style in code_border_styles))
                        expected_day = app.message_day_label(
                            datetime.fromisoformat("2026-09-02T12:01:00+00:00").timestamp()
                        )
                        self.assertIn(f"── {expected_day}", transcript_text)
                        date_rule = next(line for line in transcript.lines if f"── {expected_day}" in line.text)
                        self.assertGreater(date_rule.cell_length, 40)
                        self.assertNotIn("**", transcript_text)
                        self.assertNotIn("`viewer`", transcript_text)
                        plain_code_styles = [
                            segment.style
                            for line in transcript.lines
                            for segment in line
                            if segment.text in {"plain_name", "custom_value"}
                        ]
                        self.assertEqual(len(plain_code_styles), 2)
                        self.assertTrue(all("#c0caf5" in str(style).lower() for style in plain_code_styles))
                        self.assertEqual(
                            {style.bgcolor for style in code_border_styles},
                            {style.bgcolor for style in plain_code_styles},
                        )
                        self.assertNotIn("palette", str(app.query_one("#footer").content))
                        self.assertTrue(
                            any("on #24283b" in str(span.style).lower() for span in app.query_one("#footer").content.spans)
                        )
                        self.assertEqual(app.query_one("#footer").styles.background.hex, "#16161E")
                        with other_path.open("ab") as stream:
                            stream.write(
                                record(
                                    "2026-09-02T12:04:00Z",
                                    "event_msg",
                                    {"type": "agent_message", "message": "New elsewhere.", "phase": "commentary"},
                                )
                            )
                        app.poll_selected()
                        await pilot.pause()
                        other_item = next(
                            item for item in app.query(".session-item") if item.session.session_id == "other"
                        )
                        self.assertEqual(other_item.unread, 1)
                        view = app.query_one("#session-list")
                        view.index = list(view.children).index(other_item)
                        await pilot.pause()
                        self.assertEqual(other_item.unread, 0)
                        for selector in ("#session-list", "#transcript"):
                            styles = app.query_one(selector).styles
                            self.assertEqual(styles.scrollbar_size_vertical, 1)
                            self.assertEqual(styles.scrollbar_size_horizontal, 0)
                            self.assertEqual(styles.scrollbar_color.hex, "#5F668F")
                            self.assertEqual(styles.scrollbar_color_hover.hex, "#8992B3")
                            self.assertEqual(styles.scrollbar_background.a, 0)
                        history_item = next(
                            item
                            for item in app.query(".session-item")
                            if item.session.session_id == "history"
                        )
                        view.index = list(view.children).index(history_item)
                        await pilot.pause()
                        self.assertTrue(app.query_one("#transcript-empty").display)
                        self.assertIn("NO MESSAGES YET", str(app.query_one("#transcript-empty").content))
                        root_item = next(
                            item for item in app.query(".session-item") if item.session.session_id == "root"
                        )
                        view.index = list(view.children).index(root_item)
                        await pilot.pause()
                        self.assertFalse(app.query_one("#transcript-empty").display)
                        await resize(app, pilot, 71, 30)
                        self.assertTrue(app.screen.has_class("narrow"))
                        self.assertEqual(app.query_one("#sidebar").region.width, 71)
                        self.assertEqual(app.query_one("#main").region.width, 0)
                        await resize(app, pilot, 72, 30)
                        self.assertFalse(app.screen.has_class("narrow"))
                        self.assertEqual(app.query_one("#sidebar").region.width, 34)
                        self.assertEqual(app.query_one("#main").region.width, 38)
                        await resize(app, pilot, 44, 30)
                        self.assertTrue(app.screen.has_class("narrow"))
                        self.assertEqual(app.query_one("#sidebar").region.width, 44)
                        self.assertEqual(app.query_one("#main").region.width, 0)
                        await pilot.press("enter")
                        await pilot.pause()
                        self.assertTrue(app.screen.has_class("show-transcript"))
                        self.assertEqual(app.query_one("#main").region.width, 44)
                        self.assertEqual(app.query_one("#transcript").region.width, 44)
                        await pilot.press("pageup")
                        await pilot.pause()
                        self.assertFalse(app.follow)
                        self.assertIn("f paused", str(app.query_one("#footer").content))
                        self.assertRegex(str(app.query_one("#footer").content), r"\d+%")
                        self.assertTrue(app.screen.has_class("follow-paused"))
                        self.assertEqual(transcript.styles.scrollbar_color.hex, "#FF9E64")
                        with path.open("ab") as stream:
                            stream.write(
                                record(
                                    "2026-09-02T12:04:00Z",
                                    "event_msg",
                                    {
                                        "type": "agent_message",
                                        "message": "A new paused update.",
                                        "phase": "commentary",
                                    },
                                )
                            )
                        app.poll_selected()
                        await pilot.pause()
                        self.assertEqual(app.unread_messages, 1)
                        self.assertIn("↓1", str(app.query_one("#footer").content))
                        narrow_line_count = len(transcript.lines)
                        narrow_scroll_ratio = float(transcript.scroll_y) / max(
                            1.0, float(transcript.max_scroll_y)
                        )
                        await resize(app, pilot, 120, 30)
                        self.assertFalse(app.screen.has_class("narrow"))
                        self.assertEqual(app.query_one("#sidebar").region.width, 36)
                        self.assertEqual(app.query_one("#main").region.width, 84)
                        self.assertLess(len(transcript.lines), narrow_line_count)
                        self.assertIn("↓ 1 new", str(app.query_one("#footer").content))
                        self.assertAlmostEqual(
                            float(transcript.scroll_y) / max(1.0, float(transcript.max_scroll_y)),
                            narrow_scroll_ratio,
                            delta=0.05,
                        )
                        await pilot.press("f")
                        await pilot.pause()
                        self.assertTrue(app.follow)
                        self.assertEqual(app.unread_messages, 0)
                        self.assertFalse(app.screen.has_class("follow-paused"))
                        self.assertEqual(transcript.styles.scrollbar_color.hex, "#5F668F")
                        self.assertNotIn("new", str(app.query_one("#footer").content))
                        await pilot.press("s")
                        await pilot.pause()
                        self.assertFalse(app.screen.has_class("show-transcript"))
                        self.assertEqual(app.focused.id if app.focused else None, "session-list")
                        await pilot.click("#session-filter")
                        await pilot.press(*tuple("viewer"))
                        await pilot.pause()
                        self.assertEqual(app.query_one("#session-filter").value, "viewer")
                        self.assertEqual(app.focused.id if app.focused else None, "session-filter")
                        app.query_one("#session-filter").value = "does-not-exist"
                        await pilot.pause()
                        self.assertEqual(
                            app.query_one(".empty-state Label").content,
                            "◇  NO MATCHES\n   Try another filter",
                        )
                        self.assertTrue(app.query_one("#transcript-empty").display)
                        self.assertIn("NO MATCHES", str(app.query_one("#transcript-empty").content))

            asyncio.run(mount())


if __name__ == "__main__":
    unittest.main()
