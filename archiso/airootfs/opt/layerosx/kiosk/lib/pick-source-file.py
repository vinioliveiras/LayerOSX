#!/usr/bin/env python3
# Native "pick a macOS source file" dialog -- Tkinter/Tk instead of
# zenity's --file-selection (GTK). Kept as its own small script (not
# inlined into macos-source-wizard.sh's bash) so it's trivial to test
# standalone: `python3 pick-source-file.py`.
#
# Why not zenity for this one: GTK's own libraries are the exact thing
# that already broke zenity once on this project (a bundled QEMU
# build's Debian-flavored libglib/libgtk leaking into zenity's
# environment via a shared LD_LIBRARY_PATH crashed it outright on
# every call -- see README.md). Tk has no dependency on GTK at all, so
# that whole class of bug can't recur here regardless of what
# qemus/qemu-macos or anything else ends up bundling.
#
# Needs the `tk` package (see packages.x86_64) -- Arch's own `python`
# package already ships the _tkinter extension built in, it just needs
# Tcl/Tk's shared libraries present at runtime to actually load it.
import os
import sys
import tkinter as tk
from tkinter import filedialog


def main() -> int:
    # mount-removable-media.sh (run by macos-source-wizard.sh right
    # before this) mounts USB media read-only under here -- start
    # browsing there so a drive with the file on it is one click away
    # instead of buried under the live-ISO root filesystem.
    initial_dir = "/mnt/media" if os.path.isdir("/mnt/media") else "/"

    root = tk.Tk()
    root.withdraw()
    root.attributes("-topmost", True)

    path = filedialog.askopenfilename(
        parent=root,
        title="Pick a macOS VM disk, .dmg, or .iso",
        initialdir=initial_dir,
        filetypes=[
            ("macOS sources", "*.qcow2 *.img *.raw *.vmdk *.vdi *.vhd *.vhdx *.iso *.dmg *.app"),
            ("All files", "*"),
        ],
    )

    root.destroy()

    if path:
        print(path)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
