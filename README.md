# LayerOSX

An installer ISO for a deliberately empty Arch Linux whose only job is
to boot straight into an accelerated macOS VM (via
[qemus/qemu-macos](https://github.com/qemus/qemu-macos), which embeds
[Reims-vGPU](https://reims-vgpu.com/)). The goal: turn the laptop on,
see macOS boot — no visible Linux desktop, no manual steps after
install (other than picking where macOS comes from, once).

## Project status

This has **not been tested on real hardware yet**. It's a functional,
technically-reviewed skeleton, but the archiso/Calamares side only
gets validated by actually booting off a USB drive — the first attempt
will need iteration, mainly around the two most uncertain points: the
`qemus/qemu-macos` build inside `customize_airootfs.sh`, and the exact
Reims-vGPU accelerated-video flag in `kiosk/mac-vm-launch.sh`. See
`docs/CHECKLIST.md` for the step-by-step test plan.

## How it all fits together

```
Installer (ISO, boots from a Ventoy USB drive)
  └── Calamares, with real UI only for partitioning (same as you
      already do: reuse the ~200 MB EFI partition, never format it).
      Everything else (locale=en_US, keyboard=us, user, GRUB) is
      fixed, no questions asked — see postinstall/*.sh
        └── at the end, runs postinstall/run.sh on the installed
            system
              ├── locale, keyboard, hostname, "mac" user
              ├── NVIDIA driver + KVM
              ├── GRUB, reusing the existing EFI partition
              └── autologin of "mac" on tty1 + kiosk

First boot of the installed system:
  automatic login → kiosk/mac-vm-launch.sh
    └── no VM yet? → macos-source-wizard.sh (one question, zenity):
          1. Download the recovery image directly from Apple (default)
          2. I already have a macOS VM/disk — pick it from disk
          3. I already have an installer .dmg (App Store/another Mac)
             — pick it from disk (experimental, see docs/CHECKLIST.md)
    └── QEMU in fullscreen — this is where YOU take over: Disk
        Utility, installing macOS, Setup Assistant — that part stays
        yours, it's not automated (on purpose: it's the personal part,
        Apple ID, account, etc.)

Once macOS is installed:
  Restart from the Apple menu → the physical machine really reboots
  Shut Down from the Apple menu → the physical machine really powers off
  (mechanism: QMP + `-no-reboot`, see kiosk/README.md — done this way
  because a Restart should also clear up any problem with the Arch
  layer underneath, not just the VM)
```

## About baking macOS "into" the ISO itself

Can't be done, and that's not what this project does. Bundling an
Apple image/installer inside the ISO you distribute would mean
redistributing Apple's copyrighted software — a real problem, and it
wouldn't make this any more "automatic" either. What this project
automates is the download/preparation, always running on your own
hardware, onto your own disk, at the moment YOU do it: the ISO itself
never carries anything from Apple. This is the same line OSX-KVM and
the whole macOS-VM community has always followed — and it's still
against Apple's EULA to run macOS outside Apple hardware, accelerated
or not; nothing here changes that.

The "browse the disk and pick a newer `.dmg`" idea you wanted is in
the wizard (option 3) — it's the most experimental of the three,
because installing from a real Apple `.dmg` usually means dealing with
an APFS image, and APFS support on Linux is still limited.

## Layout

- `archiso/` — the `mkarchiso` profile (vanilla Arch, not CachyOS),
  with Calamares trimmed down to: welcome, partition (real UI), summary
- `archiso/airootfs/root/postinstall/` — scripts that run on the
  already-installed system, chrooted, before the first real boot
- `archiso/airootfs/opt/layerosx/kiosk/` — the VM launcher, the
  first-run wizard, and the shutdown/reboot watchdog via QMP
- `archiso/prepare-qemu-macos.sh` — runs on the build host, before
  `mkarchiso` (needs Docker): builds the custom `qemu-system-x86_64`
  (Reims-vGPU) from `qemus/qemu-macos` and stages it into the profile.
  This one's a real from-source QEMU build, expect 30-60+ minutes.
- `archiso/airootfs/root/customize_airootfs.sh` — builds `dmg2img` at
  ISO build time (a small, ordinary build, runs fine inside the
  chroot) and checks the qemu binary above actually got staged
- `docs/CHECKLIST.md` — step-by-step build/test plan, with the points
  most likely to need adjusting

## Build

```sh
cd archiso && ./build.sh
```

Needs to run on an Arch-based machine with the `archiso` package
installed (your CachyOS works — or the
`archlinux-2026.09.01-x86_64.iso` you already have, booted as a live
environment, also works just for this step). Produces a `.iso` to drag
onto your Ventoy drive.
