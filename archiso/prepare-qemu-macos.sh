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
cleanup() { [ -n "$CID" ] && "$ENGINE" rm -f "$CID" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> cloning qemus/qemu-macos"
git clone --depth 1 https://github.com/qemus/qemu-macos "$WORK/qemu-macos"

echo "==> building (target: artifact) — this compiles real QEMU from source, expect 30-60+ minutes"
"$ENGINE" build --target artifact -t layerosx/qemu-macos:local "$WORK/qemu-macos"

echo "==> extracting the built binary + GOP ROM"
CID=$("$ENGINE" create layerosx/qemu-macos:local)

mkdir -p airootfs/opt/layerosx/bin airootfs/usr/share/qemu
"$ENGINE" cp "$CID:/usr/bin/qemu-system-x86_64" airootfs/opt/layerosx/bin/qemu-system-x86_64
"$ENGINE" cp "$CID:/usr/share/qemu/reims-vgpu-gop.rom" airootfs/usr/share/qemu/reims-vgpu-gop.rom
chmod +x airootfs/opt/layerosx/bin/qemu-system-x86_64

echo "==> querying reims-vgpu-pci's real options (update kiosk/mac-vm-launch.sh's -device line if these differ from what's already there)"
airootfs/opt/layerosx/bin/qemu-system-x86_64 -device reims-vgpu-pci,help || \
    echo "WARNING: couldn't query it on this host — that's OK, it doesn't need KVM for a -device,help query, but worth checking why." >&2

echo "==> done: $(du -h airootfs/opt/layerosx/bin/qemu-system-x86_64 | cut -f1) binary staged into the archiso profile"
