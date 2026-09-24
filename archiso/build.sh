#!/usr/bin/env bash
# Builds the final ISO. Needs to run on an Arch-based Linux machine
# (CachyOS works) with the `archiso` package installed, plus Docker
# (or Podman) for the one-time qemu-macos build — this doesn't run
# inside this sandbox, it's meant to run on your own machine.
set -euo pipefail
cd "$(dirname "$0")"
WORKDIR="${1:-./work}"
OUTDIR="${2:-./out}"

# ---------------------------------------------------------------------------
# One build for everyone (there used to be release/debug builds). The ISO is
# configured like the old release build -- Reims, sound on, Apple-logo boot,
# console switching locked, terminal behind a password -- and everything the
# debug build did is a runtime toggle in LayerOSX Settings:
#   Maintenance > Show startup log   text boot (OpenCore*-verbose images)
#   Maintenance > Detailed logs      serial kernel log + OpenCore log + QEMU
#                              guest_errors/unimp (OpenCore*-diag images)
#   Maintenance > Text consoles      Ctrl+Alt+F1..F6 / Ctrl+Alt+Backspace (next boot)
# LAYEROSX_MODE is still accepted (old scripts) but no longer changes the ISO.
if [ -n "${LAYEROSX_MODE:-}" ] && [ "${LAYEROSX_MODE}" != release ]; then
    echo "build.sh: LAYEROSX_MODE=$LAYEROSX_MODE is no longer a build option -- one ISO for all;" >&2
    echo "          the debug features are toggles in LayerOSX Settings (Maintenance > Detailed logs, Text consoles)." >&2
fi
MODE=release
export LAYEROSX_MODE="$MODE"
echo "==================================================================="
echo "  LayerOSX build (single ISO; debug features are toggles in Settings)"
echo "==================================================================="
# Bake the chosen mode into the image so the RUNTIME launcher can pick
# mode-appropriate defaults (release: verbose off / audio on / Reims on;
# debug: verbose on / VMware / audio off -- see mac-vm-launch.sh). A plain
# marker file the launcher reads; the live-ISO rootfs (and the installed
# system rsynced from it) both carry it. Regenerated every build, gitignored.
mkdir -p airootfs/etc/layerosx
printf '%s\n' "$MODE" > airootfs/etc/layerosx/mode
# Version shown in LayerOSX Settings > About: git commit (+ "-dirty" when built
# from uncommitted changes) and build date. Regenerated every build, gitignored.
_ver="$(git -C .. describe --always --dirty 2>/dev/null || echo unknown)"
printf 'version=%s\nbuilt=%s\nmode=%s\n' "$_ver" "$(date +%Y-%m-%d)" "$MODE" > airootfs/etc/layerosx/version

# Maintenance terminal (Ctrl+Alt+T / Settings > Maintenance):
#   open (default) -> available; asks for a password only if the user set a
#                     Maintenance password in Settings (none by default)
#   off            -> no terminal at all (fully locked appliance)
# "password" (the old default: the kiosk user's password) is accepted and means
# "open" now -- the password is the user's own choice in Settings.
# Baked into airootfs/etc/layerosx/terminal (gitignored), read by
# lib/maint-terminal.sh, lib/tty2-getty.sh and the panel.
TERMINAL="${LAYEROSX_TERMINAL:-open}"
case "$TERMINAL" in
    open|off) : ;;
    password) echo "build.sh: LAYEROSX_TERMINAL=password is now 'open' + an optional Maintenance password set in Settings." >&2; TERMINAL=open ;;
    *) echo "build.sh: unknown LAYEROSX_TERMINAL='$TERMINAL' -- using open." >&2; TERMINAL=open ;;
esac
printf '%s\n' "$TERMINAL" > airootfs/etc/layerosx/terminal
echo "  Maintenance terminal (Ctrl+Alt+T): $TERMINAL"

