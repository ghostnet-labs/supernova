#!/usr/bin/env python3
# setup-test: ARC App authentication guards
import base64
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("arc_auth", ROOT / "infra/runner-platform/check_app.py")
auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth)


class AuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.credentials = {"github_app_id": "1", "github_app_installation_id": "2"}
        self.app = {"id": 1, "owner": {"type": "Organization", "login": "acme"}}
        self.installation = {"id": 2, "app_id": 1, "account": {"login": "acme"},
                             "permissions": {"metadata": "read", "organization_self_hosted_runners": "write"}, "suspended_at": None}

    def test_installation_and_scope_must_match(self):
        auth.validate_metadata(self.app, self.installation, self.credentials, "ACME", "organization")
        for changes in ({"app_id": 9}, {"id": 9}, {"account": {"login": "another"}},
                        {"permissions": {"organization_self_hosted_runners": "read"}}, {"suspended_at": "today"}):
            with self.assertRaises(auth.AuthenticationError):
                auth.validate_metadata(self.app, dict(self.installation, **changes), self.credentials, "acme", "organization")

    def test_org_owned_app_is_required(self):
        with self.assertRaises(auth.AuthenticationError):
            auth.validate_metadata(dict(self.app, owner={"type": "User", "login": "person"}),
                                   self.installation, self.credentials, "acme", "organization")

    def test_runner_permission_uses_github_api_field_name(self):
        # GitHub's installation schema names this organization permission
        # organization_self_hosted_runners, not the UI label or an alias.
        auth.validate_metadata(self.app, self.installation, self.credentials, "acme", "organization")
        with self.assertRaises(auth.AuthenticationError):
            auth.validate_metadata(self.app, dict(self.installation, permissions={"self_hosted_runners": "write"}),
                                   self.credentials, "acme", "organization")

    def test_real_signature_verifies_and_key_is_not_in_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key, public, signature, data = [root / name for name in ("key.pem", "public.pem", "signature", "data")]
            subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            credentials = dict(self.credentials, github_app_private_key=key.read_text())
            token = auth.signed_jwt(credentials)
            parts = token.split(".")
            claims = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
            self.assertEqual(claims["iss"], "1")
            self.assertEqual(claims["exp"] - claims["iat"], 600)
            self.assertNotIn("PRIVATE", token)
            data.write_bytes((parts[0] + "." + parts[1]).encode())
            signature.write_bytes(base64.urlsafe_b64decode(parts[2] + "=" * (-len(parts[2]) % 4)))
            subprocess.run(["openssl", "rsa", "-in", str(key), "-pubout", "-out", str(public)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature", str(signature), str(data)],
                           check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


if __name__ == "__main__":
    unittest.main()
