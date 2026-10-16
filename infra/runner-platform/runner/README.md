# ARM64 runner image

This image supplies build-time packages for openmanetd CGO, OpenVLM dependency
checks, and firmware hardware-qualification tooling. It includes libnl, GPS,
capabilities, Opus, PortAudio/ALSA, HID/USB/udev, PAM, mesh/network CLIs, and dtc.
Packages are installed while building the image; jobs need no runtime sudo.

`/opt/hostedtoolcache` is owned by runner UID 1001. `RUNNER_TOOL_CACHE` and
`AGENT_TOOLSDIRECTORY` point there for setup-go, setup-node, and setup-python.
Those actions still select each repository's requested language versions. Go,
Node, pnpm, and Python 3.8 are not preinstalled by this dependency change.

The image workflow builds on hosted ARM64 runners for pull requests. It runs
`native-link-smoke.sh` as UID/GID 1001 with one CPU, 2 GiB memory, all capabilities
dropped, and privilege escalation disabled. The smoke writes to the tool cache,
compiles and links a native C fixture, checks its shared libraries, and performs
a dtc round trip. Image publication is restricted to `main` after these pass.

This proves image dependencies, not workload readiness. Before routing additional
production workloads, perform a controlled idle validation rollout of the new
digest, preserving the known-good digest for rollback. Run the real setup actions
and complete upstream Go lint, build, unit, integration, race, benchmark,
frontend, and qualification jobs on ephemeral runners. Verify setup-action
cache permissions and record peak
memory: openmanetd's sqlc compilation, lint, and race tests still need to prove
they fit the pilot's 2 GiB budget. CodeQL, browser E2E, full firmware builds, and
physical hardware operations require separate qualification.
