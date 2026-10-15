#!/usr/bin/env python3
"""Small host and GitHub metrics endpoint; no credentials in output."""
import argparse
import datetime as dt
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import stat
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

STATE = {"text": "", "ok": 0, "updated": 0}
LOCK = threading.Lock()


def sample(metric_name, value, **labels):
    suffix = ""
    if labels:
        def escaped(value):
            return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')
        suffix = "{" + ",".join(f'{key}="{escaped(val)}"' for key, val in labels.items()) + "}"
    return f"{metric_name}{suffix} {value}\n"


def number(command):
    return subprocess.check_output(command, text=True, timeout=10).strip()


def host_metrics():
    disk = shutil.disk_usage("/")
    text = sample("ci_host_disk_available_bytes", disk.free)
    text += sample("ci_host_disk_size_bytes", disk.total)
    total = int(number(["sysctl", "-n", "hw.memsize"]))
    cores = int(number(["sysctl", "-n", "hw.ncpu"]))
    text += sample("ci_host_memory_size_bytes", total)
    vm = number(["vm_stat"])
    page_size = int(vm.split("page size of ")[1].split(" bytes")[0])
    pages = {}
    for line in vm.splitlines()[1:]:
        if ":" in line:
            key, val = line.split(":", 1)
            pages[key] = int(val.strip().rstrip("."))
    # Free pages only; inactive/compressed memory is not assumed available.
    text += sample("ci_host_memory_free_bytes", pages["Pages free"] * page_size)
    for label in ("Pages active", "Pages inactive", "Pages wired down", "Pages occupied by compressor"):
        if label in pages:
            text += sample("ci_host_memory_pages_bytes", pages[label] * page_size, state=label)
    cpu = sum(float(v) for v in number(["ps", "-A", "-o", "%cpu="]).split())
    text += sample("ci_host_process_cpu_ratio", cpu / (100 * cores))
    return text


