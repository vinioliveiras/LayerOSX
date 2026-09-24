#!/usr/bin/env bash
# Builds the custom qemu-system-x86_64 (with Reims-vGPU baked in) from
# the qemus/qemu-macos project and stages it into the archiso profile,
# so mkarchiso just picks it up like any other airootfs file.
#
# Runs on the BUILD HOST (not inside the ISO, not inside the archiso
# chroot) — the upstream project ships this as a multi-stage
# Dockerfile (a real QEMU 11.1.1 build from source, plus Rust and
# Vulkan dev headers — roughly a 30-60+ minute build depending on your
# machine), so this needs Docker (or Podman) installed on whatever
# machine builds the ISO. Re-run this whenever you want a newer
# qemu-macos.
#
# Source of truth for all of this: https://github.com/qemus/qemu-macos
# (there is no source-buildable checkout in that repo, no build.sh, no
# meson.build — it is Dockerfile + patches only, confirmed by reading
# it directly).
set -euo pipefail
cd "$(dirname "$0")"

ENGINE="${CONTAINER_ENGINE:-docker}"
command -v "$ENGINE" >/dev/null 2>&1 || {
    echo "$ENGINE not found. Install Docker (or set CONTAINER_ENGINE=podman) first." >&2
    exit 1
}

# The upstream Dockerfile needs BuildKit (it uses "RUN <<EOF" heredocs and
# "ADD --keep-git-dir=true", syntax the classic/legacy docker builder does
# not understand). On a fresh `pacman -S docker` (no buildx package),
# `docker build` silently falls back to the legacy builder — it does NOT
# error out on the heredoc RUN steps, it just treats them as a no-op, so
# the whole multi-stage build "succeeds" while never actually compiling
# anything, and the very next stage fails with a confusing
# "COPY failed: stat out/qemu-system-x86_64: file does not exist" that
# looks unrelated to the real cause. Forcing BuildKit here fixes this
# whether or not the buildx plugin is installed (dockerd has had built-in
# BuildKit support since Docker 18.09, driven by this env var).
if [ "$ENGINE" = "docker" ]; then
    export DOCKER_BUILDKIT=1
fi

# ---------------------------------------------------------------------------
# Dependency pins -- bump to update, set to a branch name to track upstream.
# ---------------------------------------------------------------------------
# qemu-vmvga (the VMware-vGPU code the upstream Dockerfile applies onto Reims'
# QEMU 11.1 base) is pulled from its `master` branch by default. We pin it to a
# specific commit, because upstream master moves fast and can ship a commit that
# doesn't build against this QEMU base -- and did:
#   commit 2c3cae7 (#508, 2026-09-21, "D3D9 switch lifetime and SO binding
#   order") started calling vmsvga3d_screen_target_async_poll_present_live() and
#   vmsvga3d_screen_target_async_discard_live() from inside vmware_vga_vgpu10.c,
#   which is #included partway through vmware_vga_3d.c BEFORE those two static
#   functions are defined -- so the compile dies under -Werror with "implicit
#   declaration of function" + "static declaration follows non-static
#   declaration". Purely an upstream ordering regression, nothing on our side.
# c51c680 is the commit immediately before it (#507, 2026-09-20, "Implement DX2
# whole-surface copy") -- the newest qemu-vmvga that still builds, carrying every
# fix up to that point. To update: set this to a newer commit once upstream fixes
# the ordering, or to "master" to track the branch again and take whatever's
# latest. Override for one run without editing this file: QEMU_VMVGA_REF=... ./prepare-qemu-macos.sh
QEMU_VMVGA_REF="${QEMU_VMVGA_REF:-c51c680b5d55f2ed66fc560bc9fd5e3ad962626c}"

