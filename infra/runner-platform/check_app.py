#!/usr/bin/env python3
"""Validate ARC App credentials without printing the key or authentication JWT."""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


class AuthenticationError(Exception):
    pass


def encode(data):
    if isinstance(data, dict):
        data = json.dumps(data, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def signed_jwt(credentials):
    now = int(time.time())
    message = encode({"typ": "JWT", "alg": "RS256"}) + "." + encode({
        "iat": now - 60, "exp": now + 540, "iss": credentials["github_app_id"]})
    with tempfile.TemporaryDirectory(prefix="arc-sign-") as directory:
        key = Path(directory) / "key.pem"
        fd = os.open(key, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(credentials["github_app_private_key"])
        result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)],
                                input=message.encode(), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=15)
        if result.returncode:
            raise AuthenticationError("OpenSSL could not sign with the supplied private key.")
    return message + "." + encode(result.stdout)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args):
        return None


def api(path, jwt):
    request = urllib.request.Request("https://api.github.com" + path, headers={
        "Authorization": "Bearer " + jwt, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "ghostnet-arc-preflight"})
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise AuthenticationError("Installation not found for this App/key. Install the App on the organization and verify its installation ID.") from None
        raise AuthenticationError(f"GitHub App authentication failed (HTTP {error.code}).") from None
    except urllib.error.URLError:
        raise AuthenticationError("GitHub is unreachable. Run this check in the Studio's normal Terminal.") from None


def validate_metadata(app, installation, credentials, organization, scope):
    expected = int(credentials["github_app_id"])
    if app.get("id") != expected or installation.get("app_id") != expected:
        raise AuthenticationError("App ID does not match the key and installation.")
    if installation.get("id") != int(credentials["github_app_installation_id"]):
        raise AuthenticationError("Installation ID mismatch.")
    if installation.get("account", {}).get("login", "").lower() != organization.lower():
        raise AuthenticationError("Installation belongs to a different account.")
    if installation.get("suspended_at"):
        raise AuthenticationError("GitHub App installation is suspended.")
    owner = app.get("owner", {})
    if scope == "organization" and (owner.get("type") != "Organization"
            or owner.get("login", "").lower() != organization.lower()):
        raise AuthenticationError("Organization ARC requires this organization-owned App.")
    permission = "organization_self_hosted_runners" if scope == "organization" else "administration"
    if installation.get("permissions", {}).get(permission) != "write":
        raise AuthenticationError("Installation needs " + permission + " read/write permission. Accept any pending App permission update.")


def verify(file, organization, scope="organization"):
    if file.stat().st_mode & 0o077:
        raise AuthenticationError("Credential file must be mode 0600.")
    credentials = json.loads(file.read_text())
    for name in ("github_app_id", "github_app_installation_id"):
        if not re.fullmatch(r"[0-9]+", str(credentials.get(name, ""))):
            raise AuthenticationError("Missing numeric " + name + ".")
        credentials[name] = str(credentials[name])
    if "PRIVATE KEY-----" not in credentials.get("github_app_private_key", ""):
        raise AuthenticationError("Missing private key.")
    jwt = signed_jwt(credentials)
    app = api("/app", jwt)
    installation = api("/app/installations/" + credentials["github_app_installation_id"], jwt)
    validate_metadata(app, installation, credentials, organization, scope)
    print(json.dumps({"app": app.get("slug"), "installation_id": installation["id"],
                      "organization": installation["account"]["login"], "runner_permission_verified": True}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-file", type=Path, default=Path(__file__).resolve().parent / ".local/app.json")
    parser.add_argument("--organization", default="ghostnet-labs")
    parser.add_argument("--scope", choices=("organization", "repository"), default="organization")
    args = parser.parse_args()
    try:
        verify(args.app_file, args.organization, args.scope)
        return 0
    except (AuthenticationError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print("App check stopped: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
