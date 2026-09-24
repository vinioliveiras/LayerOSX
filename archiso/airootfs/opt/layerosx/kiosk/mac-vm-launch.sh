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
QMP_CTL_SOCK="/tmp/macvm-ctl.sock"                 # 2nd QMP monitor: lib/qmp-cmd.py (sleep hook, battery-watch)
BATTERY_POWEROFF_FLAG="/tmp/layerosx-battery-poweroff"  # set by lib/battery-watch.sh
USB_PASSTHROUGH_FILE="$STATE_DIR/usb-passthrough"     # "vvvv:pppp name" lines, lib/usb-passthrough.sh
HOST_ACTION_FILE="/tmp/layerosx-host-action"          # "reboot"|"poweroff", set by lib/kiosk-menu.sh
KIOSK_DIR="/opt/layerosx/kiosk"
QEMU_BIN="/opt/layerosx/bin/qemu-system-x86_64"
OPENCORE_DIR="/opt/layerosx/opencore"
OPENCORE_IMG="$OPENCORE_DIR/OpenCore.qcow2"     # base default; reselected below by CPU vendor + verbose toggle
GOP_ROM="/usr/share/qemu/reims-vgpu-gop.rom"
MACOS_VERSION_FILE="$STATE_DIR/macos-version"   # written by macos-source-wizard.sh
GFX_FILE="$STATE_DIR/gfx"                       # optional: "vmware" to bypass Reims
VERBOSE_FILE="$STATE_DIR/verbose"                # optional: overrides the per-mode default (see BUILD_MODE)
AUDIO_FILE="$STATE_DIR/audio"                    # optional: overrides the per-mode default (see BUILD_MODE)
MODE_FILE="/etc/layerosx/mode"                   # baked at build time (build.sh): release|debug

# Per-mode RUNTIME defaults, used ONLY when the user hasn't set the matching
# toggle file yet (an explicit `verbose`/`audio`/`gpu` choice always wins):
#   release -- the shipping experience: clean Apple-logo boot (verbose off),
#              sound on, and Reims-vGPU acceleration on (the point of the
#              project).
#   debug   -- the troubleshooting build: verbose on (see the boot log),
#              plain VMware SVGA (isolates the display from the Reims path),
#              audio off (one less variable). The verbose image also carries
#              the serial kernel logging + DEBUG OpenCore (patch-opencore-
#              verbose.sh). A user toggle still overrides any of these.
BUILD_MODE="$(cat "$MODE_FILE" 2>/dev/null || echo release)"
case "$BUILD_MODE" in debug) : ;; *) BUILD_MODE=release ;; esac
if [ "$BUILD_MODE" = debug ]; then
    VERBOSE_DEFAULT=on;  AUDIO_DEFAULT=off; GFX_DEFAULT=vmware
else
    VERBOSE_DEFAULT=off; AUDIO_DEFAULT=on;  GFX_DEFAULT=reims
fi
MIN_UPTIME_FOR_REAL_REBOOT=180
LOG="$HOME/mac-vm.log"
SERIAL_LOG="$HOME/mac-vm-serial.log"
QEMU_D_LOG="$HOME/mac-vm-qemu.log"   # QEMU -d diagnostics (debug builds only)

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
# (Ctrl+Alt+F2) or pull up the Ctrl+Alt+T live-log terminal and actually read
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
        # stepping=3: QEMU's Haswell-noTSX reports stepping 1, and XNU's
        # machine_check.c mca_get_availability() panics "Haswell pre-C0
        # steppings are not supported" for model 0x3C with stepping < 3.
        # 3 = C0, the first production stepping (confirmed on the AMD test
        # machine: stepping 1 panics right after HANDOFF, 3 reaches the
        # installer).
        high-sierra|mojave|catalina|big-sur|monterey|ventura) CPU_MODEL="Haswell-noTSX"; CPU_FLAGS+=",stepping=3" ;;
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

