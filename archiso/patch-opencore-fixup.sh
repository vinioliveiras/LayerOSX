#!/usr/bin/env bash
# Fix a latent bug in the base OpenCore image: its config.plist lists several
# kexts in Kernel>Add as Enabled=True that are NOT actually present in the
# image's EFI/OC/Kexts folder (VoodooPS2Controller + its keyboard plugin,
# AppleMCEReporterDisabler, USBToolBox, UTBMap). OpenCore treats a missing
# injected kext as a CRITICAL error and HALTS ("Halting on critical error"),
# so macOS never even reaches kernel load -- confirmed on real hardware. None
# of those kexts are needed for this VM (it uses USB input, not PS/2), so we
# disable any Kernel>Add entry whose kext bundle isn't present in the image.
#
# Detection is by the filesystem, not a hardcoded list: whatever kexts the
# image actually ships stay enabled, the rest are switched off -- so this keeps
# working if the base image changes which kexts it bundles.
#
# COPY-BASED like the other patchers: $1 input, $2 output (default: in place).
# Needs qemu-img + mtools; degrades to a warning (exit 0) if missing.
set -uo pipefail
cd "$(dirname "$0")"
IN="${1:-airootfs/opt/layerosx/opencore/OpenCore.qcow2}"
OUT="${2:-$IN}"

[ -s "$IN" ] || { echo "patch-opencore-fixup: $IN not found -- nothing to do." >&2; exit 0; }
if ! command -v qemu-img >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
    echo "patch-opencore-fixup: qemu-img/mtools missing -- NOT fixing phantom kexts ($OUT)." >&2
    echo "  Without this the OpenCore image halts on a missing injected kext -- install them and re-run." >&2
    exit 0
fi

export MTOOLS_SKIP_CHECK=1
_raw="$(mktemp)"; _plist="$(mktemp)"; _present="$(mktemp)"
trap 'rm -f "$_raw" "$_plist" "$_present"' EXIT
qemu-img convert -O raw "$IN" "$_raw"
_esp="${_raw}@@1048576"
if ! mcopy -n -i "$_esp" ::/EFI/OC/config.plist "$_plist" 2>/dev/null; then
    echo "patch-opencore-fixup: couldn't read the OpenCore ESP in $IN -- not writing $OUT." >&2
    exit 0
fi
# List the kext bundle directories actually present in the image.
mdir -i "$_esp" ::/EFI/OC/Kexts/ 2>/dev/null | grep -oiE '[A-Za-z0-9._-]+\.kext' | sort -u > "$_present"

python3 - "$_plist" "$_present" <<'PYF'
import plistlib, sys
cfg_path, present_path = sys.argv[1], sys.argv[2]
present = set(l.strip() for l in open(present_path) if l.strip())
cfg = plistlib.load(open(cfg_path, "rb"))
adds = cfg.get("Kernel", {}).get("Add", []) or []
disabled = []
for k in adds:
    bp = k.get("BundlePath", "") or ""
    top = bp.split("/")[0]          # the .kext bundle this entry lives in
    if k.get("Enabled") and top and top not in present:
        k["Enabled"] = False
        disabled.append(bp)
# --- Framebuffer fix: force a fixed GOP resolution --------------------------
# Confirmed on real hardware (both vmware and reims): after HANDOFF the macOS
# kernel prints "no linesize" and stalls -- it gets a boot framebuffer with no
# valid stride (rowBytes=0), so it can't bring up the video console. The base
# config sets ProvideConsoleGop=True but leaves Resolution empty, so OpenCore
# never actively establishes a GOP mode. Forcing a concrete resolution makes
# OpenCore set up a clean framebuffer (valid stride) before handoff. This is
# the VM's INTERNAL (emulated-GPU) resolution -- QEMU/SDL scales it to whatever
# the physical monitor is, so it is safe on any monitor size. 1920x1080 is
# universally supported by the emulated adapters.
out = cfg.setdefault("UEFI", {}).setdefault("Output", {})
changed_fb = False
if out.get("Resolution", "") != "1920x1080":
    out["Resolution"] = "1920x1080"; changed_fb = True
if out.get("ProvideConsoleGop") is not True:
    out["ProvideConsoleGop"] = True; changed_fb = True
if out.get("ClearScreenOnModeSwitch") is not True:
    out["ClearScreenOnModeSwitch"] = True; changed_fb = True

if disabled or changed_fb:
    plistlib.dump(cfg, open(cfg_path, "wb"))
for b in disabled:
    sys.stderr.write("  disabled missing kext: %s\n" % b)
if changed_fb:
    sys.stderr.write("  set UEFI>Output Resolution=1920x1080 (framebuffer/no-linesize fix)\n")
sys.exit(0 if (disabled or changed_fb) else 3)
PYF
rc=$?

if [ "$rc" -eq 0 ]; then
    mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist
    qemu-img convert -O qcow2 "$_raw" "$OUT"
    chmod 644 "$OUT"
    echo "patch-opencore-fixup: disabled phantom (missing) kexts -> $OUT"
elif [ "$rc" -eq 3 ]; then
    if [ "$OUT" != "$IN" ]; then qemu-img convert -O qcow2 "$_raw" "$OUT"; chmod 644 "$OUT"; fi
    echo "patch-opencore-fixup: no phantom kexts to disable (already clean)."
else
    echo "patch-opencore-fixup: failed to process config.plist -- not writing $OUT." >&2
fi
exit 0
