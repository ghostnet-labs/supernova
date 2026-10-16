#!/usr/bin/env python3
# setup-test: macOS VM migration capacity and isolation
"""Reject unsafe or unobservable host states before macOS VM provisioning."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("macos_preflight", ROOT / "infra/runner-platform/macos/preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)
driver_spec = importlib.util.spec_from_file_location("macos_host_runner", ROOT / "infra/runner-platform/macos/host-runner.py")
driver = importlib.util.module_from_spec(driver_spec)
driver_spec.loader.exec_module(driver)


def host(**updates):
    return dict({"system": "Darwin", "arch": "arm64", "os_version": (27, 0, 1),
                 "lima_version": (2, 2, 1), "memory_bytes": 32 * preflight.GIB,
                 "free_bytes": 200 * preflight.GIB}, **updates)


def vm(name, memory, status="Running"):
    return {"name": name, "memory": memory * preflight.GIB, "status": status}


class PreflightTests(unittest.TestCase):
    def test_current_legacy_allocations_reject_new_guest(self):
        result = preflight.assess(host(), [vm("cluster", 6), vm("builder", 9), vm("old-linux", 6)], "new-macos")
        self.assertFalse(result["ready_to_provision"])
        self.assertEqual(result["budget_gib"]["remaining_after_reserve"], -3)

    def test_drained_linux_guest_fits_without_counting_stopped_disk_as_ram(self):
        result = preflight.assess(host(), [vm("cluster", 6), vm("builder", 9),
                                            vm("old-linux", 6, "Stopped")], "new-macos")
        self.assertTrue(result["ready_to_provision"])
        self.assertEqual(result["budget_gib"]["remaining_after_reserve"], 3)

    def test_permission_unknown_vm_cannot_be_treated_as_stopped(self):
        for update in ({"status": "Broken"}, {"errors": ["permission denied"]}, {"memory": None}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                preflight.parse_vms(json.dumps(dict(vm("old-linux", 6), **update)))
        self.assertFalse(preflight.assess(host(errors=["Cannot verify inventory"]), [], "new-macos")
                         ["ready_to_provision"])

    def test_existing_name_old_host_and_low_disk_are_blockers(self):
        result = preflight.assess(host(os_version=(26, 6, 2), free_bytes=50 * preflight.GIB),
                                  [vm("new-macos", 6, "Stopped")], "new-macos")
        self.assertFalse(result["ready_to_provision"])
        self.assertEqual(len(result["blockers"]), 3)

    def test_renderer_never_inherits_home_mount_or_agent(self):
        config = preflight.guest_config()
        self.assertNotIn("base", config)
        self.assertEqual(config["mounts"], [])
        self.assertTrue(config["plain"])
        self.assertFalse(config["ssh"]["forwardAgent"])
        self.assertFalse(config["ssh"]["loadDotSSHPubKeys"])
        self.assertEqual(config["images"][0]["digest"], preflight.IMAGE_DIGEST)
        self.assertEqual(config["provision"][0]["path"], "/etc/ci-runner-vm")
        self.assertEqual(config["provision"][0]["owner"], "root:wheel")

    def test_help_does_not_inspect_host_and_render_refuses_overwrite(self):
        with patch.object(preflight, "inspect_host") as inspect:
            with self.assertRaises(SystemExit) as result:
                preflight.main(["--help"])
            self.assertEqual(result.exception.code, 0)
            inspect.assert_not_called()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "vm.yaml"
            output.write_text("existing")
            with patch.object(preflight, "inspect_host", return_value=(host(), [])):
                self.assertEqual(preflight.main(["render", "--output", str(output)]), 1)
            self.assertEqual(output.read_text(), "existing")

    def test_installer_refuses_unmarked_personal_host_before_creating_runner_directory(self):
        # Model a physical Apple Silicon Mac, not merely Linux uname rejection.
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            uname = directory / "uname"
            uname.write_text('#!/bin/bash\nif [[ "$1" == -s ]]; then echo Darwin; else echo arm64; fi\n')
            uname.chmod(0o700)
            runner_root = directory / "runner"
            result = subprocess.run(["bash", str(ROOT / "infra/runner-platform/macos/guest-runner.sh"),
                                     "--url", "https://github.com/acme", "--name", "macos-canary"],
                                    env=dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                                             RUNNER_ROOT=str(runner_root)), text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Refusing installation outside a provisioned CI guest", result.stderr)
            self.assertFalse(runner_root.exists())


class HostDriverTests(unittest.TestCase):
    def args(self):
        return SimpleNamespace(name="macos-canary", organization="acme", expected_login="maintainer",
                               runner_version="2.338.0", runner_group_id=1, timeout_minutes=5)

    def test_guest_mounts_or_forwarded_host_keys_block_before_any_registration(self):
        for unsafe in ({"mounts": [{"location": "~"}]}, {"ssh": {"forwardAgent": True}},
                       {"plain": False}, {"os": "Linux"}):
            cfg = dict(preflight.guest_config(), **unsafe)
            row = dict(vm("macos-canary", 6), config=cfg)
            with self.subTest(unsafe=unsafe), patch.object(driver.preflight, "inspect_host", return_value=(host(errors=[]), [row])), \
                    patch.object(driver.preflight, "read_command", return_value=json.dumps(row)), \
                    patch.object(driver, "guest") as guest, self.assertRaises(ValueError):
                driver.observe_guest("macos-canary")
            guest.assert_not_called()

    def test_official_digest_is_required(self):
        with patch.object(driver, "command", return_value=SimpleNamespace(stdout=json.dumps(
                {"assets": [{"name": "actions-runner-osx-arm64-2.338.0.tar.gz", "digest": None}]}))):
            with self.assertRaises(ValueError):
                driver.release_digest("2.338.0")

    def test_jit_secret_only_crosses_stdin_and_busy_runner_is_not_deleted(self):
        calls = []
        def command(args, **kwargs):
            calls.append((args, kwargs))
            if args[-1] == ".login":
                return SimpleNamespace(stdout="maintainer\n")
            if "--input" in args:
                return SimpleNamespace(stdout=json.dumps({"encoded_jit_config": "secret-canary-value",
                                                          "runner": {"id": 123}}))
            if "--slurp" in args:
                return SimpleNamespace(stdout=json.dumps([{"runners": [{"id": 123, "busy": True}]}]))
            raise AssertionError(args)
        with patch.object(driver, "command", side_effect=command), patch.object(driver, "observe_guest"), \
                patch.object(driver, "release_digest", return_value="a" * 64), \
                patch.object(driver, "guest") as guest, self.assertRaisesRegex(ValueError, "still busy"):
            driver.run_one(self.args())
        self.assertFalse(any("DELETE" in args for args, _ in calls))
        registration = [kwargs for args, kwargs in calls if "--input" in args][0]
        self.assertEqual(json.loads(registration["data"])["labels"], ["macos-vm"])
        one_job = [call for call in guest.call_args_list if call.args[1] == driver.ONE_JOB][0]
        self.assertEqual(one_job.kwargs["data"], "secret-canary-value")
        self.assertNotIn("secret-canary-value", str(one_job.args))

    def test_capacity_change_during_start_prevents_vm_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(name="new-macos", state=Path(directory))
            with patch.object(driver.preflight, "inspect_host", side_effect=[(host(), []), (host(), [vm("late-vm", 20)])]), \
                    patch.object(driver, "command") as command, self.assertRaises(ValueError):
                driver.start_guest(args)
            self.assertEqual(command.call_args.args[0][1], "validate")
            self.assertEqual(command.call_count, 1)

    def test_supervisor_requires_repository_scope(self):
        args = self.args()
        args.repository = None
        with patch.object(driver, "run_one") as run, self.assertRaises(ValueError):
            driver.supervise(args)
        run.assert_not_called()

    def test_supervisor_drains_after_current_job_without_second_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args()
            args.state, args.repository = Path(directory), "acme/project"
            args.max_jobs = 10
            def finish_job(_):
                args.drain_file.touch()
                return True
            with patch.object(driver, "run_one", side_effect=finish_job) as run:
                driver.supervise(args)
            self.assertEqual(run.call_count, 1)
            self.assertTrue(args.drain_file.exists())

    def test_supervisor_never_restarts_failed_or_uncertain_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args()
            args.state, args.repository = Path(directory), "acme/project"
            args.max_jobs = 10
            with patch.object(driver, "run_one", side_effect=ValueError("cleanup unknown")) as run, \
                    self.assertRaisesRegex(ValueError, "cleanup unknown"):
                driver.supervise(args)
            self.assertEqual(run.call_count, 1)

    def test_supervisor_budget_and_existing_drain_file(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args()
            args.state, args.repository = Path(directory), "acme/project"
            args.max_jobs = 2
            with patch.object(driver, "run_one", return_value=True) as run:
                driver.supervise(args)
            self.assertEqual(run.call_count, 2)
            args.drain_file.touch()
            with patch.object(driver, "run_one") as run:
                driver.supervise(args)
            run.assert_not_called()

    def test_drain_arriving_during_preparation_prevents_jit_issue(self):
        with tempfile.TemporaryDirectory() as directory:
            args = self.args()
            args.drain_file = Path(directory) / "drain"
            def observe(_):
                args.drain_file.touch()
            with patch.object(driver, "command", return_value=SimpleNamespace(stdout="maintainer\n")) as command, \
                    patch.object(driver, "observe_guest", side_effect=observe), \
                    patch.object(driver, "release_digest", return_value="a" * 64), patch.object(driver, "guest"):
                self.assertFalse(driver.run_one(args))
            self.assertEqual(command.call_count, 1)

    def test_repository_registration_and_revocation_share_scope(self):
        args = self.args()
        args.repository = "acme/project"
        calls = []
        def command(argv, **kwargs):
            calls.append(argv)
            if argv[-1] == ".login":
                return SimpleNamespace(stdout="maintainer\n")
            if "--input" in argv:
                return SimpleNamespace(stdout=json.dumps({"encoded_jit_config": "secret", "runner": {"id": 1}}))
            if "--slurp" in argv:
                return SimpleNamespace(stdout=json.dumps([{"runners": [{"id": 1, "busy": False}]}]))
            return SimpleNamespace(stdout="")
        with patch.object(driver, "command", side_effect=command), patch.object(driver, "observe_guest"), \
                patch.object(driver, "release_digest", return_value="a" * 64), patch.object(driver, "guest"):
            self.assertTrue(driver.run_one(args))
        self.assertIn("repos/acme/project/actions/runners/generate-jitconfig", str(calls))
        self.assertIn("repos/acme/project/actions/runners/1", str(calls))
        self.assertNotIn("orgs/", str(calls))

    def test_failed_start_preserves_durable_private_ownership_record(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(name="new-macos", state=Path(directory))
            def command(argv, **kwargs):
                if argv[1] == "start":
                    record = json.loads((args.state / "new-macos-created.json").read_text())
                    self.assertEqual(record["phase"], "prepared")
                    raise subprocess.TimeoutExpired(argv, 1800)
            with patch.object(driver.preflight, "inspect_host", return_value=(host(), [])), \
                    patch.object(driver, "command", side_effect=command), self.assertRaises(subprocess.TimeoutExpired):
                driver.start_guest(args)
            path = args.state / "new-macos-created.json"
            self.assertEqual(json.loads(path.read_text())["phase"], "start_unverified")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
