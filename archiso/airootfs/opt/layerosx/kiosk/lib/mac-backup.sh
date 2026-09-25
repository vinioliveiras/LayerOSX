#!/usr/bin/env bash
# Back up the Mac to a drive, restore one from a drive, or remove it so the
# first-run setup can install another macOS -- Settings › Mac › Backups runs
# this through sudo (it mounts drives and stops the Mac).
#
#   mac-backup.sh list    <partition>            JSON list of the backups on it
#   mac-backup.sh backup  <partition> <name>     copy this Mac to <drive>/LayerOSX-backups/<name>_<date>/
#   mac-backup.sh restore <partition> <folder>   replace this Mac with that backup
#   mac-backup.sh erase                          remove this Mac (erasevm) -> first-run setup
#
# A backup folder holds macos.qcow2 (the Mac's disk, compacted: only the
# space macOS uses), OVMF_VARS.fd (its NVRAM), macos-recovery.qcow2 when
# there is one, the small files that say what it is (macos-version,
# downloaded-version, mac-model) and manifest.json.
#
# The Mac must be off while its disk is copied. This writes its PID to
# /run/layerosx-hold, asks macOS to shut down (ACPI power button), falls back
# to a QMP quit (QEMU flushes the disk, like Settings › Restart Mac), and
# mac-vm-launch.sh waits while the hold's process is alive, then starts over
# from the top (re-reading the Mac's version, or opening the first-run setup
# when there's no Mac any more).
#
# backup/restore/erase run one at a time and report progress in
# /run/layerosx-backup.json: {"kind","state","percent","message","path","pid"}
# with state stopping|copying|finishing|done|error.
#
# Deliberately narrow because it runs as root: the target must be a
# partition block device and never the running system's own root/boot
# partition; names are reduced to [A-Za-z0-9 ._-]; a restore only reads a
# folder directly inside <drive>/LayerOSX-backups.
set -uo pipefail

STATE_DIR="${LAYEROSX_STATE_DIR:-/var/lib/layerosx}"
LIB="$(dirname "$(readlink -f "$0")")"
QMP_CMD="${LAYEROSX_QMP_CMD:-$LIB/qmp-cmd.py}"
CTL_SOCK="${LAYEROSX_CTL_SOCK:-/tmp/macvm-ctl.sock}"
HOLD="${LAYEROSX_HOLD_FILE:-/run/layerosx-hold}"
STATUS="${LAYEROSX_BACKUP_STATUS:-/run/layerosx-backup.json}"
LOCK="${STATUS%.json}.lock"
QEMU_IMG="${LAYEROSX_QEMU_IMG:-qemu-img}"
ERASEVM="${LAYEROSX_ERASEVM:-/usr/local/bin/erasevm}"
# Tests only: a folder that stands in for the mounted drive (sudo's env_reset
# keeps it from ever reaching the real, root-run script).
FAKE_MNT="${LAYEROSX_BACKUP_FAKE_MNT:-}"
SHUTDOWN_WAIT="${LAYEROSX_SHUTDOWN_WAIT:-60}"
MARGIN=$((1024 * 1024 * 1024))      # keep 1 GB free on either side

VM_DISK="$STATE_DIR/macos.qcow2"
RECOVERY="$STATE_DIR/macos-recovery.qcow2"
SMALL_FILES=(OVMF_VARS.fd macos-version downloaded-version mac-model)

KIND="${1:-}"; DEV="${2:-}"; ARG="${3:-}"
CUR_PATH=""
die() { echo "mac-backup: $*" >&2; exit 2; }

status() {   # state percent message
    [ "$KIND" = list ] && return 0
    python3 - "$STATUS" "$KIND" "$1" "$2" "$3" "$CUR_PATH" "$$" <<'PY'
import json, os, sys
path, kind, state, pct, msg, dest, pid = sys.argv[1:8]
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump({"kind": kind, "state": state, "percent": int(pct), "message": msg,
               "path": dest, "pid": int(pid)}, f)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
}
fail() { status error 0 "$*"; echo "mac-backup: $*" >&2; exit 1; }

