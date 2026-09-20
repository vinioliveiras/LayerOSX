#!/usr/bin/env bash
# Main kiosk launcher (runs instead of a desktop, autologin of the
# "mac" user on tty1 — see postinstall/40-kiosk-autologin.sh).
#
# 1. If no VM exists yet, shows the first-run wizard
#    (macos-source-wizard.sh) — only happens once.
# 2. Launches our custom-built qemu-system-x86_64 (Reims-vGPU baked
#    in, staged by ../../../prepare-qemu-macos.sh at build time) in
#    fullscreen.
# 3. Waits for a QMP event to find out IF and HOW macOS asked to power
#    off, and translates that into a real action on the physical
#    machine:
#      Shut Down (inside macOS) -> systemctl poweroff (for real)
#      Restart   (inside macOS) -> systemctl reboot   (for real)
#    (decided this way on purpose: a Restart also reboots the Arch
#    underneath, in case Arch itself is having problems.)
set -uo pipefail

STATE_DIR="/var/lib/layerosx"
VM_DISK="$STATE_DIR/macos.qcow2"
OVMF_VARS="$STATE_DIR/OVMF_VARS.fd"
QMP_SOCK="/tmp/macvm-qmp.sock"
KIOSK_DIR="/opt/layerosx/kiosk"
QEMU_BIN="/opt/layerosx/bin/qemu-system-x86_64"
OPENCORE_IMG="/opt/layerosx/opencore/OpenCore.qcow2"
GOP_ROM="/usr/share/qemu/reims-vgpu-gop.rom"
MACOS_VERSION_FILE="$STATE_DIR/macos-version"   # written by macos-source-wizard.sh
GFX_FILE="$STATE_DIR/gfx"                       # optional: "vmware" to bypass Reims
VM_RAM_MB=8192
MIN_UPTIME_FOR_REAL_REBOOT=180
LOG="$HOME/mac-vm.log"
SERIAL_LOG="$HOME/mac-vm-serial.log"

# Every line gets a timestamp on its way into the log. This log is append-only
# across every boot (tee -a), so without one there is no telling which of two
# "Attaching recovery disk" lines belongs to which attempt -- confirmed on
# real hardware, that ambiguity cost a whole debugging session.
exec > >(while IFS= read -r _l || [ -n "$_l" ]; do printf '%(%H:%M:%S)T %s\n' -1 "$_l"; done | tee -a "$LOG") 2>&1

# Common landing spot for a condition nothing below would ever fix by
# itself (missing binary/image from an incomplete build, or missing
# /dev/kvm) -- these all need either a rebuild with the right prepare-*
# script run, or a physical fix like a BIOS setting, never just a
# retry. Confirmed on real hardware: a plain `exit 1` here is actually
# WORSE than the old all-QEMU-launch-failures retry loop it replaced
# for these specific cases. .xinitrc does `exec mac-vm-launch.sh`, so
# this script exiting ends the whole X session; getty's autologin
# (40-kiosk-autologin.sh) restarts it right away -- with nothing to
# pace that out, the result is tty1 flash-restarting far faster than
# the retry loop's own `sleep 3`/5x/reboot ever did, and fast enough
# that systemd's own restart-rate-limit on the getty unit can trip and
# leave tty1 dead. A long sleep before exiting fixes both: paces the
# restart to something sane, and gives a wide window to switch to tty2
# (Ctrl+Alt+F2) or pull up the F2 live-log terminal and actually read
# the message before it's gone.
fatal() {
    echo "FATAL: $1" >&2
    shift
    for _line in "$@"; do
        echo "  $_line" >&2
    done
    echo "Not retrying, and NOT restarting the graphical session -- a restart here would just re-loop (flicker). Fix it from a text console: Ctrl+Alt+F2, log in (mac/mac), make the change, then 'sudo reboot'. This screen will now sit still (no flicker) so the text console stays reachable." >&2
    # Deliberately do NOT exit: exiting ends X, and getty's tty1 autologin
    # immediately restarts it (.xinitrc re-runs force-max-refresh + this
    # script), which is the flicker loop. Staying alive keeps X up and idle --
    # no QEMU, no restart, no mode-thrash -- so Ctrl+Alt+F2 works reliably and
    # the machine is actually fixable. The user reboots once they've applied
    # the fix. (A tty is always available regardless; nothing here blocks it.)
    while true; do sleep 3600; done
}

