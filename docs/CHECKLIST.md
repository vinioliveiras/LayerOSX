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
- Should show: an info dialog → GParted (interactive, same as today:
  reuse the ~200 MB EFI partition, never format it) → two partition
  pickers (root, ESP) → a confirmation dialog → proceeds on its own
  (rsync copy, fstab, machine-id, chroot + postinstall) → a "reboot
  now" dialog.
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