# ------------------------------------------------------------------- drive
MNT="" MOUNTED_HERE=0
mount_drive() {
    if [ -n "$FAKE_MNT" ]; then MNT="$FAKE_MNT"; return 0; fi
    case "$DEV" in /dev/*) ;; *) die "not a device: $DEV" ;; esac
    [ -b "$DEV" ] || die "not a block device: $DEV"
    [ "$(lsblk -ndo TYPE "$DEV" 2>/dev/null)" = part ] || die "not a partition: $DEV"
    local sys src
    for sys in / /boot /boot/efi "$STATE_DIR"; do
        src="$(findmnt -nro SOURCE --target "$sys" 2>/dev/null || true)"
        [ -n "$src" ] && [ "$(realpath "$src" 2>/dev/null)" = "$(realpath "$DEV")" ] && die "refusing the system's own $sys partition"
    done
    MNT="$(findmnt -nro TARGET --source "$DEV" 2>/dev/null | head -n1 || true)"
    if [ -z "$MNT" ]; then
        MNT="/mnt/layerosx-save/$(basename "$DEV")"
        mkdir -p "$MNT"
        mount -o rw "$DEV" "$MNT" 2>/dev/null || { rmdir "$MNT" 2>/dev/null; MNT=""; return 1; }
        MOUNTED_HERE=1
    fi
}
unmount_drive() {
    if [ "$MOUNTED_HERE" = 1 ]; then
        sync
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
        rmdir "$MNT" 2>/dev/null || true
        MOUNTED_HERE=0
    fi
}
free_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -n1 | tr -dc '0-9'; }
gb() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }

# ----------------------------------------------------------------- the Mac
qemu_running() { pgrep -f 'qemu-system-x86_64' >/dev/null 2>&1; }
wait_qemu_gone() {   # seconds
    local i
    for ((i = 0; i < $1; i++)); do qemu_running || return 0; sleep 1; done
    ! qemu_running
}
stop_mac() {
    echo "$$" > "$HOLD"
    qemu_running || return 0
    status stopping 0 "Shutting down macOS… (if macOS asks, choose Shut Down)"
    python3 "$QMP_CMD" "$CTL_SOCK" system_powerdown >/dev/null 2>&1 || true
    wait_qemu_gone "$SHUTDOWN_WAIT" && return 0
    status stopping 0 "Stopping the Mac…"
    python3 "$QMP_CMD" "$CTL_SOCK" quit >/dev/null 2>&1 || true
    wait_qemu_gone 30 && return 0
    pkill -TERM -f 'qemu-system-x86_64' 2>/dev/null
    wait_qemu_gone 10 && return 0
    fail "The Mac didn't stop — nothing was copied."
}
release() {
    unmount_drive
    # Only our own hold: never lift one another run left.
    [ "$(cat "$HOLD" 2>/dev/null)" = "$$" ] && rm -f "$HOLD"
}

# qemu-img convert with its "(12.34/100%)" progress mapped onto from..to %.
convert() {   # src dst from to message
    local src="$1" dst="$2" from="$3" to="$4" msg="$5" chunk p last=-1 err
    err="$(mktemp)"
    "$QEMU_IMG" convert -p -O qcow2 "$src" "$dst" 2>"$err" |
        while IFS= read -r -d $'\r' chunk || [ -n "$chunk" ]; do
            p="$(printf '%s' "$chunk" | sed -n 's/.*(\([0-9]*\)\.[0-9]*\/100%).*/\1/p')"
            [ -n "$p" ] || continue
            p=$(( from + (to - from) * p / 100 ))
            [ "$p" = "$last" ] && continue
            last=$p
            status copying "$p" "$msg"
        done
    local rc=${PIPESTATUS[0]}
    [ "$rc" = 0 ] || echo "qemu-img: $(tail -n3 "$err")" >&2
    rm -f "$err"
    return "$rc"
}
disk_bytes() {   # what a compacted copy needs ("required"), else the file size
    local n
    n="$("$QEMU_IMG" measure -O qcow2 --output=json "$1" 2>/dev/null |
         python3 -c 'import json,sys; print(json.load(sys.stdin)["required"])' 2>/dev/null)"
    [ -n "$n" ] || n="$(stat -c %s "$1" 2>/dev/null || echo 0)"
    echo "$n"
}
owner_fix() { chown --reference="$STATE_DIR" "$@" 2>/dev/null || true; }

