#!/usr/bin/env bash
# Builds the final ISO. Needs to run on an Arch-based Linux machine
# (CachyOS works) with the `archiso` package installed — this doesn't
# run inside this sandbox, it's meant to run on your own machine.
set -euo pipefail
cd "$(dirname "$0")"
WORKDIR="${1:-./work}"
OUTDIR="${2:-./out}"

command -v mkarchiso >/dev/null 2>&1 || {
    echo "mkarchiso not found — install the 'archiso' package first (sudo pacman -S archiso)." >&2
    exit 1
}

sudo mkarchiso -v -w "$WORKDIR" -o "$OUTDIR" .
echo "ISO ready in $OUTDIR/ — drag it onto your Ventoy drive."
