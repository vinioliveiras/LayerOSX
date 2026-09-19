# LayerOSX

An installer ISO for a deliberately empty Arch Linux whose only job is
to boot straight into an accelerated macOS VM (via
[qemus/qemu-macos](https://github.com/qemus/qemu-macos), which embeds
[Reims-vGPU](https://reims-vgpu.com/)). The goal: turn the laptop on,
see macOS boot — no visible Linux desktop, no manual steps after
install (other than picking where macOS comes from, once).

**Hardware support:** works on any Intel or AMD (Ryzen) CPU, and any
NVIDIA, AMD or Intel GPU — Reims-vGPU accelerates over Vulkan on the
host, it isn't tied to one vendor. `postinstall/10-hardware-detect.sh`
detects what's actually in the machine being installed onto (CPU
vendor for the right KVM module, GPU vendor for driver config) and
configures only that — nothing to pick, no prompts. All the relevant
driver packages (NVIDIA, Mesa/RADV, Mesa/ANV) ship on the ISO
unconditionally either way.

## Project status

This has **not been tested on real hardware yet**. It's a functional,
technically-reviewed skeleton, but the archiso/install-wizard side
only gets validated by actually booting off a USB drive — the first attempt
will need iteration, mainly around the two most uncertain points: the
`qemus/qemu-macos` build inside `customize_airootfs.sh`, and the exact
Reims-vGPU accelerated-video flag in `kiosk/mac-vm-launch.sh`. See
`docs/CHECKLIST.md` for the step-by-step test plan.

## How it all fits together

```
Installer (ISO, boots from a Ventoy USB drive)
  └── install-wizard.sh, with real UI only for partitioning (GParted —
      same as you already do: reuse the ~200 MB EFI partition, never
      format it) and picking which partition is root/ESP. Everything
      else (copying the system over, fstab, machine-id, locale=en_US,
      keyboard=us, user, GRUB) is fixed, no questions asked
        └── at the end, runs postinstall/run.sh (chrooted) on the
            installed system
              ├── locale, keyboard, hostname, "mac" user
              ├── hardware detection: CPU vendor -> right KVM module, GPU vendor -> driver config
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

- `archiso/` — the `mkarchiso` profile (vanilla Arch, not CachyOS).
  `airootfs/root/.xinitrc` boots straight into
  `kiosk/install-wizard.sh`: GParted for partitioning (real UI, the
  one thing that can't be safely automated), then the script itself
  does the rest (copy the live system over, fstab, machine-id, chroot
  in and run postinstall/run.sh) — no other prompts
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
Docker (or Podman) for the one-time custom QEMU build. Everything
else (GParted, zenity, etc.) is in Arch's official repos — no
third-party repos or AUR helpers needed. Two ways to get that shell:

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

If the ISO boots into a black screen and then loops in
`systemd` emergency mode with `Timed out waiting for device
/dev/gpt-auto-root` (and you can't even log into the emergency shell
because "the root account is locked"), the profile is missing
`airootfs/etc/mkinitcpio.conf.d/archiso.conf`. Without it, `mkarchiso`
builds a normal, install-target-style initramfs (default HOOKS from
the `linux` package's own preset) instead of one that knows how to
find and mount the live squashfs — so the kernel falls back to
`systemd-gpt-auto-generator`, looking for a real GPT root partition
that doesn't exist on a live medium, and times out. This file is
supposed to come from the official `releng` reference profile
(`/usr/share/archiso/configs/releng/airootfs/etc/mkinitcpio.conf.d/archiso.conf`)
but wasn't copied over when this profile was first put together. It's
now part of the repo, so a fresh clone shouldn't hit this — but if you
ever regenerate the profile from scratch, remember to bring this file
along.

Adding that config file alone isn't enough, though: the hooks it
references (`archiso`, `archiso_loop_mnt`, `memdisk`, ...) — and the
`memdiskfind` binary some of them need — are shipped by the
`mkinitcpio-archiso` package, which has to be installed **inside the
ISO itself** (`packages.x86_64`), not just present on the build host.
Without it, `mkinitcpio` runs inside the airootfs during the build
without those hooks available, and you get a related-but-different
failure: the boot log shows `running hook [memdisk]` /
`memdiskfind: not found`, then `mounting '' on real root` (an empty
device) and the same emergency-mode dead end. `packages.x86_64` now
includes `mkinitcpio-archiso`; confirmed against the same `releng`
reference profile.

If the live ISO reaches `archlinux login: root (automatic login)` and
then the screen just flickers endlessly (X starting, dying, tty1
autologin immediately retrying `startx`, over and over): this was
found testing in a VM — `packages.x86_64` had no explicit X video
driver (only `mesa`), so a virtual GPU without a working DRM/KMS
"modesetting" driver leaves Xorg with nothing to use and it crashes on
every attempt. `xf86-video-fbdev` is now included as a generic
fallback (real hardware should still get a proper driver — NVIDIA via
`nvidia-open-dkms`, AMD/Intel via `mesa`'s own modesetting — and
shouldn't need it, but it's there either way).

Related: the live root account now has a debug password (`layerosx`,
set in `customize_airootfs.sh`, live-ISO-only — the installed system
still ends up with root locked, same as before, via
`postinstall/01-base-system.sh`'s own `passwd -l root`). Without this,
there was no way to get a shell to actually debug a stuck/flickering
live session (Ctrl+Alt+F2 refused login, and `sulogin` in emergency
mode refuses a locked account too) — every issue had to be diagnosed
from photos of the screen, which is exactly what forced the fixes
above to be found the slow way.

One more layer to the flickering-screen issue above: `.bash_profile`
used to call `exec startx` unconditionally on every tty1 login, with
no guard. If X keeps dying, autologin retries it immediately, forever
— which is what made this so hard to debug on real hardware, since
there was never a stable console to Ctrl+Alt+F2 away to (the tty1
session kept getting torn down and re-created faster than a VT switch
could register). It now only tries once per boot (a flag file under
`/run`, which is tmpfs and clears itself every boot); if X still fails
after that, the next tty1 login just drops to a plain root shell
instead of retrying — already logged in via autologin, no password
needed — so there's finally a way to grab `/var/log/Xorg.0.log` and
actually see why.

Last piece of the flickering-screen saga: if `Xorg.0.log` ends with
`Server terminated successfully (0)` and no `(EE)` lines at all, X
isn't crashing — its only client (`.xinitrc` execs straight into
`install-wizard.sh`) is exiting almost immediately, so X has nothing
left to serve and shuts itself down cleanly. That's what was actually
happening here: `install-wizard.sh` had lost its executable bit
(`ls -la` showed `rw-r--r--`) despite git tracking it as `100755` —
checking out this repo on a Windows-mounted drive via WSL doesn't
reliably carry that bit onto disk (same root cause as the
`core.filemode=false` gotcha above, just biting a different file this
time). `profiledef.sh`'s `file_permissions` is what mkarchiso actually
applies to the final image — a directory entry there (e.g.
`/opt/layerosx`) only sets *that directory's* own mode, it does NOT
recurse into files under it, so every script that needs +x has to be
listed individually. All of them are now listed explicitly, and
`build.sh` also does a `chmod +x` sweep over `airootfs/**/*.sh` before
every build as a second layer, so a newly added script that forgets a
`profiledef.sh` entry still ships executable instead of silently
breaking the exact same way.

Two usability fixes to `install-wizard.sh`, found while it was
actually being tested for the first time: it used to have no `set -e`
at all, so a failure in `mount`, `rsync`, `genfstab`, or `arch-chroot`
partway through would just get logged and the script would keep going
regardless — silently reaching the final "Done, reboot" dialog and
rebooting into a broken, incomplete install with no indication
anything had gone wrong. It now has `set -e` plus an `ERR` trap that
shows a `zenity --error` dialog pointing at the log instead. Separately,
the long `rsync` copy step (copying the whole live system onto the
target disk — the slowest part of the install by far) used to leave
you looking at a bare black openbox desktop with zero feedback for
however long that takes. It now sets a black background
(`xsetroot -solid "#000000"`, package `xorg-xsetroot`) and shows a
pulsating `zenity --progress` dialog for the duration — a generic dark
loading look, deliberately not a recreation of Apple's actual boot
screen/logo (trademark, not something to bundle/ship).

### Gotcha: `arch-chroot` failing with "mount point does not exist" after install (and silently killing GRUB setup)

The install-wizard's `rsync` step deliberately excludes `/dev`, `/proc`,
`/sys`, `/run`, `/tmp`, `/mnt`, `/media` from the copy (they're
pseudo-filesystems / live-only paths, not meant to be copied onto the
target disk). What's easy to miss: `rsync --exclude` on a top-level
entry doesn't create an empty placeholder directory on the destination
— it skips creating the directory at all. A normal Arch root (built
via `pacstrap`) gets these directories for free from the `filesystem`
package; since this project rsyncs a live system instead, they simply
didn't exist on the installed disk.

The result: `arch-chroot /mnt /root/postinstall/run.sh` (the step that
runs locale/keyboard/user setup and, critically, GRUB installation)
failed immediately with `mount: /mnt/proc: mount point does not
exist` / `ERROR: failed to setup chroot /mnt` — meaning postinstall,
including `grub-install`, never ran at all. The install still appeared
to "finish" and reboot, but the resulting disk had no bootloader
installed, which shows up as a UEFI firmware error after reboot
(`BdsDxe: failed to load Boot0002 ... No bootable option or device was
found`) — VirtualBox/UEFI auto-generates a generic fallback boot entry
for the raw disk, but it has no `\EFI\...\grubx64.efi` to actually
load.

Fixed in `install-wizard.sh`: right after the rsync completes, it now
recreates the excluded mount-point directories (`mkdir -p /mnt/dev
/mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/mnt /mnt/media`, plus
`chmod 1777 /mnt/tmp`) before any `arch-chroot` call.

If you hit this on a disk already installed with an older build,
there's no need to reinstall from scratch — boot the live ISO again,
mount the real partitions, recreate the same directories by hand, and
re-run postinstall manually (it never ran the first time, so this is
safe):

```bash
mount /dev/sda2 /mnt        # your root partition
mount /dev/sda1 /mnt/boot   # your ESP
mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/mnt /mnt/media
chmod 1777 /mnt/tmp
arch-chroot /mnt
/root/postinstall/run.sh
exit
umount -R /mnt
reboot
```
