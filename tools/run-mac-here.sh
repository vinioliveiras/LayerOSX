#!/usr/bin/env bash
# Boot the INSTALLED LayerOSX Mac on this Linux desktop (e.g. the CachyOS the
# ISO is built on), with the QEMU/Reims/OpenCore the last build produced -- to
# debug the VM without rebooting into LayerOSX.
#
#   tools/run-mac-here.sh                  # Reims, 4 cores, 8 GB, windowed
#   tools/run-mac-here.sh --gfx vmware     # plain VMware SVGA (SDL window)
#   tools/run-mac-here.sh --gpu nvidia     # Reims on the NVIDIA GPU only (or: amd, intel)
#   tools/run-mac-here.sh --diag           # text boot + serial kernel log + QEMU -d
#   tools/run-mac-here.sh --model MacBookPro16,2   # boot as another Mac model (SMBIOS)
#   tools/run-mac-here.sh --fullscreen --x11 --cores 8 --ram 16
#   tools/run-mac-here.sh --part /dev/nvme0n1p7   # skip auto-detecting the partition
#   tools/run-mac-here.sh --print          # show the command, don't run it
#
# SAFE: the LayerOSX partition is mounted READ-ONLY and the Mac's disk runs
# with snapshot=on (writes go to a throw-away overlay), so nothing done here
# changes the installed Mac. The UEFI NVRAM is a scratch copy.
#
# Same command line as kiosk/mac-vm-launch.sh (CPU model/flags, memfd RAM,
# reims-vgpu-pci behind a pci-bridge with the GOP ROM, OpenCore on sata.2,
# ...), minus the kiosk: no openbox, no picom, no launcher loop. So when a
# problem shows up here too it's QEMU/Reims/the GPU, not the kiosk.
#
# Everything lands in test-runs/<timestamp>/ (gitignored): run.log (this
# script + QEMU's stdout/stderr + how QEMU ended + the QMP SHUTDOWN reason),
# qemu.log (QEMU -D: Reims messages; guest_errors/unimp with --diag),
# serial.log (firmware/kernel console).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
AIR="$REPO/archiso/airootfs"
QEMU="$AIR/opt/layerosx/bin/qemu-system-x86_64"
LIBS="$AIR/opt/layerosx/lib"
ROM="$AIR/usr/share/qemu/reims-vgpu-gop.rom"
OCDIR="$AIR/opt/layerosx/opencore"

GFX=reims GPU="" MODEL="" DIAG=0 FULL=0 X11=0 CORES=4 RAM=8 PART="" PRINT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --gfx) GFX="$2"; shift ;;
        --gpu) GPU="$2"; shift ;;
        --model) MODEL="$2"; shift ;;
        --diag) DIAG=1 ;;
        --fullscreen) FULL=1 ;;
        --x11) X11=1 ;;
        --cores) CORES="$2"; shift ;;
        --ram) RAM="$2"; shift ;;
        --part) PART="$2"; shift ;;
        --print) PRINT=1 ;;
        -h|--help) sed -n 2,30p "$0"; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done
case "$GFX" in reims|vmware) : ;; *) echo "--gfx must be reims or vmware" >&2; exit 2 ;; esac

die() { echo "run-mac-here: $*" >&2; exit 1; }
[ -x "$QEMU" ] || die "no QEMU at $QEMU -- run archiso/prepare-qemu-macos.sh (or a build) first."
[ -s "$ROM" ] || [ "$GFX" != reims ] || die "no Reims GOP ROM at $ROM."
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm isn't usable by $USER (add yourself to the kvm group)."
OVMF_CODE=""
for f in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd; do
    [ -r "$f" ] && { OVMF_CODE="$f"; break; }
done
[ -n "$OVMF_CODE" ] || die "OVMF not found -- sudo pacman -S edk2-ovmf"

