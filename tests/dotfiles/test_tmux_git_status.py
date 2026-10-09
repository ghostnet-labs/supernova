#!/usr/bin/env python3
# setup-test: tmux Git status
"""Regression tests for the shared tmux Git status cache."""

from __future__ import annotations

import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[2] / "dotfiles" / ".bin" / "tmux-git-status"
PORCELAIN = """\
# branch.oid abcdef1234567890
# branch.head main
# branch.ab +3 -4
# stash 2
1 .M
1 A.
1 .D
2 R.
u UU
? untracked
"""
EXPECTED = "repo:main M1 A1 D1 R1 U1 ?1 S2 ↑3 ↓4"


class TmuxGitStatusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.repo = self.root / "repo"
        self.child = self.repo / "nested"
        self.child.mkdir(parents=True)
        self.cache = self.root / "cache"
        self.fixture = self.root / "porcelain"
        self.fixture.write_text(PORCELAIN, encoding="utf-8")
        self.call_log = self.root / "status-calls"

        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        fake_git = fake_bin / "git"
        fake_git.write_text(
            """#!/bin/sh
case " $* " in
  *" rev-parse --show-toplevel "*)
    [ "${FAKE_GIT_NOT_REPO:-0}" = 1 ] && exit 1
    printf '%s\\n' "$FAKE_GIT_REPO_ROOT"
    ;;
  *" status --porcelain=v2 "*)
    printf 'status\\n' >> "$FAKE_GIT_CALL_LOG"
    [ "${FAKE_GIT_DELAY:-0}" = 0 ] || sleep "$FAKE_GIT_DELAY"
    cat "$FAKE_GIT_FIXTURE"
    ;;
  *) exit 2 ;;
esac
""",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)

        self.environment = os.environ.copy()
        self.environment.update(
            {
                "PATH": f"{fake_bin}:{self.environment['PATH']}",
                "FAKE_GIT_REPO_ROOT": str(self.repo),
                "FAKE_GIT_FIXTURE": str(self.fixture),
                "FAKE_GIT_CALL_LOG": str(self.call_log),
                "TMUX_GIT_STATUS_CACHE_DIR": str(self.cache),
                "TMUX_GIT_STATUS_CACHE_TTL": "5",
            }
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @property
    def cache_file(self) -> Path:
        return Path(f"{self.cache}{self.repo}") / "status"

    def process(self, **environment: str) -> subprocess.Popen[str]:
        merged_environment = self.environment | environment
        return subprocess.Popen(
            ["sh", str(SCRIPT), str(self.child)],
            env=merged_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def run_status(self, **environment: str) -> str:
        process = self.process(**environment)
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stderr, "")
        return stdout

    def status_call_count(self) -> int:
        if not self.call_log.exists():
            return 0
        return len(self.call_log.read_text(encoding="utf-8").splitlines())

    def expire_cache(self) -> None:
        lines = self.cache_file.read_text(encoding="utf-8").splitlines()
        self.cache_file.write_text(f"0\n{lines[1]}\n", encoding="utf-8")

    def test_formats_status_and_reuses_fresh_cache(self) -> None:
        self.assertEqual(self.run_status(), EXPECTED)
        self.fixture.write_text(PORCELAIN.replace("main", "changed"), encoding="utf-8")
        self.assertEqual(self.run_status(), EXPECTED)
        self.assertEqual(self.status_call_count(), 1)

    def test_serves_stale_value_while_one_process_refreshes(self) -> None:
        self.assertEqual(self.run_status(), EXPECTED)
        self.expire_cache()
        self.fixture.write_text(PORCELAIN.replace("main", "updated"), encoding="utf-8")

        refresher = self.process(FAKE_GIT_DELAY="0.3")
        time.sleep(0.05)
        self.assertEqual(self.run_status(), EXPECTED)
        refreshed, stderr = refresher.communicate(timeout=3)

        self.assertEqual(refresher.returncode, 0, stderr)
        self.assertEqual(refreshed, EXPECTED.replace("main", "updated"))
        self.assertEqual(self.status_call_count(), 2)

    def test_concurrent_cold_requests_share_one_git_scan(self) -> None:
        processes = [self.process(FAKE_GIT_DELAY="0.2") for _ in range(6)]
        results = [process.communicate(timeout=3) for process in processes]

        self.assertTrue(all(process.returncode == 0 for process in processes))
        self.assertEqual([stdout for stdout, _ in results], [EXPECTED] * 6)
        self.assertEqual([stderr for _, stderr in results], [""] * 6)
        self.assertEqual(self.status_call_count(), 1)

    def test_recovers_stale_lock(self) -> None:
        self.cache_file.parent.mkdir(parents=True)
        self.cache_file.with_name("status.lock").write_text("0\n", encoding="utf-8")

        self.assertEqual(self.run_status(), EXPECTED)
        self.assertEqual(self.status_call_count(), 1)

    def test_non_repository_is_a_quiet_success(self) -> None:
        self.assertEqual(self.run_status(FAKE_GIT_NOT_REPO="1"), "")
        self.assertEqual(self.status_call_count(), 0)


if __name__ == "__main__":
    unittest.main()
