#!/usr/bin/env bash
# Downloads a macOS recovery image straight from Apple's recovery servers
# (the request a real Mac makes when it boots into network recovery) and
# turns it into the Mac's install disk: <disk>-recovery.qcow2 next to $1.
# Nothing from Apple is ever shipped in the ISO.
#
#   fetch-recovery.sh <vm-disk.qcow2> [shortname]
#   shortname: high-sierra mojave catalina big-sur monterey ventura sonoma
#              sequoia tahoe (empty = the newest macOS)
#
# Which version Apple serves depends on the board-id asked about, the MLB
# serial and os_type ("default" = roughly what that Mac shipped with,
# "latest" = the newest it supports). The rule used here: ask, with
# os_type=latest, for a board whose LAST supported macOS is the one wanted
# -- Apple then serves that version's final release. Checked against
# Apple's servers (2026-09-25): two independent boards per version return
# the same product (big-sur 071-78714, monterey 012-40515, ventura
# 042-23155, sonoma 062-58679, tahoe 140-93589), while the os_type=default
# entries fetch-macOS-v2.py's own table used for catalina / big-sur /
# sonoma / sequoia returned other, older images -- the "downloaded the
# wrong macOS" bug. High Sierra and Mojave are only reachable through
# "default" with a period MLB (as in macrecovery's docs).
#
# Every download is then CHECKED: the version is read out of the image,
# and if it isn't the one asked for, the next board is tried. Only when
# every board disagrees does the first-run wizard get to ask (it reads
# downloaded-version).
#
# Needs plain HTTP to osrecovery.apple.com / oscdn.apple.com.
set -euo pipefail
VM_DISK="$1"
MACOS_SHORTNAME="${2:-}"
LIB="$(dirname "$(readlink -f "$0")")"
WORK="/var/lib/layerosx/fetch-work"
DL_VER_FILE="$(dirname "$VM_DISK")/downloaded-version"
mkdir -p "$WORK"
cd "$WORK"

# The downloader ships with LayerOSX (lib/fetch-macOS-v2.py, vendored).
FETCH="$LIB/fetch-macOS-v2.py"
if [ ! -r "$FETCH" ]; then
    FETCH="$WORK/fetch-macOS-v2.py"
    curl -fsSLo "$FETCH" https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS-v2.py
fi
# Older LayerOSX builds cached their own download of it here, never refreshed.
[ "$FETCH" = "$LIB/fetch-macOS-v2.py" ] && rm -f "$WORK/fetch-macOS-v2.py"

Z=00000000000000000
# board-id  MLB  os_type -- one line per try, best first.
candidates() {
    case "$1" in
        high-sierra) echo "Mac-7BA5B2D9E42DDD94 00000000000J80300 default" ;;
        mojave)      echo "Mac-7BA5B2DFE22DDD8C 00000000000KXPG00 default" ;;
        catalina)    printf '%s\n' "Mac-00BE6ED71E35EB86 $Z latest" "Mac-00BE6ED71E35EB86 $Z default" ;;
        big-sur)     printf '%s\n' "Mac-2BD1B31983FE1663 $Z latest" "Mac-42FD25EABCABB274 $Z latest" ;;
        monterey)    printf '%s\n' "Mac-B809C3757DA9BB8D $Z latest" "Mac-E43C1C25D4880AD6 $Z latest" ;;
        ventura)     printf '%s\n' "Mac-4B682C642B45593E $Z latest" "Mac-B4831CEBD52A0C4C $Z latest" ;;
        sonoma)      printf '%s\n' "Mac-827FAC58A8FDFA22 $Z latest" "Mac-226CB3C6A851A671 $Z latest" ;;
        sequoia)     echo "Mac-7BA5B2D9E42DDD94 $Z latest" ;;
        tahoe|"")    printf '%s\n' "Mac-CFF7D910A743CAAF $Z latest" "Mac-27AD2F918AE68F61 $Z latest" ;;
        *) echo "unknown macOS version '$1'" >&2; return 1 ;;
    esac
}
expected() {
    case "$1" in
        high-sierra) echo 10.13 ;; mojave) echo 10.14 ;; catalina) echo 10.15 ;;
        big-sur) echo 11 ;; monterey) echo 12 ;; ventura) echo 13 ;;
        sonoma) echo 14 ;; sequoia) echo 15 ;; tahoe) echo 26 ;; *) echo "" ;;
    esac
}
# "13.6.1" matches "13"; "10.15.7" matches "10.15".
matches() {
    case "$1." in "$2".*) return 0 ;; esac
    return 1
}

