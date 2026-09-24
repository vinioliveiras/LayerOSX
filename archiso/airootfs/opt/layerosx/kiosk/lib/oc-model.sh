#!/usr/bin/env bash
# Set the Mac model (SMBIOS SystemProductName) inside an OpenCore image.
#
#   oc-model.sh <in.qcow2> <out.qcow2> <SystemProductName>
#
# OpenCore's PlatformInfo runs with Automatic=true, so SystemProductName is the
# only field that matters: OpenCore fills board-id, firmware features, memory
# form factor, ... from its own database for that model. The serial/MLB/UUID
# placeholders stay as they are.
#
# Used twice:
#   - build.sh bakes the default (MacBookPro16,2) into the base image, so every
#     derived image (verbose, diag, AMD families) inherits it;
#   - mac-vm-launch.sh, when Settings > Mac > Model picks another model, makes
#     a cached copy of the image it's about to boot (see there).
# Needs qemu-img + mtools. Exit 0 = written, 1 = failed (nothing written).
set -uo pipefail
IN="$1"; OUT="$2"; MODEL="$3"
case "$MODEL" in *[!A-Za-z0-9,]*|"") echo "oc-model: bad model '$MODEL'" >&2; exit 1 ;; esac
command -v qemu-img >/dev/null && command -v mcopy >/dev/null || { echo "oc-model: needs qemu-img + mtools" >&2; exit 1; }
export MTOOLS_SKIP_CHECK=1
raw="$(mktemp)"; plist="$(mktemp)"
trap 'rm -f "$raw" "$plist"' EXIT
qemu-img convert -O raw "$IN" "$raw" || exit 1
esp="${raw}@@1048576"
mcopy -n -i "$esp" ::/EFI/OC/config.plist "$plist" 2>/dev/null || { echo "oc-model: no EFI/OC/config.plist in $IN" >&2; exit 1; }
python3 - "$plist" "$MODEL" <<'PY' || exit 1
import plistlib, sys
p, model = sys.argv[1], sys.argv[2]
cfg = plistlib.load(open(p, "rb"))
gen = cfg.setdefault("PlatformInfo", {}).setdefault("Generic", {})
old = gen.get("SystemProductName")
gen["SystemProductName"] = model
plistlib.dump(cfg, open(p, "wb"))
print(f"oc-model: SystemProductName {old} -> {model}", file=sys.stderr)
PY
mcopy -o -n -i "$esp" "$plist" ::/EFI/OC/config.plist || exit 1
tmp="$OUT.tmp.$$"
qemu-img convert -O qcow2 "$raw" "$tmp" && mv -f "$tmp" "$OUT" && chmod 644 "$OUT"