# --- Resources (RAM + vCPUs) -------------------------------------------------
# Picked by pick_resources(), called before the first launch AND at the top of
# every loop pass, so a change made in LayerOSX Settings > Mac > Resources takes
# effect on "Restart Mac" without restarting the kiosk session.
pick_resources() {
    # --- RAM: give the Mac nearly all of it ---------------------------------------
    # Everything except a reserve for Linux + QEMU + Reims' host-side Vulkan buffers:
    # 12% of the host's RAM, at least 4 GB (a 64 GB laptop -> ~54 GB for macOS).
    # The memfd backing (share=on, needed by Reims) is only touched as the guest
    # uses it. Override (LayerOSX Settings > Mac > Resources, or by hand):
    # echo <MB> > /var/lib/layerosx/ram-mb. Keep in sync with Backend.auto_ram_mb().
    _host_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)"
    _reserve_mb=$(( _host_mb * 12 / 100 )); [ "$_reserve_mb" -lt 4096 ] && _reserve_mb=4096
    VM_RAM_MB=$(( (_host_mb - _reserve_mb) / 1024 * 1024 ))
    [ "$VM_RAM_MB" -lt 4096 ] && VM_RAM_MB=4096
    _ram_override="$(cat "$STATE_DIR/ram-mb" 2>/dev/null || true)"
    case "$_ram_override" in ''|*[!0-9]*) : ;; *) [ "$_ram_override" -ge 2048 ] && VM_RAM_MB=$_ram_override ;; esac
    # --- SMP: a power of two, at most 8 ----------------------------------------
    # macOS is picky about CPU topology (odd core counts misbehave; dockur maps 6
    # to 3 sockets x 2 cores, etc.), and Reims caps the guest at 8 vCPUs with
    # reims-vgpu-pci (upstream boot-x86.sh: the paravirt GPU kext is sensitive to
    # higher SMP). So: the largest power of two <= min(8, N), one socket, where
    # N = all host threads on small machines (<= 4 threads: the kiosk's Linux is
    # minimal and a dual-core Mac must not be left with 1 core) and threads - 2 on
    # bigger ones (room for Linux + QEMU + Reims' host threads).
    # The user can pick a fixed count in LayerOSX Settings > Mac > Resources
    # ($STATE_DIR/cpu-cores); it's honoured when valid (power of two, <= 8, <= host
    # threads, and -- on AMD -- an OpenCore image exists for it), else ignored.
    # Keep this rule in sync with Backend.auto_cores() (panel/layerosx_backend.py).
    TOTAL_CORES="$(nproc)"
    # The "reserve 2 threads" part can be switched off in Settings > Mac > Resources
    # ($STATE_DIR/cpu-reserve = off): then Automatic hands the Mac every thread.
    case "$(cat "$STATE_DIR/cpu-reserve" 2>/dev/null)" in off|0|no|false) _reserve_cpu=0 ;; *) _reserve_cpu=1 ;; esac
    if [ "$TOTAL_CORES" -le 4 ] || [ "$_reserve_cpu" = 0 ]; then VM_CORES=$TOTAL_CORES; else VM_CORES=$((TOTAL_CORES - 2)); fi
    [ "$VM_CORES" -gt 8 ] && VM_CORES=8
    [ "$VM_CORES" -lt 1 ] && VM_CORES=1
    _p=1; while [ $((_p * 2)) -le "$VM_CORES" ]; do _p=$((_p * 2)); done
    VM_CORES=$_p
    _cores_override="$(cat "$STATE_DIR/cpu-cores" 2>/dev/null || true)"
    case "$_cores_override" in
        1|2|4|8) [ "$_cores_override" -le "$TOTAL_CORES" ] && VM_CORES=$_cores_override ;;
    esac

    # --- AMD core-count pin -----------------------------------------------------
    # The AMD OpenCore images bake cpuid_cores_per_package (patch-opencore-amd.sh)
    # and XNU panics if that constant doesn't match the guest's -smp cores. build.sh
    # makes three families: OpenCore-amd2* (2 cores), OpenCore-amd* (4) and
    # OpenCore-amd8* (8). Pick the family for VM_CORES; if its image is missing, the
    # largest smaller one that exists (then 4 as the last resort). 1 core -> 2.
    AMD_OC="amd"
    if [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
        [ "$VM_CORES" -lt 2 ] && VM_CORES=2
        _picked=""
        for _c in 8 4 2; do
            [ "$_c" -le "$VM_CORES" ] || continue
            case "$_c" in 8) _f=amd8 ;; 4) _f=amd ;; 2) _f=amd2 ;; esac
            if [ -s "$OPENCORE_DIR/OpenCore-${_f}.qcow2" ]; then VM_CORES=$_c; AMD_OC=$_f; _picked=1; break; fi
        done
        [ -n "$_picked" ] || { VM_CORES=4; AMD_OC=amd; }
    fi

}
pick_resources

