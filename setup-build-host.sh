#!/usr/bin/env bash
# Installs everything needed to BUILD the LayerOSX ISO on an Arch-based host
# (Arch, CachyOS, or Arch under WSL2). Idempotent: safe to run every time --
# rebuild.sh calls it before each build, and pacman's --needed skips anything
# already installed.
#
# What and why:
#   archiso        -> mkarchiso, builds the ISO itself
#   docker +
#   docker-buildx  -> the one-time custom QEMU (qemu-macos/Reims) source build
#                     in prepare-qemu-macos.sh (buildx: the Dockerfile needs
#                     BuildKit, the legacy builder silently skips its heredocs)
#   qemu-img,
#   mtools         -> derive the OpenCore images (verbose / AMD) without root
#   git, python,
#   curl           -> clone/pull, the plist patchers, downloads
set -euo pipefail

if ! command -v pacman >/dev/null 2>&1; then
    echo "setup-build-host: not a pacman (Arch-based) system -- install by hand:" >&2
    echo "  archiso docker docker-buildx qemu-img mtools git python curl" >&2
    exit 1
fi

PKGS=(archiso docker docker-buildx qemu-img mtools git python curl)
echo "==> setup-build-host: installing/checking ${PKGS[*]}"
sudo pacman -S --needed --noconfirm "${PKGS[@]}"

# Docker daemon must be running for prepare-qemu-macos.sh. Under WSL without
# systemd this fails -- say so instead of aborting (build.sh only needs Docker
# for the first QEMU build).
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if ! systemctl is-active --quiet docker; then
        echo "==> setup-build-host: enabling + starting docker"
        sudo systemctl enable --now docker
    fi
else
    echo "WARNING: no systemd here -- start the Docker daemon by hand (e.g. 'sudo dockerd &') before the first build." >&2
fi

# Rough free-space check: the QEMU Docker build + mkarchiso work dir need
# roughly 20-30 GB.
_free_gb="$(df -BG --output=avail "$(dirname "$0")" | tail -1 | tr -dc '0-9')"
if [ -n "$_free_gb" ] && [ "$_free_gb" -lt 30 ]; then
    echo "WARNING: only ${_free_gb} GB free here -- the build needs ~20-30 GB." >&2
fi
echo "==> setup-build-host: ready."
