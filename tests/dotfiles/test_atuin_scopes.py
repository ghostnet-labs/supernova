#!/usr/bin/env python3
# setup-test: Atuin scope boundaries
# setup-test-scope: work
"""Synthetic job scopes exercise no actual Work environment or existing history."""

from test_atuin import ShellFixture, ZSH
import unittest


@unittest.skipUnless(ZSH, "Zsh required")
class ScopeTests(ShellFixture, unittest.TestCase):
    def test_jobs_and_personal_do_not_share_records(self):
        self.require_cli()
        output = self.shell("_setup_atuin_init; _atuin_preexec 'PERSONAL_ONLY'; "
                            "WORK_ENV=true JOB=example-job; _setup_atuin_init; "
                            "print -r -- CANCELLED:${ATUIN_HISTORY_ID}; _atuin_precmd; "
                            "_atuin_preexec 'WORK_ONLY'; "
                            "JOB=second-job; _setup_atuin_init; _atuin_preexec 'SECOND_ONLY'; "
                            "WORK_ENV=false; _setup_atuin_init; "
                            "atuin search --cmd-only --search-mode fulltext; "
                            "WORK_ENV=true JOB=example-job; _setup_atuin_init; "
                            "print DIVIDER; atuin search --cmd-only --search-mode fulltext")
        personal, work = output.split("DIVIDER\n")
        self.assertIn("CANCELLED:\n", personal)
        self.assertIn("PERSONAL_ONLY", personal)
        self.assertNotIn("WORK_ONLY", personal)
        self.assertNotIn("SECOND_ONLY", output)
        self.assertIn("WORK_ONLY", work)
        self.assertNotIn("PERSONAL_ONLY", work)

    def test_invalid_job_does_not_fall_back_to_personal(self):
        self.require_cli()
        output = self.shell("WORK_ENV=true JOB=../../outside; _setup_atuin_init; "
                            "print -r -- ACTIVE:${_SETUP_ATUIN_ACTIVE}; bindkey '^R'")
        self.assertIn("ACTIVE:\n", output)
        self.assertNotIn("atuin-search", output)
        self.assertEqual(list(self.directory.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
