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

### Gotcha: boot menu shows only "UEFI Firmware Settings" (no OS entry) after a successful install

Even after `grub-install` runs without errors inside postinstall, the
resulting install can still fail to boot in VirtualBox: the firmware
menu shows nothing but "UEFI Firmware Settings", with no entry for the
installed system at all — not even the generic auto-created HARDDISK
fallback seen in the earlier bug above.

Cause: `grub-install --bootloader-id=layerosx` (no `--removable`)
relies on the NVRAM boot entry it registers via `efibootmgr` to
survive across reboots. VirtualBox's EFI firmware is well known
(Arch wiki, VirtualBox forums) for not reliably persisting guest-added
NVRAM entries — GRUB installs correctly onto the ESP, but the entry
pointing to it can simply be gone on next boot, leaving the firmware
with nothing bootable to offer.

Fixed in `postinstall/50-grub.sh`: it now also runs `grub-install
--target=x86_64-efi --efi-directory=/boot --removable --recheck`
right after the normal install. This writes GRUB to the UEFI
"removable media" fallback path (`/boot/EFI/BOOT/BOOTX64.EFI`), which
firmware boots automatically with no NVRAM entry needed at all — so
the install boots reliably in VirtualBox regardless of whether the
named `layerosx` NVRAM entry survives.

To recover a disk that's already installed and stuck at this screen,
without reinstalling: boot the live ISO, mount the real partitions and
chroot in (see the previous gotcha above for the exact commands), then
just run:

```bash
grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck
```

That alone is enough — GRUB's own config (`grub.cfg`) was already
generated correctly the first time; only the boot-entry lookup was
failing.

### Gotcha: `/boot` on the installed disk has no kernel at all (`EFI/` and `grub/` only, no `vmlinuz-linux`)

The deepest of the boot-chain bugs found so far, and the real root
cause behind the "only UEFI Firmware Settings, no OS entry" symptom
above (the `--removable` GRUB fix was still correct and necessary,
but not sufficient on its own).

`install-wizard.sh` installs by `rsync`-ing the running live system's
own `/` onto the target disk — but archiso does not put the kernel,
initramfs, or microcode images inside the live squashfs it ships.
`mkarchiso` keeps those only on the ISO's own boot media, loaded
directly by the bootloader before the squashfs is even mounted as the
live root — the live system itself has no need for a redundant local
copy under `/boot` just to keep running. So `rsync` can't restore
what was never there to begin with: the installed disk's `/boot` ends
up with only `EFI/` and `grub/` (copied fine, since those really are
regular files on the live system), no kernel at all. This is why
`mkinitcpio -P` failed with `'/boot/vmlinuz-linux' must be readable`
in `postinstall/01-base-system.sh` and `10-hardware-detect.sh`, and
why `grub-mkconfig` in `50-grub.sh` produced a `grub.cfg` with no
Linux entry — nothing was reported as a hard error (postinstall's
per-step fault tolerance masked it, same as the earlier `arch-chroot`
bug), so the install still appeared to finish.