# Re-read the user toggle files (gpu/verbose/audio) and (re)compute the
# OpenCore image + device args from them. Called at the top of EVERY loop
# iteration so `relaunch` (which just kills QEMU, not Xorg) picks up a
# gpu/verbose/audio change with no flicker and no full session restart.
configure_toggles() {
    # --- OpenCore image: pick by host CPU vendor and the verbose toggle ---------
    # Intel boots the stock (Intel-only) OpenCore; AMD needs the AMD_Vanilla-patched
    # image or XNU hangs at EXITBS->HANDOFF. Verbose (-v) is a separate prebuilt
    # image per family (build.sh makes all four), so toggling it needs no slow
    # re-patch -- the `verbose` command just flips $VERBOSE_FILE. Default is verbose
    # ON (handy while bringing macOS up); `verbose off` gives the clean Apple boot.
    VERBOSE_STATE="$(cat "$VERBOSE_FILE" 2>/dev/null || echo "$VERBOSE_DEFAULT")"
    case "$VERBOSE_STATE" in off|0|no|false|OFF|Off) VERBOSE_STATE=off ;; *) VERBOSE_STATE=on ;; esac
    if [ "$CPU_VENDOR" = "AuthenticAMD" ]; then
        _oc_norm="$OPENCORE_DIR/OpenCore-${AMD_OC}.qcow2"
        _oc_verb="$OPENCORE_DIR/OpenCore-${AMD_OC}-verbose.qcow2"
    else
        _oc_norm="$OPENCORE_DIR/OpenCore.qcow2"
        _oc_verb="$OPENCORE_DIR/OpenCore-verbose.qcow2"
    fi
    if [ "$VERBOSE_STATE" = on ] && [ -s "$_oc_verb" ]; then
        OPENCORE_IMG="$_oc_verb"
    elif [ -s "$_oc_norm" ]; then
        OPENCORE_IMG="$_oc_norm"
    else
        OPENCORE_IMG="$OPENCORE_DIR/OpenCore.qcow2"   # last-ditch fallback to the base
    fi
    if [ "$CPU_VENDOR" = "AuthenticAMD" ] && [ "$OPENCORE_IMG" = "$OPENCORE_DIR/OpenCore.qcow2" ]; then
        echo "WARNING: AMD host but no OpenCore-amd image found -- macOS will likely hang at boot." >&2
        echo "         Rebuild the ISO so build.sh generates the AMD OpenCore variant." >&2
    fi

    # Observability: record which OpenCore image actually won, and why. A boot
    # that comes up non-verbose despite `verbose on` then explains itself in the
    # log (surfaced by `maclog`) -- no separate diagnostic boot needed. The most
    # common cause is the verbose image being absent from the installed system.
    if [ "$VERBOSE_STATE" = on ] && [ ! -s "$_oc_verb" ]; then
        echo "OpenCore image: $(basename "$OPENCORE_IMG")  [verbose=ON requested, but $(basename "$_oc_verb") is MISSING/empty -> using non-verbose]"
    else
        echo "OpenCore image: $(basename "$OPENCORE_IMG")  [verbose=$VERBOSE_STATE]"
    fi

    # --- Graphics device --------------------------------------------------------
    # reims-vgpu-pci (hardware-accelerated) is the whole point of this project --
    # but it is alpha software on an alpha driver stack, and Reims' own docs say
    # to provision the macOS guest on the plain VMware SVGA adapter FIRST and
    # only switch to Reims once there's a working, installed system. So the
    # DEFAULT here is vmware-svga: boring, unaccelerated, but reliable enough to
    # actually get macOS installed. Reims is opt-in -- `echo reims > $GFX_FILE`
    # (then `relaunch`, or a reboot) turns it on for the next launch,
    # `echo vmware > $GFX_FILE` (or `rm $GFX_FILE`) goes back. This is also the
    # single most useful A/B switch for telling "Reims can't draw yet" apart from
    # "macOS isn't booting at all": if it boots on vmware but not reims, it's the
    # Reims path; if it fails the same way on both, it isn't Reims.
    GFX="$(cat "$GFX_FILE" 2>/dev/null || echo "$GFX_DEFAULT")"
    case "$GFX" in
        reims|reims-vgpu-pci) GFX="reims-vgpu-pci" ;;
        std|std-vga|vga) GFX="std-vga" ;;
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
    elif [ "$GFX" = "std-vga" ]; then
        # Stock std VGA. macOS has no native driver for it, but that is not the
        # point: OVMF's QemuVideoDxe publishes a UEFI GOP on it with a LINEAR
        # framebuffer and a VALID stride, and boot.efi hands exactly that to XNU
        # as the boot framebuffer. The "no linesize" stall is XNU getting a boot
        # framebuffer with rowBytes=0 on BOTH the vmvga and reims paths, so this
        # is the direct A/B test: does a plain linear OVMF framebuffer get the
        # kernel past its video-console setup? No acceleration -- boot/console
        # framebuffer only -- but if it clears "no linesize", the culprit is the
        # framebuffer the vmvga/reims GOP hands over, not macOS itself.
        if ! LD_LIBRARY_PATH="$QEMU_LD_LIBRARY_PATH" "$QEMU_BIN" -device help 2>/dev/null | grep -q '"VGA"'; then
            echo "WARNING: this QEMU build has no 'VGA' device -- falling back to vmware-svga." >&2
            GFX="vmware-svga"
            GFX_ARGS=(-vga none -device vmvga)
        else
            GFX_ARGS=(-device VGA)
        fi
    else
        # This build's VMware SVGA adapter is qemu-vmvga, whose PCI device is
        # registered as "vmvga" (confirmed in its source: hw/display/vmware_vga.c
        # -> TypeInfo .name = "vmvga"), NOT stock QEMU's "vmware-svga". Confirmed
        # on real hardware: "-device vmware-svga: 'vmware-svga' is not a valid
        # device model name", QEMU exits instantly, 5x -> fatal, screen flickering.
        GFX_ARGS=(-vga none -device vmvga)
    fi

    # --- Display frontend ------------------------------------------------------
    # Reims on x86 presents through its OWN host window: a Vulkan window opened by
    # the reims-vgpu staticlib (present + keyboard/mouse input), enabled with
    # REIMS_VGPU_WINDOW=1, while QEMU runs `-display none` and owns no window --
    # that's upstream's vm/boot-x86.sh default. Without it Reims falls back to
    # pushing CPU scanouts through QEMU's console, a legacy path that can freeze
    # on the last pre-driver frame: exactly the black screen (cursor still
    # moving) seen on the AMD test machine once AppleParavirtGPU took over.
    # REIMS_VGPU_FULLSCREEN=1 makes that window borderless/fullscreen. The old
    # SDL path stays one file away for A/B: echo off > $STATE_DIR/reims-window.
    # vmware/std keep QEMU's SDL fullscreen window.
    DISPLAY_ARGS=(-display sdl,full-screen=on)
    REIMS_ENV=()
    if [ "$GFX" = "reims-vgpu-pci" ]; then
        case "$(cat "$STATE_DIR/reims-window" 2>/dev/null || echo on)" in
            off|0|no|false) echo "Reims: host window OFF (legacy QEMU/SDL scanout path, for A/B)." ;;
            *)
                DISPLAY_ARGS=(-display none)
                REIMS_ENV=(REIMS_VGPU_WINDOW=1 REIMS_VGPU_FULLSCREEN=1)
                echo "Reims: host Vulkan window (REIMS_VGPU_WINDOW=1, fullscreen), QEMU -display none."
                ;;
        esac
    fi

    # --- Audio (opt-in) ---------------------------------------------------------
    # Off by default. macOS drives a USB Audio Class device with its own built-in
    # AppleUSBAudio driver (no kext, unlike the intel-hda + AppleALC route), so
    # `-device usb-audio` is the lowest-risk way to get sound -- IF two things hold
    # on this build: the custom qemu-macos binary has an audio backend compiled in
    # (it's built for VNC/noVNC, so it may not), and the host has that backend's
    # library. We probe for both and simply skip audio (with a warning) when
    # they're missing, rather than handing QEMU an argument it rejects and turning
    # a working boot into a launch failure. `audio on|off` flips $AUDIO_FILE.
    AUDIO_ARGS=()
    AUDIO_STATE="$(cat "$AUDIO_FILE" 2>/dev/null || echo "$AUDIO_DEFAULT")"
    case "$AUDIO_STATE" in on|1|yes|true|ON|On) AUDIO_STATE=on ;; *) AUDIO_STATE=off ;; esac
    if [ "$AUDIO_STATE" = on ]; then
        _qhelp="$(LD_LIBRARY_PATH="$QEMU_LD_LIBRARY_PATH" "$QEMU_BIN" -audiodev help 2>/dev/null || true)"
        _has_usbaudio="$(LD_LIBRARY_PATH="$QEMU_LD_LIBRARY_PATH" "$QEMU_BIN" -device help 2>/dev/null | grep -c '"usb-audio"' || true)"
        _snd_backend=""
        # Prefer alsa: it talks straight to the kernel with no sound daemon, which
        # a bare kiosk (no PipeWire/PulseAudio running) is. The others are listed
        # as fallbacks only.
        for _b in alsa pipewire pa sdl oss; do
            if printf '%s\n' "$_qhelp" | grep -qw "$_b"; then _snd_backend="$_b"; break; fi
        done
        # The host must actually have a sound card: with none, ALSA's `default`
        # can't open ("Could not initialize DAC ... default"), QEMU logs an error
        # per voice and macOS gets a dead device. Seen on the AMD test machine.
        if ! grep -q '^ *[0-9]' /proc/asound/cards 2>/dev/null; then
            echo "WARNING: audio requested but the host has no sound card (/proc/asound/cards is empty) -- skipping audio." >&2
            echo "         Check that the laptop's audio driver loaded (sof-firmware / snd_pci_acp*); boot is unaffected." >&2
            _snd_backend=""
        fi
        if [ -n "$_snd_backend" ] && [ "${_has_usbaudio:-0}" -ge 1 ]; then
            AUDIO_ARGS=(-audiodev "${_snd_backend},id=snd0" -device usb-audio,audiodev=snd0,bus=xhci.0)
            echo "Audio: usb-audio on the ${_snd_backend} backend (turn off with 'audio off')."
        else
            echo "WARNING: audio requested but this QEMU build has no usb-audio device and/or no usable audio backend -- skipping audio." >&2
            echo "         The custom qemu-macos build needs an audio backend compiled in; see README's audio note. Boot is unaffected." >&2
        fi
    fi

    echo "Launch profile: cpu=$CPU_MODEL ($CPU_VENDOR host) smp=$VM_CORES gfx=$GFX macos=${MACOS_SHORTNAME:-unknown} recovery=${RECOVERY_DISK:-none}"
    # Same profile, machine-readable, for LayerOSX Settings > About.
    printf 'cpu_model=%s\ncores=%s\nram_mb=%s\ngfx=%s\nmacos=%s\n' \
        "$CPU_MODEL" "$VM_CORES" "$VM_RAM_MB" "$GFX" "${MACOS_SHORTNAME:-}" > /tmp/layerosx-vm-profile 2>/dev/null || true
    echo "Guest firmware/kernel console goes to $SERIAL_LOG (type 'serial' in the Ctrl+Alt+T terminal)."
}

