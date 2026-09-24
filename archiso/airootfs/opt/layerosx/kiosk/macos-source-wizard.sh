#!/usr/bin/env bash
# First-run wizard: runs a single time, before any VM exists. Asks
# where macOS should come from and prepares $1 (VM disk) + $2
# (NVRAM/OVMF_VARS) for mac-vm-launch.sh to boot.
set -uo pipefail

VM_DISK="$1"
OVMF_VARS="$2"
# Which macOS the "download from Apple" path fetched -- mac-vm-launch.sh
# reads this to pick a CPU model the guest will accept (see there).
MACOS_VERSION_FILE="$(dirname "$VM_DISK")/macos-version"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# The Mac's disk: as big as this partition allows (it's a sparse qcow2 -- it only
# takes real space as macOS fills it), leaving 20 GB for the recovery/installer
# image and a safety margin; at least 64 GB. MAC_VM_SIZE_GB overrides.
_avail_gb="$(df -BG --output=avail "$(dirname "$VM_DISK")" 2>/dev/null | tail -n1 | tr -dc '0-9')"
_auto_gb=$(( ${_avail_gb:-148} - 20 )); [ "$_auto_gb" -lt 64 ] && _auto_gb=64
VM_SIZE_GB="${MAC_VM_SIZE_GB:-$_auto_gb}"

# A failed attempt here used to leave the user permanently stuck on a
# black screen: qemu-img create below makes $VM_DISK before the step
# that can actually fail (download/conversion), and mac-vm-launch.sh
# only shows this wizard again when $VM_DISK doesn't exist yet -- so
# an empty/partial $VM_DISK left behind by a failed attempt silently
# hid the "pick where macOS comes from" screen forever, even across a
# full reboot, with no obvious way back in. This cleans up any
# partial output whenever the wizard exits non-zero (any zenity
# --error + exit 1 path below, or an unhandled crash) so the next
# boot shows the options again instead of a black screen.
cleanup_failed_attempt() {
    local ec=$?
    if [ "$ec" -ne 0 ]; then
        echo "Wizard failed (exit $ec) -- removing any partial VM disk so the options are shown again on the next boot instead of a stuck black screen." >&2
        rm -f "$VM_DISK" "${VM_DISK%.qcow2}-recovery.qcow2" "${VM_DISK%.qcow2}-installer.qcow2" "$OVMF_VARS" "$MACOS_VERSION_FILE" "$(dirname "$VM_DISK")/downloaded-version" 2>/dev/null || true
    fi
}
trap cleanup_failed_attempt EXIT

# has_internet / ensure_internet (zenity network picker, nmtui kept
# as an "Advanced" fallback) live in here now -- shared with anything
# else that ever needs a connectivity check/Wi-Fi picker.
source "$LIB_DIR/wifi-setup.sh"

# Everything this script (and whatever it calls) prints to
# stdout/stderr is already flowing into ~/mac-vm.log -- mac-vm-launch.sh
# (the parent process) redirects its own output there before running
# this script as a regular subprocess, and a plain subprocess
# inherits its parent's already-redirected file descriptors. So
# there's no separate log file to manage here: Ctrl+Alt+T (see
# lib/install-f2-keybind.sh, wired up from .xinitrc) already tails
# that exact file, and it already has everything.
#
# Runs a command with a zenity progress dialog instead of a visible
# terminal -- a download or a disk-image conversion can take a
# while, and used to just open an xterm running the command directly
# (correct, but exactly the kind of raw-terminal-by-default the
# install experience is trying to get away from -- see README.md).
# Real percentage isn't available for every command here
# (fetch-macOS-v2.py's download and dmg2img's extraction don't print
# anything reliably parseable), so this pulsates rather than guessing
# -- still far better than a black screen, and Ctrl+Alt+T opens a terminal
# tailing the exact same output live for anyone who wants to see it.
run_with_progress() {
    local title="$1" text="$2"
    shift 2

    echo "----- $text -----"

    local fifo
    fifo=$(mktemp -u /tmp/layerosx-wizard-progress.XXXXXX)
    mkfifo "$fifo"
    zenity --progress --pulsate --no-cancel --auto-close \
        --title="$title" --text="$text" --width=520 \
        < "$fifo" 2>/dev/null &
    local zpid=$!
    exec 4>"$fifo"
    rm -f "$fifo"

    "$@"
    local rc=$?

    printf '100\n' >&4
    exec 4>&-
    wait "$zpid" 2>/dev/null || true
    return "$rc"
}

