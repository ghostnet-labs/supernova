#!/usr/bin/env python3
# setup-test: Dependabot auto-merge
"""Checks that only Dependabot's minor and patch bumps get auto-merge, and only after CI."""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
WORKFLOW = (ROOT / ".github" / "workflows" / "dependabot-auto-merge.yml").read_text()
DEPENDABOT = (ROOT / ".github" / "dependabot.yml").read_text()


class DependabotAutoMergeTest(unittest.TestCase):
    def test_runs_on_pull_request_without_running_pr_code(self):
        self.assertIn("\n  pull_request:\n", WORKFLOW)
        self.assertNotIn("pull_request_target", WORKFLOW, "pull_request keeps Dependabot's token scoped to its own PR")
        self.assertNotIn("actions/checkout", WORKFLOW, "the job never checks out the PR's code")
        self.assertIn("permissions: {}", WORKFLOW, "workflow-level permissions start empty")

    def test_only_dependabot_prs_in_this_repository(self):
        self.assertIn("github.event.pull_request.user.login == 'dependabot[bot]'", WORKFLOW)
        self.assertIn("github.repository == 'ghostnet-labs/supernova'", WORKFLOW)

    def test_major_bumps_are_left_for_review(self):
        self.assertIn("steps.metadata.outputs.update-type != 'version-update:semver-major'", WORKFLOW)

    def test_uses_auto_merge_with_rebase(self):
        self.assertIn('gh pr merge --auto --rebase "$PR_URL"', WORKFLOW,
                      "auto-merge waits for the ruleset's required checks; main only accepts rebase merges")
        self.assertNotIn("--admin", WORKFLOW)

    def test_grouped_pr_holds_only_minor_and_patch_bumps(self):
        self.assertIn("update-types: [minor, patch]", DEPENDABOT,
                      "a major bump in the group would make the whole grouped PR major and block auto-merge")


if __name__ == "__main__":
    unittest.main()