# Kiosk VT-switch lock: no longer baked here. It's the "Text consoles" toggle
# (LayerOSX Settings > Maintenance), applied at every boot by
# layerosx-vtlock.service (kiosk/lib/vt-lock.sh), which writes or removes
# /etc/X11/xorg.conf.d/10-layerosx-kiosk-lock.conf before X starts. Drop any
# copy an older build left in airootfs so the ISO doesn't carry it.
rm -f airootfs/etc/X11/xorg.conf.d/10-layerosx-kiosk-lock.conf

command -v mkarchiso >/dev/null 2>&1 || {
    echo "mkarchiso not found — install the 'archiso' package first (sudo pacman -S archiso)." >&2
    exit 1
}

# Build-host tools used to derive the OpenCore boot variants below (verbose
# boot and the AMD_Vanilla-patched image): qemu-img for the qcow2<->raw
# round-trip, mtools to edit the FAT EFI partition without root. Auto-install
# the missing ones so the build doesn't silently ship without a variant just
# because a tool wasn't there -- easy to forget. Best-effort: if the install
# can't run (no network, no sudo, a non-pacman distro), we don't abort the
# build; each patch step degrades to a clear warning on its own.
_missing=()
command -v qemu-img >/dev/null 2>&1 || _missing+=("qemu-img")
command -v mcopy    >/dev/null 2>&1 || _missing+=("mtools")
if [ "${#_missing[@]}" -gt 0 ]; then
    if command -v pacman >/dev/null 2>&1; then
        echo "==> installing missing build tools for verbose-boot patching: ${_missing[*]}"
        sudo pacman -S --needed --noconfirm "${_missing[@]}" ||             echo "WARNING: couldn't auto-install ${_missing[*]} -- the ISO may ship without the verbose and/or AMD OpenCore images. Install them by hand and re-run to build those variants." >&2
    else
        echo "WARNING: ${_missing[*]} missing and this isn't a pacman system -- install them by hand to build the verbose and AMD OpenCore images." >&2
    fi
fi

# Checking just the binary isn't enough: confirmed on real hardware
# that an ISO built from an already-existing qemu-system-x86_64 (from
# before the libjpeg.so.62 bundling fix, see DEVLOG.md) kept shipping
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
# Our Reims patches / QEMU build options changed since that binary was built
# (or it predates the stamp): rebuild, or the ISO would ship without them.
_want="$(./qemu-inputs-hash.sh)"
_have="$(cat airootfs/opt/layerosx/bin/.qemu-inputs 2>/dev/null)"
if [ "$_want" != "$_have" ]; then
    echo "==> QEMU/Reims inputs changed (patches/reims or build options: ${_have:-no stamp} -> $_want) — rebuilding qemu-system-x86_64 (30-60+ min)."
    ./prepare-qemu-macos.sh
fi

# Same idea as the qemu-system-x86_64 check above: without OpenCore.qcow2
# staged, mac-vm-launch.sh has nothing to attach as the boot disk and
# macOS's kernel will never come up on plain OVMF alone (see
# prepare-opencore.sh and DEVLOG.md for why). This one's just a download
# (no Docker build), so it's quick.
if [ ! -s airootfs/opt/layerosx/opencore/OpenCore.qcow2 ]; then
    echo "No OpenCore boot image yet — staging it now."
    ./prepare-opencore.sh
fi

