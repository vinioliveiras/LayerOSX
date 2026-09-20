#!/usr/bin/env bash
# Produce an OpenCore image with verbose macOS boot (-v) enabled in its
# config.plist boot-args. XNU shows only the Apple logo by default; -v makes
# it print its boot log to the screen, the one way to see WHERE a boot stalls
# or panics (see README.md). boot-args is in this config's NVRAM/Delete list
# too, so OpenCore rewrites it every boot and -v wins even over a cached NVRAM.
#
# COPY-BASED (not in-place): this reads an input image and writes a SEPARATE
# output image, leaving the input untouched. That is what lets build.sh keep
# the downloaded, checksum-verified OpenCore.qcow2 pristine while shipping a
# distinct OpenCore-verbose.qcow2 alongside it, so the launcher can offer a
# clean Apple-logo boot by default and switch to the verbose image on demand
# (see the `verbose` command and mac-vm-launch.sh's image selection). It also
# composes: run it on OpenCore-amd.qcow2 to get OpenCore-amd-verbose.qcow2.
#
# $1 (optional): input OpenCore qcow2 (default: the staged base image).
# $2 (optional): output qcow2 to write (default: same as input = in-place,
#                for backward compatibility with older callers).
#
# Needs qemu-img + mtools; if either is missing it warns and exits 0 (the ISO
# just ships the quiet Apple-logo boot from the non-verbose image) rather than
# failing the build. Idempotent: adding -v to an already-verbose config is a
# no-op, and because the output is always a fresh copy of the input there is
# never a doubled "-v -v".
set -uo pipefail
cd "$(dirname "$0")"
IN="${1:-airootfs/opt/layerosx/opencore/OpenCore.qcow2}"
OUT="${2:-$IN}"

[ -s "$IN" ] || { echo "patch-opencore-verbose: $IN not found -- nothing to patch." >&2; exit 0; }
if ! command -v qemu-img >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
    echo "patch-opencore-verbose: qemu-img and/or mtools missing -- NOT producing a verbose image ($OUT)." >&2
    echo "  Install them (e.g. 'sudo pacman -S qemu-img mtools') and re-run to bake -v in." >&2
    exit 0
fi

# Write to a distinct output image, keeping the input pristine. Convert the
# input straight into the output as qcow2 (this both copies and normalises it);
# for the in-place case OUT==IN we operate on a temp raw and write back to IN.
export MTOOLS_SKIP_CHECK=1
_raw="$(mktemp)"; _plist="$(mktemp)"
trap 'rm -f "$_raw" "$_plist"' EXIT
qemu-img convert -O raw "$IN" "$_raw"
_esp="${_raw}@@1048576"   # pinned image is GPT with its FAT ESP at 1 MiB
if ! mdir -i "$_esp" ::/EFI/OC/ >/dev/null 2>&1 || \
   ! mcopy -n -i "$_esp" ::/EFI/OC/config.plist "$_plist" 2>/dev/null; then
    echo "patch-opencore-verbose: couldn't read the OpenCore ESP in $IN -- not writing $OUT." >&2
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
    0|3)
        # 0 = we added -v; 3 = it was already there. Either way write OUT so
        # a fresh verbose image exists at the requested path (the copy is the
        # point even when the input already carried -v).
        mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist
        qemu-img convert -O qcow2 "$_raw" "$OUT"
        chmod 644 "$OUT"
        if [ "$rc" -eq 0 ]; then
            echo "patch-opencore-verbose: verbose boot (-v) enabled -> $OUT"
        else
            echo "patch-opencore-verbose: input already verbose -- copied to $OUT"
        fi
        ;;
    2) echo "patch-opencore-verbose: no boot-args key in $IN's config.plist -- not writing $OUT." >&2 ;;
    *) echo "patch-opencore-verbose: failed to patch config.plist from $IN -- not writing $OUT." >&2 ;;
esac
exit 0
