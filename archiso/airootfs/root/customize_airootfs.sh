#!/usr/bin/env bash
# Runs INSIDE the airootfs chroot during `mkarchiso` (build time, on
# your build machine), NEVER on the target hardware. mkarchiso deletes
# this file from the final ISO by itself, at the end of the build.
#
# This is where we build what doesn't exist as an official Arch
# package: the QEMU from the qemus/qemu-macos project (already with
# Reims-vGPU integrated) and dmg2img (used by the "install from a
# .dmg" wizard option). This way postinstall just copies already-built
# binaries, no network or compiling needed on the final machine.
#
# WARNING — this has not been validated yet: the exact build steps for
# qemus/qemu-macos need to be confirmed against the project's README
# when you actually build the ISO (the build machine has network; this
# script runs there, not here). See docs/CHECKLIST.md.

set -uo pipefail
echo "==> customize_airootfs: building qemus/qemu-macos and dmg2img"

BUILD_DIR="/tmp/build-layerosx"
mkdir -p "$BUILD_DIR"

# --- dmg2img (extracting .dmg installers) -----------------------------------
if git clone --depth 1 https://github.com/Lekensteyn/dmg2img "$BUILD_DIR/dmg2img"; then
    make -C "$BUILD_DIR/dmg2img"
    install -Dm755 "$BUILD_DIR/dmg2img/dmg2img" /usr/local/bin/dmg2img
    [ -f "$BUILD_DIR/dmg2img/vfdecrypt" ] && install -Dm755 "$BUILD_DIR/dmg2img/vfdecrypt" /usr/local/bin/vfdecrypt
else
    echo "WARNING: failed to clone/build dmg2img — the .dmg install path won't work." >&2
fi

# --- qemus/qemu-macos (QEMU + Reims-vGPU) -----------------------------------
if git clone --depth 1 https://github.com/qemus/qemu-macos "$BUILD_DIR/qemu-macos"; then
    cd "$BUILD_DIR/qemu-macos"
    # TODO(verify): confirm the exact build command in the project's
    # README before the final build — this tries the most common
    # paths, with no guarantee they match the repo's current version.
    if [ -f build.sh ]; then
        bash build.sh || echo "WARNING: qemu-macos's build.sh failed — see docs/CHECKLIST.md" >&2
    elif [ -f meson.build ]; then
        meson setup build --prefix=/usr/local && ninja -C build && ninja -C build install
    else
        echo "WARNING: didn't recognize qemu-macos's build method (no build.sh or meson.build) — install manually before the final build." >&2
    fi
else
    echo "WARNING: failed to clone qemus/qemu-macos — without this there's no acceleration at all, the VM won't work as expected." >&2
fi

rm -rf "$BUILD_DIR"
echo "==> customize_airootfs: done"
