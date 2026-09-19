# Build and test checklist

None of this has been validated on real hardware yet. This is the
roadmap for doing that, in order, plus the list of spots most likely
to need adjustment.

## 1. Prepare the build machine

See the README's **Build** section for the full setup (native
Arch/CachyOS, or Windows via WSL2 — both documented there with exact
commands, so this file doesn't drift out of sync with it).

This step alone will already show if anything is missing from
`packages.x86_64` (names change, versions leave the repos, etc.).

## 2. `prepare-qemu-macos.sh` — the biggest source of uncertainty

Update (found by actually reading the qemus/qemu-macos repo instead of
guessing): that project ships **no buildable source checkout** — no
`build.sh`, no `meson.build`. It's a multi-stage `Dockerfile` +
`patches/` only. It clones real upstream QEMU 11.1.1 plus
steelbrain/reims-vgpu, applies Reims' display/device integration as a
patch, builds with Rust + Vulkan dev headers, and the final stage
(`FROM scratch AS artifact`) contains exactly two files:
`/usr/bin/qemu-system-x86_64` and
`/usr/share/qemu/reims-vgpu-gop.rom`.

Because that build needs a real Docker daemon (BuildKit heredoc
syntax throughout) and mkarchiso's `customize_airootfs.sh` runs inside
a plain chroot with no Docker available, this can't happen during the
ISO build like the original plan assumed. Instead:

- `archiso/prepare-qemu-macos.sh` runs on the **build host**, before
  `mkarchiso` — needs Docker (or Podman) installed there. It clones
  qemus/qemu-macos, runs `docker build --target artifact`, and copies
  the two output files into `airootfs/opt/layerosx/bin/` and
  `airootfs/usr/share/qemu/`. `build.sh` calls it automatically if the
  binary isn't already staged.
- Expect this single step to take 30-60+ minutes (it's compiling real
  QEMU from source) the first time you run it.
- Needs `docker-buildx` installed alongside `docker` (`pacman -S
  docker-buildx`), and `DOCKER_BUILDKIT=1` set — `prepare-qemu-macos.sh`
  now sets this itself. Without it, `docker build` silently falls back
  to the legacy builder, which treats the Dockerfile's `RUN <<EOF`
  heredocs as a no-op instead of erroring — the whole build "succeeds"
  without compiling anything, and the next stage fails with a confusing
  `COPY failed: stat out/qemu-system-x86_64: file does not exist`.
  Diagnosed this the hard way by reading a real `--progress=plain` log
  line by line; the giveaway is `DEPRECATED: The legacy builder is
  deprecated...` printed before step 1.
- There's also a genuine upstream bug (as of this writing): the step
  that checks out QEMU source places it at
  `/src/reims/vendor/qemu-11.1`, but the very next step that applies
  `patches/*.patch` still references the old `/src/qemu` path, so it
  fails with `fatal: cannot change to '/src/qemu': No such file or
  directory`. `prepare-qemu-macos.sh` patches this path in its own temp
  clone before building — worth re-checking whether this is still
  needed next time this script is touched.
- `customize_airootfs.sh` now only builds `dmg2img` (a small, ordinary
  C build, fine inside the chroot) and just checks the qemu binary
  landed where expected, warning loudly if it didn't.
- The device name is now confirmed: `reims-vgpu-pci` (found in the
  Dockerfile's own verification step, which probes
  `-device reims-vgpu-pci,help`). `mac-vm-launch.sh` uses
  `-device reims-vgpu-pci,romfile=reims-vgpu-gop.rom` as a best guess
  at the ROM property name — **still needs confirming**: run
  `sudo /opt/layerosx/bin/qemu-system-x86_64 -device reims-vgpu-pci,help`
  once you have a built binary and fix the flag if it disagrees.
  `prepare-qemu-macos.sh` already runs this query and prints the
  result at the end of the build.

## 3. Booting the ISO from a USB drive (Ventoy)

- Confirm it boots in UEFI and shows the install wizard fullscreen
  (openbox + `.xinitrc`, root autologin on tty1).
- The live root account now has a debug password (`layerosx`,
  live-ISO-only, see `customize_airootfs.sh`) — if the screen is stuck
  or flickering, switch to another console (Ctrl+Alt+F2) and log in as
  root with it to grab logs (`Xorg.0.log`, `dmesg`, `journalctl -xb`)
  instead of guessing from photos of the screen.
