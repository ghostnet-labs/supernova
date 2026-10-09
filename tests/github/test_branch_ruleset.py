#!/usr/bin/env python3
# setup-test: Branch ruleset
"""Checks that .github/rulesets/main.json requires only checks the workflows report."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
RULESET = json.loads((ROOT / ".github" / "rulesets" / "main.json").read_text())
WORKFLOWS = sorted((ROOT / ".github" / "workflows").glob("*.yml"))


def job_names(workflows: list[Path] = WORKFLOWS) -> set[str]:
    """The name: of every job; GitHub reports each job as a check with that name."""
    names = set()
    for path in workflows:
        in_jobs = False
        for line in path.read_text().splitlines():
            if re.match(r"^\S", line):
                in_jobs = line == "jobs:"
            match = re.match(r"^    name: (.+)$", line)
            if in_jobs and match:
                names.add(match.group(1).strip())
    return names


def rule(kind: str) -> dict:
    return next(r for r in RULESET["rules"] if r["type"] == kind)


def required_checks() -> set[str]:
    return {c["context"] for c in rule("required_status_checks")["parameters"]["required_status_checks"]}


class BranchRulesetTest(unittest.TestCase):
    def test_required_checks_match_job_names(self):
        # A required check that no job reports stays pending and blocks every merge.
        required = required_checks()
        self.assertTrue(required)
        self.assertLessEqual(required, job_names())

    def test_every_ci_job_is_required(self):
        # Every job in ci.yml scans or tests, so a PR merges only when all of them pass.
        ci_jobs = job_names([ROOT / ".github" / "workflows" / "ci.yml"])
        self.assertTrue(ci_jobs)
        self.assertLessEqual(ci_jobs, required_checks())

    def test_pr_format_check_is_required(self):
        required = required_checks()
        self.assertIn("Check title, description and commits", required)
        # It runs only on pushes to main, so requiring it would block every pull request.
        self.assertNotIn("Check commits pushed to main", required)

    def test_main_takes_rebased_pull_requests_only(self):
        self.assertEqual(RULESET["conditions"]["ref_name"]["include"], ["~DEFAULT_BRANCH"])
        self.assertEqual(rule("pull_request")["parameters"]["allowed_merge_methods"], ["rebase"])
        for kind in ("required_linear_history", "non_fast_forward", "deletion"):
            rule(kind)

    def test_pull_requests_need_no_approval(self):
        # The only reviewer cannot approve their own pull requests,
        # so any approval requirement, including GitHub's extra approval for
        # commits a coding agent authored, would block auto-merge on every one.
        parameters = rule("pull_request")["parameters"]
        self.assertEqual(parameters["required_approving_review_count"], 0)
        self.assertIs(parameters["require_extra_approval_for_unattributed_changes"], False)


if __name__ == "__main__":
    unittest.main()