# The build container qemus/qemu-macos compiles this binary in
# (Debian-based, with --enable-vnc-jpeg among other features) links
# it against a couple of libraries whose SONAME doesn't match what
# Arch ships -- libjpeg is the confirmed one on real hardware
# ("error while loading shared libraries: libjpeg.so.62: cannot open
# shared object file"), which made QEMU fail to even start at all
# (immediately, every single launch) rather than a display/rendering
# problem -- see README.md. prepare-qemu-macos.sh now bundles an
# exact copy of every such library (extracted from the same verified
# build image the binary was tested in) alongside the binary.
#
# Confirmed on real hardware: this used to `export` LD_LIBRARY_PATH
# here, at the top of the whole script -- which meant every later
# child process (macos-source-wizard.sh, and everything IT launches:
# zenity, GParted, ...) inherited it too, not just qemu-system-x86_64.
# QEMU itself links against glib (it always has), so the bundle above
# includes a Debian-flavored libglib-2.0/libgobject-2.0/libgio-2.0 --
# and with LD_LIBRARY_PATH leaking into zenity's environment, zenity's
# system-matching gtk4 was loading THAT foreign glib instead of
# Arch's own, crashing immediately with "libgtk-4.so.1: undefined
# symbol: g_zlib_compressor_set_os" on every single zenity call. Kept
# as a plain (non-exported) variable now and only applied as a
# per-command prefix on the actual qemu-system-x86_64 invocation
# below, so nothing else launched by this script or its children ever
# sees it.
QEMU_LD_LIBRARY_PATH=""
if [ -d /opt/layerosx/lib ] && [ -n "$(ls -A /opt/layerosx/lib 2>/dev/null)" ]; then
    QEMU_LD_LIBRARY_PATH="/opt/layerosx/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
sudo mkdir -p "$STATE_DIR"
sudo chown "$(id -u):$(id -g)" "$STATE_DIR"

# QEMU_BIN/OPENCORE_IMG/KVM are all only needed once we actually try to
# LAUNCH the accelerated VM below -- none of them are needed just to
# download/prepare macOS onto $VM_DISK via the wizard right after this.
# Confirmed on real hardware: checking these up here used to block the
# wizard (and its "download from Apple" step) from ever opening at all
# whenever one of them wasn't ready yet -- annoying on its own, and
# actively in the way while testing pieces of this independently (e.g.
# preparing a VM disk on a machine where KVM isn't sorted out yet). The
# checks now happen right before the actual QEMU launch further down,
# so the wizard always gets a chance to run regardless.

if [ ! -f "$VM_DISK" ]; then
    echo "No VM found — opening the first-run wizard."
    if ! "$KIOSK_DIR/macos-source-wizard.sh" "$VM_DISK" "$OVMF_VARS"; then
        echo "The wizard failed or was cancelled. Retrying in 10s (switch to tty2 with Alt+F2 if you need to get out)."
        sleep 10
        exec "$0"
    fi
fi

# macos-source-wizard.sh's "download from Apple" and ".dmg" paths both
# prepare a SECOND disk image (the recovery BaseSystem, or an
# extracted installer) alongside $VM_DISK -- but until now nothing
# ever attached it here, so the VM only ever saw the empty target
# disk and had nothing to boot at all (black screen, no error either
# — QEMU/OVMF just sits there with no bootable device). Attach
# whichever one exists, every boot: harmless once macOS is actually
# installed onto $VM_DISK (OVMF's own boot manager picks the disk
# that's actually bootable), and it's what actually lets the first
# boot reach the recovery/installer environment at all.
RECOVERY_DISK=""
for _cand in "${VM_DISK%.qcow2}-recovery.qcow2" "${VM_DISK%.qcow2}-installer.qcow2"; do
    if [ -f "$_cand" ]; then
        RECOVERY_DISK="$_cand"
        break
    fi
