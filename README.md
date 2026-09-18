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

You need an Arch-based Linux shell with the `archiso` package, plus
Docker (or Podman) for the one-time custom QEMU build. Two ways to get
that shell:

### Option A — native Arch/CachyOS

```sh
sudo pacman -S archiso docker docker-buildx git
sudo systemctl enable --now docker
git clone https://github.com/vinioliveiras/LayerOSX.git
cd LayerOSX/archiso
./build.sh
```

### Option B — Windows, via WSL2 (no dual-boot / native Linux needed)

1. Open PowerShell **as Administrator** and install an Arch WSL
   distro:
   ```powershell
   wsl --install -d ArchLinux
   ```
   If it asks for a reboot, reboot, then open "Arch Linux" from the
   Start menu to finish first-time setup (it'll ask you to create a
   Linux user).

2. Inside that Arch Linux WSL shell:
   ```sh
   pacman -Syu --noconfirm
   pacman -S --noconfirm archiso docker docker-buildx git base-devel python
   systemctl enable --now docker
   ```
   (If `systemctl enable --now docker` complains that the system
   "has not been booted with systemd", your WSL distro doesn't have
   systemd enabled — see the Arch WSL docs to turn it on, or run the
   Docker daemon manually instead.)

3. **Clone into WSL's own filesystem, not a Windows path.** Building
   an ISO needs loop devices, sockets and other special files that
   don't work over a `/mnt/c/...` or `/mnt/d/...` (NTFS/drvfs) path —
   this is a well-known WSL limitation, not specific to this project:
   ```sh
   git clone https://github.com/vinioliveiras/LayerOSX.git ~/LayerOSX
   cd ~/LayerOSX/archiso
   ./build.sh
   ```
   Once it's done, copy the result back to the Windows side, e.g.:
   ```sh
   cp out/*.iso /mnt/d/Downloads/
   ```

### What actually happens

`build.sh` first checks whether the custom QEMU binary
(`airootfs/opt/layerosx/bin/qemu-system-x86_64`) already exists; if
not, it runs `prepare-qemu-macos.sh` for you, which builds real QEMU
from source via Docker — **this alone typically takes 30-60+ minutes**
the first time, depending on your machine. After that, `mkarchiso`
itself is much faster. The finished `.iso` lands in `archiso/out/` —
drag it onto your Ventoy drive.

### If you're picking up this project fresh

If `git clone` gives you scripts that fail with `Permission denied`
when you try to run them, it's not your setup — some earlier commits
on this repo were made from a Windows machine with
`core.filemode=false`, which silently drops the executable bit. This
has been fixed going forward, but if you ever hit it again:
```sh
find . -name '*.sh' -exec chmod +x {} \;
```

If `prepare-qemu-macos.sh` "succeeds" (no error, all 26 Docker steps
print `Removed intermediate container`) but `build.sh` then fails to
find the compiled binary, it's almost certainly this: a fresh
`pacman -S docker` (or a Docker install with no `buildx` package)
defaults `docker build` to the legacy builder, which silently treats
the upstream Dockerfile's `RUN <<EOF ... EOF` heredocs as a no-op —
no error, it just never runs the compile step inside them. You'll see
`DEPRECATED: The legacy builder is deprecated...` at the very top of
the build log if this is happening. `prepare-qemu-macos.sh` now forces
`DOCKER_BUILDKIT=1` itself, so this shouldn't bite you again, but if
you're ever calling `docker build` on this Dockerfile by hand, always
set that env var (or use `docker buildx build`) first.

There's also a genuine bug in the upstream `qemus/qemu-macos` Dockerfile
itself (as of this writing): the step that checks out QEMU
(`EOF_SOURCE`) places it at `/src/reims/vendor/qemu-11.1`, but the very
next step that applies `patches/*.patch` (`EOF_PATCHES`) still refers to
the old `/src/qemu` path from before that was refactored, so it fails
with `fatal: cannot change to '/src/qemu': No such file or directory`.
`prepare-qemu-macos.sh` now patches this path in its own temp clone of
the Dockerfile before building, so you shouldn't need to think about it —
but if upstream fixes this later, that workaround becomes a harmless
no-op sed (worth removing next time you touch this file).
