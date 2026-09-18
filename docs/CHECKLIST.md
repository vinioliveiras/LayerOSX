# Build and test checklist

None of this has been validated on real hardware yet. This is the
roadmap for doing that, in order, plus the list of spots most likely
to need adjustment.

## 1. Prepare the build machine

Needs to run on an Arch-based machine with the `archiso` package
installed (your current CachyOS works, or you can boot the
`archlinux-2026.09.01-x86_64.iso` you already have in `D:\Downloads`
as a live environment and install `archiso` there — the official Arch
installer isn't used as a "base" for our ISO, it's just a Linux with
internet where `mkarchiso` runs).

```sh
sudo pacman -S archiso
git clone <your-repo> LayerOSX
cd LayerOSX/archiso
./build.sh
```

This step alone will already show if anything is missing from
`packages.x86_64` (names change, versions leave the repos, etc.).

## 2. `customize_airootfs.sh` — the biggest source of uncertainty

This script builds `qemus/qemu-macos` (QEMU + Reims-vGPU) and
`dmg2img` during the build. Before a "real" build:

- Open https://github.com/qemus/qemu-macos and confirm the current
  build command (the script tries `build.sh` and then `meson`, but
  this may have changed).
- Confirm the build packages (`meson`, `ninja`, `pkgconf`, `glib2`,
  `pixman`, `sdl2`, `vulkan-headers`) are enough — the project may
  need some other dependency that isn't in `packages.x86_64` yet.
- If the build fails here, the ISO still comes out (the script only
  warns, it doesn't stop `mkarchiso`), but
  `/opt/layerosx/kiosk/mac-vm-launch.sh` won't have any accelerated
  `qemu-system-x86_64` to run.

## 3. Booting the ISO from a USB drive (Ventoy)

- Confirm it boots in UEFI and shows Calamares fullscreen (openbox +
  `.xinitrc`, root autologin on tty1).
- Should only show: welcome → partition (interactive, same as today:
  reuse the ~200 MB EFI partition, never format it) → summary →
  proceeds on its own → done.
- If it hangs on a black screen before Calamares shows up: the problem
  is the `.xinitrc`/`.bash_profile`/tty1 autologin, not Calamares
  itself.

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
- **The single most uncertain point in the whole project**: the exact
  flag that turns on Reims-vGPU's accelerated video device on the
  `qemu-system-x86_64` command line (see the `TODO(verify)` in
  `kiosk/mac-vm-launch.sh`). Without confirming this against the
  `qemus/qemu-macos` README, the VM might boot but with no
  acceleration at all (software rendering only, slow).
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
