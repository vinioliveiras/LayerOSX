#!/usr/bin/env bash
# Idempotently enable verbose macOS boot (-v) in the OpenCore image's
# config.plist boot-args. XNU shows only the Apple logo by default; -v makes
# it print its boot log to the screen, the one way to see WHERE a boot stalls
# or panics (see README.md). boot-args is in this config's NVRAM/Delete list
# too, so OpenCore rewrites it every boot and -v wins even over a cached NVRAM.
#
# WHY THIS IS SEPARATE (and why build.sh runs it every build): build.sh only
# re-runs prepare-opencore.sh when OpenCore.qcow2 is MISSING, so a machine that
# already built once reuses its existing (non-verbose) image and never picks up
# -v. Making this its own idempotent step that build.sh always calls fixes that
# -- a pre-existing image still gets patched.
#
# $1 (optional): path to the OpenCore qcow2 (default: the staged one).
# Needs qemu-img + mtools; if either is missing it warns and exits 0 (the ISO
# just ships the quiet Apple-logo boot) rather than failing the build.
set -uo pipefail
cd "$(dirname "$0")"
IMG="${1:-airootfs/opt/layerosx/opencore/OpenCore.qcow2}"

[ -s "$IMG" ] || { echo "patch-opencore-verbose: $IMG not found -- nothing to patch." >&2; exit 0; }
if ! command -v qemu-img >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
    echo "patch-opencore-verbose: qemu-img and/or mtools missing -- NOT enabling verbose boot (-v)." >&2
    echo "  Install them (e.g. 'sudo pacman -S qemu-img mtools') and re-run to bake -v in." >&2
    exit 0
fi

export MTOOLS_SKIP_CHECK=1
_raw="$(mktemp)"; _plist="$(mktemp)"
trap 'rm -f "$_raw" "$_plist"' EXIT
qemu-img convert -O raw "$IMG" "$_raw"
_esp="${_raw}@@1048576"   # pinned image is GPT with its FAT ESP at 1 MiB
if ! mdir -i "$_esp" ::/EFI/OC/ >/dev/null 2>&1 || \
   ! mcopy -n -i "$_esp" ::/EFI/OC/config.plist "$_plist" 2>/dev/null; then
    echo "patch-opencore-verbose: couldn't read the OpenCore ESP -- shipping without -v." >&2
    exit 0
fi

python3 - "$_plist" <<'PYV'
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
m = re.search(r'(<key>boot-args</key>\s*<string>)([^<]*)(</string>)', s)
if not m:
    sys.exit(2)                       # no boot-args key at all
cur = m.group(2)
if "-v" in cur.split():
    sys.exit(3)                       # already verbose
new = m.group(1) + (cur + (" " if cur else "") + "-v") + m.group(3)
open(p, "w", encoding="utf-8").write(s[:m.start()] + new + s[m.end():])
sys.exit(0)
PYV
rc=$?

case "$rc" in
    0)
        mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist
        qemu-img convert -O qcow2 "$_raw" "$IMG"
        chmod 644 "$IMG"
        echo "patch-opencore-verbose: verbose boot (-v) enabled in $IMG"
        ;;
    3) echo "patch-opencore-verbose: already verbose (-v present) -- nothing to do." ;;
    2) echo "patch-opencore-verbose: no boot-args key in config.plist -- shipping without -v." >&2 ;;
    *) echo "patch-opencore-verbose: failed to patch config.plist -- shipping without -v." >&2 ;;
esac
exit 0