# -------------------------------------------------------------------- list
do_list() {
    mount_drive || die "couldn't mount $DEV"
    python3 - "$MNT/LayerOSX-backups" <<'PY'
import json, os, sys
root, out = sys.argv[1], []
for d in sorted(os.listdir(root)) if os.path.isdir(root) else []:
    p = os.path.join(root, d)
    try:
        with open(os.path.join(p, "manifest.json")) as f:
            m = json.load(f)
    except (OSError, ValueError):
        continue
    if not os.path.isfile(os.path.join(p, "macos.qcow2")):
        continue
    m["folder"] = d
    out.append(m)
out.sort(key=lambda m: m.get("created", ""), reverse=True)
print(json.dumps(out))
PY
    unmount_drive
}

# ------------------------------------------------------------------ backup
do_backup() {
    local name date folder dest need avail f
    [ -f "$VM_DISK" ] || fail "There's no Mac to back up yet."
    name="$(printf '%s' "$ARG" | tr -cd 'A-Za-z0-9 ._-' | sed 's/^[ .]*//; s/ *$//' | cut -c1-48)"
    [ -n "$name" ] || name="Mac"
    date="$(date +%Y-%m-%d_%H%M)"
    folder="${name// /-}_$date"
    status stopping 0 "Opening the drive…"
    mount_drive || fail "Couldn't open that drive (a Windows drive may be hibernated/locked by Windows)."
    case "$(findmnt -nro FSTYPE --target "$MNT" 2>/dev/null)" in
        vfat|msdos) fail "That drive is FAT32, which can't hold files over 4 GB. Use an exFAT, NTFS or ext4 drive." ;;
    esac
    need=$(( $(disk_bytes "$VM_DISK") + MARGIN ))
    [ -f "$RECOVERY" ] && need=$(( need + $(stat -c %s "$RECOVERY") ))
    avail="$(free_bytes "$MNT")"
    [ -n "$avail" ] && [ "$avail" -ge "$need" ] ||
        fail "Not enough room on that drive: the backup needs about $(gb "$need"), it has $(gb "${avail:-0}") free."
    dest="$MNT/LayerOSX-backups/$folder"
    CUR_PATH="LayerOSX-backups/$folder"
    mkdir -p "$dest" || fail "That drive is read-only."

    stop_mac
    status copying 0 "Copying the Mac's disk…"
    if ! convert "$VM_DISK" "$dest/macos.qcow2" 0 90 "Copying the Mac's disk…"; then
        rm -rf "$dest"; fail "The copy failed (drive full or unplugged?). Nothing was changed on this Mac."
    fi
    if [ -f "$RECOVERY" ]; then
        status copying 92 "Copying the macOS recovery…"
        cp -- "$RECOVERY" "$dest/" || { rm -rf "$dest"; fail "The copy failed (drive full or unplugged?)."; }
    fi
    for f in "${SMALL_FILES[@]}"; do
        [ -f "$STATE_DIR/$f" ] && cp -- "$STATE_DIR/$f" "$dest/"
    done
    python3 - "$dest" "$name" "$STATE_DIR" <<'PY'
import datetime, json, os, sys
dest, name, state = sys.argv[1:4]
def read(p):
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return ""
ver = {}
for line in read("/etc/layerosx/version").splitlines():
    k, _, v = line.partition("=")
    ver[k] = v
dl_ver, _, dl_build = read(os.path.join(state, "downloaded-version")).partition("|")
size = sum(os.path.getsize(os.path.join(dest, f)) for f in os.listdir(dest))
json.dump({"name": name, "created": datetime.datetime.now().isoformat(timespec="minutes"),
           "macos": read(os.path.join(state, "macos-version")), "macos_version": dl_ver,
           "macos_build": dl_build, "mac_model": read(os.path.join(state, "mac-model")),
           "size": size, "layerosx_build": ver.get("build", ""), "format": 1},
          open(os.path.join(dest, "manifest.json"), "w"), indent=1)
PY
    status finishing 97 "Finishing writing to the drive…"
    sync
    unmount_drive
    status done 100 "Backup saved on the drive in $CUR_PATH. The Mac starts again now."
}