- `.xinitrc`/`.bash_profile` only try `startx` **once** per boot now
  (a `/run` flag file). If X keeps dying, a flickering-forever loop was
  the actual symptom on real hardware — Ctrl+Alt+F2 never got a chance
  to register because the tty1 session kept getting torn down and
  autologin kept retrying `startx` immediately. Now the second attempt
  just drops to a plain root shell on tty1 itself (autologin, no
  password needed there) instead of retrying — no VT switch required
  to get a usable console and grab the real Xorg log.
- If X exits cleanly (`Server terminated successfully (0)` in
  `Xorg.0.log`, no `(EE)` lines) instead of crashing: that's not a
  driver problem, it means `.xinitrc`'s only client
  (`install-wizard.sh`) exited almost immediately, so X had nothing
  left to serve and shut down normally. Root cause found this way:
  `install-wizard.sh` had lost its executable bit (`ls -la` showed
  `rw-r--r--`) even though git tracks it as `100755` — checking out
  this repo on a Windows-mounted drive via WSL doesn't reliably
  preserve that bit on disk. Fixed at the source (every script now
  has its own explicit entry in `profiledef.sh`'s `file_permissions`,
  which is what mkarchiso actually applies to the final image,
  regardless of what the checkout looks like) plus a `chmod +x`
  sweep in `build.sh` as a second layer. If `layerosx-install.log`
  never even gets created, this exact bug is the first thing to
  check — `ls -la /opt/layerosx/kiosk/install-wizard.sh` from a debug
  shell (see above) confirms it in one command.
- If X keeps flickering / restarting right after `archlinux login: root
  (automatic login)`: found in a VM test — no explicit X video driver
  was in `packages.x86_64` (only `mesa`), so on a virtual GPU without a
  working DRM/KMS "modesetting" driver, Xorg crashes, `.bash_profile`
  immediately retries `startx` since it's still tty1, and that loop
  looks like the screen endlessly flickering. Fixed by adding
  `xf86-video-fbdev` as a generic fallback driver. Should also be
  retested on real hardware (NVIDIA should get a proper driver from
  `nvidia-open-dkms` + modesetting there, not need the fbdev fallback
  at all) — flag it here if it still happens on bare metal.
