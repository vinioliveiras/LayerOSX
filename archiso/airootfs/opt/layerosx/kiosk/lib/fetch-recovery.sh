#!/usr/bin/env bash
# Downloads the recovery image directly from Apple's servers
# (fetch-macOS-v2.py, from the OSX-KVM project — note the "-v2": the
# older fetch-macOS.py was renamed/replaced upstream) into disk $1.
# This never redistributes anything from Apple — it just automates the
# same request a real Mac makes when it boots into network recovery
# mode, this time onto your own disk.
#
# $2 (optional) is a macOS version shortname (high-sierra, mojave,
# catalina, big-sur, monterey, ventura, sonoma, sequoia, tahoe) --
# fetch-macOS-v2.py's own hardcoded product list (see its --shortname/
# -s option) maps each one to a real board-id, and Apple's actual
# recovery servers still serve all of them, same as any real Mac of
# that board-id asking for network recovery. Empty/unset falls back to
# fetch-macOS-v2.py's own default (RECENT_MAC).
#
# Needs unrestricted outbound HTTP to osrecovery.apple.com — this will
# fail under any kind of network allowlist/proxy (confirmed while
# testing: both this developer's sandboxed dev environments got a 403
# from their own egress allowlist, nothing to do with Apple). The
# actual installed LayerOSX system has normal internet, so this just
# works there.
set -euo pipefail
VM_DISK="$1"
MACOS_SHORTNAME="${2:-}"
WORK="/var/lib/layerosx/fetch-work"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -f fetch-macOS-v2.py ]; then
    curl -fsSLo fetch-macOS-v2.py \
        https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS-v2.py
fi

# Upstream bug, confirmed on real hardware: verify_image()'s per-chunk
# terminal-width probe (a bare os.get_terminal_size(), no fallback)
# isn't guarded the same way the download progress bar's own
# identical call a few lines above it is. The download itself always
# completed fine here (its call falls back to a width of 80 on
# OSError), but "Verifying image with chunklist..." crashed
# immediately afterward with "OSError: [Errno 25] Inappropriate ioctl
# for device" -- this whole install pipeline redirects stdout through
# a log file the entire way (never a real tty), which is exactly the
# condition that call was never guarded against. Patch in the same
# try/except the download path already uses, idempotent (a second run
# reusing the cached file is a no-op; silently does nothing if
# upstream ever restructures this function so the anchor no longer
# matches, rather than breaking the whole script over a cosmetic
# progress counter).
python3 - <<'PYEOF'
import pathlib

path = pathlib.Path("fetch-macOS-v2.py")
text = path.read_text()

old = (
    "def verify_image(dmgpath, cnkpath):\n"
    "    print('Verifying image with chunklist...')\n"
    "\n"
    "    with open(dmgpath, 'rb') as dmgf:\n"
    "        for cnkcount, (cnksize, cnkhash) in enumerate(verify_chunklist(cnkpath), 1):\n"
    "            terminalsize = max(os.get_terminal_size().columns - TERMINAL_MARGIN, 0)\n"
)
new = (
    "def verify_image(dmgpath, cnkpath):\n"
    "    print('Verifying image with chunklist...')\n"
    "\n"
    "    with open(dmgpath, 'rb') as dmgf:\n"
    "        for cnkcount, (cnksize, cnkhash) in enumerate(verify_chunklist(cnkpath), 1):\n"
    "            try:\n"
    "                terminalsize = max(os.get_terminal_size().columns - TERMINAL_MARGIN, 0)\n"
    "            except OSError:\n"
    "                terminalsize = 80\n"
)

if old in text:
    path.write_text(text.replace(old, new, 1))
    print("patched verify_image()'s terminal-size probe")
else:
    print("WARNING: fetch-macOS-v2.py's verify_image() didn't match the expected shape -- skipped patching it, upstream may have changed.", flush=True)
PYEOF

SHORTNAME_ARGS=()
if [ -n "$MACOS_SHORTNAME" ]; then
    SHORTNAME_ARGS=(-s "$MACOS_SHORTNAME")
fi
python3 fetch-macOS-v2.py --action download -o recovery "${SHORTNAME_ARGS[@]}"

DMG=$(find recovery -iname 'BaseSystem.dmg' | head -n1)
if [ -n "$DMG" ] && command -v dmg2img >/dev/null 2>&1; then
    dmg2img "$DMG" BaseSystem.img
    qemu-img convert -O qcow2 BaseSystem.img "${VM_DISK%.qcow2}-recovery.qcow2"
    echo "Recovery ready at ${VM_DISK%.qcow2}-recovery.qcow2 — mac-vm-launch.sh needs to attach it as a second disk on first boot so you can actually install macOS."
else
    echo "WARNING: couldn't find BaseSystem.dmg (under $WORK/recovery) or dmg2img — the download may have failed." >&2
    exit 1
fi
