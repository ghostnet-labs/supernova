#!/usr/bin/env bash
# Run as UID 1001 inside the candidate image; no hardware or elevated capabilities.
set -euo pipefail
test "$(id -u)" -eq 1001
test "$(uname -m)" = aarch64
test -w "${RUNNER_TOOL_CACHE:?}"
test -w "${AGENT_TOOLSDIRECTORY:?}"
work=$(mktemp -d)
cache_probe=$(mktemp -d "$RUNNER_TOOL_CACHE/native-link-smoke.XXXXXX")
trap 'rm -rf "$work" "$cache_probe"' EXIT
printf 'runner cache write probe\n' >"$cache_probe/probe"
test -s "$cache_probe/probe"
for dependency in libnl-3.0 libnl-genl-3.0 libgps libcap opus opusfile \
    portaudio-2.0 alsa hidapi-hidraw hidapi-libusb libusb-1.0 libudev; do
    pkg-config --exists "$dependency"
done
printf '%s\n' \
    '#include <alsa/asoundlib.h>' \
    '#include <gps.h>' \
    '#include <hidapi/hidapi.h>' \
    '#include <libudev.h>' \
    '#include <libusb.h>' \
    '#include <netlink/netlink.h>' \
    '#include <netlink/genl/genl.h>' \
    '#include <netlink/genl/ctrl.h>' \
    '#include <opus/opus.h>' \
    '#include <opus/opusfile.h>' \
    '#include <portaudio.h>' \
    '#include <security/pam_appl.h>' \
    '#include <sys/capability.h>' \
    'int main(void) {' \
    '    /* Referencing symbols forces the linker to resolve each native library. */' \
    '    (void)snd_asoundlib_version();' \
    '    (void)gps_errstr(0);' \
    '    (void)hid_error(NULL);' \
    '    struct udev *u = udev_new(); udev_unref(u);' \
    '    (void)libusb_get_version();' \
    '    struct nl_sock *s = nl_socket_alloc(); nl_socket_free(s);' \
    '    (void)genl_ctrl_resolve(NULL, "unused");' \
    '    (void)opus_get_version_string();' \
    '    op_free(NULL);' \
    '    (void)Pa_GetVersion();' \
    '    (void)pam_strerror(NULL, PAM_SUCCESS);' \
    '    cap_t c = cap_init(); cap_free(c);' \
    '    return 0;' \
    '}' >"$work/native.c"
# Compile/link only: do not execute calls that expect initialized device handles.
cc -Wall -Wextra -Werror "$work/native.c" -o "$work/native" \
    $(pkg-config --cflags --libs libnl-3.0 libnl-genl-3.0 libgps libcap opus \
      opusfile portaudio-2.0 alsa hidapi-hidraw libusb-1.0 libudev) -lpam
ldd "$work/native" | tee "$work/linked.txt"
! grep -q 'not found' "$work/linked.txt"
printf '/dts-v1/; / { compatible = "ghostnet,qualification"; };\n' >"$work/smoke.dts"
dtc -I dts -O dtb -o "$work/smoke.dtb" "$work/smoke.dts"
dtc -I dtb -O dts -o "$work/roundtrip.dts" "$work/smoke.dtb"
echo 'Native compile/link and device-tree round trip passed.'
