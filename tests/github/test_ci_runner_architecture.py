#!/usr/bin/env python3
# setup-test: CI runner architecture
"""Exercise the Linux tool download step with host architectures and no network."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
WORKFLOW = (ROOT / ".github/workflows/ci.yml").read_text()
STEP = WORKFLOW.split("      - name: Install fzf, Atuin and gitleaks\n", 1)[1]
STEP = STEP.split("      #", 1)[0].split("      - name:", 1)[0]
SCRIPT = "\n".join(line[10:] for line in STEP.split("        run: |\n", 1)[1].splitlines())
VERSIONS = dict(re.findall(r"^          (\w+_VERSION): ([\d.]+)$", STEP, re.MULTILINE))


class CIRunnerArchitectureTest(unittest.TestCase):
    def run_downloads(self, architecture):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            capture = directory / "downloads"
            capture.touch()
            environment = dict(os.environ, **VERSIONS, TEST_ARCH=architecture,
                               RUNNER_TEMP=temporary, GITHUB_PATH=str(directory / "path"),
                               CAPTURE=str(capture))
            stubs = (
                'uname() { printf "%s\\n" "$TEST_ARCH"; }\n'
                'curl() { printf "%s\\n" "$*" >>"$CAPTURE"; }\n'
                'tar() { cat >/dev/null; }\n'
            )
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", stubs + SCRIPT],
                                    env=environment, text=True, capture_output=True, timeout=10)
            return result, capture.read_text()

    def test_download_assets_match_runner_architecture(self):
        for architecture, fzf, atuin, gitleaks in (
            ("x86_64", "amd64", "x86_64", "x64"),
            ("aarch64", "arm64", "aarch64", "arm64"),
            ("arm64", "arm64", "aarch64", "arm64"),
        ):
            with self.subTest(architecture=architecture):
                result, downloads = self.run_downloads(architecture)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(downloads.splitlines()), 3)
                self.assertIn(f"fzf-{VERSIONS['FZF_VERSION']}-linux_{fzf}.tar.gz", downloads)
                self.assertIn(f"atuin-{atuin}-unknown-linux-gnu.tar.gz", downloads)
                self.assertIn(f"gitleaks_{VERSIONS['GITLEAKS_VERSION']}_linux_{gitleaks}.tar.gz", downloads)

    def test_unsupported_architecture_stops_before_download(self):
        result, downloads = self.run_downloads("unsupported")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported runner architecture", result.stderr)
        self.assertEqual(downloads, "")


if __name__ == "__main__":
    unittest.main()
