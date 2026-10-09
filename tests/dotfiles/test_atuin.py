#!/usr/bin/env python3
# setup-test: Local Atuin history
"""Use the installed CLI against temporary databases, never the user's history."""

import fcntl
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ZSH = shutil.which("zsh")
ATUIN = shutil.which("atuin")


def take_terminal():
    """Make stdin, a pseudo-terminal, the new session's controlling terminal."""
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class ShellFixture:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="atuin history ")
        self.directory = Path(self.temporary.name)
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("ATUIN_", "SETUP_ATUIN_", "XDG_"))
        }
        self.environment.update(HOME=str(self.directory),
                                XDG_CONFIG_HOME=str(self.directory / "config"),
                                XDG_DATA_HOME=str(self.directory / "data"),
                                WORK_ENV="false", JOB="", TERM="xterm-256color")

    def tearDown(self):
        # Atuin's generated init briefly prepares its search index in a detached
        # process. It may finish opening a file just as the shell exits.
        for attempt in range(20):
            try:
                self.temporary.cleanup()
                break
            except OSError:
                if attempt == 19:
                    raise
                time.sleep(0.05)

    def shell(self, script, interactive=True, terminal=False):
        source = shlex.quote(str(ROOT / "dotfiles/functions/atuin.zsh"))
        # .zshrc loads fzf's key bindings only with a controlling terminal,
        # which CI does not have, so tests that check them get a
        # pseudo-terminal as stdin and controlling terminal.
        primary, secondary = os.openpty() if terminal else (None, None)
        try:
            result = subprocess.run(
                [ZSH, "-dfi" if interactive else "-df", "-c", f"source {source}; {script}"],
                env=self.environment, text=True, capture_output=True, timeout=15,
                stdin=secondary, start_new_session=terminal,
                preexec_fn=take_terminal if terminal else None,
            )
        finally:
            if terminal:
                os.close(primary)
                os.close(secondary)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("Error:", result.stderr)
        return result.stdout

    def require_cli(self):
        if not ATUIN:
            self.skipTest("Atuin required for actual CLI checks")