class GitHubAPI:
    """Read-only client; refresh gh auth or a rotated token file each request."""

    def __init__(self, token_file=None, use_gh_auth=False):
        self.token_file = token_file
        self.use_gh_auth = use_gh_auth
        self.cache = {}

    def token(self):
        if self.use_gh_auth:
            return number(["gh", "auth", "token", "--hostname", "github.com"])
        if self.token_file:
            info = self.token_file.stat()
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError("Token file must be owned by this user with mode 0600.")
            token = self.token_file.read_text().strip()
            if not token:
                raise ValueError("Empty token file.")
            return token
        return ""

    def __call__(self, endpoint):
        headers = {"Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "local-ci-metrics"}
        token = self.token()
        if token:
            headers["Authorization"] = "Bearer " + token
        request = Request("https://api.github.com/" + endpoint, headers=headers)
        with urlopen(request, timeout=20) as response:
            return json.load(response)


def paginated(api, endpoint, key, params=None, max_pages=10):
    """Follow numbered pages; fail collection rather than report truncated counts."""
    values = []
    for page in range(1, max_pages + 1):
        query = dict(params or {}, per_page=100, page=page)
        data = api(endpoint + "?" + urlencode(query))
        items = data[key]
        values.extend(items)
        if len(items) < 100 or len(values) >= data["total_count"]:
            return values
    raise ValueError("API pagination limit reached; increase --max-pages.")


def seconds(start, end):
    first = dt.datetime.fromisoformat(start.replace("Z", "+00:00"))
    last = dt.datetime.fromisoformat(end.replace("Z", "+00:00"))
    value = (last - first).total_seconds()
    return value if value >= 0 else None


def github_metrics(repositories, token_file=None, organizations=(), *, client=None,
                   recent_runs=20, max_pages=10):
    api = client or GitHubAPI(token_file)
    text = ""
    cache = getattr(api, "cache", {})
    for org in dict.fromkeys(organizations):
        runners = paginated(api, f"orgs/{org}/actions/runners", "runners", max_pages=max_pages)
        text += sample("ci_github_registered_runners", len(runners), organization=org)
        for runner in runners:
            labels = dict(organization=org, runner=runner["name"],
                          runner_id=runner["id"], os=runner.get("os", "unknown"))
            if runner["status"] not in ("online", "offline"):
                raise ValueError("Unknown runner status.")
            text += sample("ci_github_runner_online", int(runner["status"] == "online"), **labels)
            text += sample("ci_github_runner_busy", int(runner["busy"]), **labels)
    # Workers only mutate private repository snapshots. Publish caches after every
    # scope succeeds, so failures cannot turn a partial snapshot into success.
    repos = list(dict.fromkeys(repositories))
    with ThreadPoolExecutor(max_workers=4, thread_name_prefix="github-metrics") as pool:
        futures = [pool.submit(repository_metrics, api, repo,
                               {key: value for key, value in cache.items() if key[0] == repo},
                               recent_runs, max_pages) for repo in repos]
        results = [future.result() for future in futures]
    refreshed = {}
    for repository_text, repository_cache in results:
        text += repository_text
        refreshed.update(repository_cache)
    cache.clear()
    cache.update(refreshed)
    return text


def repository_metrics(api, repo, cache, recent_runs, max_pages):
    """Collect one repository serially, retaining only its sampled completed jobs."""
    text = ""
    keep_cache = set()
    scope = f"repos/{repo}/actions/runs"
    active = {}
    for status in ("queued", "in_progress", "waiting", "pending", "requested"):
        runs = paginated(api, scope, "workflow_runs", {"status": status}, max_pages)
        text += sample("ci_actions_runs", len(runs), repository=repo, status=status)
        active.update((run["id"], run) for run in runs)
    completed = api(scope + "?" + urlencode({"status": "completed", "per_page": recent_runs}))
    recent = completed["workflow_runs"]
    text += sample("ci_actions_recent_run_window", recent_runs, repository=repo)
    aggregates = {}
    conclusions = {}
    jobs_counts = {}
    runs_by_id = dict(active)
    runs_by_id.update((run["id"], run) for run in recent)
    for run in runs_by_id.values():
        workflow = str(run["workflow_id"])
        complete = run["status"] == "completed"
        key = (repo, run["id"], run.get("run_attempt", 1))
        jobs = cache.get(key)
        if jobs is None:
            jobs = paginated(api, f"repos/{repo}/actions/runs/{run['id']}/jobs", "jobs",
                             {"filter": "latest"}, max_pages)
        if complete:
            cache[key] = jobs
            keep_cache.add(key)
            result = (workflow, run.get("conclusion") or "unknown")
            conclusions[result] = conclusions.get(result, 0) + 1
        for job in jobs:
            if not complete:
                count_key = (workflow, job["status"])
                jobs_counts[count_key] = jobs_counts.get(count_key, 0) + 1
            if complete and job.get("started_at") and job.get("completed_at"):
                value = seconds(job["started_at"], job["completed_at"])
                if value is not None:
                    aggregates.setdefault((workflow, "job_duration"), []).append(value)
        # REST jobs lack documented creation times. This is run startup delay,
        # not job queue time; do not include retry attempts measured from run creation.
        starts = [job["started_at"] for job in jobs if job.get("started_at")]
        if complete and starts and run.get("created_at") and run.get("run_attempt", 1) == 1:
            value = seconds(run["created_at"], min(starts))
            if value is not None:
                aggregates.setdefault((workflow, "run_start_delay"), []).append(value)
    for (workflow, status), count in jobs_counts.items():
        text += sample("ci_actions_jobs", count, repository=repo, workflow=workflow, status=status)
    # An empty active run list proves these totals are zero, rather than absent.
    for status in ("queued", "in_progress", "waiting", "pending", "requested"):
        text += sample("ci_actions_active_jobs", sum(
            value for (workflow, state), value in jobs_counts.items() if state == status),
            repository=repo, status=status)
    for (workflow, conclusion), count in conclusions.items():
        text += sample("ci_actions_recent_completed_runs", count,
                       repository=repo, workflow=workflow, conclusion=conclusion)
    for (workflow, metric), values in aggregates.items():
        labels = dict(repository=repo, workflow=workflow)
        text += sample(f"ci_actions_recent_{metric}_seconds_sum", sum(values), **labels)
        text += sample(f"ci_actions_recent_{metric}_seconds_count", len(values), **labels)
    return text, {key: cache[key] for key in keep_cache}


def collection_error(error):
    """Classify failures without exposing URLs, headers, bodies or credentials."""
    if isinstance(error, HTTPError):
        return f"HTTPError (HTTP {int(error.code)})"
    for kind in (URLError, TimeoutError, subprocess.CalledProcessError, ValueError, OSError):
        if isinstance(error, kind):
            return kind.__name__
    return "Exception"


def collect(args):
    client = GitHubAPI(args.token_file, args.use_gh_auth)
    while True:
        started = time.monotonic()
        try:
            result = host_metrics() if args.mode == "host" else github_metrics(
                args.repository, organizations=args.organization, client=client,
                recent_runs=args.recent_runs, max_pages=args.max_pages)
            with LOCK:
                STATE.update(text=result, ok=1, updated=time.time())
        except Exception as error:
            print("Metrics collection failed: " + collection_error(error), file=sys.stderr, flush=True)
            # Never print HTTP request headers, tokens, or private response bodies.
            with LOCK:
                STATE["ok"] = 0
        time.sleep(max(1, args.interval - (time.monotonic() - started)))


def exposition():
    with LOCK:
        text = STATE["text"] if STATE["ok"] else ""
        text += sample("ci_metrics_collection_success", STATE["ok"])
        text += sample("ci_metrics_last_success_timestamp_seconds", STATE["updated"])
    return text


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        payload = exposition().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Examples: %(prog)s --mode github --repository acme/project --use-gh-auth; "
        "%(prog)s --mode github --organization acme --token-file /private/token; "
        "%(prog)s --mode host. Environment: gh honors its normal authentication "
        "environment only with --use-gh-auth; file contents never appear in metrics."))
    parser.add_argument("--mode", choices=["host", "github"], required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9108)
    parser.add_argument("--interval", type=int, default=120)
    parser.add_argument("--repository", action="append", default=[])
    parser.add_argument("--organization", action="append", default=[],
                        help="Organization for conventional registered runner status; repeatable")
    auth = parser.add_mutually_exclusive_group()
    auth.add_argument("--token-file", type=Path, help="Private 0600 read-only credential file")
    auth.add_argument("--use-gh-auth", action="store_true", help="Use this user's existing gh login")
    auth.add_argument("--anonymous", action="store_true", help="Public repositories only; lower API limit")
    parser.add_argument("--recent-runs", type=int, default=20, help="Completed run sample, 1-100 (default 20)")
    parser.add_argument("--max-pages", type=int, default=10, help="Pagination safety bound (default 10)")
    args = parser.parse_args()
    if args.interval < 10:
        parser.error("interval must be at least 10 seconds")
    if not 1 <= args.recent_runs <= 100 or args.max_pages < 1:
        parser.error("recent-runs must be 1-100 and max-pages must be positive")
    if not 1 <= args.port <= 65535:
        parser.error("port must be 1-65535")
    if any(not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) for repo in args.repository):
        parser.error("repository must be OWNER/NAME")
    if any(not re.fullmatch(r"[A-Za-z0-9-]+", org) for org in args.organization):
        parser.error("organization must be a GitHub organization name")
    if args.anonymous and args.organization:
        parser.error("Organization runner inventory requires authentication")
    if args.mode == "github" and not (args.repository or args.organization):
        parser.error("GitHub mode needs --repository or --organization")
    if args.mode == "github" and not (args.token_file or args.use_gh_auth or args.anonymous):
        parser.error("Choose --token-file, --use-gh-auth or --anonymous")
    threading.Thread(target=collect, args=(args,), daemon=True).start()
    ThreadingHTTPServer((args.listen, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

