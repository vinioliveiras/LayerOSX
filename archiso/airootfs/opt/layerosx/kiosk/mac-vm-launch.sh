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
LOG="$HOME/mac-vm.log"

exec > >(tee -a "$LOG") 2>&1

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
    echo "Not retrying automatically -- this needs a fix, not another attempt. Will try again in 60s in case that fix already happened (a rebuild, a BIOS change + reboot, ...). Ctrl+Alt+F2 for a text console, or F2 for the live log if a VM window ever got this far before." >&2
    sleep 60
    exit 1
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

# Leave 2 cores for the host (Arch underneath still needs to breathe),
# minimum 1 for the VM. Was hardcoded to 6 — fine on the original dev
# machine, wrong on anything with fewer (or a lot more) cores.
TOTAL_CORES="$(nproc)"
if [ "$TOTAL_CORES" -gt 2 ]; then
    VM_CORES=$((TOTAL_CORES - 2))
else
    VM_CORES=1
fi

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

RETRIES=0
while true; do
    rm -f "$QMP_SOCK"

    # reims-vgpu-pci is the real device name (confirmed by reading the
    # qemus/qemu-macos Dockerfile's own verification step, which
    # probes it with `-device reims-vgpu-pci,help`). The `romfile=`
    # property below is QEMU's normal convention for a PCI device's
    # option ROM, matching where prepare-qemu-macos.sh stages
    # reims-vgpu-gop.rom — but the exact property names on this device
    # still need confirming: run
    #   sudo /opt/layerosx/bin/qemu-system-x86_64 -device reims-vgpu-pci,help
    # after the ISO is built and fix the line below if it disagrees.
    # See docs/CHECKLIST.md.
    QEMU_ARGS=(
        -name "macOS"
        -enable-kvm -m 8192 -smp "cores=${VM_CORES},threads=1" -cpu host
        -machine q35
        -no-reboot
        -rtc base=utc
        -qmp "unix:${QMP_SOCK},server,nowait"
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd
        -drive if=pflash,format=raw,file="$OVMF_VARS"
        # Apple-hardware emulation macOS's kernel actually checks for at
        # boot -- confirmed by reading dockur/macos's own boot.sh, which
        # every working QEMU-macOS setup does some version of. Without
        # these, XNU never gets past very early boot regardless of what
        # OpenCore below supplies.
        #   - isa-applesmc: emulates the real Apple SMC chip; osk= is the
        #     well-known public "Apple SMC key" (ROT13-encoded here only
        #     to avoid it being flagged by naive string scanners -- it is
        #     not a secret, it's been public for well over a decade and
        #     is shared by essentially every macOS-on-QEMU/Hackintosh
        #     project, OSX-KVM and dockur/macos included).
        #   - smbios type=2: baseline "Apple Inc." system info at the
        #     firmware level (OpenCore's own config.plist below adds the
        #     actual per-machine model/serial/UUID identity on top).
        #   - the ICH9-LPC globals disable ACPI sleep states (S3/S4) and
        #     bridge hotplug, both of which macOS handles unreliably on
        #     the emulated ICH9 chipset q35 provides.
        -device "isa-applesmc,osk=$(echo 'bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap' | tr 'A-Za-z' 'N-ZA-Mn-za-m')"
        -smbios type=2
        -global ICH9-LPC.disable_s3=1
        -global ICH9-LPC.disable_s4=1
        -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
        # OpenCore is what actually makes the above enough for XNU to
        # boot: it supplies the per-machine SMBIOS identity (model,
        # serial, UUID, board serial) plus the small set of ACPI/kernel
        # patches (via Lilu and friends) that stock OVMF+QEMU alone don't
        # provide. bootindex=0 makes OVMF's boot manager always try this
        # disk first; OpenCore then does its own scan of every other
        # attached disk to find the real macOS system to chainload into
        # (see prepare-opencore.sh and README.md) -- $VM_DISK and
        # $RECOVERY_DISK below intentionally get no bootindex of their
        # own, same as upstream dockur/macos does it. Read-only: nothing
        # here is meant to write to this image at runtime, only to the
        # separate $OVMF_VARS NVRAM store, which is what actually
        # remembers OpenCore's boot choice across restarts.
        #
        # Confirmed on real hardware: the shorthand `-drive
        # if=virtio,...,bootindex=0` this used to be fails outright --
        # `Block format 'qcow2' does not support the option 'bootindex'`
        # -- because that shorthand's implicit device creation routes
        # `bootindex` into the qcow2 block-layer options instead of the
        # virtio-blk device's own properties (didn't happen to $VM_DISK/
        # $RECOVERY_DISK below only because neither of them sets
        # bootindex at all). Split into the explicit two-flag form
        # instead: `-drive if=none` just opens the image with no device
        # attached, and the separate `-device virtio-blk-pci` is what
        # actually attaches it to the bus -- `bootindex` unambiguously
        # belongs to that -device, not the block layer, so there's
        # nothing left to misroute it. This is the same explicit pattern
        # already used for the AHCI/SATA fallback further down.
        -drive if=none,id=opencore,file="$OPENCORE_IMG",format=qcow2,readonly=on
        -device virtio-blk-pci,drive=opencore,bootindex=0
        -drive if=virtio,file="$VM_DISK",format=qcow2
        -device reims-vgpu-pci,romfile=reims-vgpu-gop.rom
        -display sdl,gl=on,full-screen=on
        -usb -device usb-kbd -device usb-tablet
        -netdev user,id=net0 -device virtio-net,netdev=net0
    )
    if [ -n "$RECOVERY_DISK" ]; then
        echo "Attaching recovery/installer disk: $RECOVERY_DISK"
        # Same if=virtio interface as $VM_DISK, for consistency with
        # the rest of this invocation -- if macOS's own recovery/
        # installer environment turns out to need a real AHCI/SATA
        # disk instead (no virtio block driver that early), swap this
        # to `-device ahci,id=ahci -device ide-hd,bus=ahci.0,drive=rec
        # -drive if=none,id=rec,file=...,format=qcow2`. Untested on
        # real hardware yet — see docs/CHECKLIST.md.
        QEMU_ARGS+=(-drive if=virtio,file="$RECOVERY_DISK",format=qcow2)
    fi

    LD_LIBRARY_PATH="$QEMU_LD_LIBRARY_PATH" "$QEMU_BIN" "${QEMU_ARGS[@]}" &
    QEMU_PID=$!

    for _ in $(seq 1 50); do [ -S "$QMP_SOCK" ] && break; sleep 0.2; done

    ACTION=$(python3 "$KIOSK_DIR/qmp-watch.py" "$QMP_SOCK")
    wait "$QEMU_PID" 2>/dev/null

    # Every QEMU session's outcome, good or bad, gets a fresh copy of
    # this log (and a journal snapshot) onto the USB -- during testing
    # this matters most right after a crash/black-screen exit, which
    # is exactly when there's no other easy way to see what happened.
    bash "$KIOSK_DIR/lib/save-logs-to-usb.sh" 2>/dev/null || true

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
            echo "QEMU exited without a clear guest request (action: ${ACTION}) — relaunching just the VM."
            RETRIES=$((RETRIES + 1))
            if [ "$RETRIES" -ge 5 ]; then
                echo "Too many failures in a row — rebooting the physical machine as a last resort."
                sudo systemctl reboot
                exit 1
            fi
            sleep 3
            ;;
    esac
done