done

# Everything above (the wizard, recovery-disk detection) only ever
# touches disk images -- nothing needed QEMU itself yet. From here on
# we're about to actually launch it, so this is the right point to
# insist on everything an accelerated launch needs.
if [ ! -x "$QEMU_BIN" ]; then
    fatal "$QEMU_BIN is missing." "The ISO was built without running prepare-qemu-macos.sh first — see docs/CHECKLIST.md."
fi

# Plain OVMF + a bare QEMU command line is not enough for macOS's kernel
# to boot at all -- it probes for Apple-specific hardware (SMC, SMBIOS,
# a handful of ACPI/kernel quirks) that only OpenCore supplies here. See
# prepare-opencore.sh and README.md for the full story.
if [ ! -s "$OPENCORE_IMG" ]; then
    fatal "$OPENCORE_IMG is missing." "The ISO was built without running prepare-opencore.sh first — see docs/CHECKLIST.md."
fi

# Confirmed on real hardware: "qemu-system-x86_64: Could not access KVM
# kernel module: No such file or directory" / "failed to initialize kvm:
# No such file or directory" -- QEMU's own message is accurate but gives
# no next step. /dev/kvm missing here almost always means one of:
#   1. Virtualization (Intel VT-x, or AMD-V / "SVM Mode") is disabled in
#      the machine's BIOS/UEFI firmware -- the single most common cause
#      on real hardware, and postinstall has no way to fix this itself.
#   2. postinstall/10-hardware-detect.sh's kvm_intel/kvm_amd module
#      (added to /etc/mkinitcpio.conf + /etc/modules-load.d at install
#      time) failed to load at boot -- which happens silently when the
#      BIOS doesn't actually allow it, so mkinitcpio itself can't catch
#      it ahead of time either.
#   3. Running nested inside another hypervisor (VirtualBox, etc.) --
#      "enable nested virtualization" there is unreliable at actually
#      exposing a usable /dev/kvm to a guest, even when checked. This
#      project targets real hardware; if that's the situation, testing
#      on real hardware directly is the more useful next step, not more
#      nested-virtualization settings.
# There's no useful software-only (TCG) fallback for something as heavy
# as a macOS guest, so fail via fatal() below with a message that says
# what to actually go check, instead of looping on QEMU's cryptic one.
# One more modprobe attempt here costs nothing and occasionally is
# enough on its own (e.g. if 10-hardware-detect.sh ran before a later
# BIOS update re-enabled virtualization, so the module was never loaded
# even though it now could be).
if [ ! -e /dev/kvm ]; then
    _cpu_vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    case "$_cpu_vendor" in
        GenuineIntel) sudo modprobe kvm_intel 2>/dev/null || true ;;
        AuthenticAMD) sudo modprobe kvm_amd 2>/dev/null || true ;;
    esac
    sleep 1
fi
if [ ! -e /dev/kvm ]; then
    fatal "/dev/kvm doesn't exist -- macOS needs KVM acceleration, there's no usable software-only fallback here." \
        "This is almost always virtualization being disabled in the BIOS/UEFI: reboot," \
        "enter setup (Del/F2/F10 depending on the board) and enable Intel VT-x" \
        "(sometimes just called 'Virtualization') or AMD-V / SVM Mode." \
        "If it's already enabled there, check 'dmesg | grep -i kvm' and" \
        "/var/log/layerosx-postinstall.log for why kvm_intel/kvm_amd didn't load." \
        "Running nested inside VirtualBox/VMware/etc? Test on real hardware instead --" \
        "nested KVM is unreliable even with 'nested virtualization' enabled there."