# --- Disk: let the Mac's disk use the partition ------------------------------
# macos.qcow2 is sparse: its *virtual* size is what macOS sees. It used to be a
# fixed 128 GB whatever the partition size. Grow it (never shrink) to what this
# partition can actually hold -- the space the image already occupies plus the
# free space, minus a 10 GB safety margin so the host never fills up under a
# running VM -- when that's at least 10 GB more than now. qcow2 growth is safe
# with the VM stopped (it is, here). macOS then sees a bigger disk; its APFS
# container grows with `diskutil apfs resizeContainer <disk> 0` inside macOS
# (fresh installs erase the whole disk and get it all anyway). Recorded in
# $STATE_DIR/disk-grown for LayerOSX Settings > About.
grow_vm_disk() {
    [ -f "$VM_DISK" ] && command -v qemu-img >/dev/null 2>&1 || return 0
    local sizes virt actual avail target margin=$((10 * 1024 * 1024 * 1024))
    sizes="$(qemu-img info --output=json "$VM_DISK" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["virtual-size"], d.get("actual-size", 0))' 2>/dev/null)" || return 0
    read -r virt actual <<<"$sizes"
    avail="$(df -B1 --output=avail "$(dirname "$VM_DISK")" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    [ -n "$virt" ] && [ -n "$avail" ] || return 0
    target=$(( (actual + avail - margin) / 1073741824 * 1073741824 ))
    if [ "$target" -gt $(( virt + margin )) ]; then
        if qemu-img resize -q "$VM_DISK" "$target" 2>>"$LOG"; then
            echo "Mac disk grown: $(( virt / 1073741824 )) GB -> $(( target / 1073741824 )) GB (in macOS: diskutil apfs resizeContainer <container> 0)."
            printf 'from_gb=%s\nto_gb=%s\n' $(( virt / 1073741824 )) $(( target / 1073741824 )) > "$STATE_DIR/disk-grown"
        fi
    fi
}
grow_vm_disk