- Should show: an info dialog → GParted (interactive, same as today:
  reuse the ~200 MB EFI partition, never format it) → two partition
  pickers (root, ESP) → a confirmation dialog → a black screen with
  ONE progress dialog that stays open and keeps moving forward for
  the entire rest of the install — copy (0-70%, real percentage, not
  pulsating), then fstab/machine-id/postinstall (70-100%), with the
  label naming the current step throughout (down to postinstall's own
  4 numbered steps) — then a "reboot now" dialog. All black
  window/white bar (`GTK_THEME=Adwaita:dark` + a `gtk.css` override,
  not a recreation of Apple's boot screen, see README.md). If you see
  the bar jump backward or a new dialog pop up mid-copy looking like
  it restarted, that's the two bugs already fixed in README.md
  (rsync's incremental recursion revising its total downward, and the
  old one-dialog-per-phase design) — flag it here if either recurs.
- If something fails partway through (mount, rsync, genfstab,
  arch-chroot, ...), it now stops and shows a `zenity --error` dialog
  telling you to check the log, instead of silently continuing to the
  "Done, reboot" dialog and rebooting into a broken install (the
  script had no `set -e`/error trap before — real risk, not just a
  hypothetical, since nothing was actually checking these steps'
  exit codes).
- If the install seems to finish and reboot fine, but the machine
  then shows a UEFI firmware error (`BdsDxe: failed to load
  Boot0002 "UEFI VBOX HARDDISK..."`, `No bootable option or device
  was found`): GRUB never actually installed. Root cause found in a
  VM test — the `rsync` step excludes `/dev /proc /sys /run /tmp
  /mnt /media` on purpose (they're live-only pseudo-filesystems),
  but `rsync --exclude` on a top-level path doesn't create an empty
  placeholder on the target, it skips creating the directory
  entirely. So `/mnt/proc` never existed on the installed disk, and
  `arch-chroot /mnt /root/postinstall/run.sh` (locale, user, GRUB,
  kiosk autologin — everything) failed immediately with `mount:
  /mnt/proc: mount point does not exist` / `ERROR: failed to setup
  chroot /mnt`, before postinstall ran a single line. Fixed:
  `install-wizard.sh` now recreates those directories right after
  the rsync, before any `arch-chroot` call.
  To confirm this on a disk you already installed, or to recover one
  without reinstalling: boot the live ISO, mount the real partitions
  (check with `lsblk -f` — do NOT mount the live medium's own
  `loop*`/`sr0` devices), and try to chroot in:
  ```bash
  mount /dev/sdaN /mnt        # your root partition, ext4
  mount /dev/sdaM /mnt/boot   # your ESP, vfat, mounted at /mnt/boot
  arch-chroot /mnt
  ```
  If that fails with the same `/mnt/proc` error, first check the
  disk actually has a copied system (`ls /mnt` — should show `bin`,
  `etc`, `usr`, `var`, not just `lost+found`); if it does, recreate
  the missing mount points and retry:
  ```bash
  mkdir -p /mnt/dev /mnt/proc /mnt/sys /mnt/run /mnt/tmp /mnt/mnt /mnt/media
  chmod 1777 /mnt/tmp
  arch-chroot /mnt
  /root/postinstall/run.sh   # never ran the first time, safe to run now
  exit
  umount -R /mnt
  reboot
  ```
  `efibootmgr -v` from the live session is a good way to confirm the
  symptom even before chrooting in: if the disk's boot entry shows
  `{auto_created_boot_option}` with no `\EFI\...\grubx64.efi` file
  path in its device path, that's VirtualBox/UEFI's generic disk
  fallback, not a real GRUB entry — GRUB was never installed.
- If, after the fix above, the install completes and `grub-install`
  itself logs no error, but the machine still boots straight to a
  bare "UEFI Firmware Settings" menu with no OS entry at all (not even
  the generic auto-created HARDDISK one) — this is VirtualBox's EFI
  firmware not reliably persisting the NVRAM boot entry `grub-install
  --bootloader-id=layerosx` registers via `efibootmgr`; GRUB is on the
  disk, the firmware just has no record of it after reboot. Fixed:
  `postinstall/50-grub.sh` now also runs a `--removable` install,
  which writes to the fallback path UEFI firmware boots automatically
  with no NVRAM entry required (`/boot/EFI/BOOT/BOOTX64.EFI`). To
  recover an already-installed disk without reinstalling, chroot in
  (as above) and just run:
  ```bash
  grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck
  ```
- If, after all the above, `/boot` on the target still has only
  `EFI/` and `grub/` with no `vmlinuz-linux`/`initramfs-linux.img` at
  all (`ls -la /boot/` from inside the chroot confirms it) — this is
  the actual root cause of the "no OS boot entry" symptom, not just
  the NVRAM issue. archiso doesn't ship the kernel inside the live
  squashfs (it lives only on the ISO's own boot media), so the
  installer's `rsync` copy can never restore it — `mkinitcpio -P`
  failing with `'/boot/vmlinuz-linux' must be readable` in
  `postinstall/01-base-system.sh`/`10-hardware-detect.sh` is the
  direct symptom, and it's why `grub-mkconfig` had no Linux entry to
  add. Fixed: `01-base-system.sh` now forces a `pacman -S` reinstall
  of `linux linux-firmware intel-ucode amd-ucode` before
  `mkinitcpio -P` (pacman's rsynced local DB already "thinks" they're
  installed, so this re-extracts the real files from the — also
  rsynced — local package cache, normally no network needed). To
  recover an already-installed disk, chroot in and run:
  ```bash
  pacman -S --noconfirm linux linux-firmware intel-ucode amd-ucode
  mkinitcpio -P
  grub-mkconfig -o /boot/grub/grub.cfg
  grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck
  ```
- If it hangs on a black screen and then loops in `systemd`
  emergency mode (`Timed out waiting for device /dev/gpt-auto-root`,
  can't even log into the emergency shell because root is locked):
  this was a real bug, found on the first real-hardware boot attempt —
  the profile was missing `airootfs/etc/mkinitcpio.conf.d/archiso.conf`
  (the file that makes the live initramfs actually live-aware; without
  it `mkarchiso` builds a normal install-target-style initramfs that
  can't find its own root). Fixed by copying that file from the
  official `releng` reference profile (see README.md for the full
  explanation).
- If, after that fix, it instead shows `running hook [memdisk]` /
  `memdiskfind: not found` then `mounting '' on real root` and the
  same emergency-mode dead end: also found on real hardware, one
  rebuild later. The `mkinitcpio.conf.d/archiso.conf` hooks need the
  `mkinitcpio-archiso` package **inside the ISO** to actually provide
  them at build time — fixed by adding it to `packages.x86_64` (see
  README.md). A rebuild after this fix should get past both issues.
  If it hangs on a black screen for a different reason (never reaches
  either of these emergency-mode messages), the problem is more likely
  the `.xinitrc`/`.bash_profile`/tty1 autologin, not GParted or the
  wizard script itself.
- Calamares was dropped (it's never been in Arch's official repos,
  only the AUR, and Chaotic-AUR doesn't carry it either — see
  README.md) in favor of GParted + a plain rsync-based install script
  (`kiosk/install-wizard.sh`). This is still one of the **least-tested
  parts of the whole project** — the live-boot bug above was found and
  fixed before the wizard itself was ever reached, so the GParted/rsync
  flow specifically has still not run on real hardware yet.

## 3.5. Hardware detection (`postinstall/10-hardware-detect.sh`)

Untested on real AMD/Intel CPU+GPU combinations — this was
generalized from a single Ryzen+NVIDIA dev machine, and nobody has
actually run the detection logic against real hardware yet.

- Check `/var/log/layerosx-postinstall.log` (or run it manually) for
  which CPU vendor and GPU vendor(s) it detected.
- Confirm the right KVM module loaded: `lsmod | grep kvm_` should show
  exactly `kvm_intel` (Intel) or `kvm_amd` (AMD), not both, not
  neither.
- On NVIDIA: confirm `/etc/modprobe.d/nvidia.conf` exists and
  `nvidia-persistenced` is enabled.
- On a laptop with hybrid graphics (Intel iGPU + NVIDIA/AMD dGPU),
  confirm BOTH get detected and configured — the script is written to
  handle more than one GPU, but this specific case hasn't been tried.
- If `mac-vm-launch.sh`'s Reims-vGPU acceleration doesn't work on
  non-NVIDIA hardware, start here: check `vulkaninfo` inside the live
  or installed system actually lists a working AMD/Intel Vulkan
  device (`vulkan-radeon`/`vulkan-intel` from packages.x86_64).

## 4. First boot of the installed system

- Should boot straight into the `mac` user, no password prompt, and
  land on `macos-source-wizard.sh` (zenity).
- Test all 3 options at least once each, even just to see they open
  without crashing: automatic download, existing disk, existing
  `.dmg`.
- The `.dmg` option is the most fragile (see
  `kiosk/lib/extract-dmg-installer.sh`) — if it fails, it fails
  gracefully (clear error message), but it still needs more work to
  properly support real APFS installers.

## 5. The VM itself

- Confirm `-display sdl,gl=on,full-screen=on` actually gives you a
  screen.
- The device name is confirmed (`reims-vgpu-pci`, see step 2) — what's
  still unverified is the exact `romfile=` property name used in
  `kiosk/mac-vm-launch.sh`. Without it being right, the VM might boot
  but with no acceleration at all (software rendering only, slow).
- Confirm USB keyboard/mouse work inside the VM before trying to
  install/configure anything.

## 6. Physical Restart / Shutdown

- Inside an already-installed macOS: test "Restart" from the Apple
  menu. Expected: the VM closes, and the physical machine really
  reboots (`systemctl reboot`), not just the VM relaunching.
- Test "Shut Down": expected, the physical machine really powers off
  (`systemctl poweroff`).
- If neither triggers (stuck on "vm-only" and just relaunching the
  VM): the guest may not be emitting the QMP `SHUTDOWN` event with the
  expected `reason` — check `journalctl` / the log at `~/mac-vm.log`
  for what `qmp-watch.py` actually received.

## 7. Automatic cleanup

- `systemctl status layerosx-cleanup.timer` should show the timer
  active.
- Run `sudo /usr/local/bin/layerosx-cleanup.sh` manually once to
  confirm nothing breaks (mainly `paccache`, which depends on
  `pacman-contrib` actually being installed).

## Licensing notes (not legal advice)

- The ISO this project generates never contains any Apple files.
- The recovery image and/or the `.dmg` always come directly from Apple
  (or were already yours) at the moment YOU run the wizard, onto your
  own disk — never bundled inside the ISO you distribute. This is the
  same approach OSX-KVM and the macOS-VM community have always
  followed.
- It's still against Apple's EULA to run macOS outside Apple hardware,
  accelerated or not — this doesn't change that reality.
