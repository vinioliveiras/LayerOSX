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
  `airootfs/usr/share/qemu/`, then bundles its matching runtime
  libraries (see the `libjpeg.so.62` note in section 5) into
  `airootfs/opt/layerosx/lib/`. `build.sh` calls it automatically if
  the binary or the bundled libraries aren't already staged —
  confirmed on real hardware that checking just the binary wasn't
  enough: a binary built *before* the libjpeg bundling fix existed
  already made `build.sh` skip re-running this step forever, silently
  shipping the old broken binary on every build after that (see
  README.md). If you're not sure whether your local `airootfs/opt/`
  is stale, just delete `airootfs/opt/layerosx/bin/qemu-system-x86_64`
  and let `build.sh` rebuild it from scratch.
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
- Confirmed on real hardware: even a fully working QEMU binary (past
  libjpeg and the LD_LIBRARY_PATH leak, both above) failed immediately
  with `-display sdl,...: Parameter 'type' does not accept value
  'sdl'` -- upstream builds this binary with `--disable-sdl` and
  `--disable-gtk` (it's meant to be viewed over VNC/noVNC, not as a
  local window). `prepare-qemu-macos.sh` now patches the Dockerfile to
  `--enable-sdl` and installs `libsdl2-dev` in the builder image before
  the `docker build --target artifact` step (see README.md). If a
  future rebuild ever hits `-display sdl` errors again, check that
  this patch's anchors (`--disable-sdl \`, the `libbz2-dev \` /
  `libvulkan-dev \` apt-get block) still match upstream's Dockerfile --
  the script fails loudly with a clear message if they don't.
- Confirmed on real hardware: the `--enable-sdl` patch above failed on
  its very first real run with `FAIL: apt-get dependency list anchor
  not found`, before ever touching a real Dockerfile. Root cause was
  self-inflicted: the patch script's Python string literals got
  double-escaped while being deployed through a chain of nested
  heredocs, turning the intended literal `\n` bytes into Python's
  backslash-newline line continuation (which produces no character at
  all), so the anchor strings never matched. Fixed by writing the
  string literals in explicit single-line form and verifying the
  script against a real fetched Dockerfile before redeploying (see
  README.md). Lesson for future edits to this file: never generate
  this script's content through nested string-literal layers (bash
  heredoc -> Python string -> another Python string) -- edit it
  directly and test the extracted inner script against real input
  first.
- Confirmed on real hardware: even after that fix, the next build
  still failed, further along, in the Dockerfile's own `verify` stage
  (`FROM qemux/qemu:latest`) with `FAIL: one or more QEMU runtime
  dependencies could not be resolved` -- `ldd` showed `libSDL2-2.0.so.0`
  and `libSDL2_image-2.0.so.0` both `=> not found`. Enabling SDL in the
  builder stage links the binary against both, but the verify stage's
  own base image never had them installed. Fixed by also patching the
  Dockerfile to `apt-get install libsdl2-2.0-0 libsdl2-image-2.0-0` in
  the verify stage, right after its two `COPY` lines (see README.md).
  If a future rebuild ever hits this again, check that this second
  patch's anchor (the `COPY ... reims-vgpu-gop.rom` / `RUN <<'EOF_VERIFY'`
  pair) still matches upstream.
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
- `build.sh` now clears `out/` (the ISO output dir) at the start of
  every build, same as it already does for `work/` — confirmed in
  practice that without this, ISOs from different days just pile up
  there (named after today's date, so nothing overwrites) and it's
  easy to accidentally test a stale one. After a build, `out/` should
  contain exactly one ISO.
- Confirmed on real hardware: even after the above fixes, a build can
  still bundle zero runtime libraries into `airootfs/opt/layerosx/lib/`
  with no error at all — the extraction used to pipe `ldd` into a
  `while read` loop inside a POSIX `sh -c` script, and `sh` has no
  `pipefail`, so a failing/empty `ldd` just made the loop silently do
  nothing (see README.md). Fixed to fail loudly instead. After running
  `prepare-qemu-macos.sh`, always check the `==> bundled N runtime
  librar(y|ies)` line near the end — `N` should never be `0`, and the
  script now refuses to continue if it is. `prepare-qemu-macos.sh`
  also now clears its own previous output (binary, ROM, `lib/`) at
  the very start of every run, so nothing manual is ever needed
  before re-running it, however it ends up getting triggered.
- Confirmed on real hardware: right after the fail-loud check above
  started actually catching problems, the library extraction itself
  failed with `/usr/bin/tini: invalid option -- 'c'` — the `verify`
  stage's base image (`qemux/qemu:latest`) bakes in an ENTRYPOINT
  running everything through `tini`, and `docker run` only replaces
  CMD, not ENTRYPOINT, so the extraction's `sh -c '...'` was getting
  appended onto that fixed entrypoint instead of replacing it. Fixed
  with `--entrypoint sh` on that `docker run` call (see README.md).
  If you hit this exact tini error again in the future, it means some
  other `docker run` call in this repo forgot the same `--entrypoint`
  override.

## 3. Booting the ISO from a USB drive (Ventoy)

- The whole install is meant to be UI-only now (no visible
  terminal) — press **F2** at any point during the install to
  confirm a terminal opens tailing `/var/log/layerosx-install.log`
  live (see README.md). Closing it again shouldn't affect the
  install in progress.
- **Logs now auto-save to every eligible disk found, not just the
  Ventoy drive** (`layerosx-logs/` folder at each one's root — see
  README.md) on any install failure, on a successful install, on
  every boot of the installed system, and after every QEMU session.
  When something goes wrong during testing, check that folder from
  Windows (or anywhere) before reaching for a tty or a photo — much
  faster. If it's ever empty everywhere (happened once — see
  README.md's gotcha on this), press F2 (or tty2, login
  `root`/`layerosx`) and `cat /var/log/layerosx-save-logs-status.log`
  — it now records one line per disk it tried, so it should say
  exactly why each one didn't work rather than nothing at all.
- Confirm it boots in UEFI and shows the install wizard fullscreen
  (openbox + `.xinitrc`, root autologin on tty1).
- If it hangs mid-boot searching every partition for a
  `/boot/<uuid>.uuid` marker file and drops to a `[rootfs ~]#`
  emergency shell with `ERROR: Device '<uuid>' not found` — this only
  reproduced via a **real Ventoy USB boot on physical hardware**, not
  in any VM test (VirtualBox/QEMU attach the ISO directly as a
  virtual CD, bypassing Ventoy's boot layer entirely). Fixed: switched
  `efiboot/loader/entries/01-layerosx.conf` from
  `archisosearchuuid=%ARCHISO_UUID%` to
  `archisolabel=%ARCHISO_LABEL%` (search by the ISO's volume label
  instead of its UUID — Ventoy doesn't always expose the UUID the same
  way a plain dd/Rufus write does). Rebuild after pulling this fix
  before testing on Ventoy again.
- If that's still not enough and it now waits for
  `/dev/disk/by-label/<label>` specifically (confirming the fix above
  did land) but still times out — from the emergency shell, check
  `ls /dev/loop*` and `cat /proc/partitions`. If there's no loop
  device at all (only `/dev/loop-control`, and `/proc/partitions`
  lists only the real physical disks), the ISO itself is never being
  exposed as a mountable disk to begin with — see the isohybrid MBR
  gotcha in README.md. Fixed by adding `bios.syslinux` to `bootmodes`
  in `profiledef.sh` (not to add real BIOS support — this project
  stays UEFI-only — just to get `mkarchiso` to embed the isohybrid
  MBR/El Torito structure tools like Ventoy need to loopback-mount
  the ISO). Needs the `syslinux` package in `packages.x86_64` (build
  fails without it — "package is missing from the package list") and
  a `syslinux/` directory with the standard archiso templates (copied
  from `/usr/share/archiso/configs/releng/syslinux/` on a machine
  with the `archiso` package installed) — this UEFI-only profile
  never had either before.
- For a faster, more standards-compliant iteration loop than
  VirtualBox (which has its own known EFI NVRAM quirks — see the GRUB
  gotcha further down), QEMU with OVMF firmware is the closest thing
  to real UEFI firmware behavior short of actual hardware — see
  "Testing with QEMU+OVMF" in README.md.
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
  add.
  - **First fix attempt didn't actually work**: forcing a `pacman -S`
    reinstall of `linux linux-firmware intel-ucode amd-ucode` in
    `01-base-system.sh`, on the theory that the rsynced local package
    DB would let it re-extract from the also-rsynced package cache.
    Confirmed wrong on real hardware: `mkarchiso` never populates the
    live airootfs's own package cache in the first place (it's pulled
    from the *build machine's* cache instead), and the rsynced system
    is also missing pacman's **sync** databases — so `pacman -S`
    couldn't even resolve the package names (`target not found:
    linux`), online or not.
  - **Actual fix (v1, also failed on real hardware)**: skip pacman
    entirely -- `install-wizard.sh` copies the real `vmlinuz-linux`
    straight out of the boot medium itself (searched for at runtime
    under `/run`) into `/mnt/boot`, before `arch-chroot` ever runs.
    This searching turned out to be unreliable via Ventoy on real
    hardware (came up completely empty; never pinned down exactly
    why).
  - **Actual fix (v2, current)**: `customize_airootfs.sh` (build
    time) now stashes a copy of the kernel at
    `/opt/layerosx/vmlinuz-linux.stashed` *before* `mkarchiso` strips
    `/boot/vmlinuz-linux` out of the airootfs -- so it just rides
    along inside the squashfs and rsyncs onto the target like any
    other file, no runtime medium-searching needed at all. If this
    still somehow fails, the install now dumps `findmnt`/`/run/archiso`
    diagnostics into the log and pushes it to the USB automatically
    before showing the error (see the log-saving feature below).
    `01-base-system.sh` then also deletes
    `/etc/mkinitcpio.conf.d/archiso.conf` from the target (it got
    rsynced too, and would otherwise bake the *live medium's* HOOKS —
    `archiso`, `memdisk`, the PXE hooks — into the installed system's
    initramfs) before running `mkinitcpio -P`, so it falls back to the
    normal installed-system HOOKS. See README.md for the full
    explanation. To recover an already-installed disk without
    reinstalling from scratch: boot the live ISO, then (still outside
    the chroot) find and copy the kernel, then finish inside the
    chroot:
    ```bash
    find /run -maxdepth 6 -name vmlinuz-linux   # note the path
    cp /run/.../vmlinuz-linux /mnt/boot/vmlinuz-linux
    arch-chroot /mnt
    rm -f /etc/mkinitcpio.conf.d/archiso.conf
    mkinitcpio -P
    grub-mkconfig -o /boot/grub/grub.cfg
    grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck
    ```
- If the install seems to finish (postinstall log shows all 4 steps
  ran, GRUB found the kernel) but the screen never shows "Done,
  reboot" and instead dumps you back to a bare root shell prompt: the
  final `umount -R /mnt` failed as busy (a leaked `tail -F` from the
  postinstall log-tailing job was holding a file open under `/mnt`)
  and killed the install script. Fixed in `install-wizard.sh` (kills
  tail's children too, and lazy-unmounts as a last resort instead of
  dying) — but if you hit this on a build from before the fix, DON'T
  just reboot from that shell: the ESP was still mounted, so check
  `/boot` in a fresh chroot for a real kernel/grub.cfg before trusting
  the install, and if in doubt just reinstall from a rebuilt ISO.
- GRUB only shows the LayerOSX entry and "UEFI Firmware Settings",
  never other installed OSes (Windows, other Linux disks, ...) even
  though `os-prober`/`ntfs-3g` are in `packages.x86_64` — GRUB
  disables `os-prober` by default upstream. `postinstall/50-grub.sh`
  now sets `GRUB_DISABLE_OS_PROBER=false` in `/etc/default/grub`
  before `grub-mkconfig`. To fix an already-installed disk without
  reinstalling: chroot in, edit `/etc/default/grub` (add/uncomment
  `GRUB_DISABLE_OS_PROBER=false`), then `grub-mkconfig -o
  /boot/grub/grub.cfg` again.
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
- Confirmed on real hardware: `qemu-system-x86_64: Could not access
  KVM kernel module: No such file or directory` at first launch, with
  `/dev/kvm` simply not existing — `10-hardware-detect.sh` had added
  the right module to `/etc/mkinitcpio.conf` and regenerated the
  initramfs, but had no way to confirm the module actually loads at
  boot, which fails silently when virtualization (Intel VT-x / AMD-V /
  "SVM Mode") is disabled in the BIOS/UEFI — by far the most likely
  cause if you hit this. **Check the BIOS/UEFI setting first** before
  assuming it's a LayerOSX bug. Hardened with a second registration
  path (`/etc/modules-load.d/layerosx-kvm.conf`) and a best-effort
  `modprobe` + log line right at install time (see README.md) — after
  a fresh install, grep `/var/log/layerosx-postinstall.log` for
  `[10]` to see whether it already reported success or failure right
  there, instead of waiting to find out at first VM launch.
  `mac-vm-launch.sh` also now checks `/dev/kvm` itself before ever
  invoking QEMU and fails fast with an actionable message rather than
  looping forever on QEMU's own cryptic one.
- Confirmed on real hardware, right after the above shipped: a FATAL
  message alone isn't enough — the physical screen flash-looped too
  fast to actually read it (X session ends -> getty autologin restarts
  it immediately -> same FATAL -> repeat). If you ever see this again
  (tty1 flickering, never settling): confirm `mac-vm-launch.sh`'s
  `fatal()` helper is still what all three hard-stop checks call (it
  sleeps 60s before exiting, specifically to pace this out) — it's
  easy to accidentally reintroduce a bare `echo ...; exit 1` when
  adding a new hard-stop check later and lose the pacing again.
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
  land on `macos-source-wizard.sh` (zenity). The mouse cursor should
  be visible here (a real bug found and fixed: `-nocursor` was hiding
  it for the whole session, not just inside the VM — see README.md).
- Test both options at least once each, even just to see they open
  without crashing: automatic download, and "pick a file" (one merged
  picker for a complete VM disk in `.qcow2`/`.img`/`.raw`/`.vmdk`/
  `.vdi`/`.vhd`/`.vhdx`, recovery/installer `.iso`, or a `.dmg`/`.app`
  installer). The `.vmdk`/`.vdi`/`.vhd`/`.vhdx` paths convert via
  `qemu-img` to qcow2 — confirm a small test disk of each converts and
  boots; a split VMware `.vmdk` needs all its `-s00x.vmdk` extents in
  the same folder as the descriptor you pick.
- Confirm the "where should macOS come from" list itself renders both
  rows on one line each, no horizontal scrollbar cutting text off —
  confirmed on real hardware once already (see README.md), fixed by
  shortening the second option's label.
- The `.dmg`/`.iso` installer paths are the most fragile (see
  `kiosk/lib/extract-dmg-installer.sh`) — if they fail, they fail
  gracefully (clear error message), but still need more work to
  properly support real APFS installers.
- If "pick a file" shows nothing to select, confirm the USB
  drive/partition actually got auto-mounted under `/mnt/media/` (no
  udisks2/gvfs here, so `kiosk/lib/mount-removable-media.sh` does this
  by hand right before the file dialog opens) — `lsblk -f` from tty2
  will show whether the partition's filesystem is even one of the
  ones it recognizes (ext2-4, vfat, exfat, ntfs(3), hfsplus, iso9660,
  udf).
- Confirmed on real hardware: "pick a file" used to open nothing at
  all — no dialog, no error, `zenity --file-selection` just silently
  never appeared (same GTK-dependency fragility as the
  `LD_LIBRARY_PATH`-leaking-into-zenity bug above). Replaced with a
  native Tkinter picker (`kiosk/lib/pick-source-file.py`, needs the
  `tk` package — see README.md). Confirm the file dialog now actually
  opens, that it starts browsing at `/mnt/media/`, and that the
  filter still only shows `.qcow2`/`.img`/`.raw`/`.iso`/`.dmg`/`.app`
  by default (with "All files" selectable too).
- If "download from Apple" is picked on a Wi-Fi-only machine with no
  connection yet, it should now offer a zenity list of nearby networks
  to click (`kiosk/lib/wifi-setup.sh`, see README.md) — confirm the
  scan actually finds real networks, a password prompt shows for a
  secured one, and the download proceeds afterward. Also try
  "Advanced (nmtui)…" at the bottom of the list once, to confirm
  the fallback still works.
- "Download from Apple" now asks which macOS version first (High
  Sierra through Tahoe, Ventura pre-selected — see README.md). Confirm
  the list opens, that picking a version other than Ventura actually
  downloads that version (check the progress text / F2 log mentions
  the right name, and `lib/fetch-work/recovery/` ends up with that
  version's `BaseSystem.dmg`), and that Cancel here exits back to the
  first-run wizard's outer screen instead of silently proceeding with
  a default.
- The Apple download, `.dmg` extraction and `.iso` conversion steps
  no longer open a visible terminal by default (a zenity progress bar
  instead — pulsating for the first two, a real percentage for
  `.iso`). Press **F2** during any of these to confirm a terminal
  opens tailing the live output — and confirm it still shows
  something sensible if pressed before any of these steps have
  started yet (should just say "Nothing to show yet." rather than
  erroring).
- Confirmed on real hardware: the Apple download used to succeed
  (800MB+) and then immediately fail with `Image verification
  failed. ([Errno 25] Inappropriate ioctl for device)` — an unguarded
  `os.get_terminal_size()` call inside upstream `fetch-macOS-v2.py`'s
  `verify_image()`, tripped by this pipeline's output never being a
  real terminal. Fixed with an idempotent patch applied in
  `kiosk/lib/fetch-recovery.sh` after the script is downloaded (see
  README.md) — confirm the download now proceeds past "Verifying
  image with chunklist..." instead of crashing right after the
  download bar finishes.
- Confirmed on real hardware: `cp: cannot stat
  '/usr/share/edk2-ovmf/x64/OVMF_VARS.fd'` right at the start of
  first-run setup — Arch's `edk2-ovmf` package actually installs to
  `/usr/share/edk2/x64/OVMF_CODE.4m.fd` / `OVMF_VARS.4m.fd`, not the
  path both `mac-vm-launch.sh` and `macos-source-wizard.sh` assumed
  (see README.md). Fixed in both places — confirm first-run setup no
  longer prints this error (check via F2) and that the VM actually
  gets a NVRAM file at `/var/lib/layerosx/OVMF_VARS.fd`.
- Confirmed on real hardware: a failed first-run attempt (download
  error, conversion error, etc.) used to leave the machine stuck on a
  black screen permanently, even after a full restart, because a
  half-created `$VM_DISK` from the failed attempt satisfied
  `mac-vm-launch.sh`'s "has a VM already been set up?" check. Fixed
  with an EXIT trap in `macos-source-wizard.sh` that removes any
  partial `$VM_DISK`/recovery/installer disk/`$OVMF_VARS` whenever the
  wizard exits non-zero (see README.md) — to test, deliberately fail
  a first-run attempt (e.g. disconnect Wi-Fi mid-download) and confirm
  the *next* boot shows the "where should macOS come from" screen
  again instead of a black screen.
- On a multi-monitor machine, check every connected display for a
  corrupted/noisy image (a second monitor showing this was the
  original report) — `kiosk/lib/force-max-refresh.sh` should have
  already forced each one to its real max refresh rate at `.xinitrc`
  startup (see README.md), now retrying for about a minute total to
  cover monitors that settle slowly right at boot. If a display is
  still wrong after that, run `xrandr --query` from a tty2 shell
  (Ctrl+Alt+F2, login `mac`/`mac`) to see what mode it actually
  landed on.

## 5. The VM itself

- Before chasing display/rendering flags, confirm QEMU is actually
  *running* at all: `ps aux | grep qemu` from tty2. A black screen
  with no `qemu-system-x86_64` process means it already
  crashed/exited (or never launched) — `mac-vm-launch.sh` will retry
  up to 5 times, 3s apart, then reboot the physical machine as a last
  resort, which can look like "just a black screen" if you don't
  happen to catch it mid-retry. Check `~/mac-vm.log` (the `mac`
  user's home) first in that case — it captures QEMU's own
  stdout/stderr, so the actual crash reason should be right there.
- **This was exactly what was happening on real hardware**: every
  launch failed immediately with `error while loading shared
  libraries: libjpeg.so.62: cannot open shared object file` —
  `qemus/qemu-macos` is built with `--enable-vnc-jpeg` against a
  Debian-based image's `libjpeg62-turbo`, and Arch's own
  `libjpeg-turbo` package only ships the incompatible `libjpeg.so.8`
  SONAME — not a missing package, a SONAME mismatch (see
  README.md). Fixed at the source: `prepare-qemu-macos.sh` now
  bundles the real matching libraries (extracted from the
  Dockerfile's own already-validated `verify` stage) into
  `airootfs/opt/layerosx/lib/`, and `mac-vm-launch.sh` points
  `LD_LIBRARY_PATH` at it. Needs a rebuild (re-run
  `prepare-qemu-macos.sh`, needs Docker) to take effect — on an
  already-installed system, `sudo pacman -Sy libjpeg-turbo && sudo ln
  -sf /usr/lib/libjpeg.so.8 /usr/lib/libjpeg.so.62 && sudo ldconfig`
  is an untested but plausible same-day stopgap.
- Confirm `-display sdl,gl=on,full-screen=on` actually gives you a
  screen.
- The device name is confirmed (`reims-vgpu-pci`, see step 2) — what's
  still unverified is the exact `romfile=` property name used in
  `kiosk/mac-vm-launch.sh`. Without it being right, the VM might boot
  but with no acceleration at all (software rendering only, slow).
- Confirm USB keyboard/mouse work inside the VM before trying to
  install/configure anything.
- If the VM window is just solid black with nothing happening at all
  (no OVMF text, no Apple logo) right after the first-run wizard
  finishes: `mac-vm-launch.sh` now attaches the recovery/installer
  disk the wizard just prepared (see README.md) — if it's still black
  after that fix, check `~/mac-vm.log` (the `mac` user's home) for
  what QEMU itself printed, and suspect the `reims-vgpu-pci romfile=`
  property above next.
- The recovery/installer disk is attached with the same `if=virtio`
  interface as the main disk — still unverified whether macOS's own
  recovery/installer environment actually has a virtio block driver
  that early, or needs a real AHCI/SATA drive instead. If the VM gets
  further (OVMF boots) but can't find/boot the recovery disk itself,
  this is the next thing to try — see the comment in
  `kiosk/mac-vm-launch.sh`.

- Confirmed on real hardware: the first-run wizard can fail
  instantly and loop forever ("The wizard failed or was cancelled.
  Retrying in 10s...") with every zenity dialog crashing
  (`/usr/lib/libgtk-4.so.1: undefined symbol:
  g_zlib_compressor_set_os`). This is NOT a package-version problem
  (`pacman -Syu` won't fix it either — this install is rsync-based, so
  the target never gets real pacman sync databases/mirrorlist, see
  `postinstall/01-base-system.sh`) -- it was `LD_LIBRARY_PATH` being
  `export`ed for the whole of `mac-vm-launch.sh`, leaking the bundled
  Debian-flavored glib (meant only for `qemu-system-x86_64`) into
  every zenity call. Fixed by scoping it to just the qemu invocation
  (see README.md). If you ever see this exact zenity crash again, it
  means `LD_LIBRARY_PATH` is leaking somewhere new — check what's
  exporting it before assuming it's a package problem.
- Right-click on the desktop should no longer show openbox's full
  Applications/System menu (Log Out, Reconfigure Openbox, ...) — only
  F2 should get you out of the kiosk. If it still does, check
  `~/.config/openbox/rc.xml`'s `Root` context for a `ShowMenu
  root-menu` mousebind that `install-f2-keybind.sh` should have
  stripped.

### 5.1. macOS's own kernel actually booting (OpenCore / SMC / SMBIOS)

This is new territory as of this fix — everything above only ever got
as far as QEMU launching and OVMF/the recovery environment coming up;
nothing so far has gotten confirmation that XNU (macOS's kernel)
itself boots past early init on real hardware. Treat everything below
as **unverified on real hardware** until someone actually gets a
report back from this exact point:

- Confirm `airootfs/opt/layerosx/opencore/OpenCore.qcow2` exists after
  a build (`prepare-opencore.sh` stages it, `build.sh` calls it
  automatically if missing — see README.md). If it's missing,
  `mac-vm-launch.sh` now fails fast with a clear `FATAL` instead of
  silently booting without it.
- Confirmed on real hardware: `Block format 'qcow2' does not support
  the option 'bootindex'` right at QEMU launch, from the OpenCore
  drive specifically (the only one of the three drives that sets
  `bootindex`). Fixed by splitting it into the explicit `-drive
  if=none,id=opencore,...` + `-device virtio-blk-pci,drive=opencore,
  bootindex=0` form (see README.md). If you ever see this exact error
  on a *different* drive after editing `mac-vm-launch.sh`, it means
  that drive picked up a `bootindex=` on the `-drive if=virtio,...`
  shorthand — split it the same way instead.
- The `QEMU_BIN`/`OPENCORE_IMG`/`/dev/kvm` checks now run right before
  this launch, *after* the wizard — confirm the first-run wizard
  (including "download from Apple") still opens and works even on a
  machine where one of those isn't ready yet (e.g. before
  `prepare-opencore.sh` has ever run). If a fresh install can't reach
  the wizard at all, check that these three checks haven't drifted
  back to before the `if [ ! -f "$VM_DISK" ]` block in
  `mac-vm-launch.sh`.
- If `/dev/kvm` is fine and OpenCore is staged, but the VM still never
  gets past OVMF (no Apple logo, no progress at all): check
  `~/mac-vm.log` for what QEMU printed, and confirm the OpenCore drive
  is actually the one OVMF tries to boot from first — the picture-in-
  picture OpenCore boot picker should show up before anything else,
  even before the recovery/installer disk. If OVMF's own boot manager
  is picking a different disk first, double-check the `bootindex=0`
  on the OpenCore `-drive` line in `mac-vm-launch.sh` wasn't lost in a
  future edit.
- If OpenCore's own picker shows up but macOS's kernel panics or
  reboots shortly after being chosen: this is exactly the kind of
  failure the shared/default OpenCore identity (see README.md's
  "Known v1 limitation") could plausibly cause — note down the exact
  panic text/screenshot, since diagnosing this blind without real
  hardware to test against is not realistic from this side.
- If it panics with something explicitly about SMC, SMBIOS, or a
  missing/invalid platform info: double check `isa-applesmc`,
  `smbios type=2`, and the OpenCore drive are all actually present on
  the final QEMU command line — `ps aux | grep qemu-system` from tty2
  will show the full invocation actually running, which is the
  fastest way to rule out a typo/missing flag versus a deeper
  OpenCore/config problem.

### 5.2. The launch profile (CPU / memfd / display / SATA / USB)

`mac-vm-launch.sh` now mirrors Reims' own `vm/boot-x86.sh` and
OSX-KVM's `OpenCore-Boot.sh` (see README.md, "Root cause of the
real-hardware boot stall"). Check, in this order:

- `~/mac-vm.log` (F2 → `logs`) shows a `Launch profile:` line before
  each launch: `cpu=Skylake-Client-v4` (Intel host, or AMD + Sonoma or
  newer) or `cpu=Haswell-noTSX` (AMD + Ventura or older), `smp=` a
  power of two ≤ 8, `gfx=reims-vgpu-pci`, `macos=<shortname>`. If
  `macos=unknown` on a VM made by the "download from Apple" path, the
  wizard didn't write `/var/lib/layerosx/macos-version` — check for a
  wizard error earlier in the log. (A VM made before this change has no
  marker; `erasevm` + redo the wizard, or write the shortname into that
  file by hand.)
- `ps aux | grep qemu-system` from tty2 must show `-cpu <model>,...`
  (never `host`), `-object memory-backend-memfd,...,share=on`,
  `-machine q35,memory-backend=reims-ram`, `-vga none`, `ich9-ahci` +
  three `ide-hd` on `sata.2/.3/.4`, `qemu-xhci`. If any of those is
  missing, the launcher on the machine is stale (rebuild/reinstall, or
  edit `/opt/layerosx/kiosk/mac-vm-launch.sh` in place + `sudo pkill
  Xorg`).
- Confirmed on real hardware: `Unsupported PCI slot 0 for standard
  hotplug controller` from the `reims-vgpu-pci` device -- stock QEMU
  reserves slot 0 of a pci-bridge for its hotplug controller, but Reims'
  own launcher (a QEMU fork) puts the device there. Fixed with `shpc=off`
  on the bridge (see README.md). If you see this again, the `shpc=off`
  was lost from the `pci-bridge` line in `mac-vm-launch.sh`.
- The screen flickering repeatedly (X session flashing) is this class of
  bug: a QEMU arg/device error that exits instantly, relaunched by the
  retry loop 5x before the 60 s `fatal()` pause. Switch to tty2
  (Ctrl+Alt+F2) during the pause and read the `qemu-system-x86_64:` line
  in `~/mac-vm.log` -- that names the rejected argument. A *rendering*
  failure looks different (one frozen frame, QEMU stays up).
- Every QEMU warning at launch lands in `~/mac-vm.log` right after the
  `Launch profile:` line. `warning: host doesn't support requested
  feature: ...` lines are expected on older hosts (`check` is on so they
  warn instead of failing) — a hard error there (`could not load PCI
  option ROM`, `memory-backend-memfd`, `-vga none` refused, unknown
  device) means the ISO was built from the wrong QEMU or without the
  GOP ROM staged.
- **The guest kernel's own output is now captured**: F2 → `serial`
  tails `~/mac-vm-serial.log`. OSX-KVM's OpenCore (ours) carries kernel
  patches "Send early prints to serial port" / "Send panic string to
  serial port" / "Enable early serial output on RELEASE kernel" — so
  this file holds XNU's early boot prints and, above all, the full
  text of any kernel panic. OpenCore itself does *not* log here
  (`Misc/Debug/Target` is 0 in that config), so: empty file → XNU never
  started at all, the problem is at the OVMF/OpenCore stage (look at the
  screen: is the picker there?); XNU lines then `panic(` → read the
  panic text, that's the actual bug now; `Still waiting for root device`
  → the recovery disk isn't visible to the kernel (SATA layout drifted?).
- A guest reset < 180 s after launch is logged as `treating it as a
  boot failure` and relaunched (not a physical reboot). Five in a row →
  `FATAL: QEMU exited 5 times in a row` and a 60 s pause, never a
  physical reboot. If you see the physical machine rebooting on its
  own, something regressed here.
- **The display now defaults to VMware SVGA; Reims is opt-in** (see
  README.md). Confirm a fresh launch's `Launch profile:` line says
  `gfx=vmware-svga` with no `/var/lib/layerosx/gfx` file present. Switch
  with the `gpu` command: `gpu reims` then `sudo pkill Xorg` to try
  acceleration, `gpu vmware` (or `gpu` alone to check) to go back. If
  macOS boots on VMware SVGA but not on Reims, the problem is the Reims
  path (GOP ROM, Vulkan on the host, driver maturity) — check
  `vulkaninfo --summary` on the host and `~/mac-vm.log` for Reims/Vulkan
  errors. If it fails the same way on both, it isn't Reims.
- Recommended install flow (matches Reims' own docs): leave it on the
  default VMware SVGA, get macOS fully installed and booting to the
  desktop, THEN `gpu reims` + relaunch to bring up acceleration on a
  known-good guest. No reinstall needed to switch — the disk is
  untouched, macOS redetects the GPU at boot.

### 5.3. Reaching the installer (what "working" looks like from here)

- OpenCore's boot picker appears (text/icon menu, ~5 s timeout). With
  only a blank `MacHDD` plus the recovery disk attached, the entry to
  boot is the recovery ("macOS Base System" / "Install macOS ...").
- macOS Recovery comes up (Apple logo → progress bar → the Utilities
  window). This is the milestone: from here nothing needs a host-side
  DMG conversion at all. This is also exactly how upstream OSX-KVM and
  dockur/macos install: recovery first, then the guest fetches the
  full installer itself.
- In Recovery: Disk Utility → select the 128 GB QEMU disk (`MacHDD`) →
  Erase as APFS (GUID). Then "Reinstall macOS" — the guest downloads
  the full installer from Apple over its own network (virtio-net, user
  mode) and installs onto the disk it just formatted. Expect several
  reboots; each one goes back through OpenCore and should now pick the
  installed disk automatically (`bootindex=0` is on the OpenCore drive,
  OpenCore itself picks the newest bootable volume).
- If Recovery shows no network / the reinstall fails to download:
  virtio-net is only supported by the guest on Ventura+ (older macOS
  needs `vmxnet3` or `e1000-82545em`) — swap the NIC model in
  `mac-vm-launch.sh` for older versions.
- Once installed and booted to the desktop: Restart from the Apple menu
  should reboot the physical machine, Shut Down should power it off
  (section 6) — those paths are unchanged, only gated behind the 180 s
  uptime check now.

## 5.5. Branding (GRUB menu, boot message)

- Confirmed on real hardware: without this, both said "Arch Linux"
  instead of "LayerOSX" (see README.md). After a fresh install, check:
  the GRUB boot menu's top entry should read "LayerOSX" (not
  "Arch Linux"), and the "Welcome to ...!" line during early boot
  (visible if `quiet` is ever removed from the kernel cmdline, or by
  checking `journalctl -b` for it) should also say "LayerOSX".
- If either still says "Arch Linux" after a fresh install: check
  `/etc/os-release`'s `NAME=`/`PRETTY_NAME=` lines got rewritten by
  `01-base-system.sh`, and `/etc/default/grub`'s `GRUB_DISTRIBUTOR=`
  line got set by `50-grub.sh` *before* `grub-mkconfig` ran in that
  same script — a GRUB menu still stuck on the old name after that
  usually just means `grub-mkconfig` needs a re-run (`sudo
  grub-mkconfig -o /boot/grub/grub.cfg`) after editing
  `/etc/default/grub` by hand, since it doesn't regenerate on its own.

## 5.6. Not losing the VM window to another desktop

- Confirmed on real hardware: openbox's stock 4 desktops (never used by
  this kiosk) let a stray mouse-wheel scroll switch to an empty one,
  leaving the QEMU window behind — looked like the VM going black.
  Fixed in `lib/install-f2-keybind.sh` (see README.md): only 1 desktop
  now, plus an `<application>` rule pinning the QEMU window to it,
  focused, always on top.
- After a fresh boot with a VM already prepared (no wizard), confirm
  the QEMU window appears focused and fullscreen with no manual
  action needed — no need to middle-click for the window list at all.
  If it's still not focused, check `~/.config/openbox/rc.xml` on the
  machine: `<number>1</number>` under `<desktops>`, and a
  `layerosx-qemu-focus`-tagged `<application>` block should both be
  there.

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
- `erasevm` should be on `PATH` already (installed straight
  to `/usr/local/bin`, see README.md) — run it once with an existing
  VM to confirm it lists `macos.qcow2` (and `OVMF_VARS.fd`, and
  whichever of `macos-recovery.qcow2`/`macos-installer.qcow2` exists),
  asks for confirmation, deletes them, and that the *next* boot shows
  the first-run wizard again instead of trying to launch a missing
  disk. Also confirm it refuses (without `-y`/`--force`) while a
  `qemu-system-x86_64` process is still running.

## Licensing notes (not legal advice)

- The ISO this project generates never contains any Apple files.
- The recovery image and/or the `.dmg` always come directly from Apple
  (or were already yours) at the moment YOU run the wizard, onto your
  own disk — never bundled inside the ISO you distribute. This is the
  same approach OSX-KVM and the macOS-VM community have always
  followed.
- It's still against Apple's EULA to run macOS outside Apple hardware,
  accelerated or not — this doesn't change that reality.
