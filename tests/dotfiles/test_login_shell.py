#!/usr/bin/env python3
# setup-test: Login shell in a terminal
"""Start real login shells in a pseudo-terminal from a temporary home."""

import fcntl
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
ZSH = shutil.which("zsh")
FZF = shutil.which("fzf")
MARKER = "LOGIN-SHELL-DONE"


@unittest.skipUnless(ZSH, "Zsh required")
class LoginShellTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="login shell ")
        self.root = Path(self.temporary.name)

    def tearDown(self):
        # Atuin's init may still be writing its search index from a detached
        # process as the shell exits.
        for attempt in range(20):
            try:
                self.temporary.cleanup()
                break
            except OSError:
                if attempt == 19:
                    raise
                time.sleep(0.05)

    def login(self, name, commands, env_lines=("WORK_ENV=false",)):
        """Run COMMANDS as the first input of a login shell in a terminal."""
        home = self.root / name
        if not home.exists():
            (home / ".cache").mkdir(parents=True)
            for dotfile in (".zshrc", ".zprofile", ".p10k.zsh"):
                (home / dotfile).symlink_to(ROOT / "dotfiles" / dotfile)
            (home / "env.zsh").write_text("\n".join(env_lines) + "\n")
            # Some CI images have group-writable completion directories, and
            # compinit would stop at its "insecure directories" question. A
            # fresh dump makes .zshrc run compinit -C, which skips that audit.
            subprocess.run([ZSH, "-fc", f"autoload -Uz compinit; compinit -u -d {shlex.quote(str(home / '.zcompdump'))}"],
                           check=True, env={"HOME": str(home), "PATH": os.environ["PATH"]})
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("ATUIN_", "SETUP_", "XDG_", "WORK_", "ZDOTDIR"))
        }
        # Powerlevel10k keeps its gitstatusd download in the real home's cache,
        # so each new home does not fetch it again.
        gitstatus_cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "gitstatus"
        environment.update(HOME=str(home), SETUP_LOCAL_ENV_FILE=str(home / "env.zsh"),
                           TERM="xterm-256color", JOB="",
                           GITSTATUS_CACHE_DIR=str(gitstatus_cache))
        pid, terminal = pty.fork()
        if pid == 0:
            # A real terminal has a size; Powerlevel10k's instant prompt is
            # skipped without one.
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            # The system zlogin of some distributions runs after .zshrc and
            # would hide its status, so only the user's startup files run.
            os.chdir(home)
            os.execve(ZSH, [ZSH, "-o", "no_global_rcs", "-li"], environment)
        # Type only once the first prompt is drawn, as a person does;
        # Powerlevel10k writes its instant prompt cache at that point.
        output = self.read_quiet(terminal)
        script = f"{commands}; print -r -- {MARKER[:5]}''{MARKER[5:]}; exit\n"
        os.write(terminal, script.encode())
        deadline = time.monotonic() + 30
        while MARKER.encode() not in output and time.monotonic() < deadline:
            ready, _, _ = select.select([terminal], [], [], 1)
            if ready:
                try:
                    chunk = os.read(terminal, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
        os.waitpid(pid, 0)
        os.close(terminal)
        text = output.decode(errors="replace").replace("\r", "")
        self.assertIn(MARKER, text, text[-2000:])
        return text

    @staticmethod
    def read_quiet(terminal, quiet=0.5, limit=15):
        """Read until the shell has printed and then goes QUIET seconds."""
        output = b""
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            ready, _, _ = select.select([terminal], [], [], quiet)
            if not ready:
                if output:
                    break
                continue
            chunk = os.read(terminal, 65536)
            if not chunk:
                break
            output += chunk
        return output

    def test_personal_shell_starts_with_status_zero(self):
        output = self.login("personal", 'print -r -- "STATUS:$?"')
        self.assertIn("STATUS:0\n", output)

    def test_personal_shell_has_the_kubernetes_helpers(self):
        # They stay in dotfiles/functions, not in a work overlay.
        output = self.login("kubernetes", "print -r -- KC:$aliases[kc]; "
                            "for f in k8s_switch kget_labels kget_notready kget_taints knodes kpods; "
                            "do print -r -- $f:$+functions[$f]; done")
        self.assertIn("KC:kubectl\n", output)
        for name in ("k8s_switch", "kget_labels", "kget_notready", "kget_taints", "knodes", "kpods"):
            self.assertIn(f"{name}:1\n", output)

    def test_work_overlay_without_startup_files_starts_with_status_zero(self):
        overlay = self.root / "overlay"
        (overlay / "acme").mkdir(parents=True)
        output = self.login("work", 'print -r -- "STATUS:$?"; print -r -- "WORK:$WORK_ENV"',
                            ("WORK_ENV=true", "JOB=acme", f"WORK_ROOT={shlex.quote(str(overlay))}"))
        self.assertIn("STATUS:0\n", output)
        self.assertIn("WORK:true\n", output)

    def test_old_fzf_gets_one_clear_warning(self):
        # Ubuntu's apt fzf 0.44 has no --zsh. The shell names the fix instead
        # of printing fzf's error and sourcing an empty cache.
        self.login("old fzf", ":")
        stub = self.root / "old fzf/.local/bin/fzf"
        stub.parent.mkdir(parents=True)
        stub.write_text('#!/bin/sh\necho "unknown option: $1" >&2\nexit 2\n')
        stub.chmod(0o755)
        (self.root / "old fzf/.cache/fzf-init.zsh").unlink(missing_ok=True)
        output = self.login("old fzf", 'print -r -- "STATUS:$?"; [[ -e ~/.cache/fzf-init.zsh ]]; print -r -- CACHE:${+commands[fzf]}:$?')
        self.assertIn(f"{stub} is too old for the fzf key bindings; run ./setup.sh --fix", output)
        self.assertNotIn("unknown option", output)
        self.assertIn("STATUS:0\n", output)
        self.assertIn("CACHE:1:1\n", output)  # fzf found, no cache file

    @unittest.skipUnless(FZF, "fzf required for its key bindings")
    def test_fzf_key_bindings_load_in_a_terminal(self):
        # The first shell writes Powerlevel10k's instant prompt cache, when
        # Powerlevel10k is installed; the second starts with it, as a real
        # terminal does, and it redirects stdin while .zshrc runs.
        self.login("fzf", ":")
        cache = self.root / "fzf/.cache"
        for _ in range(100):
            if not os.environ.get("HOMEBREW_PREFIX") or any(cache.glob("p10k-instant-prompt-*.zsh")):
                break
            time.sleep(0.1)
        output = self.login("fzf", "bindkey '^T'; bindkey '^[c'; "
                            "print -r -- COMPLETION:$+functions[fzf-completion]")
        self.assertIn('"^T" fzf-file-widget', output)
        self.assertIn('"^[c" fzf-cd-widget', output)
        self.assertIn("COMPLETION:1", output)


if __name__ == "__main__":
    unittest.main()
