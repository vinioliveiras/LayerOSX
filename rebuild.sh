#!/usr/bin/env bash
# One-shot rebuild helper. Run this in WSL from the repo root:
#     ./rebuild.sh              # asks for the build mode (release/debug)
#     ./rebuild.sh release      # non-interactive
#     ./rebuild.sh debug        # non-interactive
#     LAYEROSX_MODE=debug ./rebuild.sh
# It pulls the latest commits, installs any missing build tools
# (setup-build-host.sh -- archiso, docker, mtools...) and rebuilds the ISO (build.sh handles the rest:
# it only re-runs the ~30-60 min qemu Docker build when the binary/libs aren't
# already staged, otherwise just re-derives the OpenCore images + mkarchiso).
#
# Build modes (see build.sh / patch-opencore-verbose.sh):
#   release -- clean build for normal use: verbose off, audio on, Reims on.
#   debug   -- troubleshooting build: verbose on + serial kernel logging +
#              DEBUG OpenCore in the verbose image; VMware display, audio off.
set -euo pipefail
cd "$(dirname "$0")"

# Mode: 1st arg wins, else $LAYEROSX_MODE, else let build.sh prompt.
MODE="${1:-${LAYEROSX_MODE:-}}"
case "$MODE" in
    ""|debug|release) : ;;
    *) echo "usage: $0 [release|debug]" >&2; exit 2 ;;
esac

echo "==> git pull"
git pull --ff-only
echo "==> build-host dependencies (setup-build-host.sh)"
./setup-build-host.sh
echo "==> building ISO (archiso/build.sh)"
cd archiso
# sudo resets the environment, so pass the mode explicitly (sudo accepts
# VAR=value before the command). Empty MODE => build.sh prompts interactively.
if [ -n "$MODE" ]; then
    sudo LAYEROSX_MODE="$MODE" ./build.sh
else
    sudo ./build.sh
fi
echo "==> done. ISO is in archiso/out/ -- drag it onto your Ventoy drive."