# Same idea, but for the one case where a real percentage IS easy to
# get: `qemu-img convert -p` prints its own progress, and this is a
# conversion we invoke directly (not buried inside another script),
# so it's simple to parse live -- same FIFO pattern install-wizard.sh
# uses for rsync's progress.
run_convert_with_progress() {
    # $5 (optional) is the qemu-img source format. Empty = let qemu-img
    # autodetect (safe for container formats with a magic header: qcow2,
    # vmdk, vdi, vpc/vhd, vhdx). Callers pass "raw" explicitly for formats
    # with NO header (a plain disk image, an .iso), where autodetect would
    # guess wrong.
    local title="$1" text="$2" src="$3" dst="$4" src_format="${5:-}"

    echo "----- $text -----"

    local fifo
    fifo=$(mktemp -u /tmp/layerosx-wizard-progress.XXXXXX)
    mkfifo "$fifo"
    zenity --progress --no-cancel --auto-close \
        --title="$title" --text="$text" --width=520 \
        < "$fifo" 2>/dev/null &
    local zpid=$!
    exec 4>"$fifo"
    rm -f "$fifo"

    local _cargs=(convert -p)
    [ -n "$src_format" ] && _cargs+=(-f "$src_format")
    _cargs+=(-O qcow2 "$src" "$dst")
    qemu-img "${_cargs[@]}" 2>&1 | \
        stdbuf -oL tr '\r' '\n' | stdbuf -oL grep --line-buffered -oE '[0-9]{1,3}(\.[0-9]+)?%' | \
        while IFS= read -r raw; do
            raw="${raw%\%}"; raw="${raw%.*}"
            printf '%s\n' "$raw" >&4
            printf '#%s (%s%%)\n' "$text" "$raw" >&4
        done
    local rc=${PIPESTATUS[0]}

    printf '100\n' >&4
    exec 4>&-
    wait "$zpid" 2>/dev/null || true
    return "$rc"
}

# Real progress bar for the "download from Apple" path. fetch-macOS-v2.py DOES
# print a live percentage ("<MB>/<MB> MB |=== | 42.3% downloaded", carriage-
# return updated) -- the earlier note that its download "isn't reliably
# parseable" was wrong. Parse that into a real zenity percentage instead of a
# pulsating guess. The download maps to 0-95% of the bar; the verify + dmg2img
# + qemu-img phases that follow emit no parseable %, so the label switches and
# the bar holds at 95 until the whole command returns (closed at 100). Every
# line is still echoed, so the Ctrl+Alt+T live log tail stays complete.
run_download_with_progress() {
    local title="$1" text="$2"
    shift 2

    echo "----- $text -----"

    local fifo
    fifo=$(mktemp -u /tmp/layerosx-wizard-progress.XXXXXX)
    mkfifo "$fifo"
    zenity --progress --no-cancel --auto-close \
        --title="$title" --text="$text" --width=520 \
        < "$fifo" 2>/dev/null &
    local zpid=$!
    exec 4>"$fifo"
    rm -f "$fifo"

    "$@" 2>&1 | stdbuf -oL tr '\r' '\n' | while IFS= read -r line; do
        printf '%s\n' "$line"                 # keep the raw log intact (Ctrl+Alt+T terminal)
        case "$line" in
            *"% downloaded"*)
                # ".../ 650.0 MB |== | 42.3% downloaded" -> "42"
                local pct="${line%% downloaded*}"
                pct="${pct##* }"; pct="${pct%\%}"; pct="${pct%.*}"
                case "$pct" in
                    ''|*[!0-9]*) : ;;
                    *) printf '%s\n' "$(( pct * 95 / 100 ))" >&4
                       printf '#%s  (%s%%)\n' "$text" "$pct" >&4 ;;
                esac
                ;;
            *"Download complete"*)
                printf '95\n' >&4
                printf '#Verifying and preparing the image…\n' >&4 ;;
            *"Verifying image"*)
                printf '#Verifying downloaded image…\n' >&4 ;;
        esac
    done
    local rc=${PIPESTATUS[0]}

    printf '100\n' >&4
    exec 4>&-
    wait "$zpid" 2>/dev/null || true
    return "$rc"
}

