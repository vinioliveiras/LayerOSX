#!/usr/bin/env bash
# One-shot rebuild helper. Run from the repo root:
#     ./rebuild.sh
#     LAYEROSX_TERMINAL=off ./rebuild.sh     # Ctrl+Alt+T terminal: password|open|off
# It pulls the latest commits, installs any missing build tools
# (setup-build-host.sh -- archiso, docker, mtools...) and rebuilds the ISO (build.sh handles the rest:
# it only re-runs the ~30-60 min qemu Docker build when the binary/libs aren't
# already staged, otherwise just re-derives the OpenCore images + mkarchiso).
#
# There is ONE build now. The ISO is set up like the old release build (Reims,
# sound on, Apple-logo boot, consoles locked, terminal behind a password); the
# old debug build's features are toggles in LayerOSX Settings:
#   Mac > Show startup log / Detailed logs, General > Text consoles.
# `./rebuild.sh debug|release` still works but the word is ignored.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
    "") : ;;
    debug|release)
        echo "note: '$1' is no longer a build mode -- one ISO for all; the debug features are toggles in LayerOSX Settings (Mac > Detailed logs, General > Text consoles)." ;;
    *) echo "usage: $0" >&2; exit 2 ;;
esac

echo "==> git pull"
git pull --ff-only
echo "==> build-host dependencies (setup-build-host.sh)"
./setup-build-host.sh
echo "==> building ISO (archiso/build.sh)"
cd archiso
# sudo resets the environment: pass LAYEROSX_TERMINAL through explicitly
# (empty = build.sh's default, password).
sudo LAYEROSX_TERMINAL="${LAYEROSX_TERMINAL:-}" ./build.sh
echo "==> done. ISO is in archiso/out/ -- drag it onto your Ventoy drive."