# Derive every OpenCore boot variant from the pristine, checksum-verified
# OpenCore.qcow2 that prepare-opencore.sh stages -- as SEPARATE images, so the
# verified base is never mutated. mac-vm-launch.sh then picks one at launch by
# host CPU vendor (Intel vs AMD) and the `verbose` toggle:
#   OpenCore.qcow2             Intel, clean Apple-logo boot   (the base)
#   OpenCore-verbose.qcow2     Intel, verbose (-v) boot log
#   OpenCore-amd.qcow2         AMD  (AMD_Vanilla kernel patches), clean boot
#   OpenCore-amd-verbose.qcow2 AMD  (AMD_Vanilla kernel patches), verbose
# Why AMD needs its own image: XNU is Intel-only and panics/hangs at
# EXITBS->HANDOFF on an AMD CPU without the AMD_Vanilla patches, but those same
# patches would corrupt a correct kernel on Intel -- so they must live in a
# separate image the launcher hands only to AMD hosts. All steps are idempotent
# and always re-run (a reused base from an earlier build is exactly why baking
# these only in prepare-opencore.sh's download path could silently ship
# stale/missing variants). Each degrades to a clear warning if qemu-img/mtools
# are missing rather than aborting the build.
OCDIR=airootfs/opt/layerosx/opencore
# First, fix a latent bug in the base image itself (in place): its config.plist
# enables several kexts that aren't actually bundled (VoodooPS2Controller etc.),
# which makes OpenCore HALT on "missing injected kext" before macOS ever loads.
# This must run before the derivations so every image -- including the clean
# Intel base that boots directly -- inherits the fix. Idempotent.
./patch-opencore-fixup.sh   "$OCDIR/OpenCore.qcow2"
# Default Mac model (SMBIOS), baked into the base so every derived image
# inherits it: the newest Intel MacBook Pro, MacBookPro16,2 (13-inch, 2020).
# LAYEROSX_MAC_MODEL overrides; Settings > Mac > Model changes it per install
# at runtime (kiosk/lib/oc-model.sh + mac-vm-launch.sh). /etc/layerosx/mac-model
# records what the images carry.
MAC_MODEL="${LAYEROSX_MAC_MODEL:-MacBookPro16,2}"
if airootfs/opt/layerosx/kiosk/lib/oc-model.sh "$OCDIR/OpenCore.qcow2" "$OCDIR/OpenCore.qcow2" "$MAC_MODEL"; then
    printf '%s\n' "$MAC_MODEL" > airootfs/etc/layerosx/mac-model
else
    echo "build.sh: couldn't set the Mac model -- the images keep their own." >&2
    rm -f airootfs/etc/layerosx/mac-model
fi
./patch-opencore-verbose.sh "$OCDIR/OpenCore.qcow2"     "$OCDIR/OpenCore-verbose.qcow2"
./patch-opencore-verbose.sh "$OCDIR/OpenCore.qcow2" "$OCDIR/OpenCore-diag.qcow2" debug
./patch-opencore-amd.sh     "$OCDIR/OpenCore.qcow2"     "$OCDIR/OpenCore-amd.qcow2"
./patch-opencore-verbose.sh "$OCDIR/OpenCore-amd.qcow2" "$OCDIR/OpenCore-amd-verbose.qcow2"
./patch-opencore-verbose.sh "$OCDIR/OpenCore-amd.qcow2" "$OCDIR/OpenCore-amd-diag.qcow2" debug
# Same AMD image with cpuid_cores_per_package baked to 8 (the AMD_Vanilla
# core-count patch must equal the guest's -smp cores). mac-vm-launch.sh uses it
# on hosts with >= 10 threads, so the Mac gets 8 cores instead of 4 (8 is also
# Reims' own SMP cap).
./patch-opencore-amd.sh     "$OCDIR/OpenCore.qcow2"     "$OCDIR/OpenCore-amd8.qcow2" amd-vanilla-patches.plist 8
./patch-opencore-verbose.sh "$OCDIR/OpenCore-amd8.qcow2" "$OCDIR/OpenCore-amd8-verbose.qcow2"
./patch-opencore-verbose.sh "$OCDIR/OpenCore-amd8.qcow2" "$OCDIR/OpenCore-amd8-diag.qcow2" debug
# ...and baked to 2, so dual-core AMD hosts get exactly their 2 cores.
./patch-opencore-amd.sh     "$OCDIR/OpenCore.qcow2"     "$OCDIR/OpenCore-amd2.qcow2" amd-vanilla-patches.plist 2
./patch-opencore-verbose.sh "$OCDIR/OpenCore-amd2.qcow2" "$OCDIR/OpenCore-amd2-verbose.qcow2"
./patch-opencore-verbose.sh "$OCDIR/OpenCore-amd2.qcow2" "$OCDIR/OpenCore-amd2-diag.qcow2" debug

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