# Confirmed on real hardware: this used to point at
# /usr/share/edk2-ovmf/x64/OVMF_VARS.fd, which doesn't exist --
# Arch's edk2-ovmf package actually installs to /usr/share/edk2/x64/
# (not .../edk2-ovmf/x64/), and the files themselves are named
# OVMF_CODE.4m.fd / OVMF_VARS.4m.fd (the "4m" 4MiB-flash variant), not
# the plain names assumed here. This `cp` failing was silent (no
# `set -e` in this script) -- it printed an error and just kept going
# straight into an 800MB+ download that was doomed from the start,
# since mac-vm-launch.sh's own OVMF_CODE.fd reference was equally
# wrong (fixed there too, see README.md). Centralized into one
# function that actually fails loudly instead, so a future path
# change like this doesn't waste a download again before anyone
# notices.
copy_ovmf_vars() {
    if ! cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$OVMF_VARS"; then
        zenity --error --width=520 --title="LayerOSX — first run" \
            --text="Couldn't find the OVMF firmware (edk2-ovmf package) at the expected path -- this is a LayerOSX bug, not something wrong with your setup. Please report it." \
            2>/dev/null || true
        exit 1
    fi
}

# No udisks2/gvfs automount daemon on this minimal kiosk, so a USB
# drive plugged in with the file on it is otherwise completely
# invisible to zenity's file-selection dialog -- mount whatever's
# there first so it's actually browsable.
bash "$LIB_DIR/mount-removable-media.sh" 2>/dev/null || true

# Kept short on purpose: zenity sizes this list's horizontal scroll
# area off the actual text width, not --width -- the old, more
# verbose second option ("I already have macOS (VM disk, installer
# .dmg, or recovery/installer .iso) — pick a file") overflowed it and
# forced a horizontal scrollbar, cutting the row off mid-sentence on
# real hardware. The full list of accepted extensions is still shown
# one screen later, right on the file-picker itself.
CHOICE=$(zenity --list --radiolist --width=620 --height=280 \
    --title="LayerOSX — first run" \
    --text="Where should macOS come from? (only asked once)" \
    --column="" --column="Option" \
    TRUE  "Download the recovery image directly from Apple (recommended)" \
    FALSE "I already have macOS — pick a file (VM disk, .dmg, or .iso)")

[ -n "$CHOICE" ] || exit 1