# --- the installed LayerOSX: already mounted somewhere, or mount it read-only
find_root() {
    local m
    for m in /run/media/"$USER"/* /mnt /media/* "$HOME/.cache/layerosx-root"; do
        [ -r "$m/var/lib/layerosx/macos.qcow2" ] && { echo "$m"; return 0; }
    done
    return 1
}
ROOT="$(find_root || true)"
if [ -z "$ROOT" ]; then
    MNT="$HOME/.cache/layerosx-root"; mkdir -p "$MNT"
    if [ -n "$PART" ]; then CANDS="$PART"; else
        CANDS="$(lsblk -rpno PATH,FSTYPE,MOUNTPOINT | awk '$2=="ext4" && $3=="" {print $1}')"
    fi
    for dev in $CANDS; do
        echo "==> trying $dev (read-only; sudo may ask for your password)"
        sudo mount -o ro "$dev" "$MNT" 2>/dev/null || continue
        if [ -e "$MNT/var/lib/layerosx/macos.qcow2" ]; then ROOT="$MNT"; break; fi
        sudo umount "$MNT"
    done
    [ -n "$ROOT" ] || die "couldn't find the LayerOSX partition (pass --part /dev/...; lsblk -f lists them)."
fi
STATE="$ROOT/var/lib/layerosx"
echo "==> LayerOSX found at $ROOT"
[ -r "$STATE/macos.qcow2" ] || die "$STATE/macos.qcow2 isn't readable by $USER (different uid on the LayerOSX side?)."

RUN="$REPO/test-runs/$(date +%Y%m%d-%H%M%S)-$GFX"
mkdir -p "$RUN"
cp "$STATE/OVMF_VARS.fd" "$RUN/OVMF_VARS.fd" 2>/dev/null || cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$RUN/OVMF_VARS.fd"

# --- CPU: same model/flags as the launcher
HOST_FLAGS=" $(awk -F': ' '/^flags/{print $2; exit}' /proc/cpuinfo) "
has() { case "$HOST_FLAGS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)"
MACOS="$(cat "$STATE/macos-version" 2>/dev/null || echo ventura)"
CPU_FLAGS="kvm=on,vendor=GenuineIntel,vmware-cpuid-freq=on,vmx=off,-pdpe1gb,-hle,-rtm"
if has constant_tsc && has nonstop_tsc; then CPU_FLAGS+=",+invtsc"; else CPU_FLAGS+=",-invtsc"; fi
if [ "$VENDOR" = AuthenticAMD ]; then
    case "$MACOS" in
        high-sierra|mojave|catalina|big-sur|monterey|ventura) CPU_MODEL=Haswell-noTSX; CPU_FLAGS+=",stepping=3" ;;
        *) CPU_MODEL=Skylake-Client-v4; CPU_FLAGS+=",-spec-ctrl" ;;
    esac
    for f in pcid invpcid xsavec xsaves; do has "$f" && CPU_FLAGS+=",+$f" || CPU_FLAGS+=",-$f"; done
    CPU_FLAGS+=",-tsc-deadline,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+smep,+xsave,+xsaveopt,+xgetbv1,+movbe,+rdrand,check"
    # AMD OpenCore images bake the core count: 2 / 4 / 8 only.
    case "$CORES" in 2) FAM=amd2 ;; 8) FAM=amd8 ;; *) CORES=4; FAM=amd ;; esac
    OCBASE="OpenCore-$FAM"
else
    CPU_MODEL=Skylake-Client-v4
    CPU_FLAGS+=",+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+xsave,+xsaveopt,check"
    OCBASE="OpenCore"
fi
OC="$OCDIR/$OCBASE.qcow2"
[ "$DIAG" = 1 ] && [ -s "$OCDIR/$OCBASE-diag.qcow2" ] && OC="$OCDIR/$OCBASE-diag.qcow2"
[ -s "$OC" ] || die "no OpenCore image $OC -- run a build first."
if [ -n "$MODEL" ]; then
    "$AIR/opt/layerosx/kiosk/lib/oc-model.sh" "$OC" "$RUN/OpenCore-$MODEL.qcow2" "$MODEL" \
        || die "couldn't set model $MODEL (needs qemu-img + mtools)"
    OC="$RUN/OpenCore-$MODEL.qcow2"
fi

# Only the bundled libraries this system lacks (same helper as the kiosk):
# the whole bundle shadows the host's libdrm/libelf/... and breaks RADV.
LIBDIR="$("$AIR/opt/layerosx/kiosk/lib/qemu-libdir.sh" "$LIBS" "$QEMU")"
ENV=(LD_LIBRARY_PATH="${LIBDIR:-$LIBS}")
ARGS=(-name macOS-test -nodefaults -enable-kvm -no-reboot -rtc base=utc
      -L "$AIR/usr/share/qemu" -L /usr/share/qemu
      -qmp "unix:$RUN/qmp.sock,server,nowait"
      -m "${RAM}G" -object "memory-backend-memfd,id=reims-ram,size=${RAM}G,share=on"
      -machine q35,memory-backend=reims-ram
      -cpu "$CPU_MODEL,$CPU_FLAGS" -smp "$CORES,sockets=1,cores=$CORES,threads=1"
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
      -drive "if=pflash,format=raw,file=$RUN/OVMF_VARS.fd"
      -device 'isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'
      -smbios type=2 -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1
      -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
      -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0
      -device ich9-ahci,id=sata
      -drive "id=OpenCoreBoot,if=none,format=qcow2,snapshot=on,file=$OC"
      -device ide-hd,bus=sata.2,drive=OpenCoreBoot,bootindex=0
      -drive "id=MacHDD,if=none,format=qcow2,snapshot=on,file=$STATE/macos.qcow2"
      -device ide-hd,bus=sata.4,drive=MacHDD
      -netdev user,id=net0 -device vmxnet3,netdev=net0,id=net0,romfile=
      -serial "file:$RUN/serial.log" -D "$RUN/qemu.log")
[ "$DIAG" = 1 ] && ARGS+=(-d guest_errors,unimp)
if [ "$GFX" = reims ]; then
    ARGS+=(-display none -vga none
           -device pci-bridge,chassis_nr=5,id=pci.5,bus=pcie.0,addr=1e.0,shpc=off
           -device "reims-vgpu-pci,id=reimsvgpu,romfile=$ROM,rombar=1,bus=pci.5,addr=00.0")
    ENV+=(REIMS_VGPU_WINDOW=1)
    [ "$FULL" = 1 ] && ENV+=(REIMS_VGPU_FULLSCREEN=1)
    if [ -n "$GPU" ]; then
        case "$GPU" in nvidia) pat='nvidia_icd*.json' ;; amd) pat='radeon_icd*.json' ;; intel) pat='intel_icd*.json' ;;
            *) die "--gpu must be nvidia, amd or intel" ;; esac
        ICD="$(ls /usr/share/vulkan/icd.d/$pat /etc/vulkan/icd.d/$pat 2>/dev/null | head -1)"
        [ -n "$ICD" ] || die "no Vulkan driver manifest matching $pat on this system."
        ENV+=(VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD")
    fi
else
    ARGS+=(-vga none -device vmvga -display "sdl$([ "$FULL" = 1 ] && echo ,full-screen=on)")
fi
[ "$X11" = 1 ] && ENV=(-u WAYLAND_DISPLAY SDL_VIDEODRIVER=x11 "${ENV[@]}")   # winit/SDL fall back to X11 (XWayland)

{
    echo "run-mac-here $(date -Is) session=${XDG_SESSION_TYPE:-?} gfx=$GFX gpu=${GPU:-auto} model=${MODEL:-image} diag=$DIAG cores=$CORES ram=${RAM}G"
    echo "OpenCore: $OC   Mac disk: $STATE/macos.qcow2 (snapshot=on)"
    printf 'cmdline:'; printf ' %q' "${ENV[@]}" "$QEMU" "${ARGS[@]}"; printf '\n'
} | tee "$RUN/run.log"
[ "$PRINT" = 1 ] && exit 0

echo "==> starting (logs: $RUN). Close the window or Ctrl+C here to stop."
env "${ENV[@]}" "$QEMU" "${ARGS[@]}" >>"$RUN/run.log" 2>&1 &
QPID=$!
for _ in $(seq 1 50); do [ -S "$RUN/qmp.sock" ] && break; sleep 0.2; done
python3 - "$RUN/qmp.sock" >>"$RUN/run.log" 2>&1 <<'PY' &
import json, socket, sys
import time
s = socket.socket(socket.AF_UNIX)
for _ in range(50):
    try:
        s.connect(sys.argv[1]); break
    except OSError:
        time.sleep(0.2)
else:
    sys.exit(0)                      # QEMU never opened QMP (died at start)
f = s.makefile("rwb")
f.readline(); f.write(b'{"execute":"qmp_capabilities"}\n'); f.flush()
for line in f:
    m = json.loads(line)
    if m.get("event") in ("SHUTDOWN", "RESET", "STOP", "GUEST_PANICKED"):
        print("QMP event:", m.get("event"), json.dumps(m.get("data", {})), flush=True)
print("QMP: connection closed", flush=True)
PY
tail -n +1 -f "$RUN/run.log" --pid=$QPID &
START=$(date +%s)
wait $QPID; RC=$?
sleep 0.5
if [ "$RC" -gt 128 ]; then E="killed by signal $((RC-128))"; else E="exit status $RC"; fi
echo "QEMU ended: $E after $(( $(date +%s) - START ))s" | tee -a "$RUN/run.log"
echo "==> logs: $RUN"
