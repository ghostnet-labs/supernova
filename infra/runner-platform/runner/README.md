# ARM64 runner image

This image supplies build-time packages for openmanetd CGO, OpenVLM dependency
checks, and firmware hardware-qualification tooling. It includes libnl, GPS,
capabilities, Opus, PortAudio/ALSA, HID/USB/udev, PAM, mesh/network CLIs, and dtc.
Packages are installed while building the image; jobs need no runtime sudo.

`/opt/hostedtoolcache` is owned by runner UID 1001. `RUNNER_TOOL_CACHE` and
`AGENT_TOOLSDIRECTORY` point there for setup-go, setup-node, and setup-python.
Those actions still select each repository's requested language versions. Go,
Node, and pnpm are not preinstalled.

Retained firmware workflows request Python 3.8 through `actions/setup-python@v5`.
The image seeds CPython 3.8.20 at `Python/3.8.20/arm64` with the adjacent
`arm64.complete` marker expected by the Actions tool cache. The runner owns the
cache; selecting this interpreter requires no sudo or runtime download. The
image's normal Python and its rich/textual environment remain the default.
The source is Astral's official python-build-standalone release `20241002`,
asset `cpython-3.8.20+20241002-aarch64-unknown-linux-gnu-install_only.tar.gz`.
The Dockerfile verifies its published SHA-256
`9d8798f9e79e0fc0f36fcb95bfa28a1023407d51a8ea5944b4da711f1f75f1ed`
before extraction and executes the interpreter before marking the cache complete.

The one-CPU, 2 GiB pilot supplies these runner environment defaults. Workflows
can override them with explicit workflow, job, or step environment values:

| Variable | Default |
| --- | --- |
| `GOFLAGS` | `-p=1` |
| `GOMAXPROCS` | `1` |
| `GOMEMLIMIT` | `1400MiB` |
| `CODEQL_THREADS` | `1` |
| `CODEQL_RAM` | `2048` |

These limit default compiler fan-out and provide explicit CodeQL settings for
older workflow heads. `CODEQL_RAM` equals the pod's whole memory limit; it does
not reserve space for runner or native-process overhead. Real CodeQL workloads
still require separate memory qualification. These defaults do not change job
coverage, runner labels, repository settings, or the retirement audit.

The image workflow builds on hosted ARM64 runners for pull requests. It runs
`native-link-smoke.sh` as UID/GID 1001 with one CPU, 2 GiB memory, all capabilities
dropped, and privilege escalation disabled. The smoke writes to the tool cache,
compiles and links a native C fixture, checks its shared libraries, and performs
a dtc round trip. Image publication is restricted to `main` after these pass.
The same workflow also runs `runtime-smoke.sh` under those limits with networking
disabled. It executes Python 3.8, imports native standard-library modules, creates
an isolated venv with pip, and verifies toolcache ownership and runtime defaults.

After a controlled image rollout, dispatch `runner-canary.yml` with
`compatibility_probe=true`. This invokes the real `actions/setup-python@v5`
request for `3.8` and checks the selected path, version, ARM64 execution, venv,
and runtime defaults. The opt-in probe is not dispatched by the image build.

This proves image dependencies, not workload readiness. Before routing additional
production workloads, perform a controlled idle validation rollout of the new
digest, preserving the known-good digest for rollback. Run the real setup actions
and complete upstream Go lint, build, unit, integration, race, benchmark,
frontend, and qualification jobs on ephemeral runners. Verify setup-action
cache permissions and record peak
memory: openmanetd's sqlc compilation, lint, and race tests still need to prove
they fit the pilot's 2 GiB budget. CodeQL, browser E2E, full firmware builds, and
physical hardware operations require separate qualification.
