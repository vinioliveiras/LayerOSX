#!/usr/bin/env bash
# One-shot rebuild helper. Run this in WSL from the repo root:
#     ./rebuild.sh
# It pulls the latest commits and rebuilds the ISO (build.sh handles the rest:
# it only re-runs the ~30-60 min qemu Docker build when the binary/libs aren't
# already staged, otherwise just re-derives the OpenCore images + mkarchiso).
set -euo pipefail
cd "$(dirname "$0")"
echo "==> git pull"
git pull --ff-only
echo "==> building ISO (archiso/build.sh)"
cd archiso
sudo ./build.sh
echo "==> done. ISO is in archiso/out/ -- drag it onto your Ventoy drive."