case "$CHOICE" in
    *recommended*)
        # fetch-macOS-v2.py (see lib/fetch-recovery.sh) supports picking
        # a specific macOS version via its own hardcoded product list
        # (-s/--shortname) -- Apple's real recovery servers still serve
        # every one of these, tied to a real Mac board-id, same as any
        # actual Mac asking for network recovery. Ventura is marked
        # recommended here specifically because that's what Reims-vGPU's
        # own README recommends for initial testing (its alpha-stage
        # driver is most tested against it) -- not the same thing as
        # "most recent", which is why this needed its own picker instead
        # of just always grabbing whatever's newest.
        MACOS_VERSION=$(zenity --list --radiolist --width=620 --height=380 \
            --title="LayerOSX — first run" \
            --text="Which macOS version?" \
            --column="" --column="Version" \
            FALSE "High Sierra (10.13)" \
            FALSE "Mojave (10.14)" \
            FALSE "Catalina (10.15)" \
            FALSE "Big Sur (11)" \
            FALSE "Monterey (12)" \
            TRUE  "Ventura (13) — recommended for this project" \
            FALSE "Sonoma (14)" \
            FALSE "Sequoia (15)" \
            FALSE "Tahoe (26)")
        [ -n "$MACOS_VERSION" ] || exit 1
        case "$MACOS_VERSION" in
            *"High Sierra"*) MACOS_SHORTNAME=high-sierra ;;
            *Mojave*)        MACOS_SHORTNAME=mojave ;;
            *Catalina*)      MACOS_SHORTNAME=catalina ;;
            *"Big Sur"*)     MACOS_SHORTNAME=big-sur ;;
            *Monterey*)      MACOS_SHORTNAME=monterey ;;
            *Ventura*)       MACOS_SHORTNAME=ventura ;;
            *Sonoma*)        MACOS_SHORTNAME=sonoma ;;
            *Sequoia*)       MACOS_SHORTNAME=sequoia ;;
            *Tahoe*)         MACOS_SHORTNAME=tahoe ;;
            *)               MACOS_SHORTNAME="" ;;
        esac

        ensure_internet || exit 1
        qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
        copy_ovmf_vars
        [ -n "$MACOS_SHORTNAME" ] && printf '%s\n' "$MACOS_SHORTNAME" > "$MACOS_VERSION_FILE"
        if ! run_download_with_progress "LayerOSX — first run" "Downloading macOS $MACOS_VERSION… (press Ctrl+Alt+T for details)" \
            bash "$LIB_DIR/fetch-recovery.sh" "$VM_DISK" "$MACOS_SHORTNAME"; then
            zenity --error --width=520 --title="LayerOSX — first run" \
                --text="Couldn't download the macOS recovery image. Press Ctrl+Alt+T to see the details, check your internet connection, and try again."
            exit 1
        fi

        # Confirm the version we ACTUALLY got. fetch-recovery.sh writes the real
        # ProductVersion (read from the recovery image) to <vmdir>/downloaded-
        # version as "<ver>|<build>" when it can. If it doesn't match what was
        # picked (Apple's os_type:latest can hand back a newer OS than the
        # label), warn and let the user keep it or start over. Keeping it also
        # rewrites $MACOS_VERSION_FILE to the REAL version's shortname, so
        # mac-vm-launch.sh masks a matching CPU model (a Sequoia image under
        # Ventura's Haswell mask is itself a boot hazard).
        DL_VER_FILE="$(dirname "$VM_DISK")/downloaded-version"
        if [ -s "$DL_VER_FILE" ]; then
            _dv="$(cat "$DL_VER_FILE")"
            _dver="${_dv%%|*}"
            _dbuild="${_dv#*|}"; [ "$_dbuild" = "$_dv" ] && _dbuild=""
            _bmsg=""; [ -n "$_dbuild" ] && _bmsg=" (build $_dbuild)"
            _major="${_dver%%.*}"; _minor="${_dver#*.}"; _minor="${_minor%%.*}"
            case "$_major" in
                10) case "$_minor" in 13) _real_sn=high-sierra ;; 14) _real_sn=mojave ;; *) _real_sn=catalina ;; esac ;;
                11) _real_sn=big-sur ;;
                12) _real_sn=monterey ;;
                13) _real_sn=ventura ;;
                14) _real_sn=sonoma ;;
                15) _real_sn=sequoia ;;
                26) _real_sn=tahoe ;;
                *)  _real_sn="" ;;
            esac
            if [ -n "$MACOS_SHORTNAME" ] && [ -n "$_real_sn" ] && [ "$_real_sn" != "$MACOS_SHORTNAME" ]; then
                if zenity --question --width=560 --title="LayerOSX — first run" \
                    --ok-label="Install $_dver" --cancel-label="Start over" \
                    --text="You picked $MACOS_VERSION, but Apple served macOS $_dver$_bmsg.\n\nThis happens when that board-id's recovery now defaults to a newer release. Install $_dver anyway, or start over and pick again?"; then
                    printf '%s\n' "$_real_sn" > "$MACOS_VERSION_FILE"   # match the CPU model to reality
                else
                    exit 1   # cleanup_failed_attempt wipes the partial disk -> wizard reruns
                fi
            else
                zenity --info --width=520 --title="LayerOSX — first run" \
                    --text="Downloaded macOS $_dver$_bmsg." 2>/dev/null || true
            fi
        fi
        ;;
    *"pick a file"*)
        # Tkinter/Tk, not zenity (GTK) -- see lib/pick-source-file.py's
        # own header comment for why: zenity's GTK dependency is what
        # already crashed it once on this project.
        SRC=$(python3 "$LIB_DIR/pick-source-file.py")
        [ -n "$SRC" ] || exit 1

        copy_ovmf_vars

        case "$SRC" in
            *.qcow2)
                # A complete, already-installed macOS disk -- boots
                # directly, no installer step needed.
                echo "Copying $SRC as the VM disk (already a complete system, not installer media)..."
                cp -v "$SRC" "$VM_DISK"
                ;;
            *.img|*.raw|*.IMG|*.RAW)
                # Same, but raw: mac-vm-launch.sh attaches $VM_DISK as
                # format=qcow2, so a raw image has to be converted, not
                # copied (it used to be copied -- QEMU then refused it as
                # "not in qcow2 format").
                if ! run_convert_with_progress "LayerOSX — first run" "Converting VM disk to qcow2… (press Ctrl+Alt+T for details)" \
                    "$SRC" "$VM_DISK" raw; then
                    zenity --error --text="Couldn't convert this raw disk image into a qcow2 VM disk. Press Ctrl+Alt+T to see the details."
                    exit 1
                fi
                ;;
            *.vmdk|*.vdi|*.vhd|*.vhdx|*.VMDK|*.VDI|*.VHD|*.VHDX)
                # A complete, already-installed macOS disk from another
                # hypervisor -- VMware (.vmdk), VirtualBox (.vdi, also .vmdk/
                # .vhd), Hyper-V (.vhd/.vhdx). qemu-img reads all of these
                # natively; convert to the qcow2 mac-vm-launch.sh expects.
                # (A split VMware .vmdk is fine: pick the small descriptor
                # .vmdk and qemu-img pulls in the -s00x.vmdk extents sitting
                # next to it automatically.) These boot directly -- a complete
                # system, not installer media -- so no second disk is attached.
                case "${SRC,,}" in
                    *.vmdk) _srcfmt=vmdk ;;
                    *.vdi)  _srcfmt=vdi ;;
                    *.vhd)  _srcfmt=vpc ;;
                    *.vhdx) _srcfmt=vhdx ;;
                esac
                if ! run_convert_with_progress "LayerOSX — first run" "Converting ${SRC##*.} disk to qcow2… (press Ctrl+Alt+T for details)" \
                    "$SRC" "$VM_DISK" "$_srcfmt"; then
                    zenity --error --text="Couldn't convert this ${SRC##*.} disk into a qcow2 VM disk. Press Ctrl+Alt+T to see the details. If it's a split VMware disk, make sure every part (the -s001.vmdk, -s002.vmdk… files) is in the same folder as the descriptor .vmdk you picked."
                    exit 1
                fi
                ;;
            *.iso|*.ISO)
                # Recovery/installer media (not a complete system) --
                # goes on the SEPARATE disk mac-vm-launch.sh attaches
                # alongside a blank $VM_DISK, same as the .dmg path
                # below. ISO files are raw ISO9660 data, not a qcow2
                # container, hence -f raw on the way in.
                qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
                INSTALLER_DISK="${VM_DISK%.qcow2}-installer.qcow2"
                if ! run_convert_with_progress "LayerOSX — first run" "Preparing installer from .iso… (press Ctrl+Alt+T for details)" \
                    "$SRC" "$INSTALLER_DISK" raw; then
                    zenity --error --text="Couldn't convert this .iso into a VM disk. Press Ctrl+Alt+T to see the details, or try the 'download directly from Apple' option instead."
                    exit 1
                fi
                ;;
            *.dmg|*.DMG|*.app|*.APP)
                qemu-img create -f qcow2 "$VM_DISK" "${VM_SIZE_GB}G"
                if ! run_with_progress "LayerOSX — first run" "Preparing installer from .dmg… (press Ctrl+Alt+T for details)" \
                    bash "$LIB_DIR/extract-dmg-installer.sh" "$SRC" "$VM_DISK"; then
                    zenity --error --text="Couldn't prepare an installer from this .dmg (this is the most experimental part of the project — see docs/CHECKLIST.md). Press Ctrl+Alt+T to see the details, or try the 'download directly from Apple' option instead."
                    exit 1
                fi
                ;;
            *)
                zenity --error --text="Unrecognized file type: $SRC\n\nExpected a complete VM disk (.qcow2/.img/.raw/.vmdk/.vdi/.vhd/.vhdx), .iso (recovery/installer media), or .dmg/.app (macOS installer)."
                exit 1
                ;;
        esac
        ;;
    *)
        exit 1
        ;;
esac
