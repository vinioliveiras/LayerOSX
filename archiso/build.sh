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

# Checking just the binary isn't enough: confirmed on real hardware
# that an ISO built from an already-existing qemu-system-x86_64 (from
# before the libjpeg.so.62 bundling fix, see README.md) kept shipping
# the old broken binary forever, since this check never noticed
# anything was missing and never re-ran prepare-qemu-macos.sh. The
# bundled runtime libraries are just as required as the binary itself
# now, so check for both.
if [ ! -x airootfs/opt/layerosx/bin/qemu-system-x86_64 ] || \
   [ ! -d airootfs/opt/layerosx/lib ] || \
   [ -z "$(ls -A airootfs/opt/layerosx/lib 2>/dev/null)" ]; then
    echo "No pre-built qemu-system-x86_64 (or its bundled runtime libraries) yet — building it now (Docker, real QEMU source build, 30-60+ min)."
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

# Old ISOs otherwise just pile up in here forever: profiledef.sh names
# each one after today's date (iso_version), so nothing ever gets
# overwritten and it's easy to run a stale ISO by mistake without
# noticing (confirmed in practice: three different days' ISOs sitting
# side by side, only the newest actually had the latest fixes). Clean
# it the same way $WORKDIR already is, so $OUTDIR only ever has the
# ISO from the build that just ran.
sudo rm -rf "$OUTDIR"

# Belt-and-suspenders on top of profiledef.sh's file_permissions
# (which is what actually matters for the final ISO): if this repo is
# checked out on a Windows-mounted drive (common under WSL), the
# executable bit git tracked doesn't reliably survive onto disk —
# found the hard way when install-wizard.sh landed on a built ISO as
# 644 despite being 755 in the git index. Re-assert it on every build
# so a newly added script that forgets a profiledef.sh entry still
# works, instead of silently shipping non-executable.
find airootfs -name '*.sh' -exec chmod +x {} \;

sudo mkarchiso -v -w "$WORKDIR" -o "$OUTDIR" .
echo "ISO ready in $OUTDIR/ — drag it onto your Ventoy drive."