WORK=$(mktemp -d)
CID=""
VCID=""
cleanup() {
    [ -n "$CID" ] && "$ENGINE" rm -f "$CID" >/dev/null 2>&1
    [ -n "$VCID" ] && "$ENGINE" rm -f "$VCID" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

# Always start clean: wipe any binary/ROM/libraries left behind by a
# previous run before doing anything else. Confirmed useful in
# practice -- without this, a run that fails partway through can
# leave old/partial output sitting in airootfs/opt/layerosx/ that's
# easy to mistake for a good build (this is also what build.sh's own
# "does the binary + a non-empty lib/ already exist" check is
# guarding against on its side -- this is the other half, so this
# script never depends on you remembering to delete anything by hand
# before re-running it, however it's invoked).
echo "==> clearing any previous qemu-macos build output"
rm -f airootfs/opt/layerosx/bin/qemu-system-x86_64 airootfs/usr/share/qemu/reims-vgpu-gop.rom
rm -rf airootfs/opt/layerosx/lib
mkdir -p airootfs/opt/layerosx/lib

echo "==> cloning qemus/qemu-macos"
git clone --depth 1 https://github.com/qemus/qemu-macos "$WORK/qemu-macos"

# Upstream bug workaround: the Dockerfile's EOF_SOURCE step checks QEMU out
# into /src/reims/vendor/qemu-11.1, but the very next step (EOF_PATCHES,
# which applies patches/) still references the old /src/qemu path from
# before that layout was refactored, so it fails with "cannot change to
# '/src/qemu': No such file or directory". Confirmed by reading the
# upstream Dockerfile directly and reproducing with a real (BuildKit) build.
# Remove this once upstream fixes it (nothing to detect it automatically
# going stale, so worth re-checking occasionally).
sed -i \
    -e 's#git -C /src/qemu apply#git -C /src/reims/vendor/qemu-11.1 apply#g' \
    -e 's#git -C /src/qemu diff#git -C /src/reims/vendor/qemu-11.1 diff#g' \
    "$WORK/qemu-macos/Dockerfile"

# LayerOSX-specific: pin qemu-vmvga to $QEMU_VMVGA_REF instead of the upstream
# default of #master (see the QEMU_VMVGA_REF comment above for why). The upstream
# Dockerfile fetches it with `ADD ...qemu-vmvga.git#master /src/qemu-vmvga`;
# rewrite just that ref. GitHub serves any commit reachable from the default
# branch to `ADD`, so a plain commit SHA works here. Setting QEMU_VMVGA_REF back
# to "master" makes this a harmless no-op that tracks the branch again.
python3 - "$WORK/qemu-macos/Dockerfile" "$QEMU_VMVGA_REF" <<'PYEOF_VMVGA'
import pathlib, sys
path = pathlib.Path(sys.argv[1]); ref = sys.argv[2]
text = path.read_text()
anchor = "qemu-vmvga.git#master"
if anchor not in text:
    print("FAIL: qemu-vmvga.git#master anchor not found -- upstream Dockerfile may have changed how it fetches qemu-vmvga.", file=sys.stderr)
    sys.exit(1)
text = text.replace(anchor, "qemu-vmvga.git#" + ref, 1)
path.write_text(text)
print("==> patched Dockerfile: pinned qemu-vmvga to %s (was #master)" % ref)
PYEOF_VMVGA

# LayerOSX-specific: upstream builds this binary with --disable-sdl AND
# --disable-gtk (confirmed by reading the Dockerfile's configure
# invocation directly) -- it ships VNC + curses only, no local-window
# display at all. Confirmed on real hardware: mac-vm-launch.sh's
# `-display sdl,gl=on,full-screen=on` failed outright with "Parameter
# 'type' does not accept value 'sdl'" once QEMU actually got far enough
# to parse its own arguments (past the libjpeg/glib bugs above). Since
# LayerOSX wants a direct full-screen local window (not VNC), patch
# --disable-sdl to --enable-sdl here and make sure libsdl2-dev is
# installed in the builder image regardless of whether QEMU's own
# upstream base build image already carries it -- --enable-opengl is
# already on upstream's own configure line, so SDL's GL integration
# ("-display sdl,gl=on") needs nothing else on top of this. GTK stays
# disabled; nothing here uses it.
python3 - "$WORK/qemu-macos/Dockerfile" <<'PYEOF_SDL'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

old_deps = "    libbz2-dev \\\n    libvulkan-dev \\\n"
new_deps = "    libbz2-dev \\\n    libsdl2-dev \\\n    libvulkan-dev \\\n"
if old_deps not in text:
    print("FAIL: apt-get dependency list anchor not found -- upstream Dockerfile's builder deps may have changed.", file=sys.stderr)
    sys.exit(1)
text = text.replace(old_deps, new_deps, 1)

old_flag = "    --disable-sdl \\\n"
new_flag = "    --enable-sdl \\\n"
if old_flag not in text:
    print("FAIL: --disable-sdl anchor not found -- upstream Dockerfile's configure flags may have changed.", file=sys.stderr)
    sys.exit(1)
text = text.replace(old_flag, new_flag, 1)

path.write_text(text)
print("==> patched Dockerfile: --enable-sdl (was --disable-sdl), libsdl2-dev added to builder deps")
PYEOF_SDL

# LayerOSX-specific, part 2 of the SDL patch: enabling SDL in the builder
# means qemu-system-x86_64 now links against libSDL2-2.0.so.0 and
# libSDL2_image-2.0.so.0 too -- confirmed on real hardware, the
# Dockerfile's own "verify" stage (FROM qemux/qemu:latest, a plain Debian
# image that never needed SDL before this patch) failed its ldd check
# with both of those reported as "not found", aborting the whole build
# with "FAIL: one or more QEMU runtime dependencies could not be
# resolved." before ever reaching the library-bundling step below (which
# only runs once this stage has already succeeded). Install the SDL2
# runtime packages in that stage too so the ldd check actually resolves
# them -- this also means the library-bundling step further down (which
# extracts everything reported by the verify stage's own ldd) correctly
# picks up libSDL2/libSDL2_image and ships them in airootfs/opt/layerosx/lib
# alongside libjpeg, exactly like every other bundled library.
python3 - "$WORK/qemu-macos/Dockerfile" <<'PYEOF_SDL_VERIFY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

old_verify_copy = "COPY --from=builder /out/reims-vgpu-gop.rom /tmp/reims-vgpu-gop.rom\n\nRUN <<'EOF_VERIFY'\n"
new_verify_copy = (
    "COPY --from=builder /out/reims-vgpu-gop.rom /tmp/reims-vgpu-gop.rom\n\n"
    "RUN apt-get update && apt-get install -y --no-install-recommends "
    "libsdl2-2.0-0 libsdl2-image-2.0-0 && rm -rf /var/lib/apt/lists/*\n\n"
    "RUN <<'EOF_VERIFY'\n"
)
if old_verify_copy not in text:
    print("FAIL: verify-stage COPY/RUN anchor not found -- upstream Dockerfile's verify stage may have changed.", file=sys.stderr)
    sys.exit(1)
text = text.replace(old_verify_copy, new_verify_copy, 1)

path.write_text(text)
print("==> patched Dockerfile: installs libsdl2-2.0-0 + libsdl2-image-2.0-0 in the verify stage")
PYEOF_SDL_VERIFY

# LayerOSX-specific: our own patches on the Reims source (archiso/patches/reims/
# *.patch, `git diff` format against the pinned REIMS_REF). They're copied into
# the Docker build context and applied right after Reims is checked out and its
# commit verified; `git apply` fails the build if one no longer fits.
#   0001: the host window releases keys still held when it loses focus (Alt+Tab
#         left Alt/Ctrl pressed in macOS -- every key became a shortcut).
mkdir -p "$WORK/qemu-macos/layerosx-reims-patches"
cp patches/reims/*.patch "$WORK/qemu-macos/layerosx-reims-patches/" 2>/dev/null || true
python3 - "$WORK/qemu-macos/Dockerfile" <<'PYEOF_REIMSPATCH'
import pathlib, sys
path = pathlib.Path(sys.argv[1]); text = path.read_text()
run = "RUN <<EOF_SOURCE\n"
check = (
    '  if [ "$actual" != "${REIMS_REF}" ]; then\n'
    '    echo "FAIL: Reims resolved to $actual instead of ${REIMS_REF}."\n'
    '    exit 1\n'
    '  fi\n'
)
apply = (
    "\n  # LayerOSX patches (archiso/patches/reims, via prepare-qemu-macos.sh)\n"
    "  for p in /layerosx-reims-patches/*.patch; do\n"
    '    [ -e "$p" ] || continue\n'
    '    echo "LayerOSX: applying $p to Reims"\n'
    '    git -C reims apply "$p"\n'
    "  done\n"
)
if text.count(run) != 1 or text.count(check) != 1:
    print("FAIL: EOF_SOURCE / REIMS_REF check anchors not found -- upstream Dockerfile changed how it fetches Reims.", file=sys.stderr)
    sys.exit(1)
text = text.replace(run, "COPY layerosx-reims-patches /layerosx-reims-patches\n" + run, 1)
text = text.replace(check, check + apply, 1)
path.write_text(text)
print("==> patched Dockerfile: LayerOSX patches applied to Reims (archiso/patches/reims)")
PYEOF_REIMSPATCH

# LayerOSX-specific: keep Reims' host window. Upstream strips the reims-vgpu
# `host-window` Cargo feature ("qemux uses QEMU's own display path (VNC/noVNC),
# so Reims' optional host-owned winit/X11/Wayland window is unnecessary"), but
# LayerOSX shows the Mac on the local screen through exactly that window
# (REIMS_VGPU_WINDOW=1 + -display none in mac-vm-launch.sh, upstream Reims'
# own vm/boot-x86.sh default). Without the feature Reims logs "host window
# unavailable (rc=2); using QEMU display" and, with -display none, the Mac runs
# with no screen at all -- confirmed on hardware. So neutralise that one step:
# its replacement string becomes the original line (sed then changes nothing),
# keeping upstream's anchor checks intact. The enqueue_present feature guard
# upstream adds right after is correct either way. winit loads X11/Wayland
# with dlopen at runtime (libX11, libXcursor, libXrandr, libXi,
# libxkbcommon-x11 -- listed in packages.x86_64), so the build needs no extra
# system headers and the ldd/verify stage is unaffected.
# LAYEROSX_REIMS_HOST_WINDOW=0 keeps upstream's window-less build.
if [ "${LAYEROSX_REIMS_HOST_WINDOW:-1}" != 0 ]; then
python3 - "$WORK/qemu-macos/Dockerfile" <<'PYEOF_HOSTWIN'
import pathlib, sys
path = pathlib.Path(sys.argv[1]); text = path.read_text()
old = """  new="reims_vgpu_cargo_features = '--no-default-features --features backend-vulkan'"\n"""
new = """  new="$old"   # LayerOSX: keep the host-window feature (see prepare-qemu-macos.sh)\n"""
if text.count(old) != 1:
    print("FAIL: upstream Dockerfile no longer strips Reims' host-window feature the way prepare-qemu-macos.sh expects -- check the EOF_SOURCE step.", file=sys.stderr)
    sys.exit(1)
path.write_text(text.replace(old, new, 1))
print("==> patched Dockerfile: Reims built WITH its host window (host-window Cargo feature kept)")
PYEOF_HOSTWIN
fi

# LayerOSX-specific: the colour of the very first screen. Reims' EFI GOP option
# ROM (crates/reims-vgpu-efi, built into reims-vgpu-gop.rom by the same
# Dockerfile) fills the whole framebuffer with a solid colour the moment the VM
# powers on, before OpenCore paints anything. Upstream uses a dark slate blue
# (#182840, SLATE_BGRA in src/paint.rs) -- deliberately non-black so their QMP
# tests can prove the framebuffer is live. LayerOSX paints its own colour
# instead: LAYEROSX_BOOT_COLOR=RRGGBB (default 1C1C1C, a near-black grey --
# the same tone as the install wizard's panels, so the switch to OpenCore's /
# Apple's black boot screen barely shows). Alpha stays 0xff, so the value is never zero
# and upstream's own "non-black" unit test still holds even for 000000.
# Only visible with the Reims adapter (VMware / standard VGA don't use this ROM).
BOOT_COLOR="${LAYEROSX_BOOT_COLOR:-1C1C1C}"
BOOT_COLOR="${BOOT_COLOR#\#}"
if ! [[ "$BOOT_COLOR" =~ ^[0-9A-Fa-f]{6}$ ]]; then
    echo "prepare-qemu-macos.sh: LAYEROSX_BOOT_COLOR='$BOOT_COLOR' is not RRGGBB -- using 1C1C1C." >&2
    BOOT_COLOR=1C1C1C
fi
python3 - "$WORK/qemu-macos/Dockerfile" "$BOOT_COLOR" <<'PYEOF_BOOTCOLOR'
import pathlib, sys
path = pathlib.Path(sys.argv[1]); rgb = sys.argv[2].lower()
r, g, b = rgb[0:2], rgb[2:4], rgb[4:6]
text = path.read_text()
anchor = "  /src/reims/crates/reims-vgpu-efi/scripts/reims-vgpu-efi-rom/reims-vgpu-efi-rom.sh\n"
if anchor not in text:
    print("FAIL: reims-vgpu-efi-rom.sh anchor not found -- upstream Dockerfile may have changed how it builds the GOP ROM.", file=sys.stderr)
    sys.exit(1)
paint = "/src/reims/crates/reims-vgpu-efi/src/paint.rs"
old = "u32::from_le_bytes([0x40, 0x28, 0x18, 0xff])"
new = "u32::from_le_bytes([0x%s, 0x%s, 0x%s, 0xff])" % (b, g, r)   # BGRA byte order
patch = (
    "  # LayerOSX: boot colour #%s instead of Reims' slate blue\n"
    "  grep -qF '%s' %s || { echo 'FAIL: SLATE_BGRA anchor not found in reims-vgpu-efi paint.rs'; exit 1; }\n"
    "  sed -i 's/%s/%s/' %s\n"
    "  grep -qF '%s' %s\n"
) % (rgb, old, paint,
     old.replace("[", r"\[").replace("]", r"\]"), new, paint,
     new, paint)
text = text.replace(anchor, patch + anchor, 1)
path.write_text(text)
print("==> patched Dockerfile: Reims GOP boot colour #%s (was #182840)" % rgb)
PYEOF_BOOTCOLOR

echo "==> building (target: artifact) — this compiles real QEMU from source, expect 30-60+ minutes"
"$ENGINE" build --target artifact -t layerosx/qemu-macos:local "$WORK/qemu-macos"

echo "==> extracting the built binary + GOP ROM"
# The final "artifact" image is FROM scratch with no CMD/ENTRYPOINT (it
# only holds the 2 output files) — "docker create" refuses to create a
# container with no command at all, even though we never start it, we
# only docker-cp files out of it. Any placeholder argument satisfies
# that check without ever actually being executed.
CID=$("$ENGINE" create layerosx/qemu-macos:local noop)

mkdir -p airootfs/opt/layerosx/bin airootfs/usr/share/qemu
"$ENGINE" cp "$CID:/usr/bin/qemu-system-x86_64" airootfs/opt/layerosx/bin/qemu-system-x86_64
"$ENGINE" cp "$CID:/usr/share/qemu/reims-vgpu-gop.rom" airootfs/usr/share/qemu/reims-vgpu-gop.rom
chmod +x airootfs/opt/layerosx/bin/qemu-system-x86_64

echo "==> building the 'verify' stage too, to inspect + bundle its runtime libraries"
# The Dockerfile's own "verify" stage (FROM qemux/qemu:latest) already
# ldd's the built binary and fails the build outright if anything is
# unresolved *inside that image* -- so it's a known-good source for
# any library whose SONAME doesn't match what Arch ships (confirmed
# on real hardware: libjpeg is one -- Arch's libjpeg-turbo only ships
# libjpeg.so.8, this binary was built against Debian's libjpeg62-turbo
# and needs libjpeg.so.62 specifically, see README.md). BuildKit will
# reuse the layers already built above for --target artifact, so this
# is effectively free.
"$ENGINE" build --target verify -t layerosx/qemu-macos-verify:local "$WORK/qemu-macos"

mkdir -p "$WORK/libs" airootfs/opt/layerosx/lib
# Confirmed on real hardware: this used to pipe `ldd` straight into a
# `while read` loop (`ldd ... | while read -r line; do ...; done`).
# That "sh -c '...'" runs under a POSIX shell (dash on Debian-based
# images, not bash), which has no `pipefail` at all -- `set -eu`
# alone does NOT catch a failure on the left side of a pipe. If `ldd`
# ever failed or printed nothing for any reason, the loop's body
# simply never ran, the (empty) loop still "succeeded", and this
# whole step reported success while bundling exactly zero libraries
# -- which shipped straight through into a built ISO that crashed
# with "libjpeg.so.62: cannot open shared object file" every single
# launch, no error anywhere in the build log. Rewritten to capture
# `ldd`'s own exit status explicitly (no pipe to hide behind) and,
# below, to hard-fail the whole build if the bundle ends up empty --
# libjpeg alone is known to always need bundling (see README.md), so
# zero libraries bundled is never a valid outcome, only a silent bug.
#
# Also confirmed on real hardware: qemux/qemu:latest (the base image
# for the "verify" stage) bakes in ENTRYPOINT ["/usr/bin/tini", "-s",
# "/run/entry.sh"] -- `docker run` only replaces CMD, never
# ENTRYPOINT, so without --entrypoint this whole "sh -c '...'" gets
# appended onto that fixed entrypoint (effectively
# "tini -s /run/entry.sh sh -c '...'"), and tini's own argument
# parser chokes on the stray "-c" and refuses to run anything at all
# ("/usr/bin/tini: invalid option -- 'c'"). --entrypoint sh bypasses
# tini entirely for this one-off extraction, which never needed init/
# signal-forwarding supervision in the first place.
"$ENGINE" run --rm --entrypoint sh -v "$WORK/libs:/host-out" layerosx/qemu-macos-verify:local -c '
    set -eu
    if ! ldd /out/qemu-system-x86_64 >/tmp/ldd-out.txt 2>&1; then
        echo "FAIL: ldd /out/qemu-system-x86_64 itself failed inside the verify image:" >&2
        cat /tmp/ldd-out.txt >&2
        exit 1
    fi
    count=0
    while IFS= read -r line; do
        lib=$(printf "%s\n" "$line" | sed -n "s/.* => \(\/[^ ]*\).*/\1/p")
        [ -n "$lib" ] || continue
        [ -f "$lib" ] || continue
        base=$(basename "$lib")
        case "$base" in
            # These have to match the KERNEL/dynamic loader of whatever
            # machine actually runs this, not the build container -- every
            # real-hardware failure seen so far has been further down the
            # dependency list than these, so trust the target Arch system
            # to already provide them correctly instead of shipping a
            # foreign copy that could silently be wrong in a much worse way.
            libc.so.*|libm.so.*|libpthread.so.*|libdl.so.*|librt.so.*|ld-linux*|libgcc_s.so.*|libstdc++.so.*|libresolv.so.*|libutil.so.*)
                continue
                ;;
        esac
        cp -v "$lib" "/host-out/$base"
        count=$((count + 1))
    done </tmp/ldd-out.txt
    echo "extracted $count librar$([ "$count" = 1 ] && echo y || echo ies) inside the verify image" >&2