# ProductVersion / ProductBuildVersion out of the (converted) BaseSystem image.
read_version() {
    python3 - "$1" <<'PYEOF'
import sys, re
vpat = re.compile(rb'ProductVersion</key>\s*<string>([0-9]+(?:\.[0-9]+)*)</string>')
bpat = re.compile(rb'ProductBuildVersion</key>\s*<string>([0-9A-Za-z]+)</string>')
ver = build = None
prev = b''
try:
    with open(sys.argv[1], 'rb') as f:
        while True:
            chunk = f.read(8 << 20)
            if not chunk:
                break
            buf = prev + chunk
            if ver is None:
                m = vpat.search(buf)
                if m:
                    ver = m.group(1).decode()
            if build is None:
                m = bpat.search(buf)
                if m:
                    build = m.group(1).decode()
            if ver and build:
                break
            prev = buf[-256:]
except OSError:
    pass
if ver:
    print(ver + (('|' + build) if build else ''))
PYEOF
}

command -v dmg2img >/dev/null 2>&1 || { echo "dmg2img is missing -- can't unpack Apple's image." >&2; exit 1; }
WANT="$(expected "$MACOS_SHORTNAME")"
mapfile -t TRIES < <(candidates "$MACOS_SHORTNAME")
rm -f "$DL_VER_FILE"
GOT="" DETECTED=""
n=0
for try in "${TRIES[@]}"; do
    n=$((n + 1))
    read -r board mlb ostype <<<"$try"
    echo "==> [$n/${#TRIES[@]}] asking Apple for ${MACOS_SHORTNAME:-the newest macOS} (board $board, os_type $ostype)"
    rm -rf recovery BaseSystem.img
    if ! python3 "$FETCH" --action download -o recovery -b "$board" -m "$mlb" -os "$ostype"; then
        echo "    download failed with this board -- trying the next one" >&2
        continue
    fi
    DMG=$(find recovery -iname 'BaseSystem.dmg' | head -n1)
    [ -n "$DMG" ] || { echo "    no BaseSystem.dmg in the download" >&2; continue; }
    dmg2img "$DMG" BaseSystem.img
    DETECTED="$(read_version BaseSystem.img)"
    GOT="${DETECTED%%|*}"
    if [ -z "$WANT" ] || [ -z "$GOT" ] || matches "$GOT" "$WANT"; then
        break
    fi
    echo "    Apple served macOS $GOT for this board, not $WANT -- trying the next board." >&2
done

[ -f BaseSystem.img ] || { echo "WARNING: no recovery image could be downloaded." >&2; exit 1; }
if [ -n "$DETECTED" ]; then
    printf '%s\n' "$DETECTED" > "$DL_VER_FILE"
    echo "Detected downloaded macOS version: ${DETECTED/|/ build }"
    if [ -n "$WANT" ] && ! matches "$GOT" "$WANT"; then
        echo "WARNING: every board tried served macOS $GOT instead of $WANT -- the first-run wizard will ask." >&2
    fi
else
    echo "NOTE: couldn't read the downloaded macOS version from the image (will show the selected version instead)." >&2
fi
qemu-img convert -O qcow2 BaseSystem.img "${VM_DISK%.qcow2}-recovery.qcow2"
rm -f BaseSystem.img
echo "Recovery ready at ${VM_DISK%.qcow2}-recovery.qcow2"
