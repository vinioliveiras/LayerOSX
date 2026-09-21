#!/usr/bin/env bash
# Produce an OpenCore image with a verbose macOS boot (-v). How much extra
# diagnostic machinery rides along depends on the BUILD MODE (LAYEROSX_MODE):
#
#   release (default) -- the SHIPPING verbose image. boot-args gets only `-v`,
#     so `verbose on` gives a readable XNU boot log on screen and nothing else.
#     Stock RELEASE OpenCore, no serial routing, no OpenCore log spam. This is
#     the clean build handed to users.
#
#   debug -- the DIAGNOSTIC verbose image. On top of `-v` it adds serial kernel
#     logging (serial=3 debug=0x108 keepsyms=1), turns on OpenCore's own Misc>
#     Debug logging, and enables kholia's kernel serial patches so XNU's log
#     reaches the serial port. This is the "show me everything, find the hang"
#     image -- see README.md / CLAUDE.md. (No OpenCore BINARY swap: it caused an
#     "Already started" halt and the kernel log doesn't need it -- see below.)
#
# Everything diagnostic is gated on debug mode, so there is nothing to strip out
# by hand once the boot is fixed: just build in release mode.
#
# Keeping all of this ONLY in the verbose image (never the base) is deliberate:
# `verbose off` is always a silent Apple-logo boot regardless of mode.
#
# COPY-BASED: $1 input, $2 output (default: in place). Composes on top of the
# AMD image to yield OpenCore-amd-verbose.qcow2.
#
# Needs qemu-img + mtools; degrades to a warning (exit 0) if missing.
set -uo pipefail
cd "$(dirname "$0")"
IN="${1:-airootfs/opt/layerosx/opencore/OpenCore.qcow2}"
OUT="${2:-$IN}"

# Build mode: anything other than "debug" is treated as "release" (the clean
# default), so a typo can never accidentally ship the diagnostic image.
MODE="${LAYEROSX_MODE:-release}"
case "$MODE" in
    debug) : ;;
    release) : ;;
    *) echo "patch-opencore-verbose: unknown LAYEROSX_MODE='$MODE' -- treating as release." >&2; MODE="release" ;;
esac

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

python3 - "$_plist" "$MODE" <<'PYV'
import plistlib, sys
p = sys.argv[1]
mode = sys.argv[2]
cfg = plistlib.load(open(p, "rb"))

# 1) Append boot-args to every boot-args value in NVRAM>Add (the standard
#    boot-args GUID here is ...A880...; boot-args is also in NVRAM>Delete so
#    OpenCore rewrites it every boot and our args win even over a cached NVRAM).
nv = cfg.setdefault("NVRAM", {}).setdefault("Add", {})
targets = [sec for sec in nv.values() if isinstance(sec, dict) and "boot-args" in sec]
if not targets:
    guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    nv.setdefault(guid, {})["boot-args"] = ""
    targets = [nv[guid]]

# release: just -v, so the on-screen boot log is readable and nothing else.
# debug:   also route the KERNEL's console to the serial port. -v alone only
#   draws XNU's boot log on the framebuffer -- which is exactly what fails here
#   ("no linesize"): the OpenCore picker renders fine, but the instant the
#   kernel takes the framebuffer it can't bring up its video console, so the
#   screen freezes at HANDOFF and the kernel is a black box. serial=3 makes XNU
#   use the 16550 serial console (COM1 / 0x3F8, captured to ~/mac-vm-serial.log)
#   INDEPENDENT of the framebuffer, so the kernel log survives even with a
#   broken FB. debug=0x108 = 0x100 (DB_KERN_DUMP_ON_PANIC, symbolicated panic on
#   serial) | 0x08 (DB_KPRT, stream the kernel's live kprintf() to serial) -- so
#   the serial log shows WHERE the kernel spins after handoff (it is alive: qemu
#   pins one core at ~100%), not just a post-mortem. keepsyms=1 symbolicates it.
if mode == "debug":
    # msgbuf=524288 enlarges XNU's kernel message buffer so early kprintf
    # output can't scroll off before we capture it.
    extra_args = ["-v", "keepsyms=1", "debug=0x108", "serial=3", "msgbuf=524288"]
else:
    extra_args = ["-v"]
for sec in targets:
    toks = (sec.get("boot-args", "") or "").split()
    for a in extra_args:
        if "=" in a:
            key = a.split("=", 1)[0]
            toks = [t for t in toks if t.split("=", 1)[0] != key]
            toks.append(a)
        elif a not in toks:
            toks.append(a)
    sec["boot-args"] = " ".join(toks)

# 2) debug only: turn on OpenCore's own logging (serial+console+file, all
#    levels) so kext injection and kernel-patch results are visible. In release
#    the stock Misc>Debug is left untouched (no log spam on a clean boot).
if mode == "debug":
    dbg = cfg.setdefault("Misc", {}).setdefault("Debug", {})
    dbg["Target"] = 0x4B               # enable(1)+console(2)+serial(8)+file(64)
    dbg["DisplayLevel"] = 0xFFFFFFFF   # include INFO -- patch/kext results live there
    dbg["DisableWatchDog"] = True
    dbg["AppleDebug"] = True
    dbg["ApplePanic"] = True

# 3) debug only: enable kholia's own kernel serial-output patches, which ship
#    DISABLED. They route XNU's early boot log and its panic string to the
#    serial port (0x3F8 / COM1, captured to ~/mac-vm-serial.log). They are
#    Base-symbol patches (_panic, _kernel_debug_string_early,
#    _disable_serial_output) with no MinKernel/MaxKernel, so they apply to every
#    macOS version incl. Ventura. Left disabled in release.
if mode == "debug":
    for _p in (cfg.get("Kernel", {}).get("Patch", []) or []):
        if _p.get("Identifier") == "kernel" and "serial" in (_p.get("Comment", "") or "").lower():
            _p["Enabled"] = True

plistlib.dump(cfg, open(p, "wb"))
sys.exit(0)
PYV
rc=$?
if [ "$rc" -eq 0 ]; then
    mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist

    # NOTE: no OpenCore BINARY swap. We used to swap in a public DEBUG OpenCore
    # here (to get OC:/OCAK logging), but that put a full OpenCore.efi at
    # \EFI\BOOT\BOOTx64.efi, which relaunched \EFI\OC\OpenCore.efi and halted
    # with "Found previous image, aborting / Already started" once NVRAM stopped
    # pointing straight at \EFI\OC. We already have the OCAK data we needed, and
    # the KERNEL serial log (what we need for the "no linesize" framebuffer hang)
    # comes from the boot-args (serial=3 debug=0x108) + kholia's kernel serial
    # patches above -- NOT from a DEBUG OpenCore. So the verbose image keeps
    # kholia's stock RELEASE OpenCore; only boot-args + kernel patches differ.

    qemu-img convert -O qcow2 "$_raw" "$OUT"
    chmod 644 "$OUT"
    echo "patch-opencore-verbose: [$MODE] verbose boot (-v) enabled -> $OUT"
else
    echo "patch-opencore-verbose: failed to patch config.plist from $IN -- not writing $OUT." >&2
fi
exit 0
