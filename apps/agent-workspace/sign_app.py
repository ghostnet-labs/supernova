"""Sign local builds with a persistent identity so macOS remembers permissions."""

import argparse
import fcntl
import os
from pathlib import Path
import pwd
import secrets
import shlex
import subprocess
import tempfile


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        # Command arguments can contain keychain passwords; never print them.
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def identity(directory):
    destination = directory / "identity"
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix="identity-", dir=directory) as scratch:
            scratch = Path(scratch)
            password = secrets.token_hex(32)
            (scratch / "password").write_text(password)
            (scratch / "openssl.cnf").write_text(
                "[req]\nprompt = no\ndistinguished_name = subject\n"
                "x509_extensions = signing\n[subject]\n"
                "CN = Agent Workspace Local Builds\n[signing]\n"
                "basicConstraints = critical,CA:FALSE\n"
                "keyUsage = critical,digitalSignature\n"
                "extendedKeyUsage = critical,codeSigning\n"
            )
            run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048",
                "-nodes", "-sha256", "-days", "36500", "-config", str(scratch / "openssl.cnf"),
                "-keyout", str(scratch / "key.pem"), "-out", str(scratch / "certificate.pem"))
            run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(scratch / "key.pem"),
                "-in", str(scratch / "certificate.pem"), "-out", str(scratch / "identity.p12"),
                "-passout", "file:" + str(scratch / "password"))
            fingerprint = run("/usr/bin/openssl", "x509", "-in", str(scratch / "certificate.pem"),
                              "-noout", "-fingerprint", "-sha1").split("=", 1)[1].replace(":", "")
            # Publish the complete identity atomically; interrupted setup cannot rotate it.
            ready = scratch / "ready"
            ready.mkdir(mode=0o700)
            for name in ("password", "identity.p12"):
                (scratch / name).rename(ready / name)
            (ready / "fingerprint").write_text(fingerprint)
            ready.rename(destination)
    return destination


def sign(bundle, directory):
    # Only the current user can read the private key, password, and temporary keychain.
    os.umask(0o077)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    with (directory / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        saved = identity(directory)
        password = (saved / "password").read_text()
        fingerprint = (saved / "fingerprint").read_text()
        # The keychain search list is per user, not per state directory: hold a
        # user-wide lock while it carries the temporary keychain, so two
        # signings at once can't drop or restore each other's entries.
        search_lock = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/agent-workspace-signing.lock"
        search_lock.parent.mkdir(parents=True, exist_ok=True)
        with search_lock.open("a") as user_lock, \
                tempfile.TemporaryDirectory(prefix="keychain-", dir=directory) as scratch:
            fcntl.flock(user_lock, fcntl.LOCK_EX)
            keychain = str(Path(scratch) / "build.keychain-db")
            try:
                run("/usr/bin/security", "create-keychain", "-p", password, keychain)
                # codesign requires the keychain in the search list while signing.
                # delete-keychain removes only this temporary entry afterward.
                search = shlex.split(run("/usr/bin/security", "list-keychains", "-d", "user"))
                run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *search, keychain)
                run("/usr/bin/security", "import", str(saved / "identity.p12"),
                    "-k", keychain, "-P", password, "-T", "/usr/bin/codesign")
                run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:",
                    "-s", "-k", password, keychain)
                run("/usr/bin/codesign", "--force", "--sign", fingerprint,
                    "--keychain", keychain, "--timestamp=none", str(bundle))
            finally:
                if Path(keychain).exists():
                    run("/usr/bin/security", "delete-keychain", keychain)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--state-dir", type=Path,
                        default=Path.home() / "Library/Application Support/Agent Workspace/Signing")
    args = parser.parse_args()
    try:
        sign(args.bundle, args.state_dir)
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f"error: Agent Workspace signing failed: {error}") from None


if __name__ == "__main__":
    main()