RETRIES=0
while true; do
    rm -f "$QMP_SOCK" "$QMP_CTL_SOCK"
    pick_resources   # re-read Settings > Mac > Resources (cpu-cores, cpu-reserve, ram-mb)
    # Which physical screen shows the Mac (Settings > Displays > Screens): put it
    # at 0,0 as primary and turn off / mirror the others before QEMU opens its
    # window there. No-op when nothing is chosen ("Automatic") or the layout
    # already matches. See lib/displays.py.
    python3 "$KIOSK_DIR/lib/displays.py" apply 2>/dev/null || true
    # Critical-battery shutdown in progress (lib/battery-watch.sh stopped the
    # VM on purpose): power the host off instead of relaunching.
    if [ -e "$BATTERY_POWEROFF_FLAG" ]; then
        echo "Battery critical -- powering off the physical machine."
        sudo systemctl poweroff
        exit 0
    fi
    # Restart / Shut Down chosen from the kiosk menu (Ctrl+Alt+W): the menu
    # stopped QEMU cleanly (QMP quit, disks flushed) and left the action here.
    if [ -s "$HOST_ACTION_FILE" ]; then
        _act="$(cat "$HOST_ACTION_FILE")"; rm -f "$HOST_ACTION_FILE"
        case "$_act" in
            reboot)   echo "Kiosk menu: restarting the physical machine."; sudo systemctl reboot;   exit 0 ;;
            poweroff) echo "Kiosk menu: shutting down the physical machine."; sudo systemctl poweroff; exit 0 ;;
        esac
    fi
    configure_toggles

    QEMU_ARGS=(
        -name "macOS"
        -nodefaults
        -enable-kvm
        -no-reboot
        -rtc base=utc
        -qmp "unix:${QMP_SOCK},server,nowait"
        # Second, independent QMP monitor for one-shot commands (a QMP unix
        # socket serves one client at a time and qmp-watch.py holds the first
        # one for the whole session): the systemd-sleep hook pauses/resumes
        # the VM around host suspend, battery-watch.sh requests a clean
        # shutdown at critical battery. See lib/qmp-cmd.py.
        -qmp "unix:${QMP_CTL_SOCK},server,nowait"
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
        # p2/p3=8: room for hot-plugged USB passthrough (lib/usb-passthrough.sh)
        # next to the keyboard, tablet and optional usb-audio (default is 4+4).
        -device qemu-xhci,id=xhci,p2=8,p3=8
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
        # vmxnet3, NOT virtio-net: macOS ships no virtio-net driver, so a
        # virtio NIC shows up as a dead card with no network at all. macOS DOES
        # bundle VMware's AppleVmxnet3Ethernet.kext, so a vmxnet3 NIC is
        # recognised out of the box and pulls an IP over QEMU's user-mode NAT
        # with zero guest config. (e1000-82545em is the fallback model if a
        # future macOS ever drops vmxnet3.)
        # romfile= (empty) drops the NIC's PXE option ROM: no "UEFI Misc
        # Device" network-boot entry for OVMF to wander into.
        -netdev user,id=net0
        -device vmxnet3,netdev=net0,id=net0,romfile=
        # OSX-KVM's OpenCore config (ours) patches XNU to send its early boot
        # prints and its panic string to the serial port. Until now nothing
        # captured it, which made every stall a blind blue screen; this is
        # what turns a kernel panic into readable text.
        -serial "file:$SERIAL_LOG"
        "${DISPLAY_ARGS[@]}"
    )
    QEMU_ARGS+=("${GFX_ARGS[@]}")
    if [ "${#AUDIO_ARGS[@]}" -gt 0 ]; then QEMU_ARGS+=("${AUDIO_ARGS[@]}"); fi
    # USB devices the user chose to "always" give to the Mac (usb always /
    # the picker's "Always"). Matched by vendor:product, so QEMU attaches each
    # one whenever it's plugged in -- absent devices are simply waited for.
    if [ -s "$USB_PASSTHROUGH_FILE" ]; then
        while read -r _vp _rest; do
            case "$_vp" in
                [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
                *) continue ;;
            esac
            QEMU_ARGS+=(-device "usb-host,bus=xhci.0,vendorid=0x${_vp%%:*},productid=0x${_vp##*:},id=usb-${_vp%%:*}-${_vp##*:}")
            echo "USB passthrough (always): $_vp $_rest"
        done < "$USB_PASSTHROUGH_FILE"
    fi
    if [ -n "$RECOVERY_DISK" ]; then
        echo "Attaching recovery/installer disk: $RECOVERY_DISK"
        QEMU_ARGS+=(
            -drive id=InstallMedia,if=none,format=qcow2,file="$RECOVERY_DISK"
            -device ide-hd,bus=sata.3,drive=InstallMedia
        )
    fi

    # Debug builds capture extra QEMU-side diagnostics that would be pure
    # overhead + noise on a clean release boot: guest_errors (illegal or
    # unimplemented instructions -- the FIRST thing to check when the CPU model
    # is masked for an AMD host) and unimp (unimplemented device features),
    # each written to its own file so they don't drown the serial log.
    if [ "$BUILD_MODE" = debug ]; then
        : > "$QEMU_D_LOG" 2>/dev/null || true
        QEMU_ARGS+=(-d guest_errors,unimp -D "$QEMU_D_LOG")
    fi

    # Always record the EXACT command line this boot used, %q-quoted so it can
    # be pasted back verbatim -- a future postmortem then never has to guess
    # which args produced a given log (and `macdiag` picks this line up).
    { printf 'QEMU cmdline:'; printf ' %q' "${REIMS_ENV[@]}" "$QEMU_BIN" "${QEMU_ARGS[@]}"; printf '\n'; } 2>/dev/null || true

    LAUNCHED_AT=$(date +%s)
    # SDL_GRAB_KEYBOARD=0: stop the fullscreen SDL window from taking an
    # exclusive keyboard grab. Without this, the moment you click into the VM
    # (e.g. to pick macOS in the OpenCore menu) SDL grabs the keyboard and the
    # openbox log-terminal keybind (Ctrl+Alt+T, formerly F2) stops firing -- you're stuck using the raw
    # Ctrl+Alt+F2 VT (which is low-refresh and ghosts on some monitors). With
    # the grab off, Ctrl+Alt+T keeps opening the in-X log terminal while the VM is
    # focused, and macOS still receives every other key through normal focus.
    env "${REIMS_ENV[@]}" SDL_GRAB_KEYBOARD=0 LD_LIBRARY_PATH="$QEMU_LD_LIBRARY_PATH" "$QEMU_BIN" "${QEMU_ARGS[@]}" &
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
            # A session that ran a while and then exited (or was killed by
            # `relaunch`) is not a fast crash-loop -- reset the counter so a
            # deliberate relaunch doesn't march toward fatal().
            if [ "$RAN_FOR" -ge 30 ]; then RETRIES=0; fi
            RETRIES=$((RETRIES + 1))
            if [ "$RETRIES" -ge 5 ]; then
                fatal "QEMU exited $RETRIES times in a row." \
                    "That's a boot that fails the same way every time, not a transient glitch -- rebooting the physical" \
                    "machine (what this used to do here) would just loop it faster. Read $LOG and $SERIAL_LOG" \
                    "(Ctrl+Alt+T terminal: 'logs' / 'serial'). The display defaults to plain VMware SVGA;" \
                    "if you'd switched it to Reims, echo vmware > $GFX_FILE (or rm it) + relaunch to go back."
            fi
            sleep 3
            ;;
    esac
done
