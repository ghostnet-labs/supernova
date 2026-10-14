#!/usr/bin/env python3
"""Small host and GitHub metrics endpoint; no credentials in output."""
import argparse
import datetime as dt
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import threading
import time
from urllib.request import Request, urlopen

STATE = {"text": "", "ok": 0, "updated": 0}
LOCK = threading.Lock()


def sample(name, value, **labels):
    suffix = ""
    if labels:
        suffix = "{" + ",".join(f"{key}={json.dumps(str(val))}" for key, val in labels.items()) + "}"
    return f"{name}{suffix} {value}\n"


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


def api(endpoint, token_file):
    token = token_file.read_text().strip()
    request = Request("https://api.github.com/" + endpoint, headers={
        "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "local-ci-metrics",
    })
    with urlopen(request, timeout=20) as response:
        return json.load(response)


def github_metrics(repositories, token_file):
    text = ""
    for repo in repositories:
        scope = f"repos/{repo}/actions/runs"
        for status in ("queued", "in_progress"):
            result = api(scope + "?status=" + status + "&per_page=1", token_file)
            text += sample("ci_actions_runs", result["total_count"], repository=repo, status=status)
        completed = api(scope + "?status=completed&per_page=20", token_file)
        durations = {}
        conclusions = {}
        for run in completed["workflow_runs"]:
            workflow = run.get("name") or str(run["workflow_id"])
            key = (workflow, run.get("conclusion") or "unknown")
            conclusions[key] = conclusions.get(key, 0) + 1
            jobs = api(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100", token_file)
            if jobs["total_count"] > 100:
                # Mark collection incomplete instead of silently dropping jobs.
                raise ValueError("Job pagination required for this workflow.")
            for job in jobs["jobs"]:
                if job.get("started_at") and job.get("completed_at"):
                    start = dt.datetime.fromisoformat(job["started_at"].replace("Z", "+00:00"))
                    end = dt.datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
                    durations.setdefault(workflow, []).append(max(0, (end - start).total_seconds()))
        for (workflow, conclusion), value in conclusions.items():
            text += sample("ci_actions_recent_completed_runs", value,
                           repository=repo, workflow=workflow, conclusion=conclusion)
        for workflow, values in durations.items():
            text += sample("ci_actions_recent_job_duration_seconds_sum", sum(values),
                           repository=repo, workflow=workflow)
            text += sample("ci_actions_recent_job_duration_seconds_count", len(values),
                           repository=repo, workflow=workflow)
    return text


def collect(args):
    while True:
        try:
            result = host_metrics() if args.mode == "host" else github_metrics(
                args.repository, args.token_file)
            with LOCK:
                STATE.update(text=result, ok=1, updated=time.time())
        except Exception:
            # Never print HTTP request headers, tokens, or private response bodies.
            with LOCK:
                STATE["ok"] = 0
        time.sleep(args.interval)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        with LOCK:
            text = STATE["text"] if STATE["ok"] else ""
            text += sample("ci_metrics_collection_success", STATE["ok"])
            text += sample("ci_metrics_last_success_timestamp_seconds", STATE["updated"])
        payload = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["host", "github"], required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9108)
    parser.add_argument("--interval", type=int, default=120)
    parser.add_argument("--repository", action="append", default=[])
    parser.add_argument("--token-file", type=Path)
    args = parser.parse_args()
    if args.interval < 10:
        parser.error("interval must be at least 10 seconds")
    if args.mode == "github" and (not args.repository or not args.token_file):
        parser.error("GitHub mode needs --repository and --token-file")
    threading.Thread(target=collect, args=(args,), daemon=True).start()
    ThreadingHTTPServer((args.listen, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

