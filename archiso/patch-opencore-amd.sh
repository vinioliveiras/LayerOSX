#!/usr/bin/env bash
# Produce an OpenCore image carrying the AMD_Vanilla kernel patches, so macOS
# boots on an AMD host CPU instead of instantly panicking / hanging at
# EXITBS->HANDOFF (confirmed on this project's AMD test machine: the stock
# Intel-only OpenCore.qcow2 freezes there; Dortania's guide attributes exactly
# that EXITBS hang on AMD to missing kernel patches).
#
# WHY THIS IS NEEDED: XNU (the macOS kernel) is built for Intel. On an AMD CPU
# a few instruction sequences it runs unconditionally (rdmsr on MSRs AMD lays
# out differently, its cpuid_cores_per_package math, the XCPM power-management
# path, ...) fault or return garbage and the kernel dies before it can print
# anything. The AMD-OSX community's "AMD_Vanilla" patch set (github.com/
# AMD-OSX/AMD_Vanilla) rewrites those sequences in-memory as OpenCore loads
# the kernel. It is the standard, widely-used fix for running macOS on AMD.
#
# Intel hosts must NOT get these patches (they would corrupt a correct kernel),
# which is why this is a SEPARATE image: build.sh produces both, and
# mac-vm-launch.sh picks the AMD image only when it sees an AuthenticAMD host
# (see that script). Intel keeps booting from the untouched OpenCore.qcow2.
#
# COPY-BASED: reads an input image, writes a SEPARATE output image, leaving the
# input pristine -- same contract as patch-opencore-verbose.sh, so the two
# compose (verbose can then be layered on top of the AMD image).
#
# CORE COUNT: four of the 25 patches force cpuid_cores_per_package to a
# constant the user picks -- it MUST equal the guest's -smp core count or macOS
# panics on the mismatch. We bake in AMD_CORES (default 4) here and
# mac-vm-launch.sh pins the AMD guest to exactly that many cores. Keep the two
# in sync: change AMD_CORES here => change the AMD pin there.
#
# ProvideCurrentCpuInfo=True is set as well: on AMD this makes OpenCore feed
# XNU a sane CPU topology/frequency (AMD_Vanilla's own sample config enables
# it), which the core-count patches rely on.
#
# $1 (optional): input OpenCore qcow2 (default: the staged base image).
# $2 (optional): output qcow2 to write (default: OpenCore-amd.qcow2 beside it).
# $3 (optional): AMD_Vanilla patches.plist (default: amd-vanilla-patches.plist,
#                the copy committed in this repo -- see its provenance below).
# $4 (optional): core count to bake in (default 4).
#
# PROVENANCE of the bundled patches file (archiso/amd-vanilla-patches.plist):
#   source : github.com/AMD-OSX/AMD_Vanilla  (patches.plist, master)
#   sha256 : 4bc820109b3d020c3c547fa23c49e0098e4f4a2c625ed6184dd54e390e84e1ab
#   content: 25 patches, incl. the 4 cpuid_cores_per_package variants.
# It is vendored (committed) rather than downloaded at build time so the build
# is reproducible and works offline; bump it deliberately to track upstream.
#
# Needs qemu-img + mtools + python3; if a tool is missing it warns and exits 0
# WITHOUT writing the output, so build.sh keeps going and mac-vm-launch.sh's
# "no AMD image" fallback/warning kicks in rather than the build aborting.
set -uo pipefail
cd "$(dirname "$0")"
IN="${1:-airootfs/opt/layerosx/opencore/OpenCore.qcow2}"
OUT="${2:-airootfs/opt/layerosx/opencore/OpenCore-amd.qcow2}"
PATCHES="${3:-amd-vanilla-patches.plist}"
AMD_CORES="${4:-4}"

[ -s "$IN" ]      || { echo "patch-opencore-amd: $IN not found -- nothing to patch." >&2; exit 0; }
[ -s "$PATCHES" ] || { echo "patch-opencore-amd: $PATCHES not found -- cannot build the AMD OpenCore image." >&2; exit 0; }
if ! command -v qemu-img >/dev/null 2>&1 || ! command -v mcopy >/dev/null 2>&1; then
    echo "patch-opencore-amd: qemu-img and/or mtools missing -- NOT producing the AMD image ($OUT)." >&2
    echo "  Install them (e.g. 'sudo pacman -S qemu-img mtools') and re-run; AMD hosts need this image." >&2
    exit 0
fi

export MTOOLS_SKIP_CHECK=1
_raw="$(mktemp)"; _plist="$(mktemp)"
trap 'rm -f "$_raw" "$_plist"' EXIT
qemu-img convert -O raw "$IN" "$_raw"
_esp="${_raw}@@1048576"   # same GPT/FAT-ESP-at-1MiB layout as the base image
if ! mdir -i "$_esp" ::/EFI/OC/ >/dev/null 2>&1 || \
   ! mcopy -n -i "$_esp" ::/EFI/OC/config.plist "$_plist" 2>/dev/null; then
    echo "patch-opencore-amd: couldn't read the OpenCore ESP in $IN -- not writing $OUT." >&2
    exit 0
fi

python3 - "$_plist" "$PATCHES" "$AMD_CORES" <<'PYA'
import plistlib, sys
cfg_path, patches_path, cores = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = plistlib.load(open(cfg_path, "rb"))
amd = plistlib.load(open(patches_path, "rb"))["Kernel"]["Patch"]

kern = cfg.setdefault("Kernel", {})
existing = kern.get("Patch", []) or []

# Idempotency / safety: never stack AMD_Vanilla twice. If the input already
# carries them (marker: algrey-authored comments), leave the patch list alone
# but still ensure the quirk + a written-out copy, and report "already".
already = any(
    isinstance(p, dict) and "algrey" in (p.get("Comment", "") or "")
    for p in existing
)

if not already:
    # Force the four cpuid_cores_per_package patches to our chosen core count:
    # the count lives in the Replace bytes at index [1] (mov reg, imm32).
    for p in amd:
        if "cpuid_cores_per_package" in (p.get("Comment", "") or ""):
            r = bytearray(p["Replace"]); r[1] = cores; p["Replace"] = bytes(r)
    existing.extend(amd)
    kern["Patch"] = existing

kern.setdefault("Quirks", {})["ProvideCurrentCpuInfo"] = True
plistlib.dump(cfg, open(cfg_path, "wb"))
sys.exit(3 if already else 0)
PYA
rc=$?

case "$rc" in
    0)
        mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist
        qemu-img convert -O qcow2 "$_raw" "$OUT"
        chmod 644 "$OUT"
        echo "patch-opencore-amd: injected 25 AMD_Vanilla patches (cores=$AMD_CORES, ProvideCurrentCpuInfo=True) -> $OUT"
        ;;
    3)
        mcopy -o -n -i "$_esp" "$_plist" ::/EFI/OC/config.plist
        qemu-img convert -O qcow2 "$_raw" "$OUT"
        chmod 644 "$OUT"
        echo "patch-opencore-amd: input already carries AMD_Vanilla patches -- copied to $OUT (quirk re-asserted)."
        ;;
    *) echo "patch-opencore-amd: failed to inject patches into $IN's config.plist -- not writing $OUT." >&2 ;;
esac
exit 0
