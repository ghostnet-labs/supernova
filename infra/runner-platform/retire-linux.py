#!/usr/bin/env python3
"""Retire the five legacy Linux slots, keeping their VM and rollback configuration."""
import argparse
import base64
import datetime as dt
import fcntl
import hashlib
import importlib.util
import json
import os
import plistlib
import re
import shlex
import signal
import stat
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("retire_rollout", ROOT / "rollout.py")
rollout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rollout)
platform = rollout.platform
VM = "gh-ubuntu"
SLOTS = tuple(f"studio-ubuntu-{n}" for n in range(1, 6))
LABELS = tuple("com.ghostnet.jit." + slot for slot in SLOTS)
AUTOSTART = "com.ghostnet.lima-gh-ubuntu"
RECORD = "linux-retirement.json"
CI_EXPRESSION = "${{ github.event_name == 'workflow_dispatch' && inputs.linux_runner || 'ubuntu-latest' }}"

# No process arguments or environment are emitted: those can contain credentials.
# Freeze every listener in one guest transaction; resume every paused process on error.
GUEST = r'''import json, os, signal, sys, time
from pathlib import Path
action, payload = sys.argv[1], json.loads(sys.argv[2])
def processes(name):
    return [int(p.name) for p in Path('/proc').iterdir() if p.name.isdigit()
            and (p / 'comm').exists() and (p / 'comm').read_text().strip() == name]
def identity(pid):
    p = Path('/proc') / str(pid)
    return {'pid': pid, 'exe': str((p / 'exe').resolve()),
            'started': (p / 'stat').read_text().rsplit(')', 1)[1].split()[19]}
def matches(item):
    try: return identity(item['pid']) == item
    except (FileNotFoundError, ProcessLookupError): return False
def idle():
    if processes('Runner.Worker'): raise RuntimeError('A runner worker exists; retry after completion.')
    for pid in processes('Runner.Listener'):
        children = Path('/proc') / str(pid) / 'task' / str(pid) / 'children'
        if children.read_text().strip(): raise RuntimeError('A listener has children; refusing retirement.')
def checked():
    current = [identity(pid) for pid in processes('Runner.Listener')]
    expected = {str((Path(d) / 'bin/Runner.Listener').resolve()) for d in payload['directories']}
    if any(item['exe'] not in expected for item in current):
        raise RuntimeError('An unexpected listener exists; refusing retirement.')
    return current, expected
if action == 'resume':
    current, expected = checked()
    for item in current: os.kill(item['pid'], signal.SIGCONT)
elif action == 'freeze':
    paused = []
    try:
        idle()
        current, expected = checked()
        if len(current) != 5 or {i['exe'] for i in current} != expected:
            raise RuntimeError('Expected exactly the five inspected listeners.')
        for item in current:
            if not matches(item): raise RuntimeError('Listener identity changed.')
            os.kill(item['pid'], signal.SIGSTOP)
            paused.append(item)
        for attempt in range(100):
            if all(matches(i) and '\nState:\tT' in (Path('/proc') / str(i['pid']) / 'status').read_text()
                   for i in paused): break
            time.sleep(.02)
        else: raise RuntimeError('Listeners did not pause.')
        idle()
        print(json.dumps(paused))
    except BaseException:
        for item in paused:
            if matches(item): os.kill(item['pid'], signal.SIGCONT)
        raise
elif action in ('check', 'terminate', 'empty'):
    idle()
    current, expected = checked()
    records = payload.get('listeners', [])
    if any(item not in records for item in current): raise RuntimeError('A new listener appeared.')
    if action == 'check' and (current != records and sorted(current, key=lambda i:i['pid']) != sorted(records, key=lambda i:i['pid'])):
        raise RuntimeError('A listener disappeared during retirement.')
    if action == 'check':
        for item in current:
            if '\nState:\tT' not in (Path('/proc') / str(item['pid']) / 'status').read_text():
                raise RuntimeError('A listener resumed during retirement.')
    if action == 'terminate':
        for item in current:
            if not matches(item): raise RuntimeError('Listener identity changed.')
            os.kill(item['pid'], signal.SIGTERM)
            os.kill(item['pid'], signal.SIGCONT)
        for attempt in range(120):
            idle()
            if not processes('Runner.Listener'): break
            time.sleep(.25)
        else: raise RuntimeError('Listeners did not exit; VM remains running.')
    if action == 'empty' and current: raise RuntimeError('A listener remains; VM remains running.')
else: raise RuntimeError('Unknown guest action.')
'''


