#!/usr/bin/env python3
# setup-test: Runner fleet metrics
"""Check pagination, API semantics and private collector credentials offline."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]
METRICS = ROOT / "infra" / "runner-platform" / "metrics.py"
spec = importlib.util.spec_from_file_location("runner_metrics", METRICS)
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


class FakeAPI:
    def __init__(self, retry=False):
        self.cache = {}
        self.calls = []
        self.retry = retry

    def __call__(self, endpoint):
        self.calls.append(endpoint)
        url = urlsplit(endpoint)
        query = parse_qs(url.query)
        if url.path.endswith("actions/runners"):
            return {"total_count": 1, "runners": [{"id": 3, "name": "build-1", "os": "linux",
                                                  "status": "online", "busy": False}]}
        if url.path.endswith("/jobs"):
            return {"total_count": 1, "jobs": [{"status": "completed", "started_at": "2026-01-01T00:02:00Z",
                                                "completed_at": "2026-01-01T00:03:00Z"}]}
        status = query["status"][0]
        runs = [] if status != "completed" else [{"id": 4, "workflow_id": 6, "status": "completed",
                    "conclusion": "failure", "run_attempt": 2 if self.retry else 1,
                    "created_at": "2026-01-01T00:00:00Z"}]
        return {"total_count": len(runs), "workflow_runs": runs}


class MetricsTests(unittest.TestCase):
    def test_prometheus_label_escaping_keeps_utf8(self):
        text = metrics.sample("value", 1, name='日本 "a"\\b\nc')
        self.assertIn('日本 \\"a\\"\\\\b\\nc', text)
        self.assertNotIn('\\u', text)
        self.assertEqual(text.count('\n'), 1)

    def test_pagination_returns_every_runner(self):
        calls = []
        def api(endpoint):
            calls.append(endpoint)
            page = int(parse_qs(urlsplit(endpoint).query)["page"][0])
            return {"total_count": 101, "runners": list(range(100)) if page == 1 else [100]}
        self.assertEqual(len(metrics.paginated(api, "orgs/acme/actions/runners", "runners")), 101)
        self.assertEqual(len(calls), 2)

    def test_pagination_guard_never_reports_partial_counts(self):
        def api(_):
            return {"total_count": 101, "jobs": [1] * 100}
        with self.assertRaisesRegex(ValueError, "pagination limit"):
            metrics.paginated(api, "jobs", "jobs", max_pages=1)

    def test_runner_and_workflow_snapshots_are_separate(self):
        client = FakeAPI()
        text = metrics.github_metrics(["acme/project"], organizations=["acme"], client=client)
        self.assertIn('ci_github_runner_online{organization="acme",runner="build-1",runner_id="3",os="linux"} 1', text)
        self.assertIn('ci_github_runner_busy{organization="acme",runner="build-1",runner_id="3",os="linux"} 0', text)
        self.assertIn('ci_actions_recent_job_duration_seconds_sum{repository="acme/project",workflow="6"} 60.0', text)
        self.assertIn('ci_actions_recent_run_start_delay_seconds_sum{repository="acme/project",workflow="6"} 120.0', text)
        self.assertIn('ci_actions_active_jobs{repository="acme/project",status="queued"} 0', text)
        self.assertNotIn('queue_seconds', text)

    def test_repeated_scope_flags_do_not_duplicate_prometheus_series(self):
        text = metrics.github_metrics(["acme/project", "acme/project"],
                                      organizations=["acme", "acme"], client=FakeAPI())
        self.assertEqual(text.count('ci_github_registered_runners{'), 1)
        self.assertEqual(text.count('ci_actions_recent_run_window{'), 1)

    def test_completed_jobs_cache_avoids_repeated_api_cost(self):
        client = FakeAPI()
        metrics.github_metrics(["acme/project"], client=client)
        metrics.github_metrics(["acme/project"], client=client)
        self.assertEqual(sum('/jobs?' in endpoint for endpoint in client.calls), 1)
        client.retry = True
        metrics.github_metrics(["acme/project"], client=client)
        self.assertEqual(sum('/jobs?' in endpoint for endpoint in client.calls), 2)
        self.assertEqual(len(client.cache), 1)

    def test_rerun_excluded_from_creation_delay(self):
        text = metrics.github_metrics(["acme/project"], client=FakeAPI(retry=True))
        self.assertNotIn('recent_run_start_delay_seconds', text)
        self.assertIn('recent_job_duration_seconds', text)

    def test_token_file_permissions_and_gh_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            path.write_text("test-secret\n")
            path.chmod(0o644)
            with self.assertRaisesRegex(ValueError, '0600'):
                metrics.GitHubAPI(path).token()
            path.chmod(0o600)
            self.assertEqual(metrics.GitHubAPI(path).token(), 'test-secret')
        with patch.object(metrics, 'number', return_value='test-gh-secret') as run:
            self.assertEqual(metrics.GitHubAPI().token(), '')
            run.assert_not_called()
            self.assertEqual(metrics.GitHubAPI(use_gh_auth=True).token(), 'test-gh-secret')
            run.assert_called_once_with(['gh', 'auth', 'token', '--hostname', 'github.com'])

    def test_failed_collection_removes_stale_measurements_but_keeps_health(self):
        with patch.dict(metrics.STATE, text="stale_runner_count 17\n", ok=0, updated=42):
            text = metrics.exposition()
            self.assertNotIn("stale_runner_count", text)
            self.assertIn("ci_metrics_collection_success 0", text)
            self.assertIn("ci_metrics_last_success_timestamp_seconds 42", text)
        with patch.dict(metrics.STATE, text="fresh_runner_count 2\n", ok=1, updated=44):
            self.assertIn("fresh_runner_count 2", metrics.exposition())

    def test_dashboard_queries_keep_capacity_separate_and_missing_visible(self):
        resource = json.loads((METRICS.parent / 'monitoring/dashboard.json').read_text())
        dashboard = json.loads(resource['data']['ci-fleet.json'])
        panel = next(row for row in dashboard['panels'] if row['title'] == 'ARC runner capacity')
        self.assertEqual([target['expr'] for target in panel['targets']], [
            f'gha_{name}_runners' for name in ['desired', 'registered', 'busy', 'idle', 'min', 'max']])
        expressions = [target['expr'] for row in dashboard['panels'] for target in row['targets']]
        self.assertFalse(any('or vector(0)' in expression for expression in expressions))
        for name in ['node_network_receive_bytes_total', 'node_disk_read_bytes_total', 'ci_github_runner_online']:
            self.assertTrue(any(name in expression for expression in expressions), name)


if __name__ == '__main__':
    unittest.main()
