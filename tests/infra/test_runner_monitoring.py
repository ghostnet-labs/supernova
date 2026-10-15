#!/usr/bin/env python3
# setup-test: Bounded runner monitoring
"""Check monitoring capacity, persistence and health without a live cluster."""
import contextlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PLATFORM = ROOT / "infra" / "runner-platform"
SPEC = importlib.util.spec_from_file_location("monitoring_platform", PLATFORM / "platform.py")
platform = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(platform)


class MonitoringTests(unittest.TestCase):
    def setUp(self):
        self.cfg = json.loads((PLATFORM / "config.example.json").read_text())
        self.cfg.update(github_url="https://github.com/acme", expected_github_login="test-admin")

    def targets(self):
        return [{"labels": {"job": job, "namespace": ns,
                            "component": "runner-scale-set-listener" if "listener" in url else "controller-manager"},
                 "health": "up", "scrapeUrl": url}
                for job, ns, url in [
                    ("apiserver", "default", "https://node:6443/metrics"),
                    ("node-exporter", "monitoring", "http://node:9100/metrics"),
                    ("ci-monitoring-kube-state-metrics", "monitoring", "http://pod:8080/metrics"),
                    ("kubelet", "kube-system", "https://node:10250/metrics"),
                    ("kubelet", "kube-system", "https://node:10250/metrics/cadvisor"),
                    ("arc-metrics", "arc-system", "http://controller:8080/metrics"),
                    ("arc-metrics", "arc-system", "http://listener:8080/metrics")]]

    def test_pilot_bounds_include_auxiliary_containers(self):
        values = platform.monitoring_values(self.cfg, "pilot")
        resources = [values["prometheus"]["prometheusSpec"]["resources"],
                     values["grafana"]["resources"], values["grafana"]["sidecar"]["resources"],
                     values["grafana"]["sidecar"]["resources"],
                     values["prometheusOperator"]["resources"],
                     values["prometheusOperator"]["prometheusConfigReloader"]["resources"],
                     values["prometheusOperator"]["prometheusConfigReloader"]["resources"],
                     values["kube-state-metrics"]["resources"], values["prometheus-node-exporter"]["resources"],
                     values["alertmanager"]["alertmanagerSpec"]["resources"]]
        for item in resources + [values["grafana"]["initChownData"]["resources"],
                                 values["prometheusOperator"]["admissionWebhooks"]["patch"]["resources"]]:
            for kind in ("requests", "limits"):
                self.assertEqual(set(item[kind]), {"cpu", "memory"})
        self.assertEqual(sum(platform.memory_bytes(r["limits"]["memory"]) for r in resources),
                         platform.memory_bytes("1616Mi"))
        self.assertEqual(values["grafana"]["sidecar"]["resources"]["limits"]["memory"], "128Mi")
        self.assertFalse(values["grafana"]["grafana.ini"]["auth.anonymous"]["enabled"])
        self.assertFalse(values["kubelet"]["serviceMonitor"]["tlsConfig"]["insecureSkipVerify"])
        self.assertTrue(values["kubelet"]["serviceMonitor"]["cAdvisor"])

    def test_capacity_reserves_runner_while_scaled_to_zero(self):
        node = {"metadata": {"name": self.cfg["vm_name"]}, "status": {
            "allocatable": {"memory": "4Gi"}, "conditions": []}}
        with patch.object(platform, "kube", side_effect=[json.dumps({"items": [node]}), '{"items": []}']):
            budget = platform.monitoring_capacity(self.cfg, "pilot", Path("/unused"))
        self.assertEqual(budget["reserved_mib"], 3840)
        self.assertEqual(budget["monitoring_limit_mib"], 1792)
        node["status"]["allocatable"]["memory"] = "3Gi"
        with patch.object(platform, "kube", side_effect=[json.dumps({"items": [node]}), '{"items": []}']):
            with self.assertRaisesRegex(platform.PlatformError, "runner headroom"):
                platform.monitoring_capacity(self.cfg, "pilot", Path("/unused"))

    def test_capacity_includes_existing_workload_limits(self):
        node = {"metadata": {"name": self.cfg["vm_name"]}, "status": {
            "allocatable": {"memory": "4Gi"}, "conditions": []}}
        pod = {"metadata": {"namespace": "other"}, "spec": {
            "nodeName": self.cfg["vm_name"], "containers": [{"resources": {"limits": {"memory": "1Gi"}}}]}}
        with patch.object(platform, "kube", side_effect=[json.dumps({"items": [node]}), json.dumps({"items": [pod]})]):
            with self.assertRaisesRegex(platform.PlatformError, "runner headroom"):
                platform.monitoring_capacity(self.cfg, "pilot", Path("/unused"))

    def test_capacity_refuses_memory_pressure_before_install(self):
        node = {"metadata": {"name": self.cfg["vm_name"]}, "status": {
            "conditions": [{"type": "MemoryPressure", "status": "True"}]}}
        with patch.object(platform, "kube", return_value=json.dumps({"items": [node]})):
            with self.assertRaisesRegex(platform.PlatformError, "resource pressure"):
                platform.monitoring_capacity(self.cfg, "pilot", Path("/unused"))

    def test_existing_volume_cannot_be_silently_shrunk_or_expanded(self):
        values = platform.monitoring_values(self.cfg, "pilot")
        claim = {"metadata": {"name": "prometheus-ci-monitoring-data-0"},
                 "spec": {"resources": {"requests": {"storage": "20Gi"}}}}
        with patch.object(platform, "kube", return_value=json.dumps({"items": [claim]})):
            with self.assertRaisesRegex(platform.PlatformError, "refusing to resize"):
                platform.check_monitoring_pvcs(Path("/unused"), values)
        claim["spec"]["resources"]["requests"]["storage"] = "8Gi"
        with patch.object(platform, "kube", return_value=json.dumps({"items": [claim]})):
            platform.check_monitoring_pvcs(Path("/unused"), values)

    def test_existing_grafana_credentials_survive_rerun_with_rollback(self):
        for version, flag in (("v4.3.0", "--rollback-on-failure"), ("v3.19.0", "--atomic")):
            with tempfile.TemporaryDirectory() as temp:
                with patch.object(platform, "check_deployment"), patch.object(platform, "monitoring_capacity", return_value={}), patch.object(
                    platform, "check_monitoring_pvcs"), patch.object(platform, "apply_object"), patch.object(platform, "secret") as secret, patch.object(
                    platform, "kube", return_value='{"data":{"admin-user":"YWRtaW4=","admin-password":"cHJlc2VydmU="}}'), patch.object(
                    platform, "helm") as helm, patch.object(platform, "run", return_value=version), patch.object(platform, "verify_monitoring"):
                    platform.monitor(self.cfg, "pilot", Path(temp))
                secret.assert_not_called()
                install = next(c.args for c in helm.call_args_list if "upgrade" in c.args)
                self.assertIn(flag, install)
                self.assertIn("--wait", install)

    def test_target_health_needs_cadvisor_and_all_configured_hosts(self):
        targets = self.targets()
        self.assertEqual(platform.monitoring_target_gaps(self.cfg, targets), [])
        self.assertIn("cadvisor", platform.monitoring_target_gaps(self.cfg, targets[:4] + targets[5:]))
        self.cfg["host_exporters"] = [{"name": "mac-node", "address": "host:9100"}]
        self.assertIn("mac-node", platform.monitoring_target_gaps(self.cfg, targets))
        targets.append({"labels": {"job": "mac-node"}, "health": "up"})
        targets.append({"labels": {"job": "node-exporter"}, "health": "down"})
        self.assertIn("down:node-exporter", platform.monitoring_target_gaps(self.cfg, targets))

    def test_verify_requires_authenticated_grafana_and_keeps_evidence_secret_free(self):
        workloads = {kind: {"items": [{"metadata": {"name": kind + "-test"}}]}
                     for kind in ("deployment", "statefulset", "daemonset")}
        def kube(state, *args, **kwargs):
            if args[0] == "rollout":
                return ""
            if args[1] in workloads:
                return json.dumps(workloads[args[1]])
            if args[1] == "pvc":
                return json.dumps({"items": [{"status": {"phase": "Bound"}}] * 3})
            if args[1] == "services":
                return json.dumps({"items": [{"metadata": {"name": "prom", "labels": {"release": "ci-monitoring"}},
                                             "spec": {"type": "ClusterIP", "selector": {"app.kubernetes.io/name": "prometheus"}}}]})
            return '{"data":{"admin-user":"YWRtaW4=","admin-password":"c2VjcmV0"}}'
        def request(base, path, auth=None):
            if path == "/api/health":
                return '{"database":"ok"}'
            if path == "/api/user":
                self.assertEqual(auth, "Basic YWRtaW46c2VjcmV0")
                return '{"isGrafanaAdmin":true}'
            if path.startswith("/api/dashboards/uid/"):
                dashboard = json.loads(next(iter(json.loads((PLATFORM / "monitoring" / "dashboard.json").read_text())["data"].values())))
                return json.dumps({"meta": {"provisioned": True}, "dashboard": dashboard})
            if path == "/-/ready":
                return "ready"
            if path.startswith("/api/v1/query?"):
                return '{"status":"success","data":{"result":[{"value":[1,"1"]}]}}'
            return json.dumps({"status": "success", "data": {"activeTargets": self.targets()}})
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(platform, "kube", side_effect=kube), patch.object(
                platform, "monitoring_forward", side_effect=lambda *a: contextlib.nullcontext("http://127.0.0.1:1")), patch.object(
                platform, "monitoring_request", side_effect=request):
                platform.verify_monitoring(self.cfg, Path(temp))
            evidence = (Path(temp) / "monitoring-evidence.json").read_text()
            self.assertTrue(json.loads(evidence)["grafana_authenticated"])
            self.assertNotIn("c2VjcmV0", evidence)
            self.assertNotIn("Basic", evidence)

    def test_dashboard_check_requires_provisioned_complete_source_dashboard(self):
        source = json.loads((PLATFORM / "monitoring" / "dashboard.json").read_text())
        dashboard = json.loads(next(iter(source["data"].values())))
        result = {"meta": {"provisioned": True}, "dashboard": dashboard}
        with patch.object(platform, "monitoring_request", return_value=json.dumps(result)) as request:
            self.assertEqual(platform.verify_grafana_dashboards("http://127.0.0.1:1", "Basic PRIVATE"), [dashboard["uid"]])
            self.assertEqual(request.call_args.args[1], "/api/dashboards/uid/" + dashboard["uid"])
        result["meta"]["provisioned"] = False
        with patch.object(platform, "monitoring_request", return_value=json.dumps(result)), patch.object(platform.time, "sleep"):
            with self.assertRaisesRegex(platform.PlatformError, "missing or incomplete"):
                platform.verify_grafana_dashboards("http://127.0.0.1:1", "Basic PRIVATE")
        result["meta"]["provisioned"] = True
        result["dashboard"]["panels"] = []
        with patch.object(platform, "monitoring_request", return_value=json.dumps(result)), patch.object(platform.time, "sleep"):
            with self.assertRaisesRegex(platform.PlatformError, "missing or incomplete"):
                platform.verify_grafana_dashboards("http://127.0.0.1:1", "Basic PRIVATE")

    def test_missing_dashboard_does_not_count_as_healthy_grafana(self):
        with patch.object(platform, "monitoring_request", side_effect=platform.PlatformError("HTTP missing")), patch.object(platform.time, "sleep") as sleep:
            with self.assertRaisesRegex(platform.PlatformError, "missing or incomplete"):
                platform.verify_grafana_dashboards("http://127.0.0.1:1", "Basic PRIVATE")
            self.assertEqual(sleep.call_count, 29)

    def test_actions_collector_scrape_alone_does_not_hide_stale_api_data(self):
        self.cfg["host_exporters"] = [{"name": "actions", "address": "host:9108"}]
        responses = [json.dumps({"status": "success", "data": {"result": [{"value": [1, "1"]}]}}),
                     json.dumps({"status": "success", "data": {"result": [{"value": [1, "301"]}]}})]
        with patch.object(platform, "monitoring_request", side_effect=responses):
            with self.assertRaisesRegex(platform.PlatformError, "failing or stale"):
                platform.verify_actions_collectors(self.cfg, "http://127.0.0.1:1")

    def test_healthy_scrape_cannot_hide_missing_runner_metrics(self):
        with patch.object(platform, "monitoring_request", return_value='{"status":"success","data":{"result":[]}}'):
            with self.assertRaisesRegex(platform.PlatformError, "no data"):
                platform.verify_monitoring_metrics("http://127.0.0.1:1")


if __name__ == "__main__":
    unittest.main()