@unittest.skipUnless(ZSH, "Zsh required")
class AtuinTests(ShellFixture, unittest.TestCase):

    def test_noninteractive_and_disabled_do_not_create_files(self):
        self.shell("_setup_atuin_init", interactive=False)
        self.shell("SETUP_ATUIN_ENABLED=false; _setup_atuin_init")
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_missing_binary_preserves_bindings(self):
        output = self.shell("path=(/usr/bin /bin); rehash; bindkey '^R' backward-char; "
                            "_setup_atuin_init; bindkey '^R'")
        self.assertIn('"^R" backward-char', output)
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_dependency_and_readonly_template_contract(self):
        # Personal dependency selection does not load a Work environment.
        result = subprocess.run(
            ["/bin/bash", "-c", 'source "$1/setup/dependencies.sh"; '
             'setup_collect_dependencies macos false ""; '
             'printf "%s\\n" "${SETUP_SELECTED_DEPENDENCIES[@]}"', "bash", str(ROOT)],
            capture_output=True, text=True, check=True,
        )
        self.assertIn("base|all|brew|atuin|command|atuin", result.stdout)
        self.assertNotIn("work|", result.stdout)
        self.assertNotIn("work:", result.stdout)
        config = (ROOT / "dotfiles/atuin/config.toml").read_text()
        for setting in ("auto_sync = false", "update_check = false", "enter_accept = false"):
            self.assertIn(setting, config)

    def test_real_config_and_separate_data_paths(self):
        self.require_cli()
        output = self.shell("_setup_atuin_init; "
                            "for key in db_path record_store_path key_path auto_sync update_check "
                            "enter_accept daemon.enabled daemon.autostart pty_proxy.enabled; do "
                            "atuin config get --resolved $key || exit 1; done")
        data = self.directory / "data/atuin/scopes/personal"
        for name in ("history.db", "records.db", "key"):
            self.assertIn(str(data / name), output)
        self.assertEqual(output.count("false\n"), 6)
        self.assertTrue((self.directory / "config/atuin/scopes/personal/config.toml").is_file())
        self.assertFalse((self.directory / ".zsh_history").exists())

    def test_history_import_requires_an_explicit_file(self):
        self.require_cli()
        history = self.directory / "separated-history"
        history.write_text(": 1700000000:0;SCOPED_IMPORT_ONLY\n")
        output = self.shell(f"HISTFILE={shlex.quote(str(history))}; _setup_atuin_init; "
                            "atuin search --cmd-only; print BEFORE_IMPORT; "
                            "HISTFILE=$HISTFILE atuin import zsh >/dev/null; "
                            "atuin search --cmd-only")
        before, after = output.split("BEFORE_IMPORT\n")
        self.assertNotIn("SCOPED_IMPORT_ONLY", before)
        self.assertIn("SCOPED_IMPORT_ONLY", after)

    def test_reload_preserves_bindings_and_has_one_hook(self):
        self.require_cli()
        output = self.shell("bindkey -e; bindkey '^R' history-incremental-search-backward; "
                            "bindkey '^[[A' up-line-or-history; bindkey -M vicmd '/' vi-history-search-backward; "
                            "ZSH_AUTOSUGGEST_STRATEGY=(history completion); "
                            "_setup_atuin_init; _setup_atuin_init; _setup_atuin_init; "
                            "print -rl -- $preexec_functions $precmd_functions $zshaddhistory_functions; "
                            "bindkey '^R'; bindkey '^[[A'; bindkey -M vicmd '/'; "
                            "print -r -- STRATEGY:${(j:,:)ZSH_AUTOSUGGEST_STRATEGY}; "
                            "SETUP_ATUIN_ENABLED=false; _setup_atuin_init; bindkey '^R'; "
                            "print -r -- HOOKS:${(j:,:)preexec_functions}:${(j:,:)precmd_functions}")
        for hook in ("_atuin_preexec", "_atuin_precmd", "_atuin_zshaddhistory"):
            self.assertEqual(output.splitlines().count(hook), 1)
        for binding in ('"^R" atuin-search', '"^[[A" up-line-or-history',
                        '\'/\' vi-history-search-backward', "STRATEGY:history,completion",
                        '"^R" history-incremental-search-backward', "HOOKS::"):
            # Zsh quotes '/' with double quotes rather than single on some versions.
            self.assertIn(binding.replace("'/'", '\"/\"'), output)

    def test_uninstall_restores_fzf_binding(self):
        self.require_cli()
        output = self.shell("bindkey '^R' fzf-history-widget; _setup_atuin_init; "
                            "path=(/usr/bin /bin); rehash; _setup_atuin_init; bindkey '^R'; "
                            "print -r -- HOOKS:${(j:,:)preexec_functions}")
        self.assertIn('"^R" fzf-history-widget', output)
        self.assertIn("HOOKS:\n", output)

    def test_source_zsh_reloads_the_whole_managed_configuration(self):
        self.require_cli()
        if not shutil.which("fzf"):
            self.skipTest("fzf required for shell reload checks")
        (self.directory / ".cache").mkdir()
        (self.directory / ".zshrc").symlink_to(ROOT / "dotfiles/.zshrc")
        output = self.shell('source "$HOME/.zshrc"; source_zsh; source_zsh; '
                            'print -r -- HOOKS:${(j:,:)preexec_functions}; bindkey -M emacs "^R"; '
                            'SETUP_ATUIN_ENABLED=false; source_zsh; bindkey -M emacs "^R"',
                            terminal=True)
        hooks = next(line for line in output.splitlines() if line.startswith("HOOKS:"))
        self.assertEqual(hooks.count("_atuin_preexec"), 1)
        self.assertIn('"^R" atuin-search', output)
        self.assertIn('"^R" fzf-history-widget', output)

    def test_unmanaged_config_is_preserved_and_integration_disabled(self):
        self.require_cli()
        config = self.directory / "config/atuin/scopes/personal/config.toml"
        config.parent.mkdir(parents=True)
        original = 'inline_height = 7\nauto_sync = true\nenter_accept = true\n'
        config.write_text(original)
        output = self.shell("_setup_atuin_init; print -r -- ACTIVE:${_SETUP_ATUIN_ACTIVE}")
        self.assertEqual(output, "ACTIVE:\n")
        self.assertEqual(config.read_text(), original)


if __name__ == "__main__":
    unittest.main()