'
cp -a "$WORK"/libs/. airootfs/opt/layerosx/lib/
LIBCOUNT=$(find airootfs/opt/layerosx/lib -type f | wc -l)
echo "==> bundled $LIBCOUNT runtime librar$([ "$LIBCOUNT" = 1 ] && echo y || echo ies) into airootfs/opt/layerosx/lib: $(ls airootfs/opt/layerosx/lib 2>/dev/null | tr '\n' ' ')"
if [ "$LIBCOUNT" -eq 0 ]; then
    echo "FAIL: bundled zero runtime libraries. This is never expected (libjpeg alone always needs bundling, see README.md) -- aborting instead of silently shipping a qemu-system-x86_64 that will crash on every launch." >&2
    exit 1
fi

echo "==> querying reims-vgpu-pci's real options (update kiosk/mac-vm-launch.sh's -device line if these differ from what's already there)"
# Same LD_LIBRARY_PATH trick mac-vm-launch.sh uses on the installed
# system -- lets this actually succeed on a build host that also
# doesn't have libjpeg.so.62 etc. (WSL/most desktop distros), instead
# of always silently hitting the fallback warning below.
LD_LIBRARY_PATH="$(pwd)/airootfs/opt/layerosx/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    airootfs/opt/layerosx/bin/qemu-system-x86_64 -device reims-vgpu-pci,help || \
    echo "WARNING: couldn't query it on this host — that's OK, it doesn't need KVM for a -device,help query, but worth checking why." >&2

echo "==> done: $(du -h airootfs/opt/layerosx/bin/qemu-system-x86_64 | cut -f1) binary staged into the archiso profile"