**First fix attempt (didn't work, kept for the record):**
`postinstall/01-base-system.sh` was changed to force a `pacman -S`
reinstall of `linux`, `linux-firmware`, `intel-ucode`, `amd-ucode`
right before `mkinitcpio -P`, on the theory that pacman's local
database (rsynced along with everything else) would let `pacman -S`
re-extract the real files from the also-rsynced package cache, no
network needed. Confirmed wrong on real hardware, on two counts:
`mkarchiso` never populates the live airootfs's own
`/var/cache/pacman/pkg` in the first place (packages are pulled from
the *build machine's* own cache, not baked into the ISO), and the
rsynced system is also missing pacman's **sync** databases
(`/var/lib/pacman/sync/*.db` — distinct from the installed-package
state db, which *is* present). Without those, `pacman -S` can't even
resolve the package names (`error: target not found: linux`), so it
failed outright, offline or not.

**Actual fix:** skip pacman entirely for this. `install-wizard.sh` now
copies the real `vmlinuz-linux` straight out of the boot medium itself
— the same one currently booted, still mounted somewhere under `/run`
— into `/mnt/boot`, right after recreating the pseudo-filesystem mount
points and before `arch-chroot` ever runs. It finds it by matching the
same `<install_dir>/boot/<arch>/vmlinuz-linux` layout `mkarchiso` uses
on the ISO itself (see `efiboot/loader/entries/01-layerosx.conf`),
checked against every currently mounted filesystem except the target
disk. This needs neither pacman nor a network connection.
`linux-firmware`'s actual files (`/usr/lib/firmware/...`) don't have
this problem to begin with — they're part of the live `/` like
everything else, so they arrive via the normal rsync.

That still leaves the initramfs. The live ISO's own
`/etc/mkinitcpio.conf.d/archiso.conf` (rsynced onto the target too)
overrides `HOOKS` with archiso-specific ones (`archiso`,
`archiso_loop_mnt`, `memdisk`, the PXE hooks…) meant for booting the
*live medium*, not an installed system on a real disk — left in place,
`mkinitcpio -P` would bake those into the installed system's own
initramfs, which at best is dead weight and at worst means every real
boot tries to find a live medium that isn't there. `01-base-system.sh`
now deletes that file before calling `mkinitcpio -P`, so mkinitcpio
falls back to its own package-default `/etc/mkinitcpio.conf` (`base
udev autodetect microcode modconf kms keyboard keymap consolefont
block filesystems fsck`) — the normal set an installed system needs.

To recover a disk already installed without this fix, without
reinstalling from scratch: boot the live ISO, mount and chroot in (see
the gotchas above), then, still on the live ISO (not yet chrooted),
find and copy the kernel from the boot medium into the target, then
finish inside the chroot:

```bash
# outside the chroot, live ISO still booted from its medium:
find /run -maxdepth 6 -name vmlinuz-linux   # note the path it prints
cp /run/.../vmlinuz-linux /mnt/boot/vmlinuz-linux

arch-chroot /mnt
rm -f /etc/mkinitcpio.conf.d/archiso.conf
mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg
grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck
```

### Feature: real black/white progress bar during install (not just pulsating)

The install's disk-copy step now shows an actual percentage instead of
a pulsating "working…" bar. `rsync --info=progress2` prints an
overall `NN%` that updates in place; the script normalizes that
(`tr '\r' '\n'` + `grep -oE '[0-9]{1,3}%'`) into plain `NN` / `#text`
lines on the fly, which is the format `zenity --progress` reads from
stdin to drive a real bar. `set -o pipefail` (already set at the top
of the script) means a real `rsync` failure still fails the whole
pipeline and trips the existing `set -e`/ERR trap, even though `rsync`
is the first stage of a long pipe.

The dialogs also get a small `~/.config/gtk-3.0/gtk.css` override
(black window background, white text, a black trough / white fill
progress bar) so the whole install — not just the loading screen —
keeps a consistent black-background/white-bar look instead of
whatever the default GTK theme draws. This is a generic minimal-boot
look (black screen, white bar), not a reproduction of Apple's actual
boot screen — no Apple logo, wordmark, or other trademarked visual is
drawn anywhere, just a plain rectangle.

### Fixes/tweaks to the install progress bar (theme, monotonic %, single bar for the whole install)

Three follow-up issues found by actually watching the bar run in a VM
test, all in `install-wizard.sh`:

- **Dialogs stayed light-themed** even with the `gtk.css` override
  from the previous section. A bare user `gtk.css` can silently lose
  to the active theme's own more specific selectors. Fixed by also
  setting `export GTK_THEME=Adwaita:dark` (Adwaita ships built into
  GTK3, no extra package needed) as the actual baseline, plus a
  `~/.config/gtk-3.0/settings.ini` with `gtk-application-prefer-dark-theme=1`,
  with the `gtk.css` overrides now using `!important` on top to force
  the exact black/white (not Adwaita-dark's default greys). All three
  are written once, right after the log redirect near the top of the
  script, so every dialog in the install — not just the loading
  screen — gets it from the first one shown.
- **The bar visibly jumped backward** during the copy (e.g. 40% then
  back to 25%). Cause: by default modern `rsync` streams its file
  list incrementally as it walks the tree, so `--info=progress2`'s
  "total size" denominator keeps growing mid-copy as more files are
  discovered, and the percentage gets revised downward when that
  happens. Fixed by adding `--no-inc-recursive`, which makes rsync
  build the complete file list up front — the total is known from the
  start, so the percentage only moves forward (costs a few extra
  seconds up front scanning the tree, worth it for a bar that
  doesn't rewind).
- **A new dialog per phase looked like the process restarting.**
  Originally only the rsync copy had a progress dialog; everything
  after it (fstab, machine-id, postinstall) ran with no visual
  feedback at all, and the copy dialog auto-closing made the whole
  thing look like it reset. Replaced with a single long-lived
  `zenity --progress` fed through a named pipe (`PROGRESS_FIFO`) for
  the entire rest of the install: a `progress() { echo "$1" >&3; echo
  "#$2" >&3; }` helper writes percentage + a short "what's happening
  now" label from every phase (copy scaled to 0-70%, then fstab/
  machine-id/postinstall filling 70-100%). postinstall's own 4
  numbered steps are surfaced too — the install-wizard tails
  postinstall's own log file from outside the chroot and bumps the
  label ("Setting locale, user, hostname…", "Detecting CPU/GPU
  hardware…", etc.) each time a new step starts, so the single bar
  keeps moving and naming the current step through the whole install,
  including the minute or two postinstall itself takes. The ERR trap
  now also closes the pipe's write end first, so a failure doesn't
  leave the progress dialog stuck open behind the error dialog.

### Gotcha: live ISO hangs at boot with "ERROR: Device '<uuid>' not found", drops to an emergency shell (Ventoy-specific)

Found on a real-hardware boot via a Ventoy USB drive (the ISO booted
fine as a VirtualBox virtual CD, which is what had been used for
every VM test up to this point — this bug only shows up with a real
USB boot medium prepared by Ventoy). The `archiso`/`archiso_loop_mnt`
hooks load correctly (confirming the earlier
`mkinitcpio.conf.d/archiso.conf` fix is in place and working), but the
init script then searches every partition it can find
(`/dev/sdb1`, `/dev/sdb2`, `/dev/nvme...`, ...) for a marker file
named after the ISO's own filesystem UUID
(`/boot/<uuid>.uuid`), fails to find it anywhere, and drops to a
`[rootfs ~]#` emergency shell instead of finding its own medium.

Root cause: `efiboot/loader/entries/01-layerosx.conf` (the
systemd-boot entry mkarchiso builds from, inherited unmodified from
mkarchiso's own default new-profile template) used
`archisosearchuuid=%ARCHISO_UUID%` — search-by-UUID. This is a known
compatibility gap with Ventoy specifically: Ventoy doesn't always
expose the ISO's on-disk filesystem UUID to the booting kernel the
same way a plain `dd`/Rufus-written USB does, so the UUID the archiso
hook is told to look for is never found, even though the medium
itself is right there.

Fixed: switched to `archisolabel=%ARCHISO_LABEL%` — search by the
ISO's volume **label** (`LAYEROSX_YYYYMM`, set by `iso_label` in
`profiledef.sh`) instead of by UUID. Label-based search is the
standard, more portable alternative and is what's generally
recommended for USB-creation-tool compatibility (Ventoy included).
`%ARCHISO_LABEL%` is filled in by `mkarchiso` at build time exactly
like `%ARCHISO_UUID%` was — no other change needed.

If you land in that `[rootfs ~]#` emergency shell before rebuilding
with this fix: it's a dead end (the medium genuinely can't be found by
UUID), just power off and reboot. Note this only reproduced via a real
Ventoy USB boot — it did not show up in any VirtualBox/QEMU VM test
where the ISO is attached directly as a virtual CD-ROM, since that
path doesn't go through Ventoy's own boot-chain layer at all.

### Testing with QEMU+OVMF (recommended over VirtualBox)

VirtualBox's EFI implementation has its own known quirks (see the
GRUB `--removable`/NVRAM gotcha above) that don't reflect real
firmware behavior well. QEMU with OVMF firmware is much closer to
real UEFI and is the recommended way to iterate before testing on
actual hardware. On Windows:

1. Install QEMU from `https://qemu.weilnetz.de/w64/` (default install
   path: `C:\Program Files\qemu`).
2. The Windows build bundles EDK2/OVMF firmware under
   `C:\Program Files\qemu\share\`. Use `edk2-x86_64-code.fd` as the
   CODE file. There's no separate `edk2-x86_64-vars.fd` — the VARS
   template is shared with i386, so use `edk2-i386-vars.fd` (this is
   correct, not a typo — it's how QEMU itself pairs them by default).
   Copy the VARS file somewhere writable first (QEMU writes to it):
   ```powershell
   mkdir C:\LayerOSX-VM
   copy "C:\Program Files\qemu\share\edk2-i386-vars.fd" "C:\LayerOSX-VM\OVMF_VARS.fd"
   & "C:\Program Files\qemu\qemu-img.exe" create -f qcow2 C:\LayerOSX-VM\layerosx-test.qcow2 60G
   ```
3. Boot the ISO:
   ```powershell
   & "C:\Program Files\qemu\qemu-system-x86_64.exe" `
       -machine q35,accel=whpx `
       -cpu max `
       -m 4096 `
       -smp 4 `
       -drive if=pflash,format=raw,readonly=on,file="C:\Program Files\qemu\share\edk2-x86_64-code.fd" `
       -drive if=pflash,format=raw,file="C:\LayerOSX-VM\OVMF_VARS.fd" `
       -drive file="C:\LayerOSX-VM\layerosx-test.qcow2",if=virtio,format=qcow2 `
       -cdrom "path\to\layerosx.iso" `
       -boot d `
       -vga virtio `
       -display sdl
   ```
   `accel=whpx` needs "Windows Hypervisor Platform" enabled (Control
   Panel → Programs → Turn Windows features on or off); without it,
   fall back to `accel=tcg` (software emulation, much slower). To test
   the installed disk afterward, drop `-cdrom`/`-boot d` and re-run —
   or press Esc at the OVMF splash for its own boot menu, same
   workflow as a real machine's boot-device picker. Swap
   `edk2-x86_64-code.fd` for `edk2-x86_64-secure-code.fd` to test with
   Secure Boot enabled (unsigned archiso images are expected to fail
   to boot in that case — see the Secure Boot note in the checklist).

### Gotcha: real-hardware Ventoy boot never finds its own medium — no `/dev/loop*` at all (isohybrid MBR missing)

Found on a real Ventoy USB boot on physical hardware, after the
`archisolabel` fix above was already in place and working (the log
clearly showed it searching `/dev/disk/by-label/LAYEROSX_<date>`, not
by UUID anymore) — it still timed out and dropped to the archiso
emergency shell. From there, `ls /dev/loop*` showed only
`/dev/loop-control` (no actual loop device instantiated at all), and
`cat /proc/partitions` listed only the real physical disks/partitions
— nothing at all backed by the ISO's own filesystem.

Root cause: `profiledef.sh` had `bootmodes=('uefi.systemd-boot')` —
UEFI only, on purpose (this project only ever intends to support UEFI
boot). But that bootmode alone doesn't make `mkarchiso` write an
isohybrid MBR / El Torito boot catalog into the ISO — that structure
only gets generated when at least one `bios.syslinux.*` bootmode is
also enabled. Without it, tools like Ventoy can't recognize/loopback-
mount the whole ISO as a disk; they can only chainload the kernel and
initramfs directly out of it, so the running system's own `archiso`
init hook — however it searches for its medium, by UUID or by label —
has nothing to find, because the ISO's own filesystem was never made
available as a device at all. This is also why it never showed up in
any VM test: VirtualBox/QEMU attach the `.iso` file directly as a
virtual CD-ROM, which sidesteps this whole problem (the VM's own
"drive" already presents the ISO as a device, independent of whatever
boot-catalog structure is or isn't embedded in the file).

Fixed: `bootmodes` now also includes `bios.syslinux`, alongside the
existing `uefi.systemd-boot` (left untouched — still the only mode
actually used to boot). This is not about adding real legacy-BIOS
support; it's what gets `mkarchiso` to embed the isohybrid MBR
structure that USB-writing tools (Ventoy included) rely on to treat
the ISO as a proper disk image. It's also just what every official
Arch ISO does, for the same reason. This mode needs a `syslinux/`
directory with the standard archiso templates, which this UEFI-only
profile never had — copied verbatim from the local `archiso`
package's own `releng` reference profile
(`/usr/share/archiso/configs/releng/syslinux/`), the same source
already used for the `mkinitcpio.conf.d/archiso.conf` fix earlier.

(Note: `bios.syslinux.mbr`/`bios.syslinux.eltorito` — the mode names
used in an earlier version of this fix — are deprecated in newer
`archiso` releases in favor of the single combined `bios.syslinux`
token; `mkarchiso` only warns about the old names, it still builds,
but use the current one. Also needs the `syslinux` package itself in
`packages.x86_64` — without it `mkarchiso` refuses to build at all
with "The 'syslinux' package is missing from the package list!", since
it extracts the actual syslinux binaries from that package. Added
`memtest86+`/`memtest86+-efi` too, just to quiet mkarchiso's unrelated
informational notices about memory testing being unavailable.)

### Feature: force each monitor to its real max refresh rate at kiosk startup

On a multi-monitor machine, X's own EDID-based auto-detection doesn't
always pick a display's actual best mode — seen firsthand on a second
monitor, whose image came out visibly corrupted/noisy until forced to
its real max refresh rate by hand with `xrandr`.

Rather than hardcode a fixed mode in an `xorg.conf` (which would be
flat-out wrong on any other monitor/setup), `kiosk/lib/force-max-refresh.sh`
runs from both `.xinitrc` entry points (the live-ISO install session,
and the installed system's kiosk session for the `mac` user) right
after `openbox` starts. It re-detects every *currently connected*
output via `xrandr --query`, and for each one, re-applies its own
*current* resolution at the highest refresh rate that same resolution
actually supports — no resolution changes, just the rate. Runs in the
background (`&`) so it never delays the actual kiosk/install UI, and
no-ops quietly if `xrandr` is missing or a display reports nothing
useful. Needs the `xorg-xrandr` package (added to `packages.x86_64` —
`xorg-server` alone doesn't include the `xrandr` binary).

### Gotcha: macOS VM shows a black screen forever (recovery/installer disk never actually attached)

`macos-source-wizard.sh`'s "download from Apple" path (`fetch-recovery.sh`)
and its ".dmg" path (`extract-dmg-installer.sh`) both prepare a second
disk image next to `$VM_DISK` — `<name>-recovery.qcow2` or
`<name>-installer.qcow2` — but `mac-vm-launch.sh` never actually
attached either one to QEMU. So after the first-run wizard finished,
the VM launched with only the empty target disk: nothing to boot,
nothing to show, just a black `-display sdl` window with no error at
all (OVMF has nowhere to go, so it just sits there).

Fixed: `mac-vm-launch.sh` now looks for either file next to `$VM_DISK`
and attaches whichever one exists as an extra `-drive` on every
launch — harmless once macOS is actually installed onto `$VM_DISK`
(OVMF's own boot manager should prefer the disk that's actually
bootable), and it's what makes the first boot able to reach the
recovery/installer environment at all. Uses the same `if=virtio`
interface as the main disk for consistency; if macOS's own
recovery/installer environment turns out not to have a virtio block
driver that early (a real possibility — untested on real hardware
yet), it'll need switching to a real AHCI/SATA drive instead — see the
comment in `mac-vm-launch.sh`.

### Feature: a visible terminal for kiosk steps that don't have their own UI yet

`macos-source-wizard.sh`'s download/extract steps could take minutes
(multi-GB download, or converting a disk image) with zero feedback of
their own — from the outside this looked exactly like a frozen/black
screen, indistinguishable from something actually being broken. Rather
than build real progress UI for every such step right now,
`run_in_terminal()` (in that script) runs the underlying command inside
a visible `xterm` instead of silently in the background: closes itself
a couple seconds after a successful run, or waits for Enter on failure
so the error output stays readable before the caller's own `zenity
--error` dialog shows. Needs the `xterm` package (added to
`packages.x86_64`). Same idea can wrap any other not-yet-polished step
later instead of leaving it silent.

### Feature: GRUB shows other installed OSes too (os-prober)

Modern GRUB ships with `os-prober` disabled by default (a past CVE:
an unprivileged user could get `grub-mkconfig`, run as root, to act on
another mounted OS) — but this project deliberately reuses the
existing ESP and never touches the rest of the disk specifically so it
can coexist with whatever else is already installed (Windows, other
Linux distros, ...), so the whole point is defeated if GRUB never
shows them. `os-prober` and `ntfs-3g` were already in
`packages.x86_64`; `postinstall/50-grub.sh` now also sets
`GRUB_DISABLE_OS_PROBER=false` in `/etc/default/grub` before
`grub-mkconfig` (handling the line being absent, commented out, or
already present, since that depends on the exact `grub` package
template) so those tools actually get used.

### Gotcha: install finishes but `umount: /mnt: target is busy` at the very end, install-wizard.sh dies to a bare root shell

Real-hardware install log confirmed the kernel/GRUB fixes above
actually worked (`Found linux image: /boot/vmlinuz-linux`) — but the
very last step, `umount -R /mnt`, failed as "busy" and killed the
script right there (the `ERR` trap did fire, but its `zenity --error`
call silently no-ops once X is already gone, since the trap runs as
the script — and with it the whole `exec`'d X session — is exiting).
The user never sees the "Done, reboot" dialog, just lands back on the
root autologin shell, and has to reboot manually — with the EFI System
Partition (FAT32, holding the kernel/initramfs/grub.cfg just written)
still mounted, risking exactly those files not being fully flushed to
disk before a hard reboot.

Root cause: the postinstall log-tailing job (`( tail -F ... | while
read...; ) &`, `TAIL_PID=$!`) backgrounds a *subshell* wrapping a
pipeline — killing `$TAIL_PID` kills that subshell, but not
necessarily `tail` itself (a separate child process holding the pipe's
write end and the actual open file handle on
`/mnt/var/log/layerosx-postinstall.log`). A leaked `tail -F` is enough
on its own to make `umount -R /mnt` fail as busy.

Fixed in two layers: `install-wizard.sh` now also kills `$TAIL_PID`'s
direct children (found via `/proc/$TAIL_PID/task/$TAIL_PID/children`,
no extra package needed) so `tail` can't linger; and the final
`umount -R /mnt` now retries a few times and, if it's still busy after
that (anything else unexpected holding it open), falls back to a lazy
unmount (`umount -R -l`) instead of letting the whole install die at
the last step.

### Feature: pick an existing macOS source from a USB drive, and connect to Wi-Fi to download one

Two related first-run wizard gaps, both from the same cause: this is a
minimal openbox kiosk with no desktop shell, so nothing here ever
automounted removable media or exposed Wi-Fi setup.

- **"I already have a VM/disk" showed nothing to pick.** zenity's file
  dialog only ever browses the local filesystem tree from wherever it
  starts — a USB drive that was never mounted anywhere is invisible to
  it, regardless of what's actually on it. `kiosk/lib/mount-removable-media.sh`
  now mounts every currently-unmounted partition with a recognizable
  filesystem (read-only) under `/mnt/media/<name>` before the wizard's
  file dialog opens, which is also pointed at `/mnt/media/` as its
  starting directory.
- **The "existing VM/disk" and ".dmg installer" options are now one
  picker** that also accepts `.iso` (recovery/installer media, handled
  the same way `.dmg` already was — via `qemu-img convert -f raw`
  since an `.iso` is raw ISO9660 data, not a qcow2 container),
  dispatched by the picked file's extension: `.qcow2`/`.img`/`.raw` is
  treated as a complete, already-installed system (copied straight to
  `$VM_DISK`); `.iso`/`.dmg`/`.app` is treated as installer/recovery
  media (goes on the separate disk `mac-vm-launch.sh` already knows
  how to attach, next to a freshly created blank `$VM_DISK`).
- **No way to get online for the "download from Apple" option** on a
  Wi-Fi-only machine — `NetworkManager` was already enabled, but
  nothing ever exposed a way to pick a network and enter a password on
  this panel-less kiosk. The wizard now checks connectivity first
  (`curl` against the exact host `fetch-recovery.sh` needs) and, if
  there's none, offers to open `nmtui` (NetworkManager's text UI, part
  of the already-installed `networkmanager` package) in a terminal.

Also added `ttf-dejavu` to `packages.x86_64` — `xterm -fa Monospace`
(used by `run_in_terminal()` and the new Wi-Fi setup terminal) needs
an actual font installed to resolve that name against, and nothing
else in the package list was pulling one in reliably.

### Feature: logs auto-saved to the USB drive (Ventoy preferred)

During this testing phase especially, a failure often happens exactly
where there's no easy way to read a log — a black screen, or a reboot
loop, leaves no tty to type commands into, and photographing a
terminal back and forth is slow. `kiosk/lib/save-logs-to-usb.sh` is a
best-effort script that finds a removable USB partition (preferring
one labeled "Ventoy" — that's what's actually plugged in during
testing, since it's the install medium itself — falling back to any
other removable exfat/ntfs/vfat partition), mounts it if needed, and
copies every known LayerOSX log plus a `journalctl -b` snapshot of the
current boot into a timestamped `layerosx-logs/<UTC timestamp>-<host>/`
folder on it — plain text files, readable from any machine (Windows
included) with zero booting, no tty, no photo needed.

Wired into every point where something can go wrong:
- `install-wizard.sh`'s `ERR` trap (any install failure) and again
  right before the final unmount on a *successful* install (so the
  postinstall log on the target gets picked up too, while `/mnt` is
  still mounted).
- A new `layerosx-save-logs.service` (oneshot, enabled by default,
  runs early on every boot of the *installed* system — same pattern
  as the existing `layerosx-cleanup.timer`) — this is what covers a
  silent boot failure with no GUI ever coming up at all.
- `mac-vm-launch.sh`, after every QEMU session exits (crash or clean),
  refreshing `mac-vm.log` and a fresh journal snapshot.

Never fails loudly — a missing/unwritable USB just means no log copy
that run, never a broken boot/install.

### Gotcha: mouse cursor invisible on the installed system's first boot

`postinstall/40-kiosk-autologin.sh` started the `mac` user's X session
with `startx "$HOME/.xinitrc" -- -nocursor`, which hides the mouse
pointer for the *entire* X session — not just once QEMU/SDL is up and
drawing its own cursor inside the VM, but also during
`macos-source-wizard.sh`'s own zenity dialogs and file pickers on
first boot (before any VM disk exists yet), which genuinely need a
visible, clickable cursor. Root's own live-ISO session never had this
flag (`startx /root/.xinitrc`, no `-nocursor`) and has always worked
fine — so it's dropped from the installed system's session too now,
to match.

If a doubled/duplicate-looking cursor ever shows up specifically once
a macOS VM is actually running full-screen (a real possibility with
`-display sdl` — this wasn't the reason `-nocursor` broke anything, so
it's untested either way), the better fix would be hiding the cursor
right before `mac-vm-launch.sh` actually execs QEMU and restoring it
after, not blanking it for the whole session again.

### Gotcha: runtime kernel search failed on real hardware ("Could not find the kernel on the boot medium")

The previous fix (searching the live boot medium at runtime for
`<install_dir>/boot/<arch>/vmlinuz-linux`, prioritizing
`/run/archiso/bootmnt`) failed on an actual real-hardware install via
Ventoy — the search came up completely empty, on every mounted
filesystem. Never pinned down the exact reason (possibly the medium
gets unmounted once the squashfs is copied to RAM, possibly Ventoy's
runtime mount layout just doesn't match plain archiso's — the live
session was already closed by the time this was reported, so the
diagnostic dump this fix now adds wasn't available yet to confirm
either way).

Rather than guess at Ventoy/archiso runtime internals a third time,
sidestepped the problem: `customize_airootfs.sh` (build time, runs
*before* `mkarchiso` extracts `/boot/vmlinuz-linux` out to the ISO's
own separate boot directory and packs the squashfs) now stashes a
copy at `/opt/layerosx/vmlinuz-linux.stashed` — a path mkarchiso has
no reason to touch, so it rides along inside the squashfs like any
other file under `/opt/layerosx`, and rsyncs onto the installed target
like everything else in "/". `install-wizard.sh` now copies from
there first — no runtime medium-searching needed at all. The old
runtime search is kept as a fallback (for an ISO built before this
fix), and if kernel-finding ever fails completely again, the install
now dumps real diagnostics (`findmnt`, `/opt/layerosx` listing,
`/run/archiso` tree) into the install log *and* pushes it to the USB
via `save-logs-to-usb.sh` before showing the error — that call site is
outside the `ERR` trap (an explicit `exit` doesn't trigger it), so
without this it wouldn't have been auto-saved.