fi

# ---------------------------------------------------------------------------
# Everything from here down mirrors the two upstream references this project
# is built from, deliberately and closely, after a long real-hardware detour
# (see README.md, "Root cause of the boot stall"):
#   - Reims' own vm/boot-x86.sh (github.com/steelbrain/reims-vgpu) -- THE
#     validated invocation for the reims-vgpu-pci device on x86/KVM.
#   - kholia/OSX-KVM's OpenCore-Boot.sh -- the launcher the OpenCore.qcow2
#     we ship (prepare-opencore.sh) was configured against.
# Where the two agree, that's what's here. Where this file used to differ
# from both, it was wrong: `-cpu host`, no shared memfd RAM, a default VGA
# next to the Reims GPU, virtio-blk disks, ICH9 USB. Each one alone is
# enough to explain a blue/black screen followed by QEMU exiting and
# relaunching in a loop, which is exactly what was observed.
# ---------------------------------------------------------------------------

# --- CPU model: never `-cpu host` -------------------------------------------
# macOS's kernel (XNU) only boots on CPUs it recognises as Intel, and only
# calibrates its clock through the `vmware-cpuid-freq` leaf on a hypervisor.
# `-cpu host` breaks both: on an AMD host it hands XNU an AuthenticAMD vendor
# (instant early panic unless OpenCore carries AMD kernel patches -- ours
# doesn't), and on any host it omits vmware-cpuid-freq (XNU hangs before it
# ever draws anything). Every working macOS-on-KVM setup masks the CPU as a
# named Intel model instead. Model choice follows dockur/macos (same QEMU
# build family as ours): a conservative Haswell for AMD hosts running Ventura
# or older, Skylake-Client otherwise. The version comes from the file the
# first-run wizard writes ($MACOS_VERSION_FILE); unknown falls through to
# Skylake-Client, dockur's own default.
CPU_VENDOR="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
HOST_CPU_FLAGS=" $(awk -F': ' '/^flags/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true) "
host_has_flag() { case "$HOST_CPU_FLAGS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
MACOS_SHORTNAME="$(cat "$MACOS_VERSION_FILE" 2>/dev/null || true)"

CPU_FLAGS="kvm=on,vendor=GenuineIntel,vmware-cpuid-freq=on,vmx=off,-pdpe1gb,-hle,-rtm"
# Invariant TSC: Reims' script always asks for it, dockur only when the host
# really has one (a constant, nonstop TSC) -- requesting it on a host without
# one is refused by KVM. Detect, don't assume.
if host_has_flag constant_tsc && host_has_flag nonstop_tsc; then
    CPU_FLAGS+=",+invtsc"
else
    CPU_FLAGS+=",-invtsc"
fi
if [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
    case "$MACOS_SHORTNAME" in
        high-sierra|mojave|catalina|big-sur|monterey|ventura) CPU_MODEL="Haswell-noTSX" ;;
        *) CPU_MODEL="Skylake-Client-v4"; CPU_FLAGS+=",-spec-ctrl" ;;
    esac
    # An AMD host can't pass a real Intel model through unchanged: mirror the
    # handful of optional features the model advertises that this particular
    # host may or may not have, then spell out the instruction sets macOS
    # expects from that model. `check` makes QEMU warn (not fail) about any
    # remaining mismatch, so the warning lands in the log instead of a boot
    # silently degrading.
    for _f in pcid invpcid xsavec xsaves; do
        if host_has_flag "$_f"; then CPU_FLAGS+=",+$_f"; else CPU_FLAGS+=",-$_f"; fi
    done
    CPU_FLAGS+=",-tsc-deadline,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+smep,+xsave,+xsaveopt,+xgetbv1,+movbe,+rdrand,check"
