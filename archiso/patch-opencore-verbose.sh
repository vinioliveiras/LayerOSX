#!/usr/bin/env bash
# Produce an OpenCore image with verbose macOS boot (-v) AND OpenCore's own
# diagnostic logging turned on. This is the "show me everything" image:
#   * -v in boot-args  -> XNU prints its boot log to the screen.
#   * Misc>Debug logging -> OpenCore prints, per kext/patch, what it did
#     (e.g. "OCAK: Kernel patcher result 0 for <comment> - Success/Not found")
#     to the serial port (captured in ~/mac-vm-serial.log), the screen, and a
#     file on the ESP.
# Keeping BOTH of these ONLY in the verbose image is deliberate: the non-verbose
# image stays completely clean, so `verbose off` gives a silent Apple-logo boot
# with no OpenCore log spam, and `verbose on` turns everything back on -- one
# switch for all diagnostics (see the `verbose` command and mac-vm-launch.sh).
#
# COPY-BASED: $1 input, $2 output (default: in place). Composes on top of the
# AMD image to yield OpenCore-amd-verbose.qcow2.
#
# Needs qemu-img + mtools; degrades to a warning (exit 0) if missing.
set -uo pipefail
cd "$(dirname "$0")"
IN="${1:-airootfs/opt/layerosx/opencore/OpenCore.qcow2}"
OUT="${2:-$IN}"

[ -s "$IN" ] || { echo "patch-opencore-verbose: $IN not found -- nothing to patch." >&2; exit 0; }
if ! command -v qemu-img >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
    echo "patch-opencore-verbose: qemu-img/mtools missing -- NOT producing verbose image ($OUT)." >&2
    exit 0
fi

export MTOOLS_SKIP_CHECK=1
_raw="$(mktemp)"; _plist="$(mktemp)"
trap 'rm -f "$_raw" "$_plist"' EXIT
qemu-img convert -O raw "$IN" "$_raw"
_esp="${_raw}@@1048576"
if ! mcopy -n -i "$_esp" ::/EFI/OC/config.plist "$_plist" 2>/dev/null; then
    echo "patch-opencore-verbose: couldn't read the OpenCore ESP in $IN -- not writing $OUT." >&2
    exit 0
fi

python3 - "$_plist" <<'PYV'
import plistlib, sys
p = sys.argv[1]
cfg = plistlib.load(open(p, "rb"))

# 1) Append -v to every boot-args value in NVRAM>Add (the standard boot-args
#    GUID here is ...A880...; boot-args is also in NVRAM>Delete so OpenCore
#    rewrites it every boot and -v wins even over a cached NVRAM).
nv = cfg.setdefault("NVRAM", {}).setdefault("Add", {})
targets = [sec for sec in nv.values() if isinstance(sec, dict) and "boot-args" in sec]
if not targets:
    guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    nv.setdefault(guid, {})["boot-args"] = ""
    targets = [nv[guid]]
for sec in targets:
    ba = sec.get("boot-args", "") or ""
    if "-v" not in ba.split():
        sec["boot-args"] = (ba + (" " if ba else "") + "-v")

# 2) Turn on OpenCore's own logging (serial+console+file, all levels) so kext
#    injection and kernel-patch results are visible.
dbg = cfg.setdefault("Misc", {}).setdefault("Debug", {})
dbg["Target"] = 0x4B               # enable(1)+console(2)+serial(8)+file(64)
dbg["DisplayLevel"] = 0xFFFFFFFF   # include INFO -- patch/kext results live there
dbg["DisableWatchDog"] = True
dbg["AppleDebug"] = True
dbg["ApplePanic"] = True

plistlib.dump(cfg, open(p, "wb"))
sys.exit(0)
PYV
rc=$?
if [ "$rc" -eq 0 ]; then
    mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist
    qemu-img convert -O qcow2 "$_raw" "$OUT"
    chmod 644 "$OUT"
    echo "patch-opencore-verbose: verbose boot (-v) + OpenCore logging enabled -> $OUT"
else
    echo "patch-opencore-verbose: failed to patch config.plist from $IN -- not writing $OUT." >&2
fi
exit 0
