#!/usr/bin/env bash
# Prints a short hash of what goes into our QEMU/Reims build besides upstream:
# our Reims patches and the build options that change the binary. Written
# next to the binary by prepare-qemu-macos.sh (bin/.qemu-inputs); build.sh
# rebuilds QEMU when it differs, so a new or edited patch can't be silently
# left out of an ISO that reuses an old binary.
cd "$(dirname "$0")" || exit 1
{
    for p in patches/reims/*.patch; do [ -e "$p" ] && { echo "== $p"; cat "$p"; }; done
    echo "boot-color=${LAYEROSX_BOOT_COLOR:-1C1C1C}"
    echo "host-window=${LAYEROSX_REIMS_HOST_WINDOW:-1}"
} | sha256sum | cut -c1-16
