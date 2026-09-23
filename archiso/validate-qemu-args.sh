#!/usr/bin/env bash
# Validate the macOS VM's QEMU command line against a REAL qemu-system-x86_64,
# WITHOUT KVM, macOS, or the physical test machine -- catching the class of
# bug that cost the most real-hardware time (a rejected -device/-drive/-global:
# bootindex misrouting, "Unsupported PCI slot 0", a wrong device name, ...).
# Those are argument-validation errors QEMU raises at startup, before it ever
# needs /dev/kvm or a guest, so a plain QEMU on any Linux box reproduces them.
#
# Run it before shipping any change to mac-vm-launch.sh:
#     archiso/validate-qemu-args.sh
# Needs: qemu-system-x86_64 (any recent stock build) and an OVMF firmware.
# It exits non-zero if QEMU rejects the assembled command line.
#
# Two things a STOCK QEMU can't know about, handled explicitly below:
#   - vmvga: this build's VMware adapter (qemu-vmvga) is named "vmvga";
#     stock QEMU calls the same class of device "vmware-svga". The names are
#     inverted, so for a stock binary we swap vmvga -> vmware-svga.
#   - reims-vgpu-pci: a custom device stock QEMU doesn't have at all. We swap
#     it for a stock "VGA" on the SAME pci-bridge/slot, so the bridge + slot +
#     shpc=off topology (the part that actually broke) still gets validated.
# On the real qemus/qemu-macos binary (QEMU_BIN=... to point at it) neither
# swap is needed and the exact names are validated too.
set -uo pipefail

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
LAUNCHER="$(dirname "$0")/airootfs/opt/layerosx/kiosk/mac-vm-launch.sh"

command -v "$QEMU_BIN" >/dev/null 2>&1 || { echo "no $QEMU_BIN found -- install qemu (e.g. 'pacman -S qemu-base' / 'apt install qemu-system-x86')."; exit 2; }

OVMF_CODE=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    [ -f "$c" ] && { OVMF_CODE="$c"; break; }
done
[ -n "$OVMF_CODE" ] || { echo "no OVMF firmware found -- install edk2-ovmf / ovmf."; exit 2; }
OVMF_VARS="${OVMF_CODE%CODE*}VARS${OVMF_CODE##*CODE}"
[ -f "$OVMF_VARS" ] || OVMF_VARS="$OVMF_CODE"

# Regression guard: the reconstructed command line below MUST stay in sync with
# mac-vm-launch.sh. Fail loudly if the launcher's key device lines drift, so a
# future edit can't quietly invalidate this check.
guard() { grep -qF -- "$1" "$LAUNCHER" || { echo "DRIFT: mac-vm-launch.sh no longer contains: $1"; echo "  -> update archiso/validate-qemu-args.sh to match, then re-run."; exit 3; }; }
guard 'memory-backend-memfd,id=reims-ram,size='
guard '-machine q35,memory-backend=reims-ram'
guard 'ich9-ahci,id=sata'
guard 'bus=sata.2,drive=OpenCoreBoot,bootindex=0'
guard 'bus=sata.4,drive=MacHDD'
guard 'chassis_nr=5,id=pci.5,bus=pcie.0,addr=1e.0,shpc=off'
guard '-device vmvga'

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
qemu-img create -f qcow2 "$TMP/oc.qcow2" 64M >/dev/null
qemu-img create -f qcow2 "$TMP/hdd.qcow2" 64M >/dev/null
qemu-img create -f qcow2 "$TMP/rec.qcow2" 64M >/dev/null
cp "$OVMF_CODE" "$TMP/code.fd"; cp "$OVMF_VARS" "$TMP/vars.fd"
OSK="$(echo 'bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap' | tr 'A-Za-z' 'N-ZA-Mn-za-m')"

COMMON=(
  -name macOS -nodefaults -no-reboot -rtc base=utc
  -m 8192M
  -object "memory-backend-memfd,id=reims-ram,size=8192M,share=on"
  -machine q35,memory-backend=reims-ram
  -cpu qemu64 -smp 8,sockets=1,cores=8,threads=1
  -drive "if=pflash,format=raw,readonly=on,file=$TMP/code.fd"
  -drive "if=pflash,format=raw,file=$TMP/vars.fd"
  -device "isa-applesmc,osk=$OSK" -smbios type=2
  -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1
  -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
  -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 -device usb-ehci,id=ehci
  -device ich9-ahci,id=sata
  -drive "id=OpenCoreBoot,if=none,format=qcow2,snapshot=on,file=$TMP/oc.qcow2"
  -device ide-hd,bus=sata.2,drive=OpenCoreBoot,bootindex=0
  -drive "id=MacHDD,if=none,format=qcow2,file=$TMP/hdd.qcow2"
  -device ide-hd,bus=sata.4,drive=MacHDD
  -netdev user,id=net0 -device vmxnet3,netdev=net0,id=net0,romfile=
  -drive "id=InstallMedia,if=none,format=qcow2,file=$TMP/rec.qcow2"
  -device ide-hd,bus=sata.3,drive=InstallMedia
  -display none -S
)

# Pick the display device names the given binary actually has. (An unknown
# device's error from `-device X,help` goes to stdout, not stderr, so probe the
# device LIST instead -- reliable across QEMU versions.)
have_dev() { "$QEMU_BIN" -device help 2>&1 | grep -q "\"$1\""; }
if have_dev vmvga; then VMDEV=vmvga; else VMDEV=vmware-svga; fi
if have_dev reims-vgpu-pci; then REIMSDEV=reims-vgpu-pci; else REIMSDEV=VGA; fi

fail=0
run() {
  local label="$1"; shift
  local err; err="$(timeout 6 "$QEMU_BIN" "${COMMON[@]}" "$@" 2>&1 1>/dev/null)"; local rc=$?
  if [ "$rc" = "124" ]; then
    echo "PASS  $label  (machine built, halted at -S)"
  else
    echo "FAIL  $label  (rc=$rc)"
    echo "$err" | grep -iE "not a valid|does not support|Unsupported|could not|not found|Invalid|no such|failed|error" | head -6 | sed 's/^/        /'
    fail=1
  fi
}

echo "Validating with: $($QEMU_BIN --version | head -1)   [vm=$VMDEV reims=$REIMSDEV]"
run "vmware path" -vga none -device "$VMDEV"
run "reims  path" -vga none -device pci-bridge,chassis_nr=5,id=pci.5,bus=pcie.0,addr=1e.0,shpc=off -device "${REIMSDEV},bus=pci.5,addr=00.0"
exit "$fail"
