#!/usr/bin/env python3
"""Which GPU Reims draws with, and which vendor that is.

    gpu-pick.py <choice> <mac-output> [<failed-icd>]
      choice      Settings > Displays > Graphics card: an ICD file name, or auto
      mac-output  the xrandr output showing the Mac (displays.py mac-output)
      failed-icd  an automatic pick that failed before (skipped)
    prints: <icd path or "-"> <vendor id or "-"> <why>

On Automatic, Reims would pick the discrete GPU -- and on a hybrid laptop
whose built-in screen hangs off the integrated GPU, every frame then crosses
GPUs (a copy per frame). So Automatic now picks the GPU that drives the
Mac's screen: Xorg's primary GPU (boot_vga) for its own outputs, the other
one for a secondary provider's outputs (xrandr names those NAME-<provider>-<n>,
e.g. HDMI-1-0). Only for exactly two GPUs; otherwise Reims' own choice.
The vendor is also reported for a fixed choice (power-mode.sh uses it to
raise that GPU's clocks in Performance mode).
"""
import glob
import os
import re
import sys

DRM = os.environ.get("LAYEROSX_DRM", "/sys/class/drm")
ICD_DIRS = os.environ.get("LAYEROSX_VK_ICD_DIRS", "/usr/share/vulkan/icd.d:/etc/vulkan/icd.d").split(":")
VENDOR_ICDS = {"0x10de": ("nvidia_icd",), "0x1002": ("radeon_icd",), "0x8086": ("intel_icd",)}
SECONDARY = re.compile(r"^[A-Za-z]+(?:-[A-Za-z]+)?-\d+-\d+$")


def _read(p):
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return ""


def gpus():
    """[(vendor, boot_vga)] for each GPU (card*, not connectors)."""
    out = []
    for card in sorted(glob.glob(os.path.join(DRM, "card[0-9]*"))):
        if "-" in os.path.basename(card):
            continue
        dev = os.path.join(card, "device")
        v = _read(os.path.join(dev, "vendor"))
        if v:
            out.append((v, _read(os.path.join(dev, "boot_vga")) == "1"))
    return out


def icd_for(vendor):
    for d in ICD_DIRS:
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for key in VENDOR_ICDS.get(vendor, ()):
            for n in names:
                if n.startswith(key) and n.endswith(".json"):
                    return os.path.join(d, n)
    return ""


def vendor_of_icd(name):
    n = os.path.basename(name).lower()
    for v, keys in VENDOR_ICDS.items():
        if any(n.startswith(k) for k in keys):
            return v
    return "0x10de" if n.startswith("nouveau") else "0x1002" if n.startswith("amd_") else ""


def pick(choice, output, failed=""):
    g = gpus()
    if choice and choice != "auto":
        return "-", vendor_of_icd(choice) or "-", "fixed choice"
    discrete = [v for v, boot in g if not boot]
    if len(g) != 2:
        # One GPU: that's the one. More: leave it to Reims (discrete first).
        v = g[0][0] if len(g) == 1 else (discrete[0] if discrete else "-")
        return "-", v, "Reims' own choice"
    primary = next((v for v, boot in g if boot), g[0][0])
    other = next((v for v, boot in g if not boot), g[1][0])
    want = other if output and SECONDARY.match(output) else primary
    if g[0][0] == g[1][0]:
        return "-", want, "two GPUs of the same vendor (one Vulkan driver)"
    icd = icd_for(want)
    if not icd or os.path.basename(icd) == failed:
        return "-", (discrete[0] if discrete else want), ("auto pick failed before" if icd else "no Vulkan driver for it")
    return icd, want, f"drives {output or 'the screen'}"


def main(argv):
    if len(argv) < 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    icd, vendor, why = pick(argv[1], argv[2], argv[3] if len(argv) > 3 else "")
    print(icd, vendor, why)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