# ----------------------------------------------------------------- restore
do_restore() {
    local folder="$ARG" src need avail cur target f
    case "$folder" in ""|.|..|*/*|*[!A-Za-z0-9._\ -]*) die "not a backup folder: $folder" ;; esac
    status stopping 0 "Opening the drive…"
    mount_drive || fail "Couldn't open that drive."
    src="$MNT/LayerOSX-backups/$folder"
    CUR_PATH="LayerOSX-backups/$folder"
    [ -f "$src/manifest.json" ] && [ -f "$src/macos.qcow2" ] && [ ! -L "$src/macos.qcow2" ] ||
        fail "That folder isn't a LayerOSX backup."
    "$QEMU_IMG" info "$src/macos.qcow2" >/dev/null 2>&1 || fail "The backup's disk can't be read (damaged or incomplete)."

    need=$(( $(stat -c %s "$src/macos.qcow2") + MARGIN ))
    [ -f "$src/macos-recovery.qcow2" ] && need=$(( need + $(stat -c %s "$src/macos-recovery.qcow2") ))
    avail="$(free_bytes "$STATE_DIR")"; avail="${avail:-0}"
    cur=0
    [ -f "$VM_DISK" ] && cur="$(stat -c %s "$VM_DISK")"
    [ -f "$src/macos-recovery.qcow2" ] && [ -f "$RECOVERY" ] && cur=$(( cur + $(stat -c %s "$RECOVERY") ))
    if [ "$avail" -ge "$need" ]; then
        target="$VM_DISK.new"         # the current Mac stays until the copy is complete
    elif [ $(( avail + cur )) -ge "$need" ]; then
        target="$VM_DISK"             # only fits once the current Mac is gone
    else
        fail "Not enough room on this computer: the Mac needs about $(gb "$need"), there's $(gb $(( avail + cur ))) free."
    fi

    stop_mac
    if [ "$target" = "$VM_DISK" ]; then
        status copying 0 "Removing the current Mac to make room…"
        rm -f "$VM_DISK" "$VM_DISK.new"
        [ -f "$src/macos-recovery.qcow2" ] && rm -f "$RECOVERY"
    fi
    if ! convert "$src/macos.qcow2" "$target" 0 90 "Copying the Mac from the drive…"; then
        rm -f "$VM_DISK.new"
        [ "$target" = "$VM_DISK" ] && rm -f "$VM_DISK"
        fail "The copy failed (drive unplugged?).$([ "$target" = "$VM_DISK" ] && echo " The old Mac was already removed to make room — restore again, or install macOS from the first-run setup.")"
    fi
    owner_fix "$target"
    [ "$target" = "$VM_DISK.new" ] && mv -f "$VM_DISK.new" "$VM_DISK"
    if [ -f "$src/macos-recovery.qcow2" ]; then
        status copying 92 "Copying the macOS recovery…"
        cp -- "$src/macos-recovery.qcow2" "$RECOVERY.new" && mv -f "$RECOVERY.new" "$RECOVERY" && owner_fix "$RECOVERY"
    fi
    for f in "${SMALL_FILES[@]}"; do
        if [ -f "$src/$f" ]; then
            cp -- "$src/$f" "$STATE_DIR/$f" && owner_fix "$STATE_DIR/$f"
        else
            rm -f "$STATE_DIR/$f"    # e.g. no mac-model = the default model
        fi
    done
    rm -f "$STATE_DIR/disk-grown"    # belonged to the old disk; the launcher grows this one
    status finishing 97 "Finishing…"
    sync
    unmount_drive
    status done 100 "Mac restored. It starts now."
}

# ------------------------------------------------------------------- erase
do_erase() {
    stop_mac
    status copying 50 "Removing the Mac…"
    "$ERASEVM" -y >/dev/null 2>&1 || fail "Couldn't remove the Mac (see erasevm in the terminal)."
    rm -f "$STATE_DIR/disk-grown"
    status done 100 "Mac removed. The first-run setup opens in a moment."
}

case "$KIND" in
    list)
        [ -n "$DEV" ] || die "usage: mac-backup.sh list <partition>"
        trap unmount_drive EXIT
        do_list ;;
    backup|restore|erase)
        if [ "$KIND" != erase ]; then
            [ -n "$DEV" ] && [ -n "$ARG" ] || die "usage: mac-backup.sh $KIND <partition> <name|folder>"
        fi
        exec 9>"$LOCK" || die "can't open $LOCK"
        flock -n 9 || die "another backup/restore is already running"
        trap release EXIT
        trap 'fail "Stopped."' INT TERM HUP
        "do_$KIND" ;;
    *) die "usage: mac-backup.sh list|backup|restore|erase …" ;;
esac