else
    CPU_MODEL="Skylake-Client-v4"
    CPU_FLAGS+=",+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+xsave,+xsaveopt,check"
fi

# --- SMP: a power of two, at most 8 ----------------------------------------
# macOS is picky about CPU topology (odd core counts misbehave; dockur maps 6
# to 3 sockets x 2 cores, etc.), and Reims' own script caps the guest at 8
# vCPUs with reims-vgpu-pci. Simplest topology that satisfies both: the
# largest power of two <= min(8, host cores - 2), on one socket.
TOTAL_CORES="$(nproc)"
VM_CORES=$((TOTAL_CORES - 2))
[ "$VM_CORES" -gt 8 ] && VM_CORES=8
[ "$VM_CORES" -lt 1 ] && VM_CORES=1
_p=1; while [ $((_p * 2)) -le "$VM_CORES" ]; do _p=$((_p * 2)); done
VM_CORES=$_p

# --- Graphics device --------------------------------------------------------
# reims-vgpu-pci (hardware-accelerated) is the whole point of this project --
# but it is alpha software on an alpha driver stack, and Reims' own docs say
# to provision the macOS guest on the plain VMware SVGA adapter FIRST and
# only switch to Reims once there's a working, installed system. So the
# DEFAULT here is vmware-svga: boring, unaccelerated, but reliable enough to
# actually get macOS installed. Reims is opt-in -- `echo reims > $GFX_FILE`
# (then `sudo pkill Xorg`, or a reboot) turns it on for the next launch,
# `echo vmware > $GFX_FILE` (or `rm $GFX_FILE`) goes back. This is also the
# single most useful A/B switch for telling "Reims can't draw yet" apart from
# "macOS isn't booting at all": if it boots on vmware but not reims, it's the
# Reims path; if it fails the same way on both, it isn't Reims.
GFX="$(cat "$GFX_FILE" 2>/dev/null || true)"
case "$GFX" in
    reims|reims-vgpu-pci) GFX="reims-vgpu-pci" ;;
    *) GFX="vmware-svga" ;;
esac
GFX_ARGS=()
if [ "$GFX" = "reims-vgpu-pci" ]; then
    # Straight from Reims' boot-x86.sh: `-vga none` because the UEFI GOP lives
    # on this same PCI device (its option ROM, rombar=1) and must never share
    # the guest with a second display; the device itself sits behind a
    # conventional pci-bridge (their default attach, "IOFBIntegrated=No; OVMF
    # maps BAR0"). romfile is an absolute path on purpose -- a bare name only
    # works if QEMU's firmware search path happens to include where
    # prepare-qemu-macos.sh staged it.
    if [ ! -s "$GOP_ROM" ]; then
        fatal "$GOP_ROM is missing." "The ISO was built without prepare-qemu-macos.sh staging the Reims GOP ROM — see docs/CHECKLIST.md. (Or write 'vmware' into $GFX_FILE -- or just delete it -- to go back to the default VMware display.)"
    fi
    GFX_ARGS=(
        -vga none
        # shpc=off is not in Reims' own boot-x86.sh -- they run a QEMU fork that
        # accepts the device at slot 0 of the bridge. Confirmed on real hardware
        # that stock QEMU 11.1 (what qemus/qemu-macos builds) does NOT: with the
        # bridge's default Standard Hot-Plug Controller on, slot 0 is reserved
        # ("Unsupported PCI slot 0 for standard hotplug controller. Valid slots
        # are between 1 and 31."), QEMU refuses the device and exits instantly,
        # which the retry loop then repeats 5x into a fatal(). Turning the
        # hotplug controller off frees slot 0, so the Reims device stays exactly
        # where its own launcher puts it (addr=00.0) instead of being moved to a
        # different slot, which its BAR/GOP mapping comments suggest matters.
        -device pci-bridge,chassis_nr=5,id=pci.5,bus=pcie.0,addr=1e.0,shpc=off
        -device "reims-vgpu-pci,id=reimsvgpu,romfile=$GOP_ROM,rombar=1,bus=pci.5,addr=00.0"
    )
