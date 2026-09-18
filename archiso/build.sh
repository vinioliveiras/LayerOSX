#!/usr/bin/env bash
# Builds the final ISO. Needs to run on an Arch-based Linux machine
# (CachyOS works) with the `archiso` package installed, plus Docker
# (or Podman) for the one-time qemu-macos build — this doesn't run
# inside this sandbox, it's meant to run on your own machine.
set -euo pipefail
cd "$(dirname "$0")"
WORKDIR="${1:-./work}"
OUTDIR="${2:-./out}"

command -v mkarchiso >/dev/null 2>&1 || {
    echo "mkarchiso not found — install the 'archiso' package first (sudo pacman -S archiso)." >&2
    exit 1
}

if [ ! -x airootfs/opt/layerosx/bin/qemu-system-x86_64 ]; then
    echo "No pre-built qemu-system-x86_64 yet — building it now (Docker, real QEMU source build, 30-60+ min)."
    ./prepare-qemu-macos.sh
fi

# mkarchiso reuses $WORKDIR across runs and does NOT reliably notice
# when profiledef.sh/pacman.conf/packages.x86_64 changed — it can
# silently skip re-copying them and build with stale config (seen
# firsthand: it kept ignoring a newly added pacman repo). Package
# downloads are cached separately by pacman itself (CacheDir, usually
# /var/cache/pacman/pkg/), so clearing this directory doesn't mean
# re-downloading everything — just a fresh airootfs assembly. Safer to
# always start clean.
sudo rm -rf "$WORKDIR"

sudo mkarchiso -v -w "$WORKDIR" -o "$OUTDIR" .
echo "ISO ready in $OUTDIR/ — drag it onto your Ventoy drive."