def durable(path, value):
    """Publish the recovery record atomically before changing host or guest state."""
    temporary = path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as output:
        os.fchmod(output.fileno(), 0o600)
        json.dump(value, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def guest(action, record):
    payload = {"directories": [slot["directory"] for slot in record["slots"]],
               "listeners": record.get("listeners", [])}
    return platform.run(["limactl", "shell", VM, "--", "sudo", "python3", "-c", GUEST,
                         action, json.dumps(payload)], capture=True, timeout=90)


def services():
    result = {}
    for line in platform.run(["launchctl", "list"], capture=True).splitlines():
        fields = line.split()
        if len(fields) == 3:
            result[fields[2]] = int(fields[0]) if fields[0].isdigit() else None
    return result


def process_started(pid):
    value = platform.run(["ps", "-p", str(pid), "-o", "lstart="], capture=True).strip()
    if not value:
        raise platform.PlatformError("The inspected host process exited.")
    return value


def signal_parent(slot, sig):
    if services().get(slot["label"]) != slot["pid"] or process_started(slot["pid"]) != slot["started"]:
        raise platform.PlatformError("Host JIT process identity changed; refusing to signal it.")
    os.kill(slot["pid"], sig)


def inspect_slots(home):
    loaded = services()
    if any("watchdog" in label for label in loaded):
        raise platform.PlatformError("A watchdog is loaded; configure maintenance exclusion first.")
    slots = []
    for label, slot in zip(LABELS, SLOTS):
        path = home / "Library/LaunchAgents" / (label + ".plist")
        data = plistlib.loads(path.read_bytes())
        args = data.get("ProgramArguments", [])
        index = next((i for i, arg in enumerate(args) if arg.endswith("/jit-slot.sh")), None)
        if (data.get("Label") != label or index is None or len(args) != index + 5
                or args[index + 1] != VM or args[index + 3] != slot
                or set(args[index + 4].split(",")) != {"self-hosted", "ARM64", "Linux"}):
            raise platform.PlatformError("Unexpected Linux slot LaunchAgent: " + label)
        directory = args[index + 2]
        if not directory.startswith("/home/runner/") or ".." in Path(directory).parts:
            raise platform.PlatformError("Unexpected Linux slot guest directory.")
        pid = loaded.get(label)
        if not pid:
            raise platform.PlatformError("The expected Linux slot has no host process: " + label)
        actual = shlex.split(platform.run(["ps", "-ww", "-p", str(pid), "-o", "command="], capture=True))
        if actual != args:
            raise platform.PlatformError("The host process differs from its LaunchAgent: " + label)
        slots.append({"label": label, "plist": str(path), "directory": directory,
                      "pid": pid, "started": process_started(pid)})
    if len({slot["directory"] for slot in slots}) != 5:
        raise platform.PlatformError("Linux slots do not have five distinct directories.")
    path = home / "Library/LaunchAgents" / (AUTOSTART + ".plist")
    auto = plistlib.loads(path.read_bytes())
    args = auto.get("ProgramArguments", [])
    if (auto.get("Label") != AUTOSTART or AUTOSTART not in loaded or len(args) != 3
            or Path(args[0]).name != "limactl" or args[1:] != ["start", VM]):
        raise platform.PlatformError("Unexpected legacy VM autostart LaunchAgent.")
    return slots, {"label": AUTOSTART, "plist": str(path), "loaded": AUTOSTART in loaded}


def input_choices(document, name):
    value = document.get("on", {}).get("workflow_dispatch", {}).get("inputs", {}).get(name, {})
    options = value.get("options")
    if (value.get("type") != "choice" or not isinstance(options, list) or not options
            or any(not isinstance(option, str) or "${{" in option for option in options)
            or value.get("default") not in options):
        raise platform.PlatformError("Runner expression needs a closed, defaulted choice input: " + name)
    return options


UNKNOWN = object()
MAX_VALUES = 256


def finite(values):
    result = []
    for value in values:
        if not any(value is prior or (value is not UNKNOWN and prior is not UNKNOWN
                                     and type(value) is type(prior) and value == prior) for prior in result):
            result.append(value)
        if len(result) > MAX_VALUES:
            raise platform.PlatformError("Runner expression exceeds finite audit limit.")
    return result


def truth(value):
    return None if value is UNKNOWN else not (value is None or value is False or value == 0 or value == "")


class RouteExpression:
    """Interpret a deliberately small Actions expression subset, never Python eval."""
    token = re.compile(r"\s*('(?:[^']|'')*'|&&|\|\||==|!=|[!(),]|[A-Za-z_][A-Za-z_0-9.-]*|-?\d+(?:\.\d+)?)")

    def __init__(self, source, context):
        self.tokens = []
        while source.strip():
            match = self.token.match(source)
            if not match or len(self.tokens) >= 256:
                raise platform.PlatformError("Unmapped dynamic runs-on expression.")
            self.tokens.append(match[1])
            source = source[match.end():]
        self.index, self.context = 0, context

    def accept(self, token):
        if self.index < len(self.tokens) and self.tokens[self.index] == token:
            self.index += 1
            return True
        return False

    def parse(self):
        result = self.binary(0)
        if self.index != len(self.tokens):
            raise platform.PlatformError("Unmapped dynamic runs-on expression.")
        return result

    def binary(self, level):
        if level == 3:
            return self.atom()
        left = self.binary(level + 1)
        operators = (("||",), ("&&",), ("==", "!="))[level]
        while self.index < len(self.tokens) and self.tokens[self.index] in operators:
            operator = self.tokens[self.index]
            self.index += 1
            right = self.binary(level + 1)
            output = []
            for a in left:
                for b in right:
                    if operator in ("==", "!="):
                        if a is UNKNOWN or b is UNKNOWN or isinstance(a, (list, dict)) or isinstance(b, (list, dict)):
                            # Actions arrays/objects compare by identity, not Python deep equality.
                            output.extend([True, False])
                        elif type(a) is type(b):
                            equal = a.lower() == b.lower() if isinstance(a, str) else a == b
                            output.append(equal if operator == "==" else not equal)
                        else:
                            # Actions coerces mixed comparison types. Overapproximate both outcomes.
                            output.extend([True, False])
                    elif operator == "&&":
                        output.extend([False, b] if truth(a) is None else [b if truth(a) else a])
                    else:
                        output.extend([UNKNOWN, b] if truth(a) is None else [a if truth(a) else b])
            left = finite(output)
        return left

    def atom(self):
        if self.accept("!"):
            return finite(answer for value in self.atom() for answer in
                          ([True, False] if truth(value) is None else [not truth(value)]))
        if self.accept("("):
            value = self.binary(0)
            if not self.accept(")"):
                raise platform.PlatformError("Unbalanced runner expression.")
            return value
        if self.index >= len(self.tokens):
            raise platform.PlatformError("Incomplete runner expression.")
        token = self.tokens[self.index]
        self.index += 1
        if token.startswith("'"):
            return [token[1:-1].replace("''", "'")]
        if token.lower() == "fromjson":
            if not self.accept("("):
                raise platform.PlatformError("Unmapped fromJSON expression.")
            values = self.binary(0)
            if not self.accept(")") or any(not isinstance(value, str) for value in values):
                raise platform.PlatformError("fromJSON needs finite literal strings.")
            return finite(json.loads(value) for value in values)
        if token in ("true", "false", "null"):
            return [{"true": True, "false": False, "null": None}[token]]
        if re.fullmatch(r"-?\d+(?:\.\d+)?", token):
            return [json.loads(token)]
        return self.context.get(token, [UNKNOWN])


def expression_values(value, context):
    if isinstance(value, str) and "${{" in value:
        match = re.fullmatch(r"\s*\$\{\{(.*?)\}\}\s*", value, re.S)
        if not match:
            raise platform.PlatformError("Unmapped interpolated runner expression.")
        return RouteExpression(match[1], context).parse()
    return [value]


def context_values(value, context):
    """Unknown data is harmless until it participates in a runner route."""
    try:
        return expression_values(value, context)
    except (platform.PlatformError, ValueError):
        return [UNKNOWN]


def input_context(document, supplied=None):
    supplied = supplied or {}
    context = dict(supplied)
    events = document.get("on", {})
    if not isinstance(events, dict):
        return context
    for event in ("workflow_dispatch", "workflow_call"):
        definition = events.get(event) or {}
        for name, value in definition.get("inputs", {}).items():
            key = "inputs." + name
            if key in supplied:
                continue
            if value.get("type") == "choice" and event == "workflow_dispatch":
                values = input_choices(document, name)
            elif value.get("type") == "boolean":
                values = [True, False]
            else:
                # A workflow_call default does not constrain a caller's supplied string.
                values = [UNKNOWN]
            context[key] = finite(context.get(key, []) + values)
    for key in set(context) - set(supplied):
        name = key.removeprefix("inputs.")
        if any(event not in ("workflow_dispatch", "workflow_call") or
               name not in (definition or {}).get("inputs", {})
               for event, definition in events.items()):
            # Push/PR/schedule events have no dispatch inputs. Their absent value
            # is falsy, so an || fallback must remain part of the route audit.
            context[key] = finite(context[key] + [None])
    return context


def job_context(document, job, supplied=None):
    context = input_context(document, supplied)
    matrix = (job.get("strategy") or {}).get("matrix", {})
    alternatives = []
    try:
        matrices = context_values(matrix, context)
    except platform.PlatformError:
        matrices = [UNKNOWN]
    for matrix in matrices:
        dimensions = {}
        if isinstance(matrix, dict):
            for name, values in matrix.items():
                if name in ("include", "exclude"):
                    continue
                dimensions["matrix." + name] = finite(
                    v for value in values for v in context_values(value, context)) if isinstance(values, list) and values else [UNKNOWN]
            includes = matrix.get("include", [])
            if isinstance(includes, list) and all(isinstance(row, dict) for row in includes):
                for row in includes:
                    for key, value in row.items():
                        key = "matrix." + key
                        dimensions[key] = finite(dimensions.get(key, []) + context_values(value, context))
                base_dimensions = set(matrix) - {"include", "exclude"}
                for key in {key for row in includes for key in row} - base_dimensions:
                    if base_dimensions or any(key not in row for row in includes):
                        dimensions["matrix." + key] = finite(dimensions["matrix." + key] + [UNKNOWN])
            else:
                # Unknown include entries may alter any matrix routing property.
                dimensions = {}
            # Ignoring excludes broadens the audit, so cannot hide legacy routes.
        alternatives.append(dimensions)
    for key in {key for alternative in alternatives for key in alternative}:
        context[key] = finite(value for alternative in alternatives for value in alternative.get(key, [UNKNOWN]))
    return context


def route_labels(route, document, context=None):
    context = input_context(document) if context is None else context
    if isinstance(route, dict) and set(route) == {"labels"}:
        return route_labels(route["labels"], document, context)
    result = []
    for value in expression_values(route, context):
        if isinstance(value, str) and value and "${{" not in value:
            result.append([value])
        elif isinstance(value, list) and value:
            combinations = [[]]
            for label in value:
                choices = expression_values(label, context)
                if any(not isinstance(choice, str) or not choice or "${{" in choice for choice in choices):
                    raise platform.PlatformError("Unmapped dynamic runner label.")
                combinations = finite(prior + [choice] for prior in combinations for choice in choices)
            result.extend(combinations)
        else:
            raise platform.PlatformError("Unmapped runs-on structure or runner group.")
    return finite(result)


def workflow_routes(workflows, legacy_labels):
    blockers, documents, remote, visits = [], {}, {}, [0]
    index = {(entry["repository"], entry.get("commit"), entry["path"]): entry for entry in workflows}

    def document(entry):
        key = (entry["repository"], entry.get("commit"), entry["path"], entry["content"])
        if key not in documents:
            value = json.loads(platform.run(["yq", "-o=json", ".", "-"],
                                            input_text=entry["content"], capture=True))
            if not isinstance(value, dict) or not isinstance(value.get("jobs"), dict):
                raise platform.PlatformError("Workflow jobs cannot be inspected.")
            documents[key] = value
        return documents[key]

    def fetched(repository, commit, path):
        # Workflow text is untrusted, including the coordinates inherited by a
        # local sibling. Validate before constructing any GitHub API endpoint.
        if (not isinstance(repository, str)
                or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
                or any(part in (".", "..") for part in repository.split("/"))
                or not isinstance(commit, str) or not re.fullmatch(r"[a-fA-F0-9]{40}", commit)
                or not isinstance(path, str)
                or not re.fullmatch(r"\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml", path)):
            raise platform.PlatformError("Invalid immutable reusable workflow coordinates.")
        key = (repository, commit, path)
        if key not in remote:
            if len(remote) >= 100:
                raise platform.PlatformError("Remote reusable workflow audit limit exceeded.")
            payload = platform.gh_json(f"repos/{repository}/contents/{quote(path, safe='/')}?ref={commit}")
            if payload.get("encoding") != "base64":
                raise platform.PlatformError("Reusable workflow content unavailable.")
            content = base64.b64decode(payload["content"], validate=False).decode("utf-8")
            if len(content) > 1024 * 1024:
                raise platform.PlatformError("Reusable workflow exceeds audit size limit.")
            remote[key] = dict(repository=repository, commit=commit, branch=commit, path=path, content=content)
        return remote[key]

    def called(entry, uses):
        if not isinstance(uses, str):
            raise platform.PlatformError("Unmapped reusable workflow reference.")
        if re.fullmatch(r"\./\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml", uses):
            key = (entry["repository"], entry.get("commit"), uses[2:])
            if key[1] and key in index:
                return index[key]
            caller = (entry["repository"], entry.get("commit"), entry["path"])
            # Only already-fetched external callers may expand their immutable
            # dependency closure. Missing inventory entries remain blockers.
            if caller in remote and remote[caller] is entry:
                return fetched(key[0], key[1], key[2])
            raise platform.PlatformError("Reusable workflow missing at exact caller commit: " + uses)
        match = re.fullmatch(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml)@([a-fA-F0-9]{40})", uses)
        if not match:
            raise platform.PlatformError("Reusable workflow requires immutable SHA audit: " + uses)
        repository, path, commit = match.groups()
        return fetched(repository, commit, path)

    def inspect(entry, supplied=None, stack=()):
        key = (entry["repository"], entry.get("commit"), entry["path"])
        visits[0] += 1
        if key in stack or len(stack) >= 10 or visits[0] > 10000:
            raise platform.PlatformError("Reusable workflow cycle/depth/breadth audit limit exceeded.")
        data = document(entry)
        for job_id, job in data["jobs"].items():
            if not isinstance(job, dict):
                raise platform.PlatformError("Workflow job cannot be inspected.")
            try:
                context = job_context(data, job, supplied)
                if "uses" in job:
                    target = called(entry, job["uses"])
                    child = document(target)
                    definitions = (child.get("on", {}).get("workflow_call") or {}).get("inputs", {})
                    passed = job.get("with", {})
                    if not isinstance(passed, dict):
                        raise platform.PlatformError("Reusable workflow inputs cannot be inspected.")
                    values = {"inputs." + name: context_values(value, context) for name, value in passed.items()}
                    for name, definition in definitions.items():
                        if name not in passed and "default" in definition:
                            # Child defaults cannot be evaluated in the caller input context.
                            default = definition["default"]
                            values["inputs." + name] = [UNKNOWN] if isinstance(default, str) and "${{" in default else [default]
                    inspect(target, values, stack + (key,))
                    continue
                for labels in route_labels(job.get("runs-on"), data, context):
                    lower = {label.lower() for label in labels}
                    if any(lower <= known for known in legacy_labels) or any(
                            label.lower().startswith("studio-ubuntu-") for label in labels):
                        where = f"{entry['repository']}@{entry['branch']}:{entry['path']}:{job_id}"
                        blockers.append(where + " still routes to legacy Linux")
            except (platform.PlatformError, ValueError, KeyError, TypeError, AttributeError, RecursionError) as error:
                where = f"{entry['repository']}@{entry['branch']}:{entry['path']}:{job_id}"
                blockers.append(where + ": " + str(error))

    for entry in workflows:
        where = f"{entry['repository']}@{entry['branch']}:{entry['path']}"
        try:
            inspect(entry)
        except (platform.PlatformError, ValueError, KeyError, TypeError, AttributeError, RecursionError) as error:
            blockers.append(where + ": " + str(error))
    if blockers:
        # Mutable external targets recur across many branch snapshots: retain one
        # exact context and a count instead of flooding the operator with copies.
        summaries = {}
        for blocker in blockers:
            marker = ": Reusable workflow requires immutable SHA audit: "
            key = blocker.split(marker, 1)[1] if marker in blocker else blocker
            if key not in summaries:
                summaries[key] = [blocker, 0]
            summaries[key][1] += 1
        messages = [message + (f" ({count} inventory references)" if count > 1 else "")
                    for message, count in summaries.values()]
        raise platform.PlatformError("Retirement workflow blockers:\n" + "\n".join(messages))


def registrations(cfg):
    scope = platform.github_path(cfg["github_url"])
    rows = platform.gh_pages(scope + "/actions/runners?per_page=100", "runners")
    result = []
    for slot in SLOTS:
        matches = [row for row in rows if row["name"] == slot or row["name"].startswith(slot + "-")]
        if len(matches) != 1 or matches[0].get("busy") or matches[0].get("status") != "online":
            raise platform.PlatformError("Expected one online, idle registration for " + slot)
        result.append(matches[0])
    return result


def open_pr_workflows(cfg, workflows):
    """Include reachable open PR heads, including fork heads absent from branch lists."""
    result = list(workflows)
    seen = {(entry["repository"], entry["commit"]) for entry in workflows}
    for repository in rollout.repositories(cfg):
        pulls = platform.gh_pages(f"repos/{repository}/pulls?state=open&per_page=100")
        for pull in pulls:
            head = pull.get("head", {})
            source = (head.get("repo") or {}).get("full_name")
            sha = head.get("sha")
            if not source or not sha:
                raise platform.PlatformError("An open PR head cannot be inspected in " + repository)
            if (source, sha) in seen:
                continue
            seen.add((source, sha))
            scope = "repos/" + source
            tree = platform.gh_json(scope + f"/git/trees/{sha}?recursive=1")
            if tree.get("truncated"):
                raise platform.PlatformError("An open PR workflow tree is truncated in " + repository)
            for entry in tree["tree"]:
                if entry["type"] == "blob" and re.fullmatch(r"[.]github/workflows/[^/]+[.]ya?ml", entry["path"]):
                    blob = platform.gh_json(scope + "/git/blobs/" + entry["sha"])
                    result.append({"repository": repository, "branch": f"pull/{pull['number']}/head",
                                   "commit": sha, "path": entry["path"],
                                   "content": base64.b64decode(blob["content"]).decode()})
    return result


def gates(cfg, state, repository, run_id):
    rollout.lifecycle_evidence(cfg, state, repository)
    workload = rollout.real_workload(cfg, repository, run_id)
    if not workload.get("arc_jobs"):
        raise platform.PlatformError("No successful real Linux workload evidence.")
    run = platform.gh_json(f"repos/{repository}/actions/runs/{run_id}")
    jobs = platform.gh_pages(f"repos/{repository}/actions/runs/{run_id}/jobs?per_page=100", "jobs")
    full_jobs = [job for job in jobs if job["id"] in workload["arc_jobs"]
                 and job.get("name") == "Lint and test on Ubuntu"
                 and any(step.get("name") == "Run ./setup.sh --test" and step.get("conclusion") == "success"
                         for step in job.get("steps", []))]
    if run.get("path") != ".github/workflows/ci.yml" or not full_jobs:
        raise platform.PlatformError("The validation run must include the complete Linux repository suite on ARC.")
    # Recheck actual cluster state, including collector scrapes, rather than trusting an old report.
    platform.verify_monitoring(cfg, state)
    rollout.require_idle(rollout.collect(cfg, state))
    return workload


def preflight(cfg, state, repository, run_id, home):
    gates(cfg, state, repository, run_id)
    platform.inventory(cfg, state)
    rows = registrations(cfg)
    workflows = open_pr_workflows(cfg, json.loads((state / "workflow-inventory.json").read_text()))
    workflow_routes(workflows, [{label["name"].lower() for label in row["labels"]} for row in rows])
    slots, autostart = inspect_slots(home)
    vm = next((vm for vm in platform.lima_state() if vm["name"] == VM), None)
    if not vm or vm["status"] != "Running" or vm["memory"] != 6 * platform.GIB:
        raise platform.PlatformError("Expected the running legacy 6 GiB Linux VM.")
    return {"phase": "prepared", "vm": VM, "memory": vm["memory"], "slots": slots,
            "autostart": autostart, "registration_ids": [row["id"] for row in rows],
            "repository": repository, "validation_run": run_id,
            "prepared_at": dt.datetime.now(dt.timezone.utc).isoformat()}


def restore_services(record):
    domain = f"gui/{os.getuid()}"
    errors = []
    for service in [*record["slots"], record["autostart"]]:
        try:
            platform.run(["launchctl", "enable", f"{domain}/{service['label']}"])
            if service["label"] not in services() and service.get("loaded", True):
                platform.run(["launchctl", "bootstrap", domain, service["plist"]])
        except BaseException as error:
            errors.append(str(error))
    if errors:
        raise platform.PlatformError("Service recovery needs inspection: " + "; ".join(errors))


def recover(record):
    errors = []
    try:
        guest("resume", record)
    except BaseException as error:
        errors.append(str(error))
    finally:
        for slot in record["slots"]:
            try:
                if services().get(slot["label"]) == slot["pid"]:
                    signal_parent(slot, signal.SIGCONT)
            except ProcessLookupError:
                pass
            except BaseException as error:
                errors.append(str(error))
        try:
            restore_services(record)
        except BaseException as error:
            errors.append(str(error))
    if errors:
        raise platform.PlatformError("Retirement recovery needs inspection: " + "; ".join(errors))


def retire(cfg, state, repository, run_id, home):
    path = state / RECORD
    if path.exists():
        previous = json.loads(path.read_text())
        if previous.get("phase") == "stopped":
            vm = next((vm for vm in platform.lima_state() if vm["name"] == VM), None)
            if vm and vm["status"] == "Stopped" and not (set(LABELS) | {AUTOSTART}) & services().keys():
                print("Legacy Linux VM is already retired; disk and configuration retained.")
                return
        if previous.get("phase") != "restored":
            raise platform.PlatformError("An incomplete or changed retirement exists; run rollback before retrying.")
    record = preflight(cfg, state, repository, run_id, home)
    durable(path, record)
    try:
        for slot in record["slots"]:
            signal_parent(slot, signal.SIGSTOP)
        record["listeners"] = json.loads(guest("freeze", record))
        record["phase"] = "paused"
        durable(path, record)
        rollout.require_idle(rollout.collect(cfg, state))
        if [row["id"] for row in registrations(cfg)] != record["registration_ids"]:
            raise platform.PlatformError("Legacy registrations changed during retirement.")
        guest("check", record)
        domain = f"gui/{os.getuid()}"
        for service in [*record["slots"], record["autostart"]]:
            platform.run(["launchctl", "disable", f"{domain}/{service['label']}"])
        record["phase"] = "disabled"
        durable(path, record)
        for slot in record["slots"]:
            signal_parent(slot, signal.SIGCONT)
        for service in [*record["slots"], record["autostart"]]:
            if service["label"] in services():
                platform.run(["launchctl", "bootout", f"{domain}/{service['label']}"], timeout=90)
        guest("terminate", record)
        rollout.require_idle(rollout.collect(cfg, state))
        guest("empty", record)
        if (set(LABELS) | {AUTOSTART}) & services().keys():
            raise platform.PlatformError("A legacy LaunchAgent reappeared; VM remains running.")
        platform.run(["limactl", "stop", VM], timeout=180)
        record["phase"] = "stopped"
        durable(path, record)
    except BaseException:
        record["phase"] = "recovery_required"
        durable(path, record)
        try:
            recover(record)
            record["phase"] = "restored"
            durable(path, record)
        except BaseException:
            print("Recovery needs inspection; run retire-linux.py rollback.", file=sys.stderr)
        raise
    print("Legacy Linux VM stopped. Five JIT slots and its autostart disabled; disk retained.")


def rollback(cfg, state):
    path = state / RECORD
    if not path.exists():
        raise platform.PlatformError("No retirement recovery record exists.")
    record = json.loads(path.read_text())
    if record.get("vm") != VM or tuple(slot["label"] for slot in record["slots"]) != LABELS:
        raise platform.PlatformError("Recovery record does not name the exact legacy Linux slots.")
    if record["phase"] == "restored":
        print("Legacy Linux services were already restored.")
        return
    instances = platform.lima_state()
    old = next((vm for vm in instances if vm["name"] == VM), None)
    if not old or old["memory"] != record["memory"]:
        raise platform.PlatformError("Legacy VM allocation changed; inspect recovery before restart.")
    if old["status"] != "Running":
        running = sum(vm["memory"] for vm in instances if vm["status"] == "Running")
        host_memory = int(platform.run(["sysctl", "-n", "hw.memsize"], capture=True))
        if running + old["memory"] + 8 * platform.GIB > host_memory:
            # A guest name alone is not ownership or authorization to stop it.
            # Only a managed record may release a new macOS guest's allocation.
            mac_path = state / "ci-macos-created.json"
            mac = json.loads(mac_path.read_text()) if mac_path.exists() else {}
            candidate = next((vm for vm in instances if vm["name"] == mac.get("vm_name")
                              and vm["name"] == "ci-macos" and vm["status"] == "Running"), None)
            if (not candidate or mac.get("schema_version") != 1
                    or mac.get("created_by") != "runner-platform-macos" or not mac.get("created_at")
                    or not managed_macos_configuration(state, mac, candidate)
                    or mac.get("memory_gib") != 6 or candidate["memory"] != 6 * platform.GIB
                    or mac.get("cpus") != 2 or candidate.get("cpus") != 2
                    or candidate.get("disk") != 80 * platform.GIB
                    or running - candidate["memory"] + old["memory"] + 8 * platform.GIB > host_memory):
                raise platform.PlatformError("Rollback exceeds the 8 GiB host reserve; drain and stop the new guest first.")
            rollout.require_idle(rollout.collect(cfg, state))
            platform.run(["limactl", "stop", candidate["name"]], timeout=180)
            durable(mac_path, dict(mac, stopped_for_linux_rollback=True))
        platform.run(["limactl", "start", "--tty=false", VM], timeout=600)
    recover(record)
    durable(path, dict(record, phase="restored"))
    print("Legacy Linux VM and exact original services restored; all disks retained.")


def managed_macos_configuration(state, record, candidate):
    if not candidate:
        return False
    path = Path(record.get("configuration", ""))
    if path != (state / "ci-macos.yaml").resolve():
        return False
    try:
        for owned in (path, state / "ci-macos-created.json"):
            info = owned.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) & 0o077):
                return False
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != record.get("configuration_sha256"):
            return False
        saved = json.loads(content)
        live = candidate.get("config", {})
        return all(live.get(key) == saved.get(key) for key in
                   ("os", "arch", "mounts", "plain", "ssh", "images")) and saved.get("os") == "Darwin"
    except (OSError, ValueError):
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Examples:\n  retire-linux.py plan --repository acme/toolbox --validation-run 123\n"
               "  retire-linux.py retire --repository acme/toolbox --validation-run 123\n"
               "  retire-linux.py rollback\nEnvironment: Run in the normal macOS host terminal; gh, limactl, yq and kubectl are required.")
    parser.add_argument("command", choices=("plan", "retire", "rollback"))
    parser.add_argument("--config", type=Path, default=ROOT / ".local/config.json")
    parser.add_argument("--repository", help="Repository containing lifecycle and full Linux workload evidence")
    parser.add_argument("--validation-run", type=int, help="Successful full Linux workload run on ARC")
    args = parser.parse_args(argv)
    if args.command != "rollback" and (not args.repository or not args.validation_run):
        parser.error("plan and retire require --repository and --validation-run")
    if args.repository and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("--repository must be OWNER/REPO")
    try:
        if sys.platform != "darwin":
            raise platform.PlatformError("Run in the normal macOS host terminal.")
        cfg = platform.load_config(args.config)
        if cfg["github_url"] != "https://github.com/ghostnet-labs":
            raise platform.PlatformError("This helper is scoped to the inspected Studio organization.")
        platform.identity(cfg)
        state = args.config.resolve().parent
        state.mkdir(mode=0o700, parents=True, exist_ok=True)
        with (state / "pilot.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.command == "rollback":
                rollback(cfg, state)
            elif args.command == "retire":
                retire(cfg, state, args.repository, args.validation_run, Path.home())
            else:
                record = preflight(cfg, state, args.repository, args.validation_run, Path.home())
                print(json.dumps(record, indent=2))
        return 0
    except (platform.PlatformError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Linux retirement stopped: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted; inspect the recovery record and run rollback before retrying.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