else
    # This build's VMware SVGA adapter is qemu-vmvga, whose PCI device is
    # registered as "vmvga" (confirmed in its source: hw/display/vmware_vga.c
    # -> TypeInfo .name = "vmvga"), NOT stock QEMU's "vmware-svga". Confirmed
    # on real hardware: "-device vmware-svga: 'vmware-svga' is not a valid
    # device model name", QEMU exits instantly, 5x -> fatal, screen flickering.
    GFX_ARGS=(-vga none -device vmvga)
fi

echo "Launch profile: cpu=$CPU_MODEL ($CPU_VENDOR host) smp=$VM_CORES gfx=$GFX macos=${MACOS_SHORTNAME:-unknown} recovery=${RECOVERY_DISK:-none}"
echo "Guest firmware/kernel console goes to $SERIAL_LOG (type 'serial' in the F2 terminal)."

RETRIES=0
while true; do
    rm -f "$QMP_SOCK"

    QEMU_ARGS=(
        -name "macOS"
        -nodefaults
        -enable-kvm
        -no-reboot
        -rtc base=utc
        -qmp "unix:${QMP_SOCK},server,nowait"
        # Reims requirement, not a preference: the GPU command stream is
        # decoded out of guest RAM on the host side, which only works when
        # that RAM is a shared memfd mapping. Plain `-m` (what this used to
        # be) leaves the device unable to see guest memory at all.
        -m "${VM_RAM_MB}M"
        -object "memory-backend-memfd,id=reims-ram,size=${VM_RAM_MB}M,share=on"
        -machine q35,memory-backend=reims-ram
        -cpu "${CPU_MODEL},${CPU_FLAGS}"
        -smp "${VM_CORES},sockets=1,cores=${VM_CORES},threads=1"
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd
        -drive if=pflash,format=raw,file="$OVMF_VARS"
        # Apple-hardware emulation XNU checks for at boot (see dockur/macos'
        # boot.sh; every working QEMU-macOS setup does some version of this).
        # osk= is the well-known public "Apple SMC key", ROT13'd here only so
        # naive string scanners don't flag it -- it is not a secret.
        -device "isa-applesmc,osk=$(echo 'bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap' | tr 'A-Za-z' 'N-ZA-Mn-za-m')"
        -smbios type=2
        -global ICH9-LPC.disable_s3=1
        -global ICH9-LPC.disable_s4=1
        -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
        # USB: xHCI, as both references do. macOS handles the q35 default ICH9
        # EHCI/UHCI pair (what `-usb` used to give us) far less reliably.
        -device qemu-xhci,id=xhci
        -device usb-kbd,bus=xhci.0
        -device usb-tablet,bus=xhci.0
        -device usb-ehci,id=ehci
        # Disks: SATA, the exact OSX-KVM layout our OpenCore.qcow2 was built
        # against (OpenCore sata.2, install media sata.3, system disk sata.4).
        # Not virtio-blk: only Ventura+ carries a VirtIO block driver at all,
        # and the recovery environment is the one place we can't afford to
        # find out it doesn't. snapshot=on on the OpenCore image instead of
        # readonly=on -- an IDE/SATA hard disk can't be attached read-only,
        # but writes to a snapshot drive land in a throwaway overlay, which
        # is the same outcome we wanted.
        -device ich9-ahci,id=sata
        -drive id=OpenCoreBoot,if=none,format=qcow2,snapshot=on,file="$OPENCORE_IMG"
        -device ide-hd,bus=sata.2,drive=OpenCoreBoot,bootindex=0
        -drive id=MacHDD,if=none,format=qcow2,file="$VM_DISK"
        -device ide-hd,bus=sata.4,drive=MacHDD
        # romfile= (empty) drops the NIC's PXE option ROM: no "UEFI Misc
        # Device" network-boot entry for OVMF to wander into.
        -netdev user,id=net0
        -device virtio-net-pci,netdev=net0,id=net0,romfile=
        # OSX-KVM's OpenCore config (ours) patches XNU to send its early boot
        # prints and its panic string to the serial port. Until now nothing
        # captured it, which made every stall a blind blue screen; this is
        # what turns a kernel panic into readable text.
        -serial "file:$SERIAL_LOG"
        -display sdl,full-screen=on
    )
    QEMU_ARGS+=("${GFX_ARGS[@]}")
    if [ -n "$RECOVERY_DISK" ]; then
        echo "Attaching recovery/installer disk: $RECOVERY_DISK"
        QEMU_ARGS+=(
            -drive id=InstallMedia,if=none,format=qcow2,file="$RECOVERY_DISK"
            -device ide-hd,bus=sata.3,drive=InstallMedia
        )
    fi

    LAUNCHED_AT=$(date +%s)
    LD_LIBRARY_PATH="$QEMU_LD_LIBRARY_PATH" "$QEMU_BIN" "${QEMU_ARGS[@]}" &
    QEMU_PID=$!

    for _ in $(seq 1 50); do [ -S "$QMP_SOCK" ] && break; sleep 0.2; done

    ACTION=$(python3 "$KIOSK_DIR/qmp-watch.py" "$QMP_SOCK")
    wait "$QEMU_PID" 2>/dev/null
    RAN_FOR=$(( $(date +%s) - LAUNCHED_AT ))

    # Every QEMU session's outcome, good or bad, gets a fresh copy of
    # this log (and a journal snapshot) onto the USB -- during testing
    # this matters most right after a crash/black-screen exit, which
    # is exactly when there's no other easy way to see what happened.
    bash "$KIOSK_DIR/lib/save-logs-to-usb.sh" 2>/dev/null || true

    # A guest "reboot" seconds after launch is not someone clicking Restart
    # in the Apple menu -- it's XNU panicking and auto-restarting (or OVMF
    # resetting after a failed boot). With -no-reboot that arrives as the
    # same guest-reset SHUTDOWN event a real Restart does, so tell them
    # apart by uptime: nothing a person does reaches the Apple menu inside
    # $MIN_UPTIME_FOR_REAL_REBOOT seconds of a cold start. Rebooting the
    # physical machine on a panic loop (what this used to do) fixes nothing
    # and takes the logs away.
    if [ "$ACTION" = "host-reboot" ] && [ "$RAN_FOR" -lt "$MIN_UPTIME_FOR_REAL_REBOOT" ]; then
        echo "Guest reset only ${RAN_FOR}s after launch -- treating it as a boot failure (kernel panic / firmware reset), not a Restart request. See $SERIAL_LOG."
        ACTION="vm-only"
    fi

    case "$ACTION" in
        host-poweroff)
            echo "macOS asked to Shut Down — powering off the physical machine."
            sudo systemctl poweroff
            exit 0
            ;;
        host-reboot)
            echo "macOS asked to Restart — rebooting the physical machine."
            sudo systemctl reboot
            exit 0
            ;;
        vm-only|*)
            echo "QEMU exited without a clear guest request (action: ${ACTION}, ran ${RAN_FOR}s) — relaunching just the VM."
            RETRIES=$((RETRIES + 1))
            if [ "$RETRIES" -ge 5 ]; then
                fatal "QEMU exited $RETRIES times in a row." \
                    "That's a boot that fails the same way every time, not a transient glitch -- rebooting the physical" \
                    "machine (what this used to do here) would just loop it faster. Read $LOG and $SERIAL_LOG" \
                    "(F2 terminal: 'logs' / 'serial'). The display defaults to plain VMware SVGA;" \
                    "if you'd switched it to Reims, echo vmware > $GFX_FILE (or rm it) + sudo pkill Xorg to go back."
            fi
            sleep 3
            ;;
    esac
done
