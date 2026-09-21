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
# Add -v (verbose) AND route the KERNEL's console to the serial port. -v alone
# only draws XNU's boot log on the framebuffer -- which is exactly what fails
# here ("no linesize"): the OpenCore picker renders fine, but the instant the
# kernel takes the framebuffer it can't bring up its video console, so the
# screen freezes at HANDOFF and the kernel is a black box. serial=3 makes XNU
# use the 16550 serial console (COM1 / 0x3F8, captured to ~/mac-vm-serial.log)
# INDEPENDENT of the framebuffer, so the kernel log survives even with a broken
# FB -- which finally tells us whether XNU hangs at handoff or just boots
# invisibly. keepsyms=1 + debug=0x100 give a symbolicated panic on serial if it
# panics. (These join the kholia kernel serial patches enabled below.)
extra_args = ["-v", "keepsyms=1", "debug=0x100", "serial=3"]
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

# 2) Turn on OpenCore's own logging (serial+console+file, all levels) so kext
#    injection and kernel-patch results are visible.
dbg = cfg.setdefault("Misc", {}).setdefault("Debug", {})
dbg["Target"] = 0x4B               # enable(1)+console(2)+serial(8)+file(64)
dbg["DisplayLevel"] = 0xFFFFFFFF   # include INFO -- patch/kext results live there
dbg["DisableWatchDog"] = True
dbg["AppleDebug"] = True
dbg["ApplePanic"] = True

# 3) Enable kholia's own kernel serial-output patches, which ship DISABLED.
#    They route XNU's early boot log and its panic string to the serial port
#    (0x3F8 / COM1, which the launcher captures to ~/mac-vm-serial.log). Without
#    them the serial log stops at HANDOFF and the kernel is a black box -- with
#    them we finally see WHERE/why XNU dies. They are Base-symbol patches
#    (_panic, _kernel_debug_string_early, _disable_serial_output) with no
#    MinKernel/MaxKernel, so they apply to every macOS version incl. Ventura.
for _p in (cfg.get("Kernel", {}).get("Patch", []) or []):
    if _p.get("Identifier") == "kernel" and "serial" in (_p.get("Comment", "") or "").lower():
        _p["Enabled"] = True

plistlib.dump(cfg, open(p, "wb"))
sys.exit(0)
PYV
rc=$?
if [ "$rc" -eq 0 ]; then
    mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist

    # --- Swap in a DEBUG OpenCore so the verbose image actually LOGS ----------
    # DIAGNOSTIC / TEMPORARY (remove once the boot is fixed -- see CLAUDE.md).
    # kholia's OpenCore is a RELEASE build: it prints NOTHING regardless of the
    # Misc>Debug flags above, so OCAK (kernel-patch results -- e.g. whether the
    # AMD_Vanilla patches actually apply) is invisible. Swap the WHOLE OpenCore
    # binary set (OpenCore.efi + Bootstrap + the revision-checked drivers) for
    # the matching public DEBUG release -- all from ONE release so their driver
    # revision matches OpenCore.efi (mixing a public OpenCore.efi with kholia's
    # newer drivers is what gave "Invalid revision"). Config + kexts stay
    # kholia's. Verified booting in TCG: 1.0.5 DEBUG loads kholia's config
    # cleanly and logs OC:/OCB:/OCAK to serial. Verbose image only; `verbose off`
    # keeps the RELEASE OpenCore. Needs curl + python3 (both present in the build
    # env); degrades to a warning (keeps RELEASE) if the download fails.
    OC_DEBUG_VER="${OC_DEBUG_VER:-1.0.5}"
    _ocz="/tmp/layerosx-oc-${OC_DEBUG_VER}-DEBUG.zip"
    _ocd="$(mktemp -d)"
    if [ ! -s "$_ocz" ]; then
        curl -fsSL -o "$_ocz" "https://github.com/acidanthera/OpenCorePkg/releases/download/${OC_DEBUG_VER}/OpenCore-${OC_DEBUG_VER}-DEBUG.zip" 2>/dev/null \
            || echo "patch-opencore-verbose: WARNING could not download OpenCore ${OC_DEBUG_VER} DEBUG -- verbose image keeps the RELEASE OpenCore (no OC:/OCAK log)." >&2
    fi
    if [ -s "$_ocz" ] && python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$_ocz" "$_ocd" 2>/dev/null && [ -s "$_ocd/X64/EFI/OC/OpenCore.efi" ]; then
        _ocx="$_ocd/X64/EFI"
        mcopy -o -n -i "$_esp" "$_ocx/OC/OpenCore.efi"  ::/EFI/OC/OpenCore.efi
        mcopy -o -n -i "$_esp" "$_ocx/BOOT/BOOTx64.efi" ::/EFI/BOOT/BOOTx64.efi
        for _d in OpenCanopy OpenRuntime OpenPartitionDxe ResetNvramEntry ToggleSipEntry OpenHfsPlus; do
            [ -f "$_ocx/OC/Drivers/$_d.efi" ] && mcopy -o -n -i "$_esp" "$_ocx/OC/Drivers/$_d.efi" "::/EFI/OC/Drivers/$_d.efi"
        done
        echo "patch-opencore-verbose: swapped OpenCore -> ${OC_DEBUG_VER} DEBUG (OC:/OCAK logging) in $OUT"
    else
        echo "patch-opencore-verbose: NOTE keeping RELEASE OpenCore in $OUT (no DEBUG swap) -- OCAK log will be empty." >&2
    fi
    rm -rf "$_ocd"

    qemu-img convert -O qcow2 "$_raw" "$OUT"
    chmod 644 "$OUT"
    echo "patch-opencore-verbose: verbose boot (-v) + OpenCore logging enabled -> $OUT"
else
    echo "patch-opencore-verbose: failed to patch config.plist from $IN -- not writing $OUT." >&2
fi
exit 0
