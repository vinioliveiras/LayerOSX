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

WORK=$(mktemp -d)
CID=""
VCID=""
cleanup() {
    [ -n "$CID" ] && "$ENGINE" rm -f "$CID" >/dev/null 2>&1
    [ -n "$VCID" ] && "$ENGINE" rm -f "$VCID" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

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
"$ENGINE" run --rm -v "$WORK/libs:/host-out" layerosx/qemu-macos-verify:local sh -c '
    set -eu
    ldd /out/qemu-system-x86_64 | while read -r line; do
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
    done
'
cp -a "$WORK"/libs/. airootfs/opt/layerosx/lib/
LIBCOUNT=$(find airootfs/opt/layerosx/lib -type f | wc -l)
echo "==> bundled $LIBCOUNT runtime librar$([ "$LIBCOUNT" = 1 ] && echo y || echo ies) into airootfs/opt/layerosx/lib: $(ls airootfs/opt/layerosx/lib 2>/dev/null | tr '\n' ' ')"

echo "==> querying reims-vgpu-pci's real options (update kiosk/mac-vm-launch.sh's -device line if these differ from what's already there)"
# Same LD_LIBRARY_PATH trick mac-vm-launch.sh uses on the installed
# system -- lets this actually succeed on a build host that also
# doesn't have libjpeg.so.62 etc. (WSL/most desktop distros), instead
# of always silently hitting the fallback warning below.
LD_LIBRARY_PATH="$(pwd)/airootfs/opt/layerosx/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    airootfs/opt/layerosx/bin/qemu-system-x86_64 -device reims-vgpu-pci,help || \
    echo "WARNING: couldn't query it on this host — that's OK, it doesn't need KVM for a -device,help query, but worth checking why." >&2

echo "==> done: $(du -h airootfs/opt/layerosx/bin/qemu-system-x86_64 | cut -f1) binary staged into the archiso profile"
