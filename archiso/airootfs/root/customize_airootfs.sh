#!/usr/bin/env bash
# Runs INSIDE the airootfs chroot during `mkarchiso` (build time, on
# your build machine), NEVER on the target hardware. mkarchiso deletes
# this file from the final ISO by itself, at the end of the build.
#
# Only builds dmg2img here (a small, quick, plain C build — fine to do
# inside the chroot). The custom qemu-system-x86_64 (with Reims-vGPU)
# is NOT built here: it's a full from-source QEMU build via Docker
# that doesn't work inside mkarchiso's chroot (no Docker daemon in
# there), so it's staged ahead of time by ../prepare-qemu-macos.sh,
# straight into airootfs/opt/layerosx/bin/ — this script just checks
# it's actually there.

set -uo pipefail
echo "==> customize_airootfs: building dmg2img"

BUILD_DIR="/tmp/build-layerosx"
mkdir -p "$BUILD_DIR"

if git clone --depth 1 https://github.com/Lekensteyn/dmg2img "$BUILD_DIR/dmg2img"; then
    make -C "$BUILD_DIR/dmg2img"
    install -Dm755 "$BUILD_DIR/dmg2img/dmg2img" /usr/local/bin/dmg2img
    [ -f "$BUILD_DIR/dmg2img/vfdecrypt" ] && install -Dm755 "$BUILD_DIR/dmg2img/vfdecrypt" /usr/local/bin/vfdecrypt
else
    echo "WARNING: failed to clone/build dmg2img — the .dmg install path won't work." >&2
fi
rm -rf "$BUILD_DIR"

if [ -x /opt/layerosx/bin/qemu-system-x86_64 ]; then
    echo "==> found the pre-staged custom qemu-system-x86_64 ($(du -h /opt/layerosx/bin/qemu-system-x86_64 | cut -f1))"
else
    echo "WARNING: /opt/layerosx/bin/qemu-system-x86_64 is missing — run ../prepare-qemu-macos.sh on the build host BEFORE mkarchiso, otherwise this ISO has no accelerated QEMU at all." >&2
fi

# By default a fresh Arch root filesystem ships with root locked
# (no usable password) — tty1 autologin (agetty --autologin) doesn't
# care, but anything that actually checks the password (sulogin in
# emergency mode, a manual login on tty2/Ctrl+Alt+F2) refuses it, with
# no way to get a debug shell if something goes wrong on the live
# session. This is LIVE-ISO-ONLY: install-wizard.sh's rsync carries it
# onto the installed system too, but postinstall/01-base-system.sh
# re-locks root there with its own `passwd -l root`, same as before.
echo "root:layerosx" | chpasswd
echo "==> customize_airootfs: done"
