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

## Kiosk commands (runtime cheat-sheet)

Once LayerOSX is running the macOS VM, these commands are on `PATH` for the
`mac` user. You reach a shell to run them with **Ctrl+Alt+T** (a terminal
inside the graphical session). **In a `debug` build** it opens directly (and
**Ctrl+Alt+F2**, tty2 autologin as `mac`, works too). **In a `release` build**
it first asks for the **maintenance password** (the `mac` user's password,
chosen in the installer) — the kiosk stays locked for whoever is at the
keyboard, but is never unmaintainable. VT switching stays off in release. The
policy is a build parameter: `LAYEROSX_TERMINAL=password|open|off` (see
"Maintenance terminal"). Each one changes how the *next* launch
behaves; apply a change with
**`relaunch`** (no reboot) or a full reboot. This is the fastest way to A/B a
problem without rebuilding the ISO — settings are plain-text files under
`/var/lib/layerosx/`, so they can be scripted too.

| command | what it does |
|---------|--------------|
| `commands [name]` | List every kiosk command (one line + short description each, grouped). `commands <name>` prints the full description + usage of a single command. The discoverable index, so you don't have to remember them. |
| `gpu <mode>` | Graphics adapter for the next launch. Modes: `vmware` (default, reliable, unaccelerated), `reims` (hardware-accelerated, alpha), `std` (stock VGA — OVMF linear framebuffer; was the "no linesize" A/B test, which turned out to be a CPUID cache panic — see "ROOT CAUSE of \"no linesize\""). |
| `verbose <on\|off>` | Boot diagnostics. `on` shows XNU's `-v` log (in a **debug**-mode ISO also OpenCore's own logging + serial kernel log); `off` is a clean Apple-logo boot. Default follows the build mode: **off** in release, **on** in debug. |
| `audio <on\|off>` | Attach a `usb-audio` device (macOS drives it with AppleUSBAudio, no kext). Default follows the build mode: **on** in release, **off** in debug; safe either way — it skips itself if the build has no audio backend. |
| `relaunch` | Restart just the macOS VM to apply a `gpu`/`verbose`/`audio` change — kills QEMU only (not Xorg), so no reboot and no screen flicker. |
| `maclog [sub]` | View the guest boot/serial log (`~/mac-vm-serial.log`). No arg = curated view (where it stopped + errors + which OpenCore image booted). Subs: `tail`, `oc`, `patch`, `err`, `launch` (launcher log: OpenCore image + profile + exact cmdline), `qemu` (QEMU `-d guest_errors`, debug builds), `all`, `usb`. For a full shareable bundle of *all* logs + host/config, use `macdiag`. |
| `macstatus` | One-glance summary of the current gpu / verbose / audio settings and the VM disk state. |
| `macdiag [usb]` | Collect a FULL diagnostics bundle into one folder — host CPU/flags/KVM/memory, QEMU version + the exact launch cmdline + which OpenCore image booted, the selected vs downloaded macOS version, the toggles, and the serial + QEMU logs (summary + raw copies). `macdiag usb` copies it to a USB stick. The same bundle is also saved to any USB automatically on every VM exit. |
| `wifi [status\|pick\|list]` | **Host** Wi-Fi (the Mac only sees a wired NAT link, so networks are picked on the Linux side). No arg = current network + internet check; `pick` = the Wi-Fi picker (zenity list + password; `nmtui` when there's no graphical session); `list` = nearby networks. **Hotkey: Ctrl+Alt+W** opens the picker from anywhere — in **both** build modes, so it also works in a locked release kiosk. No relaunch needed: macOS keeps its Ethernet link and rides the new uplink. |
| `usb [list\|pick\|attach\|detach\|always\|forget] [VVVV:PPPP]` | **USB passthrough**: give a host USB device (pendrive, phone, webcam…) to the Mac or take it back. No arg = every device and where it is (Linux / Mac / always→Mac). `always` gives it to the Mac on every launch and re-plug. **Hotkey: Ctrl+Alt+U** opens a picker (both build modes). Keyboards/mice/touchpads and hubs are never passed (input already reaches the Mac); storage must be unmounted on the host first. |
| **Ctrl+Alt+W** (LayerOSX Settings) | **LayerOSX Settings** — a System-Settings-style window (see "LayerOSX Settings"); falls back to the zenity kiosk menu if GTK can't start. The zenity menu offers: status line (Wi-Fi, battery, graphics, boot log, audio, Mac running), **Wi-Fi…**, **USB devices…**, **Graphics…** (Reims / VMware / std), boot log and audio switches, **Restart the Mac** (relaunch the VM — the rescue for a stuck/black screen), **Restart / Shut down computer** (QEMU stopped cleanly first), **Save diagnostics to USB**, **Maintenance terminal…** (same policy as Ctrl+Alt+T). Everything asks before restarting anything. |
| `erasevm` | Delete the VM disk + recovery/installer image + UEFI NVRAM so the first-run wizard runs from scratch again (reinstall, or pick a different macOS version). Refuses while QEMU is running unless `-y`. |

`layerosx-cleanup.sh` also exists but runs on a systemd timer for housekeeping —
not something you invoke by hand. State files: `/var/lib/layerosx/{gfx,verbose,audio}`.

## Build modes: `release` vs `debug`

`build.sh` (and `./rebuild.sh`) asks which build you want, or takes it
non-interactively:

```
./rebuild.sh release     # or: LAYEROSX_MODE=release ./build.sh
./rebuild.sh debug
```

The mode is baked into the ISO (`/etc/layerosx/mode`) and only changes two
things — everything else is identical:

- **Per-mode runtime defaults** (first boot, before you touch any toggle):
  - `release` — the shipping experience: **verbose off** (clean Apple-logo
    boot), **audio on**, **Reims-vGPU on** (the whole point of the project).
  - `debug` — the troubleshooting build: **verbose on**, **VMware SVGA**
    (isolates the display from the Reims path), **audio off** (one variable
    fewer). A user toggle (`verbose`/`audio`/`gpu`) always overrides the
    default.
- **The verbose OpenCore image.** In `debug` it additionally ships serial
  kernel logging (`serial=3 debug=0x108 keepsyms=1`), OpenCore's own Misc>Debug
  logging, kholia's kernel serial patches, and a public **DEBUG OpenCore** so
  `OC:`/`OCAK:` lines actually print (see the OCAK section below). In `release`
  the verbose image is just `-v` on stock RELEASE OpenCore. This is why there is
  nothing to strip out by hand once the boot is fixed — just build `release`.

A `debug` build also turns on **extra logging** aimed at exactly the kind of
stall we're chasing: QEMU's `-d guest_errors,unimp` (illegal / unimplemented
instructions — the first suspect when the CPU model is masked for an AMD host)
to its own `~/mac-vm-qemu.log`, and `msgbuf=524288` so XNU's early `kprintf`
can't scroll off before capture. Every boot (both modes) also records the exact
`%q`-quoted QEMU command line to `~/mac-vm.log`. `macdiag` gathers all of this
into one shareable bundle.

## Kiosk lockdown (no host shortcuts)

A running VM should be the only thing on screen, with no accidental (or
deliberate) way out to the Linux host underneath. `lib/install-f2-keybind.sh`
(run from `.xinitrc` before `openbox &`) edits a copy of openbox's own stock
`rc.xml` to:

- drop the desktop count 4 -> 1,
- remove **every** `<keybind>` — Ctrl+Alt+arrows (which the user hit to switch
  windows/desktops), Alt+Tab, Alt+F4, the Reconfigure/Restart binds, all of it,
- remove the desktop-switch mousebinds (scroll-on-root -> GoToDesktop),
- strip the right-click root menu (Log Out / settings panels),
- pin the QEMU/SDL window focused and above everything on the one desktop.

`build.sh` additionally disables the two shortcuts openbox can't (they're
X-server options): **VT switching** (Ctrl+Alt+Fn) and **Ctrl+Alt+Backspace**
(zap X), via `/etc/X11/xorg.conf.d/10-layerosx-kiosk-lock.conf`.

All of this is **mode-aware**: a `release` build strips everything for a
locked appliance, while a `debug` build keeps VT switching and
Ctrl+Alt+Backspace so the developer still has an escape hatch. A few
deliberate, fixed shortcuts are re-added in **both** modes: **Ctrl+Alt+T** (maintenance
terminal — password-protected in release by default, see "Maintenance
terminal"; build parameter `LAYEROSX_TERMINAL`), **Ctrl+Alt+W** (kiosk menu: Wi-Fi, USB,
graphics, restart, ...), **Ctrl+Alt+U** (USB picker) and the brightness keys.
`SDL_GRAB_KEYBOARD=0` (so F2 keeps reaching openbox instead of the guest) is why
these shortcuts reach the host at all — hence the need to disable them here.

## TODO / polish (deferred until macOS boots cleanly)

Running list of polish items we agreed to revisit once the VM boots to macOS.
None of these block a working boot; they make it nicer.

- **Auto-switch to Reims after install** — provision the guest on VMware SVGA
  (reliable), then flip to the accelerated Reims vGPU automatically once macOS
  is actually installed, instead of the manual `gpu reims`.
- [x] **Kiosk menu as a native single-window app** — done: LayerOSX Settings
  (GTK4/libadwaita, `opt/layerosx/panel/`). Next: a Bluetooth section, a
  "Displays > Resolution" option, and the in-macOS app mirroring it.
- **Pre-boot settings menu** — (partly done: the Ctrl+Alt+W kiosk menu now
  switches gpu / boot log / audio and restarts the VM at any time) — a short countdown screen (~10s) before the VM
  launches, with a "continue to system" button and toggles for gpu / verbose /
  audio (writing the same `/var/lib/layerosx/*` state files the commands use).
- **Easy dependency updates** — an `update-deps.sh` (or a documented process)
  to bump each dependency with one command: Reims/qemu-macos (currently tracks
  master via prepare-qemu-macos.sh), the OpenCore pin (prepare-opencore.sh),
  and the vendored AMD_Vanilla patches.
- **Audio (host side)** — the `audio on` toggle attaches a usb-audio device,
  but the custom qemu-macos binary is likely built with no audio backend. Patch
  its Dockerfile (libasound2-dev + `--audio-drv-list=alsa`) and rebuild so
  sound actually comes out.
- **Adaptive VM resolution** — the framebuffer resolution is a fixed 1920x1080
  (scaled to any monitor by SDL). Optionally match it to the host's real
  resolution for pixel-crisp, unscaled output.
- **Access the host's other disks from the VM** — the guest only gets its own
  qcow2 today. Add a way to reach the physical machine's other drives, in order
  of safety: (1) an SMB share on the Arch host over the existing NAT NIC (mount
  from Finder — safe, no risk to the real disks; likely a toggle/command);
  (2) optional read-only passthrough of a specific disk/partition
  (`-drive file=/dev/sdX`), HFS+/APFS only without extra kexts; (3) USB
  passthrough for external drives. Post-boot feature, doesn't block the boot.
- **LayerOSX menu-bar app (macOS guest) + host helper** — make the Linux host
  invisible by managing the physical laptop from inside macOS. A small Swift
  menu-bar app in the guest talks to a host-side helper daemon over the QEMU
  user-net gateway (`10.0.2.2`, no extra setup; a virtio-serial channel is the
  alternative), with a Wi-Fi-style menu for:
  - **Wi-Fi**: list/join/forget networks (host `nmcli`) — the guest itself only
    has a wired NAT NIC, so this is the in-macOS answer to the `wifi` command.
  - **Battery**: level/charging/time left (host `/sys/class/power_supply`),
    low-battery warning.
  - **Brightness**: slider + map the brightness keys (host backlight).
  - **Bluetooth**: pair/connect mice, keyboards, headphones on the host.
  - **Power profile / GPU mode** (asusctl / supergfxctl on ASUS), keyboard
    backlight.
  - **USB passthrough**: pick a plugged device (pendrive, phone, webcam) to hand
    to the VM.
  - **Host status/updates**: LayerOSX version, host update check.
  Security: bind the helper to the NAT gateway only, expose a fixed allow-list
  of actions (no arbitrary commands), authenticate the app with a per-install
  token. **Reuse the Ctrl+Alt+W kiosk menu as the source of truth**: its
  status line and actions (`lib/kiosk-menu.sh`, `lib/settings.sh`,
  `lib/qmp-cmd.py`, `wifi-setup.sh`, `usb-passthrough.sh`) are exactly the
  helper's allow-list, so the in-macOS app becomes a second front-end for the
  same host actions rather than a parallel implementation. New host features
  should land in the kiosk menu first. The in-guest app must be installed into macOS (first-run step or a
  shared folder).
- **Host integration without the app (interim)** — the host-side baseline so
  each item works before/without the menu-bar app:
  - [x] Brightness keys handled by the host (brightnessctl, both build modes).
  - [x] Battery guard: warnings at 20%/10%, clean macOS shutdown at 5%, forced
        stop + host poweroff at 3% (`lib/battery-watch.sh`).
  - [x] Lid close: host suspends, VM paused/resumed around it (systemd-sleep
        hook); docked = ignore; NVIDIA VRAM preserved across suspend.
  - [ ] Battery level shown *inside* macOS (ACPI battery / VirtualSMC
        SMCBatteryManager research, or via the menu-bar app).
  - [ ] macOS "Sleep" wired to host suspend (needs S3 re-enabled in the guest
        + QMP SUSPEND/WAKEUP handling), like Restart/Shut Down already are.
  - [x] USB passthrough: `usb` command + Ctrl+Alt+U picker, per-device
        "always" list re-attached on every launch/re-plug (never keyboards,
        mice, hubs or host-mounted storage).
  - [ ] USB: optional auto-offer when a new device is plugged in (udev ->
        "Give it to the Mac?" prompt), instead of opening the picker by hand.
  - [ ] Bluetooth picker like the Wi-Fi one (pair mice/keyboards/headphones on
        the host).
  - [ ] Controlled host update path (kernel + NVIDIA driver must move together
        or Reims breaks) — or "update = flash a new ISO".
  - [ ] qcow2 snapshots before macOS updates (`qemu-img snapshot`).
- **Per-install unique SMBIOS identity** — every install currently ships the
  same serial/MLB/UUID baked into OpenCore.qcow2; generate a unique one per
  install so iMessage/App Store/FaceTime don't collide across machines.
- **Boot picker polish** — set a sensible default entry / timeout so an
  unattended (or slow-to-select) boot doesn't land on a blank EFI entry / black
  screen.
- **tty2 (F2 console) refresh rate** — the text console is KMS-controlled, not
  X, so force-max-refresh.sh doesn't reach it; a monitor-specific `video=`
  kernel arg could, if it's worth it.
- **Pre-boot mouse cursor** — the OVMF/OpenCore cursor duplicates/sticks before
  boot; purely cosmetic, pre-boot only.

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
git clone https://github.com/vinioliveiras/LayerOSX.git
cd LayerOSX
./rebuild.sh release        # or: ./rebuild.sh debug
LAYEROSX_TERMINAL=off ./rebuild.sh release   # optional: Ctrl+Alt+T terminal password|open|off
```

`rebuild.sh` runs `setup-build-host.sh` first, which installs everything the
build needs (`archiso docker docker-buildx qemu-img mtools git python curl`,
with `--needed`, so it's a no-op once installed), enables/starts the Docker
daemon and warns if there's under ~30 GB free. You can also run
`./setup-build-host.sh` on its own. (Manual equivalent:
`sudo pacman -S archiso docker docker-buildx qemu-img mtools git python curl`
+ `sudo systemctl enable --now docker`.)

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

(It happened again with `rebuild.sh`, `validate-qemu-args.sh`,
`kiosk/lib/collect-diag.sh` and `kiosk/qmp-watch.py` — all four were stored as
`100644`; fish refused `./rebuild.sh` with "exists but is not an executable
file". They're now `100755` in the index. Check with
`git ls-files -s | grep -E '\.(sh|py)$' | grep ^100644` — it should print
nothing.)

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

### Gotcha: automatic log-save-to-USB silently saved nothing

Confirmed on real hardware: `save-logs-to-usb.sh` never produced a
single file on the Ventoy drive, even though it's wired into multiple
call sites that should have fired repeatedly during a failing test
session (every QEMU exit in `mac-vm-launch.sh`'s retry loop, the
install-wizard's `ERR` trap and successful-install path, and
`layerosx-save-logs.service` at boot). By design the script never
fails loudly, which meant this failure mode itself was invisible.

Root cause: `pick_partition()` required `RM="1"` (lsblk's "removable"
column) before considering a partition at all — but that flag comes
straight from `/sys/block/*/removable`, and a number of real USB
enclosures/bridge chips report `0` there for drives that are
genuinely removable (a known lsblk quirk, not a bug in lsblk itself).
On a drive that misreports this, `pick_partition()`'s loop skipped
every single line, both the Ventoy-labeled best match and the
generic fallback, and returned nothing — exactly this symptom.

Fixed by dropping the `RM` check entirely (the existing
`mount-removable-media.sh`, used by the file picker, never checked it
either and has worked fine) and instead explicitly excluding the
parent disk(s) actually backing `/` and `/boot` (via `findmnt` +
`lsblk -no PKNAME`) — this is the thing we actually care about never
writing onto, and it's a much more reliable signal than a
removable-media flag some hardware just gets wrong. Also added a
`$STATUS_LOG` breadcrumb (`/var/log/layerosx-save-logs-status.log`,
on the *local* disk, so it survives even when the USB step itself is
what's failing) at every exit point of the script, so a future silent
failure like this one can actually be diagnosed instead of guessed
at blind. `layerosx-save-logs.service` also now waits 5s
(`ExecStartPre=sleep 5`) before running, since `local-fs.target` alone
can fire before udev has actually finished enumerating a just-plugged
USB stick.

### Gotcha: force-max-refresh.sh only ran once, too early for some monitors

Reported as "some screens don't get the max refresh rate forced,
mostly right at the start of boot". The script ran exactly once, 1s
after `openbox &` in `.xinitrc` — on a multi-monitor setup a
display's EDID/mode list can still be settling at that point, so a
single `xrandr --query` pass can simply run before an output is fully
ready (empty/incomplete rate list for it) and nothing reapplies the
fix afterwards. Fixed by having the script itself retry internally:
8 passes 2.5s apart over the first ~20s, then two more slower
follow-up passes (at +15s and +45s) in case something else resets the
mode after that window. Runs backgrounded from `.xinitrc` either way,
so this doesn't delay the install wizard or the VM launcher starting.

### Diagnostic finding: QEMU wasn't running at all during a reported black screen

A `ps aux | grep qemu` captured on tty2 during a reported black
screen showed no `qemu-system-x86_64` process at all — meaning the
black screen wasn't QEMU rendering nothing, QEMU had already exited
(or hadn't launched), consistent with `mac-vm-launch.sh`'s retry loop
being mid-cycle (or exhausted, right before its last-resort
`systemctl reboot`). Confirms the black-screen investigation should
focus on why QEMU exits/crashes (check `~/mac-vm.log`, which captures
QEMU's own stdout/stderr via `mac-vm-launch.sh`'s
`exec > >(tee -a "$LOG") 2>&1`), not on display/rendering flags like
`gl=on` or the `reims-vgpu-pci romfile=` property — those only matter
once QEMU is confirmed to actually be running.

### Root cause found: QEMU was crashing on startup every single time (missing libjpeg.so.62)

The black screen and the "reboots itself after a while" behavior
turned out to be the same bug, and `~/mac-vm.log` (captured live on
real hardware, once the auto-log-save fix above made it reachable)
finally showed the real error:

```
/opt/layerosx/bin/qemu-system-x86_64: error while loading shared libraries: libjpeg.so.62: cannot open shared object file: No such file or directory
```

QEMU never actually started, not even once — `mac-vm-launch.sh`'s
5-retry-then-reboot loop was cycling on a guaranteed failure every
time, which is exactly what looked like "black screen, then reboots
after a while" from the outside. Confirmed why: `qemus/qemu-macos`'s
Dockerfile builds with `--enable-vnc-jpeg` (needs libjpeg at link
time for VNC's Tight encoding, regardless of whether `-vnc` is even
used at runtime — the dynamic loader resolves every linked library at
startup no matter what code path actually runs), inside a
Debian-based build image that ships `libjpeg62-turbo`
(`libjpeg.so.62`). Arch's own `libjpeg-turbo` package only ships
`libjpeg.so.8` — a different, incompatible SONAME generation, not a
missing package Arch just needs installed.

Fixed at the source instead of guessing with a symlink: the
Dockerfile's own `verify` stage (`FROM qemux/qemu:latest`) already
`ldd`s the built binary and fails the build if anything's unresolved
*there* — so it's a known-good, already-validated place to pull the
exact right library from. `prepare-qemu-macos.sh` now also builds
that `verify` stage (free — BuildKit reuses the cached layers from
building `artifact`), `ldd`s the binary inside it, and copies every
resolved library that isn't glibc/libstdc++-core (those have to match
the *target* machine's kernel/loader, not the build container's, so
they're deliberately left alone) into
`airootfs/opt/layerosx/lib/`. `mac-vm-launch.sh` now sets
`LD_LIBRARY_PATH` to include that directory before launching QEMU.
Also applied the same `LD_LIBRARY_PATH` trick to
`prepare-qemu-macos.sh`'s own `-device reims-vgpu-pci,help` sanity
query, so it can actually succeed on a build host that's missing the
same libraries (most non-Debian build machines) instead of always
silently falling through to the "couldn't query on this host"
warning.

This requires re-running `prepare-qemu-macos.sh` (needs Docker) and a
full ISO rebuild to take effect — it doesn't fix an already-installed
system. For unblocking a live test session on hardware installed from
an older ISO: `sudo pacman -Sy libjpeg-turbo && sudo ln -sf
/usr/lib/libjpeg.so.8 /usr/lib/libjpeg.so.62 && sudo ldconfig` is an
untested but plausible stopgap (libjpeg-turbo keeps its basic
compression API stable across SONAME generations, and QEMU's VNC-jpeg
usage is a narrow, simple subset of it) — worth trying, but the
bundled-library fix above is the real one and is what any new ISO
build will carry.

### Feature: a real Wi-Fi picker instead of nmtui in a terminal

The "download from Apple" path used to open `nmtui` in a raw xterm
when no internet was detected — functional, but a text-mode tool
needing Tab/arrow-key/Enter navigation, and looks broken to anyone
who's never seen a TUI before. `kiosk/lib/wifi-setup.sh` replaces it
with a zenity list of nearby networks (signal strength, whether
they're secured) — click one, type the password if asked, done.
Includes "Connect to a hidden network…" (prompts for an SSID that
won't show up in a scan) and "Advanced (nmtui)…" as an escape hatch
for anything the simple picker can't do (WPA-Enterprise/802.1X,
captive portals) — nothing regresses, nmtui is just no longer the
only option. `macos-source-wizard.sh` now sources this file instead
of defining `has_internet`/`ensure_internet` inline.

### Feature: F2 opens a live terminal instead of one being forced on you

The install and first-run wizard show a lot of "just wait" moments —
partitioning, copying the system, downloading macOS, converting a
disk image — and used to handle the ones without a zenity progress
bar of their own (`fetch-recovery.sh`, `extract-dmg-installer.sh`,
the `.iso` conversion step) by opening a visible xterm and running
the command directly in it. That's honest feedback, but forced on
everyone even when they don't care to watch raw command output.

Now those three steps run behind a zenity progress dialog instead
(pulsating for the ones with no reliably-parseable progress output —
the Apple download and `dmg2img`; a real percentage for `.iso`
conversion, since `qemu-img convert -p` gives one easily) — no
terminal shown by default, matching the rest of the install. Pressing
**F2** at any time opens a plain terminal tailing whatever's actually
happening right now, for anyone who wants to check — closing it again
doesn't pause or affect anything, it's a read-only peek.

Implementation: `kiosk/lib/install-f2-keybind.sh` runs from
`.xinitrc`, *before* `openbox &` (openbox only reads its config file
at startup) — it copies openbox's own stock `rc.xml` (shipped by the
`openbox` package) into `~/.config/openbox/rc.xml` the first time,
then idempotently injects one `<keybind key="F2">` running
`kiosk/lib/peek-terminal.sh <log-file>`, without touching or losing
any of openbox's own default keybindings/window behavior. Wired into
both `.xinitrc`s: the live-ISO one tails `/var/log/layerosx-install.log`
(what `install-wizard.sh` already writes everything to), the
installed-system one tails `~/mac-vm.log` (which already has
everything `macos-source-wizard.sh` and its children print too, since
it runs as `mac-vm-launch.sh`'s subprocess and inherits that
already-redirected output — no separate log file needed for the
wizard's own progress-bar steps).

### Gotcha: the black/white theme never actually applied (invalid CSS)

Confirmed on real hardware (GParted's own GTK warnings, visible after
pressing F2 mid-install): every rule in `~/.config/gtk-3.0/gtk.css`
used `!important`, and this GTK3 build's CSS parser doesn't
understand it — `Junk at end of value for color`, `Junk at end of
value for background-color`, etc. GTK's CSS parser drops a
declaration whole when it can't parse the value, not just the
`!important` part, so none of the custom colors were ever actually
applied — the "theme" was silently a no-op the entire time.

Fixed by just removing `!important` everywhere (and `border: none`
→ `border-style: none`, since the shorthand's own parsing looked
implicated in one of the errors too). It was never actually needed:
`~/.config/gtk-3.0/gtk.css` is loaded by GTK at
`GTK_STYLE_PROVIDER_PRIORITY_USER`, the highest priority in its whole
cascade by definition — it already wins over the active theme
(`GTK_THEME=Adwaita:dark`) without forcing anything, once the
declarations can actually be parsed.

### Feature: F2 terminal is now interactive, not just a log tail

`kiosk/lib/peek-terminal.sh` used to just run `tail -f` on the
relevant log — fine for watching, but you couldn't actually run a
command in it (check `ps`, `lsblk`, a status file, anything) without
switching away. It now shows the last 40 lines for context, then
drops into a real interactive shell (`$LOG` is exported, and a `logs`
command is predefined to go back to watching live — Ctrl-C stops
watching without affecting anything it was tailing).

### Feature: logs now save to every eligible disk, not just one

`save-logs-to-usb.sh` used to pick a single "best" candidate
(Ventoy-labeled, or the first other match) and stop — which meant one
wrong guess (a drive that looks eligible but turns out unwritable for
a reason invisible from the outside) meant zero logs anywhere, with
no way to tell why from outside a live session. It now tries **every**
exfat/ntfs/vfat partition that isn't part of the system's own disk
(Ventoy-labeled ones first), independently, and keeps going even if
one fails — a `$STATUS_LOG` line records the outcome for each one.
Also always does its own dedicated read-write mount now instead of
ever reusing an existing mountpoint — the live ISO's own boot medium
is commonly already mounted read-only somewhere (e.g.
`/run/archiso/bootmnt`), and silently reusing that would have looked
exactly like "nothing saved, no error" all over again.

### Bug: OVMF firmware path was wrong the whole time

Confirmed on real hardware (F2 terminal showed `cp: cannot stat
'/usr/share/edk2-ovmf/x64/OVMF_VARS.fd': No such file or directory`
right before a doomed 800MB+ macOS download): both `mac-vm-launch.sh`
and `macos-source-wizard.sh` assumed Arch's `edk2-ovmf` package
installs to `/usr/share/edk2-ovmf/x64/OVMF_CODE.fd` /
`OVMF_VARS.fd`. It actually installs to `/usr/share/edk2/x64/`
(no `-ovmf` in the path) and the files themselves are the 4MiB-flash
variant, named `OVMF_CODE.4m.fd` / `OVMF_VARS.4m.fd` — confirmed
against Arch's own package file listing. This had been broken from
the start; it was masked by `macos-source-wizard.sh` not using
`set -e` (the failing `cp` printed an error and kept going anyway)
and, on top of that, by the `libjpeg.so.62` crash (see above)
happening earlier in QEMU's own startup, so nobody had gotten far
enough to notice the OVMF copy itself failing.

Fixed both references to the correct path, and centralized the
`macos-source-wizard.sh` copy into a `copy_ovmf_vars()` function that
now actually fails loudly (a `zenity --error` + `exit 1`) instead of
silently continuing into a download that was never going to boot.

### Bug: macOS download crashed right after finishing ("Inappropriate ioctl for device")

Confirmed on real hardware (F2 terminal): the recovery image
downloaded successfully (843MB), then immediately failed with
`Image verification failed. ([Errno 25] Inappropriate ioctl for
device)`. Root cause is upstream, in `fetch-macOS-v2.py` (from the
OSX-KVM project, fetched at build/run time): its `verify_image()`
function calls `os.get_terminal_size()` directly, with no fallback,
to size a per-chunk progress line. The identical call a few lines
earlier, in the download loop, IS wrapped in `try/except OSError` —
this one just wasn't. This whole install pipeline pipes its output
through a log file the entire way (`tee`, process substitution),
never a real terminal, so that raw call hits `OSError: [Errno 25]`
(ENOTTY) every single time, right as verification starts.

Fixed in `kiosk/lib/fetch-recovery.sh`: after downloading
`fetch-macOS-v2.py`, an idempotent Python patch wraps that one call
in the same `try/except OSError: terminalsize = 80` pattern the
download path already uses. Safe if upstream ever changes that
function's shape — the patch just no-ops with a warning instead of
breaking the script.

### Bug: a failed first-run attempt permanently hid the setup screen

Reported on real hardware: after any failure during first-run setup
(download failed, disk conversion failed, etc.), even a full restart
left the machine stuck on a black screen — no way back to the "where
should macOS come from" screen. Root cause: `macos-source-wizard.sh`
creates `$VM_DISK` (via `qemu-img create`) *before* the step that can
actually fail (the download or conversion), and `mac-vm-launch.sh`
only shows this wizard when `$VM_DISK` doesn't exist yet. A failed
attempt left behind an empty/partial `$VM_DISK`, which satisfied that
check forever after — the wizard would never run again on its own.

Fixed with a `trap ... EXIT` in `macos-source-wizard.sh`: whenever the
wizard exits non-zero for any reason, it now removes `$VM_DISK` and
any partial recovery/installer disk + `$OVMF_VARS` it may have
created, so the very next boot shows the setup options again instead
of a stuck black screen. A clean, successful run exits 0 and the trap
does nothing.

### Bug: `build.sh` kept shipping the old broken qemu-macos binary

Confirmed on real hardware: after the `libjpeg.so.62` bundling fix
landed (see above), a fresh ISO was built and run, and the VM still
crashed with the exact same `error while loading shared libraries:
libjpeg.so.62: cannot open shared object file` — the fix hadn't
actually taken effect. Root cause: `build.sh` only re-runs
`prepare-qemu-macos.sh` (the Docker build that produces the binary
*and* bundles its matching runtime libraries) when
`airootfs/opt/layerosx/bin/qemu-system-x86_64` doesn't exist yet. A
binary built *before* the libjpeg fix already existed on disk from an
earlier session, so that check passed, `prepare-qemu-macos.sh` never
ran again, and every subsequent `build.sh` just repackaged the same
stale binary with no bundled libraries — indefinitely, with no error
or warning.

Fixed: `build.sh` now also checks that
`airootfs/opt/layerosx/lib/` exists and isn't empty, and re-runs
`prepare-qemu-macos.sh` if either check fails. If you already hit
this, delete `airootfs/opt/layerosx/bin/qemu-system-x86_64` once (or
just run `./prepare-qemu-macos.sh` directly) before your next build to
force a clean rebuild.

### `out/` no longer accumulates old ISOs

`profiledef.sh` names each ISO after today's date
(`layerosx-YYYY.MM.DD-x86_64.iso`), so nothing was ever overwritten —
building on three different days left three different ISOs sitting in
`out/` side by side, and it's easy to grab a stale one by mistake
without noticing. `build.sh` now clears `$OUTDIR` at the start of
every build, the same way it already clears `$WORKDIR`, so `out/`
always has exactly one ISO: the one from the build that just ran.

### Bug: the library-bundling step could silently bundle zero libraries

Confirmed on real hardware, after already fixing the two issues above:
a fresh build still shipped a `qemu-system-x86_64` that crashed with
`libjpeg.so.62: cannot open shared object file`, and this time
`/opt/layerosx/lib/` was completely empty in the built system — not
missing one library, missing *all* of them, with no error anywhere in
the build log.

Root cause: `prepare-qemu-macos.sh`'s extraction step ran `ldd
/out/qemu-system-x86_64 | while read -r line; do ...; done` inside
`sh -c '...'` — a POSIX shell (dash, not bash), which has no
`pipefail` option at all. `set -eu` alone does not catch a failure on
the left side of a pipe, so if `ldd` ever failed or produced no
output for any reason, the `while` loop's body simply never ran, the
loop itself still "succeeded", and the whole step reported success
while bundling exactly zero libraries — completely silently.

Fixed two ways: the extraction now captures `ldd`'s own exit status
explicitly (via a temp file + `if ! ldd ...`, no pipe to hide a
failure behind), and — regardless of what silently breaks in the
future — `prepare-qemu-macos.sh` now hard-fails the whole build if it
ends up bundling zero libraries, since libjpeg alone is known to
always need bundling. A build that bundles nothing now stops with a
clear error instead of quietly producing an ISO that crashes on every
boot.

### `prepare-qemu-macos.sh` now always starts clean

Previously it only ever added files to `airootfs/opt/layerosx/` —
never removed anything first. Combined with the bug above, this meant
a failed/partial run could leave old or half-updated output sitting
there, easy to mistake for a good build. It now clears
`airootfs/opt/layerosx/bin/qemu-system-x86_64`,
`airootfs/usr/share/qemu/reims-vgpu-gop.rom`, and
`airootfs/opt/layerosx/lib/` at the very start of every run, before
doing anything else — the same "always start clean" approach
`build.sh` already uses for its own work directory. Combined with
`build.sh`'s existing check (rebuilds automatically whenever the
binary or a non-empty `lib/` is missing), this means neither script
depends on manually deleting anything by hand anymore, however
`prepare-qemu-macos.sh` ends up getting invoked.

### Bug: `docker run` for the library extraction failed against `tini`

Confirmed on real hardware, immediately after the previous fix started
actually surfacing errors instead of hiding them (exactly as
intended): the library extraction step failed outright with
`/usr/bin/tini: invalid option -- 'c'` plus tini's own usage text.

Root cause: `qemux/qemu:latest` (the base image for the Dockerfile's
`verify` stage) bakes in `ENTRYPOINT ["/usr/bin/tini", "-s",
"/run/entry.sh"]`. `docker run image sh -c '...'` only replaces the
image's CMD — it never touches ENTRYPOINT unless `--entrypoint` is
passed — so the actual command executed ends up being the ENTRYPOINT
with `sh -c '...'` appended onto the end of it, effectively `tini -s
/run/entry.sh sh -c '...'`. tini's own argument parser doesn't expect
a stray `-c` like that and refuses to run anything at all.

Fixed by passing `--entrypoint sh` to that one `docker run`, bypassing
tini entirely — this extraction is a one-off `ldd` + `cp` script, it
never needed tini's init/signal-forwarding supervision in the first
place.

### Bug: `LD_LIBRARY_PATH` was leaking into zenity, crashing it on every dialog

Confirmed on real hardware: after `sudo pacman -Syu` couldn't even run
(`error: failed to synchronize all databases (no servers configured
for repository)` — this install is rsync-based, not pacstrap-based,
so the installed system never gets a real `/etc/pacman.d/mirrorlist`
or pacman sync databases; see the comment in
`postinstall/01-base-system.sh`), every `zenity` dialog in the
first-run wizard was crashing immediately with `/usr/lib/libgtk-4.so.1:
undefined symbol: g_zlib_compressor_set_os` — which is why the wizard
kept failing instantly and looping ("The wizard failed or was
cancelled. Retrying in 10s...") no matter what.

Root cause had nothing to do with installed package versions.
`mac-vm-launch.sh` used to `export LD_LIBRARY_PATH=...` for the whole
script, right at the top — meant only for `qemu-system-x86_64` (see
the libjpeg fix above), but `export` makes it inherited by *every*
later child process too, including `macos-source-wizard.sh` and
everything it launches: zenity, GParted, all of it. QEMU has always
linked against glib, so the bundled-library fix above pulls in a
Debian-flavored `libglib-2.0`/`libgobject-2.0`/`libgio-2.0` alongside
it — and with `LD_LIBRARY_PATH` leaking into zenity's environment,
zenity's own (correctly matched, system) gtk4 was loading *that*
foreign glib instead of Arch's, crashing on a missing symbol every
single time.

Fixed by keeping `LD_LIBRARY_PATH` as a plain (non-exported) variable
and applying it only as a per-command prefix on the actual
`qemu-system-x86_64` invocation — nothing else launched by this script
or its children ever sees it now.

### Bug: right-click still opened openbox's full menu (Log Out and all)

Confirmed on real hardware: right-clicking the desktop on an installed
kiosk system opened openbox's stock root menu — Applications, and
System → Log Out / Reconfigure Openbox / GNOME-KDE-Xfce settings
panels. A plain, undocumented way out of "boots straight into the VM,
nothing else" that defeats the whole point of making F2 the one
deliberate escape hatch (see above).

Fixed in `kiosk/lib/install-f2-keybind.sh`: alongside injecting the F2
keybind, it now also strips just the Right-click → root-menu
mousebind from openbox's `rc.xml` (everything else — middle-click for
the window list, and every other context GParted/zenity/the QEMU
window need — is untouched). Each change is independently idempotent
now (checked inside the script, not by skipping the whole file on a
single marker), so a system that already got the F2 keybind from an
older build still picks up the root-menu fix on its next boot.

### Bug: the custom QEMU build had no local-window display support at all

Confirmed on real hardware: once QEMU actually got far enough to parse
its own arguments (past the libjpeg and glib-leak bugs above), it
failed immediately with `-display sdl,gl=on,full-screen=on: Parameter
'type' does not accept value 'sdl'`. Reading `qemus/qemu-macos`'s
Dockerfile directly confirmed why: QEMU is configured with
`--disable-sdl` and `--disable-gtk` — this build ships VNC (with JPEG
+ SASL) and curses only, no local window at all. Makes sense for the
upstream project's own use case (a container, viewed over VNC/noVNC in
a browser) but not for LayerOSX, which wants a direct full-screen
window on the physical display.

Decided to keep the direct-window architecture rather than switch to
VNC + a local viewer (the alternative would avoid a further ~30-60 min
rebuild, but adds a whole extra display layer permanently). Fixed in
`prepare-qemu-macos.sh`: after cloning `qemus/qemu-macos`, it now also
patches the Dockerfile's configure invocation to `--enable-sdl`
(`--enable-opengl` was already on upstream's own configure line, so
SDL's GL integration needs nothing else) and makes sure `libsdl2-dev`
is installed in the builder image, regardless of whether QEMU's own
upstream build image already carries it. GTK stays disabled — nothing
here uses it. `mac-vm-launch.sh`'s own `-display sdl,gl=on,full-screen=on`
line didn't need to change; it was always correct, just unsupported by
the old binary.

### Bug: the --enable-sdl patch itself failed with "apt-get dependency list anchor not found"

The fix above was committed and then failed on real hardware on the
very next build, before it ever got to touch a real Dockerfile. Root
cause was a bug in how the patch script itself was generated, not
anything about the target system: the Dockerfile-patching Python
script is embedded inside `prepare-qemu-macos.sh` as a heredoc, and
while deploying it through a chain of nested heredocs (bash -> an
outer Python string -> this inner Python script's own string
literals), the intended literal `\` + newline sequence inside the
inner script's string values got interpreted by the outer layer at
write time instead of passed through untouched. That turned

    old_deps = "    libbz2-dev \n    libvulkan-dev \n"

into a version using Python's backslash-newline line continuation
inside the string (spread across several source lines), which
produces no character at all -- so the value being searched for never
matched the real Dockerfile content, and the patch always failed with
`FAIL: apt-get dependency list anchor not found`.

Fixed by writing the string literals in explicit single-line form
(`"    libbz2-dev \\n    libvulkan-dev \\n"`, i.e. a real backslash
followed by a real `n`), which encodes the intended bytes unambiguously
no matter how many layers of heredoc/string generation wrap it later.
Verified before redeploying by extracting just the inner script and
running it against a real fetched copy of the `qemus/qemu-macos`
Dockerfile: `libsdl2-dev` is correctly added to the apt-get dependency
list and `--disable-sdl` is correctly flipped to `--enable-sdl`.

### Bug: the verify stage still rejected the binary after --enable-sdl was fixed

Even with the double-escaping bug above fixed, the very next real
build still failed -- this time further along, inside the
Dockerfile's own `verify` stage (`FROM qemux/qemu:latest`), with:

    FAIL: one or more QEMU runtime dependencies could not be resolved.

The full `ldd` output printed just above that line showed exactly two
unresolved entries: `libSDL2-2.0.so.0 => not found` and
`libSDL2_image-2.0.so.0 => not found`. Enabling SDL in the builder
stage makes `qemu-system-x86_64` link against both libraries, but the
`verify` stage's base image (`qemux/qemu:latest`, a plain Debian image
that never needed SDL before this patch) never gets those packages
installed -- so its own `ldd` check, which hard-fails the whole build
on any `not found`, rejected the binary before it ever reached `/out`.

Fixed by patching the Dockerfile a second time: right after the two
`COPY` lines that stage the built binary + GOP ROM into the `verify`
stage, `prepare-qemu-macos.sh` now also inserts
`RUN apt-get update && apt-get install -y --no-install-recommends
libsdl2-2.0-0 libsdl2-image-2.0-0 && rm -rf /var/lib/apt/lists/*`
before the verify stage's own `RUN` heredoc. This has a nice side
effect too: the later library-bundling step (which extracts every
library the verify stage's own `ldd` reports) automatically picks up
`libSDL2`/`libSDL2_image` into `airootfs/opt/layerosx/lib` alongside
`libjpeg`, exactly like any other bundled library -- nothing extra
needed there. Verified end-to-end against a real, freshly fetched copy
of the Dockerfile before deploying: both SDL patches (the builder-stage
`--enable-sdl` one and this verify-stage `apt-get install` one) apply
cleanly together, in the order the script actually runs them.

## OpenCore / Apple SMC / SMBIOS: why plain QEMU isn't enough

Getting `qemu-system-x86_64` to launch cleanly (Reims-vGPU, display,
SDL runtime libs, and so on -- all the fixes above) only gets you to
the point where macOS's own kernel (XNU) starts trying to boot. Plain
OVMF + a bare QEMU command line is not enough for XNU to get past very
early boot at all: it probes for a handful of Apple-specific hardware
pieces that only exist on a real Mac (or something emulating one), and
without them it just doesn't come up -- no useful error message,
just never gets there.

This is well-trodden ground in the wider Hackintosh / macOS-on-QEMU
community (this project isn't inventing anything new here), confirmed
firsthand by reading `dockur/macos`'s own `src/boot.sh` in full, which
every working setup implements some version of:

- **Apple SMC emulation** (`-device isa-applesmc,osk=...`): the `osk=`
  value is the well-known *public* "Apple SMC key" -- it's stored
  ROT13-encoded in `mac-vm-launch.sh` only to keep it from being
  flagged by naive string scanners, **not** because it's a secret. It
  has been public for well over a decade and is shared by essentially
  every macOS-on-QEMU/Hackintosh project, OSX-KVM and dockur/macos
  included.
- **`-smbios type=2`**: baseline "Apple Inc." system info at the
  firmware level.
- **ICH9-LPC ACPI quirks** (`disable_s3`, `disable_s4`,
  `acpi-pci-hotplug-with-bridge-support=off`): macOS handles sleep
  states and bridge hotplug unreliably on the emulated ICH9 chipset
  that QEMU's `q35` machine type provides, so these are disabled
  outright.
- **An OpenCore boot disk**: this is the piece that actually ties
  everything together. OpenCore supplies the *per-machine* SMBIOS
  identity (model, serial, UUID, board serial) plus a small set of
  ACPI/kernel patches (via Lilu and friends) that stock OVMF+QEMU
  don't provide on their own. It's attached with `bootindex=0`
  (read-only) so OVMF's own boot manager always tries it first; once
  OVMF hands it control, OpenCore does its *own* scan of every other
  attached disk to find and chainload into the real macOS system --
  no extra `bootindex` needed on those other disks, matching how
  `dockur/macos` itself does it.

### Decision: reuse a pre-built OpenCore image instead of assembling our own

`dockur/macos`'s own approach builds a fresh, per-install OpenCore
disk image at runtime: extract a bundled OpenCore release, edit its
`config.plist` with a generator tool (`xmlstarlet`), generate a unique
per-machine identity, build a GPT/FAT32 disk with `sfdisk` + `mtools`.
That's a lot of new tooling this project doesn't otherwise depend on
(7z, xmlstarlet, mtools/sfdisk), and -- more importantly -- there was
no way to actually test-boot a hand-assembled `config.plist` before
real hardware does; a subtly wrong identity or patch set would only
surface as a mysterious failure to boot on the one machine that
matters.

Instead, `prepare-opencore.sh` (new) downloads
[kholia/OSX-KVM](https://github.com/kholia/OSX-KVM)'s pre-built
`OpenCore.qcow2` as is -- a community-battle-tested image already
containing `OpenCore.efi`/`BOOTx64.efi`/`config.plist`/the standard
Lilu-based kexts. It's pinned to a specific commit
(`4c378a4b5e0b219783683012bec680325eb40719`) plus a SHA-256 integrity
check, since unlike the QEMU binary (which gets re-verified by the
Dockerfile's own build+verify stage on every run), this is a static
binary blob with no such self-check of its own -- if the pin ever goes
stale or the download is corrupted/tampered with, `prepare-opencore.sh`
refuses to stage it rather than silently shipping something broken.
`build.sh` now calls it automatically, the same way it already calls
`prepare-qemu-macos.sh`, whenever
`airootfs/opt/layerosx/opencore/OpenCore.qcow2` doesn't exist yet.

Note on `file`'s "AES-encrypted (v3)" report for this image: that's a
false positive from a qcow2-v3 header flag. Confirmed with `qemu-img
info` (no encryption in the format-specific section) and by reading
OSX-KVM's own `OpenCore-Boot.sh`, which attaches it with a plain
`-drive ...,format=qcow2,file=...` and no `-object secret` at all.

**Known v1 limitation, flagged for future work:** because this image
is reused as-is, every LayerOSX install currently shares the same
default OpenCore identity (model/serial/UUID/board serial) rather than
generating a unique one per machine, the way `dockur/macos`'s own
runtime build does. This is a deliberate tradeoff for now -- shared
identity is a known, well-understood limitation in the Hackintosh
community (some Apple services that key off hardware identity may
treat multiple machines with the same identity as one device) -- not
an oversight. Generating a real per-machine identity properly (valid
serial/board-serial/SmUUID format, a real MLB, a ROM value derived
from the machine's MAC address) is real future work, not something to
get subtly wrong under time pressure with no way to test it.

There was no explicit LICENSE file found in kholia/OSX-KVM at the time
of writing (checked both a direct fetch and the repo's own GitHub
page). The underlying OpenCore/Lilu/kexts it redistributes prebuilt
are separately acidanthera-licensed (BSD-3-Clause) open source
components -- noting this plainly rather than overclaiming a specific
license for the repackaged blob itself, which is how the wider
community already treats this artifact.

### Note: no VMware-style "unlocker" or extra guest kext needed

Worth spelling out explicitly since it comes up when researching this
topic: the well-known `unlocker` project patches VMware Workstation/
Fusion's own EULA-enforcement code, which blocks macOS guests on
non-Apple hardware at the hypervisor level. **This doesn't apply
here** -- LayerOSX uses QEMU, which has never had that restriction, so
there's nothing to patch on that front.

Separately, [reims-vgpu.com](https://reims-vgpu.com/) states that
standard macOS 13 Ventura+ installations use Apple's own built-in
`AppleParavirtGPU.kext` for the GPU -- no separate driver or kext to
install on the guest side for that. This is unrelated to the OpenCore/
Lilu kexts described above, which exist purely for kernel-boot
compatibility (ACPI/SMBIOS patching), not GPU acceleration.

## Bug: `qemu-system-x86_64: Could not access KVM kernel module`

First real-hardware boot attempt after the OpenCore work above hit a
new failure, right at QEMU launch:

    qemu-system-x86_64: Could not access KVM kernel module: No such file or directory
    qemu-system-x86_64: failed to initialize kvm: No such file or directory
    could not connect to QMP: [Errno 111] Connection refused
    QEMU exited without a clear guest request (action: vm-only) — relaunching just the VM.

Before this fix, `mac-vm-launch.sh`'s own retry loop just kept
relaunching QEMU into the exact same error forever (and eventually
rebooted the whole physical machine as a last resort) -- a bad loop
for what's almost always a one-time configuration problem that a
reboot alone doesn't fix.

`postinstall/10-hardware-detect.sh` already detects the CPU vendor and
adds `kvm_intel`/`kvm_amd` to `/etc/mkinitcpio.conf`'s `MODULES=()`
array at install time, then regenerates the initramfs -- but had no
way to confirm the module actually loads. That fails *silently* when
virtualization (Intel VT-x, or AMD-V / "SVM Mode") is disabled in the
machine's BIOS/UEFI firmware, by far the most common real-hardware
cause of this exact error -- mkinitcpio has no way to detect that
ahead of time, so the install would appear to succeed and the failure
would only surface much later, as QEMU's cryptic message on first
launch.

Fixed in two places:

- `10-hardware-detect.sh` now also registers the module via
  `/etc/modules-load.d/layerosx-kvm.conf` (a second, simpler path to
  the same result -- `kvm_intel`/`kvm_amd` don't actually need to be
  *in* the initramfs at all, since nothing before root-mount needs
  `/dev/kvm`), and does a best-effort `modprobe` right there in the
  chroot with logging, so a BIOS-disabled-virtualization failure shows
  up in `/var/log/layerosx-postinstall.log` immediately instead of
  only at first VM launch.
- `mac-vm-launch.sh` now checks for `/dev/kvm` before ever invoking
  QEMU, tries one more `modprobe` itself, and if it's still missing,
  fails fast with a message that says what to actually check --
  reboot, enter BIOS/UEFI setup, enable Intel VT-x / AMD-V / SVM
  Mode -- instead of looping on QEMU's own unhelpful one. There's no
  useful software-only (TCG) fallback for something as heavy as a
  macOS guest, so this is a hard `FATAL`, not a degraded-performance
  path.

### Bug: the FATAL fix above flash-looped the whole X session

Deploying the `/dev/kvm` check above immediately surfaced a second,
worse problem on real hardware: the message printed correctly, but the
machine kept cycling through it so fast it was only readable via the
F2 live-log terminal, never on the physical screen itself.

Root cause: `.xinitrc` runs `mac-vm-launch.sh` as the very last `exec`
in its chain (agetty autologin -> `.bash_profile`'s `exec startx` ->
`.xinitrc`'s `exec mac-vm-launch.sh`), so this script exiting doesn't
just end the script -- it ends the whole X session. `getty@tty1`'s
autologin config restarts that chain immediately. A plain `exit 1`
right after printing the FATAL message, with nothing pacing it, meant
the entire X-session-relaunch cycle repeated as fast as the machine
could manage -- confirmed faster and worse than the old
all-QEMU-launch-failures retry loop it was partly replacing (which at
least had `sleep 3` between its 5 attempts before rebooting), and fast
enough to risk tripping systemd's own restart-rate-limit on the getty
unit, which would leave `tty1` dead until a manual restart.

None of the three FATAL conditions in this script (missing
`qemu-system-x86_64`, missing `OpenCore.qcow2`, missing `/dev/kvm`) are
things a quick retry a second later would ever fix -- they all need
either a rebuild with the right `prepare-*.sh` script run, or a
physical fix like a BIOS setting. Fixed with a shared `fatal()` helper
that all three now go through: prints the message, says plainly it
isn't retrying automatically, then sleeps 60s before exiting. This
paces the X-session restart to something sane and, more importantly,
gives a wide window to switch to a text console (Ctrl+Alt+F2) or pull
up the F2 live-log terminal and actually read the message before it
scrolls away.

### Bug: `bootindex` rejected on the OpenCore drive, and the wizard blocked by unrelated checks

With `/dev/kvm` sorted out, the very next real-hardware boot got
further -- past the first-run wizard, downloading and decompressing
the recovery image successfully -- and then hit a new failure right at
the actual QEMU launch:

    qemu-system-x86_64: -drive if=virtio,file=/opt/layerosx/opencore/OpenCore.qcow2,format=qcow2,readonly=on,bootindex=0: Block format 'qcow2' does not support the option 'bootindex'
    could not connect to QMP: [Errno 111] Connection refused
    QEMU exited without a clear guest request (action: vm-only) — relaunching just the VM.

The `-drive if=virtio,...,bootindex=N` shorthand implicitly creates its
own device, and on this QEMU build that implicit creation routes
`bootindex` into the qcow2 block-layer's own options instead of the
virtio-blk device's properties -- `$VM_DISK` and `$RECOVERY_DISK` never
hit this because neither of them sets `bootindex` at all; the OpenCore
drive was the only one that did. Fixed by splitting it into the
explicit two-flag form already used for the AHCI/SATA fallback further
down in the same script: `-drive if=none,id=opencore,...` just opens
the image with nothing attached, and a separate `-device
virtio-blk-pci,drive=opencore,bootindex=0` is what actually attaches it
to the bus -- `bootindex` unambiguously belongs to that `-device` now,
so there's nothing left to misroute it into the block layer.

Separately (surfaced while testing without KVM available, in a nested
virtualization setup): the `QEMU_BIN`/`OPENCORE_IMG`/`/dev/kvm`
preflight checks used to run *before* the first-run wizard, which meant
a missing or not-yet-ready piece of the accelerated-launch path blocked
the wizard -- and its "download from Apple" step -- from ever opening
at all, even though downloading/preparing macOS onto `$VM_DISK` needs
none of them. Moved all three checks to right before the actual QEMU
launch, after the wizard and recovery-disk detection, so preparing a VM
disk always works regardless of whether the accelerated launch path is
ready yet. Also added a line to the `/dev/kvm` `fatal()` message
pointing at real hardware over nested virtualization specifically,
since "enable nested virtualization" in VirtualBox (or similar) is
unreliable at actually exposing a usable `/dev/kvm` to a guest even
when turned on -- this project targets real hardware, and chasing
nested-virtualization settings further wasn't a good use of time.

## Live real-hardware testing: two follow-up UX fixes

Both surfaced while testing on real hardware, past the point where the
`bootindex` fix above got the VM to actually launch — neither is a boot
blocker, but both were annoying enough while iterating (trying a
different macOS source, or trying to attach a local `.dmg`) to fix
right away instead of working around by hand every time.

### Feature: `erasevm` — a one-command way to redo the first-run wizard

`mac-vm-launch.sh` only ever shows `macos-source-wizard.sh` (the
"where should macOS come from" first-run screen) when `$VM_DISK`
doesn't exist yet — so trying a different macOS source/version, or
recovering from a bad first attempt, meant knowing to manually delete
the right handful of files under `/var/lib/layerosx/` by hand (and
knowing that `OVMF_VARS.fd`, the UEFI NVRAM store, has to go too — it
remembers OpenCore's last boot choice, which can point at nothing
useful once the disk it pointed at is gone). Wrapped that into a
single command, installed straight into `PATH`:

    erasevm         # asks for confirmation first
    erasevm -y      # skip the confirmation

It deletes `macos.qcow2`, `macos-recovery.qcow2`/`macos-installer.qcow2`
(whichever exists), and `OVMF_VARS.fd`, then tells you to reboot (or
switch to tty1 and re-run `mac-vm-launch.sh`) so the first-run wizard
opens again. Refuses by default if a `qemu-system-x86_64` process is
still running — deleting the disk out from under `mac-vm-launch.sh`'s
own launch loop while it's still active would make *its* automatic
relaunch fail instead of cleanly reopening the wizard, so this asks for
a reboot first instead (or `-y`/`--force` to delete anyway).

### Bug: zenity's file-selection dialog never appeared for the "I already have macOS" path — replaced with a native Tkinter picker

Picking "I already have macOS (VM disk, installer `.dmg`, or
recovery/installer `.iso`) — pick a file" in the first-run wizard is
supposed to open a `zenity --file-selection` dialog next. On real
hardware, no dialog ever appeared — no error either, it just silently
didn't show up. This is the same dependency class of bug documented
above ("`LD_LIBRARY_PATH` was leaking into zenity, crashing it on
every dialog"): zenity is a GTK application, and GTK is exactly the
kind of thing this project already bundles a conflicting,
Debian-flavored copy of (for the custom `qemus/qemu-macos` build) —
that earlier bug was fixed by no longer exporting `LD_LIBRARY_PATH`
globally, but it's still a live risk any time something upstream of
zenity in the environment changes.

Rather than keep chasing this specific class of fragility, the file
picker no longer uses zenity at all: `lib/pick-source-file.py` opens a
plain Tkinter (`Tk`) "open file" dialog instead — same filters
(`*.qcow2 *.img *.raw *.iso *.dmg *.app`), same starting directory
(`/mnt/media`, where `lib/mount-removable-media.sh` mounts USB media),
same behavior (prints the chosen path, or nothing if cancelled).
Tkinter has no dependency on GTK whatsoever, so this whole bug class
can't recur here regardless of what `qemus/qemu-macos` or anything
else ends up bundling in the future. Needs the `tk` package (added to
`packages.x86_64`) for Tcl/Tk's shared libraries — Arch's `python`
package already ships the `_tkinter` extension built in. The rest of
the wizard (the initial "where should macOS come from" choice,
progress dialogs, error messages, the Wi-Fi picker) still uses zenity
— this swap is scoped to just the one dialog that was actually
breaking.

### Bug: the "where should macOS come from" list forced a horizontal scrollbar

Confirmed on real hardware (screenshot): the second option's label
("I already have macOS (VM disk, installer `.dmg`, or
recovery/installer `.iso`) — pick a file") was wider than zenity's
list actually renders before scrolling, cutting the row off mid-
sentence behind a horizontal scrollbar instead of just wrapping or
shrinking to fit `--width=620`. Shortened to "I already have macOS —
pick a file (disk, `.dmg`, or `.iso`)" — short enough to render on one
line with no scrollbar. The full list of accepted extensions is still
shown right on the file picker itself one screen later, so nothing
was lost by trimming this one.

## Feature: pick a specific macOS version for the "download from Apple" path

Come up while looking for a Ventura `.dmg` to test with (see the `.dmg`-corruption bug above) — there was no way to ask the wizard for a *specific* macOS version at all; "download the recovery image directly from Apple" always just grabbed whatever `fetch-macOS-v2.py`'s own default board-id resolves to. `fetch-macOS-v2.py` (from kholia/OSX-KVM) already has a hardcoded table mapping version names to real Mac board-ids, exposed via its own `-s`/`--shortname` flag — Apple's actual recovery servers still serve every one of them (High Sierra through Tahoe), the same request a real Mac of that board-id makes when it boots into network recovery. This is the same "get it directly from Apple, over the real network-recovery protocol" mechanism the wizard already used, just parameterized instead of hardcoded to one implicit default — nothing about this redistributes or bundles anything from Apple.

The wizard now shows a version picker right after choosing "download from Apple," defaulting to **Ventura (13)** — recommended specifically because that's what Reims-vGPU's own README recommends for initial testing (its alpha-stage driver is most tested against it), which is a different reason than upstream OSX-KVM's own "Sonoma — RECOMMENDED" default (that one's about general Hackintosh/OSX-KVM compatibility, not this project's specific GPU driver). `lib/fetch-recovery.sh` takes the chosen shortname as an optional second argument and passes it straight through to `fetch-macOS-v2.py -s`.

Also means there's no more need to go hunting for a macOS installer `.dmg` on a Hackintosh forum (unreliable in general — no way to verify integrity of an unofficial re-upload, and see the `.dmg`-corruption bug above for what an old `dmg2img` does with modern Apple DMGs anyway) just to test an older/specific macOS version — the automatic download path can just be asked for that version directly now.

## Feature: real progress bar for the macOS download

The "download from Apple" path used a *pulsating* zenity bar because an earlier
note assumed `fetch-macOS-v2.py`'s download printed nothing parseable. It does:
a carriage-return-updated `"<MB>/<MB> MB |=== | 42.3% downloaded"` line.
`run_download_with_progress()` now parses that into a **real** percentage. The
download maps to 0-95% of the bar; the verify/`dmg2img`/`qemu-img` phases after
it emit no parseable %, so the label switches ("Verifying and preparing…") and
the bar holds at 95 until the whole thing finishes (closed at 100). Every line
is still echoed so the F2 live log stays complete. (`qemu-img convert -p` for
the "I already have a disk" paths was already a real bar via
`run_convert_with_progress()`.)

## Bug: "Ventura" selection could install Sequoia (stale cache + `os_type: latest`)

Selecting **Ventura** in the wizard once came up as **Sequoia 15.4** (Darwin
`24.4.0`) on the real machine. Two things conspire here:

1. **Stale download cache.** `fetch-recovery.sh` downloads into
   `/var/lib/layerosx/fetch-work/recovery/`, which persists across boots, and
   the wizard re-runs for a different version after a failed/erased attempt.
   It then did `find recovery -iname BaseSystem.dmg | head -n1` — which, if a
   *previous* run had left a different version's `BaseSystem.dmg` there, would
   pick up the stale image. Fixed: `fetch-recovery.sh` now `rm -rf recovery
   BaseSystem.img` before every download, so `find` can only ever see the image
   we just asked for.

2. **`os_type: "latest"` on kholia's Ventura entry.** In
   `fetch-macOS-v2.py`'s product table the Ventura row is tagged
   `os_type: "latest"`, i.e. it asks Apple for the *newest* recovery that
   board-id serves, not Ventura specifically. `Mac-4B682C642B45593E` is capped
   at 13.7.8 in OpenCore's `boards.json`, but the `latest` request defers to
   Apple's live server, so it can hand back something newer than the label
   promises. If a fresh, cache-cleared `-s ventura` still returns too-new an
   image on a given day, the deterministic fix is to pin an explicit board-id +
   `os_type` in `fetch-recovery.sh` rather than trust the shortname table — the
   cache fix above is the first, always-correct half of the problem.

## Feature: confirm the macOS version actually downloaded

The picker shows the version you *ask* for; this shows the version you *get*.
After the "download from Apple" path finishes, `fetch-recovery.sh` reads the
real `ProductVersion` (+ build) straight out of `SystemVersion.plist` in the
decompressed `BaseSystem.img` — a plain byte scan, so it's format-agnostic
(HFS+ or APFS) and needs no mounting or extra tools; it writes
`<vmdir>/downloaded-version` as `<ver>|<build>` (and simply skips this if the
plist can't be read, e.g. if it were compressed).

The wizard then either confirms it ("Downloaded macOS 13.7.8 (build 22H625).")
or, if it doesn't match what you picked, warns and lets you **Install anyway**
or **Start over**. Keeping a mismatched version also rewrites
`$MACOS_VERSION_FILE` to the *real* version's shortname, so `mac-vm-launch.sh`
masks a CPU model that matches the OS — important because e.g. a Sequoia image
booting under Ventura's Haswell mask is itself a boot hazard. This is the
user-facing companion to the `os_type: "latest"` caveat above: even when Apple
hands back a newer release than the label, you see it and decide.

## Feature: rebrand the installed system away from "Arch Linux"

Confirmed while installing on real hardware: past the wizard/VM
concerns above, the installed *host* system still visibly says "Arch
Linux" in two places outside the kiosk itself — the GRUB boot menu
entry, and systemd's own early-boot "Welcome to Arch Linux!" message.
Both trace back to the same untouched `/etc/os-release` (`NAME`/
`PRETTY_NAME` still say "Arch Linux" from the base install) — GRUB's
own `grub-mkconfig` falls back to reading it for the menu title
whenever `GRUB_DISTRIBUTOR` isn't set, which Arch's own
`/etc/default/grub` template leaves unset by default.

Fixed with two small, independent postinstall changes: `01-base-
system.sh` now rewrites `NAME`/`PRETTY_NAME` in `/etc/os-release` to
"LayerOSX" (leaving `ID`/`ID_LIKE`/`VERSION` alone on purpose — those
are what pacman hooks and other tooling check to know this is really
Arch underneath, no reason to risk breaking that for a cosmetic
rename), and `50-grub.sh` now explicitly sets `GRUB_DISTRIBUTOR=
"LayerOSX"` in `/etc/default/grub` before `grub-mkconfig` runs, rather
than relying on the os-release fallback alone — that's the more
standard, explicit way distros control their own GRUB menu title.

## Feature: stop the VM window from getting "lost" on another openbox desktop

Confirmed on real hardware, repeatedly: openbox's stock `rc.xml` (copied wholesale by `lib/install-f2-keybind.sh`, see there) ships with 4 virtual desktops by default -- completely unused by this kiosk (it only ever runs one fullscreen QEMU window), but still fully wired up, including openbox's own default mouse-wheel-on-desktop bindings (`DesktopNext`/`DesktopPrevious`). A stray scroll while the pointer wasn't over the QEMU window (or anything else that happened to trigger a desktop switch) could flip to an empty desktop with the VM window left behind on the old one -- from the user's side this looked like the VM vanishing into a black/blank screen, recoverable only via openbox's middle-click window-list pager.

`install-f2-keybind.sh` now also drops the desktop count from 4 to 1 (there's nothing to accidentally switch *to* anymore) and adds an `<application>` rule pinning the QEMU window (matched on a wildcard class and its actual SDL title, confirmed on real hardware as `QEMU (<-name value>)`) to desktop 1, focused, always above everything else the moment it appears. Both edits follow the same idempotent pattern the rest of the script already uses.

## Root cause of the real-hardware boot stall: the launch profile itself

After everything above, the VM reliably reached OVMF (TianoCore logo,
`BdsDxe: starting Boot0002`), then went blue, then black, and QEMU's
PID kept changing -- it was exiting and being relaunched by
`mac-vm-launch.sh`'s own retry loop, over and over, with nothing
readable on screen. Instead of guessing further, `mac-vm-launch.sh`
was compared line by line against the two upstream launchers this
project actually descends from: **Reims' own `vm/boot-x86.sh`**
(github.com/steelbrain/reims-vgpu -- the validated invocation for the
`reims-vgpu-pci` device on x86/KVM) and **kholia/OSX-KVM's
`OpenCore-Boot.sh`** (the launcher the `OpenCore.qcow2` we ship was
configured against), with **dockur/macos** (same QEMU build family as
`qemus/qemu-macos`) as a third reference. Where those agree, our
launcher now does the same. Where it used to differ from all of them,
it was wrong -- five times over, any one of which is enough on its own
to produce exactly the symptom observed:

1. **`-cpu host`.** No working macOS-on-KVM setup does this. XNU only
   boots on a CPU it recognises as Intel, and only calibrates its clock
   through the `vmware-cpuid-freq` CPUID leaf; `-cpu host` on an AMD
   host hands it an `AuthenticAMD` vendor (immediate early panic --
   our OpenCore carries no AMD kernel patches), and on any host omits
   `vmware-cpuid-freq=on` (XNU hangs before drawing anything). A
   panicking guest auto-restarts; with `-no-reboot` that restart is a
   QEMU exit; the retry loop relaunches it -- the PID-cycling loop. Now:
   a named Intel model with the exact flags the references use
   (`kvm=on,vendor=GenuineIntel,vmware-cpuid-freq=on,vmx=off,-pdpe1gb,
   -hle,-rtm`, `+invtsc` only when the host really has a constant,
   nonstop TSC). Model choice follows dockur/macos: `Haswell-noTSX` for
   an AMD host running Ventura or older, `Skylake-Client-v4` otherwise,
   with dockur's per-host feature mirroring on AMD. The macOS version
   comes from `/var/lib/layerosx/macos-version`, which the first-run
   wizard now writes.
2. **No shared memfd RAM.** Reims decodes the guest's GPU command
   stream out of guest memory on the host side; its README lists
   "shared memfd-backed guest RAM" as a hard runtime requirement and
   its script does `-object memory-backend-memfd,share=on` +
   `-machine memory-backend=`. Plain `-m` gives the device no view of
   guest memory at all.
3. **A second display.** Without `-vga none` (or `-nodefaults`) QEMU
   adds its default VGA next to the Reims device. Reims' script is
   explicit: the UEFI GOP lives on the Reims PCI device's own option
   ROM and it must "never [be] a second display". Now `-nodefaults
   -vga none`, the Reims device behind a `pci-bridge` (their default
   attach), `romfile=` as an absolute path.
4. **virtio-blk disks.** Only Ventura+ has a VirtIO block driver, and
   the recovery environment is the one place we can't afford to find
   out it doesn't. Both references put everything on SATA
   (`ich9-ahci` + `ide-hd`), and OSX-KVM's exact port layout is what
   our OpenCore image was built for: OpenCore on `sata.2`, install
   media on `sata.3`, system disk on `sata.4`. (`snapshot=on` instead
   of `readonly=on` on the OpenCore image -- an IDE/SATA hard disk
   can't be attached read-only, but a snapshot drive discards its
   writes, which was the intent.)
5. **ICH9 USB (`-usb`).** Both references use xHCI (`qemu-xhci`) with
   the keyboard and tablet on it; macOS handles the q35 default
   EHCI/UHCI pair far less reliably.

Also from the references and folded in at the same time: `-smp` capped
at 8 and rounded down to a power of two (Reims caps its guest at 8 with
`reims-vgpu-pci`; macOS misbehaves on odd topologies), `romfile=` on
the NIC (no PXE option ROM, so no "UEFI Misc Device" network-boot entry
for OVMF to wander into), and `-serial file:~/mac-vm-serial.log` --
OSX-KVM's OpenCore config carries kernel patches that send XNU's early
boot prints and its panic string to the serial port, so what used to be
a blind blue screen is now text (`serial` in the F2 terminal).

Two behaviours of the retry loop changed with it, because the old ones
actively hid this bug: a guest "reset" within 180 s of launch is now
treated as a boot failure (kernel panic / firmware reset) and relaunched,
not as a Restart request that reboots the physical machine (nothing a
person does reaches the Apple menu that fast from a cold start), and
five QEMU exits in a row now stop with a `fatal()` pointing at both logs
instead of rebooting the physical machine (which fixes nothing and
takes the logs away). Every log line now carries a timestamp, since the
log is append-only across boots and the "which attempt was that?"
ambiguity cost a whole session.

And one escape hatch, because Reims is alpha on top of alpha: writing
`vmware` into `/var/lib/layerosx/gfx` (then `sudo pkill Xorg` from tty2)
makes the next launch use the plain VMware SVGA adapter -- the same
VMVGA build dockur/macos runs on, unaccelerated but boring -- with
everything else identical. It's the single most useful A/B switch for
telling "Reims can't draw yet" apart from "macOS isn't booting at all",
and it needs no rebuild. (Also fixed on the way: the wizard's
`.img`/`.raw` "complete disk" path copied the file verbatim, but the
launcher attaches `$VM_DISK` as qcow2 -- it's converted now.)


### Bug: QEMU rejected the Reims device at slot 0 of the PCI bridge

Confirmed on real hardware, right after the launch-profile rewrite above
got the VM past OVMF: QEMU exited instantly, five times, into the
`fatal()` -- and `~/mac-vm.log` had the exact reason:

    qemu-system-x86_64: -device reims-vgpu-pci,...,bus=pci.5,addr=00.0: Unsupported PCI slot 0 for standard hotplug controller. Valid slots are between 1 and 31.

Reims' own `vm/boot-x86.sh` puts the device at slot 0 of the pci-bridge
(`addr=00.0`) and this launcher copied that exactly -- but Reims runs a
QEMU *fork*, and stock QEMU 11.1 (what `qemus/qemu-macos` builds) enables
the bridge's Standard Hot-Plug Controller (SHPC) by default, which
reserves slot 0. Two ways out: move the device to slot 1+, or turn the
hotplug controller off. Chose `shpc=off` on the bridge, because it keeps
the Reims device at `addr=00.0` exactly where its own launcher puts it
(its BAR0/GOP mapping comments suggest the slot placement isn't
arbitrary) instead of moving it to a slot QEMU happens to allow.

This was a fast-exit error, so the symptom on screen was the whole X
session flickering -- QEMU taking the fullscreen, exiting immediately,
openbox coming back, the loop relaunching, five times, then a 60 s
`fatal()` pause. "The screen keeps flickering" is what a fast-exit
launch error looks like from the outside; a *rendering* problem (Reims
drawing wrong) would instead leave a single frozen/garbage frame with no
relaunch. That distinction is worth remembering: flicker = QEMU exiting
= read the `qemu-system-x86_64:` line in `~/mac-vm.log`; frozen = QEMU
up = read `~/mac-vm-serial.log` for what the guest is doing.

## VMware SVGA is now the default display; Reims is opt-in

Reims is alpha, and its own docs say to provision the macOS guest on the
plain VMware SVGA adapter first and only switch to Reims once there's a
working, installed system. So the launcher now defaults to `vmware-svga`
-- unaccelerated but reliable enough to actually get macOS installed --
and Reims is opt-in. This splits two problems that were being fought at
once: "can macOS install/boot here at all" (vmware answers that) and
"does the accelerated GPU work yet" (a separate problem, on a guest
that's already known-good).

Switching needs no rebuild and no macOS reinstall -- the disk is
untouched, only the GPU QEMU hands the guest changes, and macOS
redetects it at boot (Reims uses the stock `AppleParavirtGPU.kext`). A
small `gpu` command wraps it:

    gpu            # show the current adapter
    gpu reims      # use Reims vGPU next launch
    gpu vmware     # use VMware SVGA next launch (the default)
    # then: sudo pkill Xorg   (or reboot)

Under the hood it just writes `reims` or `vmware` into
`/var/lib/layerosx/gfx`, which `mac-vm-launch.sh` reads at launch
(anything other than `reims` -- including no file at all -- means
vmware). `erasevm` deliberately leaves this file alone: it's a display
preference, not tied to any particular macOS install.

## More "I already have macOS" disk formats: VMware, VirtualBox, Hyper-V

The "pick a file" path used to take a complete disk only as
`.qcow2`/`.img`/`.raw`. It now also takes the native disk formats of the
other common hypervisors, since `qemu-img` reads them all and converts
straight to the qcow2 the launcher expects:

- `.vmdk` — VMware (also VirtualBox's default export)
- `.vdi` — VirtualBox
- `.vhd` / `.vhdx` — Hyper-V (and VirtualBox)

All are treated as a complete, already-installed system (they boot
directly, no installer step). A split VMware `.vmdk` works too: pick the
small descriptor `.vmdk` and `qemu-img` pulls in the `-s001.vmdk`/
`-s002.vmdk`… extents sitting next to it. (Where the disk *comes from*
is the user's business, same as any other source here — a pre-installed
macOS image redistributed by a third party is not something LayerOSX
fetches or bundles; this is format support for a disk you already have.)

### Bug: the VMware adapter is `vmvga` in this build, not `vmware-svga`

Confirmed on real hardware, the moment vmware-svga became the default: QEMU
exited instantly with `-device vmware-svga: 'vmware-svga' is not a valid
device model name`, five times into the `fatal()`, screen flickering. The
qemu-vmvga overlay this build uses (see `qemus/qemu-macos`) *replaces* stock
QEMU's VMware SVGA device and registers its own under the name `vmvga`
(verified in qemu-vmvga's source: `hw/display/vmware_vga.c` →
`TypeInfo .name = "vmvga"`). Stock QEMU and this build have the name
inverted — stock has `vmware-svga` and no `vmvga`, this build has `vmvga`
and no `vmware-svga` — which is exactly the kind of build-specific detail a
generic reference launcher gets wrong. Fixed to `-device vmvga`.

### Hardening: a persistent launch failure no longer flicker-loops the machine

The same incident exposed a worse problem than any single wrong argument:
once QEMU failed to launch, the machine became nearly impossible to fix by
hand. `fatal()` used to `sleep 60; exit 1`, but exiting ends the X session,
and getty's tty1 autologin restarts it immediately — which re-runs
`force-max-refresh.sh` (resetting the display mode) and relaunches the VM,
an endless ~75 s flicker cycle with only a brief, mode-thrashing window to
switch to a text console. (The user's own read of it — "it keeps trying to
force the refresh rate in a loop" — was the symptom of exactly this: the
refresh reset every time X restarted.)

`fatal()` now does **not** exit. It prints what to do and then holds the
session alive and idle (`while true; do sleep 3600; done`) — no QEMU, no X
restart, no mode-thrash — so the screen sits still and `Ctrl+Alt+F2` stays
reliably reachable. The machine is recoverable: switch to a text console,
apply the fix, `sudo reboot`. The transient-crash retry loop (a QEMU that
exits *without* a fatal-class cause, fewer than 5 times) is unchanged; only
the give-up path stopped nuking the session.

## Verbose macOS boot enabled by default

macOS boots to the Apple logo + progress bar by default, which tells you
nothing when it stalls. `prepare-opencore.sh` now bakes `-v` (verbose) into
the OpenCore config's `boot-args` at build time, so XNU prints its boot log
straight to the screen instead of hiding behind the logo — the fastest way
to see exactly where a boot hangs or panics on real hardware. It patches the
`config.plist` inside the pinned OpenCore image *after* the sha256 check (the
integrity check still guards the download; only our known `-v` edit is added
on top), This is its own script, `patch-opencore-verbose.sh`, that `build.sh` runs on
**every** build — not just inside `prepare-opencore.sh`'s download path.
That matters: `build.sh` only re-downloads OpenCore when the image is missing,
so a machine that already built once reuses its existing (non-verbose) image;
baking `-v` only into the download path silently shipped a non-verbose ISO on
every rebuild. The standalone patcher is idempotent (skips if `-v` is already
there) and always runs, so a reused image gets patched too.

It edits the FAT EFI partition in place with `mtools`. The build host needs
`qemu-img` and `mtools`; `build.sh` auto-installs them via pacman if missing
(best-effort — on a non-pacman host, or with no network, install by hand). If
either is still missing the patch step is skipped with a warning rather than
failing the build. `boot-args` is in this config's `NVRAM/Delete` list as well as `Add`,
so OpenCore rewrites it every boot and `-v` applies even over a cached NVRAM.

To toggle this per-install without a rebuild, use the `verbose on|off`
command (see "Verbose boot is now a toggle" below) — this always-on bake was
later superseded by per-CPU OpenCore images plus that toggle, so `-v` is no
longer edited into the base image in place.

## Running macOS on an AMD host CPU (AMD_Vanilla kernel patches)

Confirmed on the AMD test machine: with the stock, Intel-only OpenCore the
macOS recovery froze every time at `EXITBS` → `HANDOFF TO XNU` — the kernel
takes over and dies before printing anything more. Per Dortania's OpenCore
guide, an `EXITBS` hang on an AMD host is the signature of missing AMD kernel
patches. XNU is built for Intel: even though QEMU is handed a masked Intel CPU
(`Haswell-noTSX,vendor=GenuineIntel`), the guest still executes on real AMD
silicon, and the Intel-specific MSRs XNU's power-management (XCPM) path
reads/writes don't exist on AMD — KVM injects a fault and the kernel is gone
before it can log a thing. The fix the whole AMD-Hackintosh world uses is the
**AMD_Vanilla** patch set (github.com/AMD-OSX/AMD_Vanilla): OpenCore rewrites
those kernel byte sequences in memory as it loads XNU.

Because those same patches would corrupt a *correct* (Intel) kernel, they
can't share one OpenCore image — Intel and AMD need different images. So the
build now derives **four** OpenCore images from the one pristine,
checksum-verified base:

| image | host | boot log |
|-------|------|----------|
| `OpenCore.qcow2` (the base) | Intel | clean (Apple logo) |
| `OpenCore-verbose.qcow2` | Intel | verbose `-v` |
| `OpenCore-amd.qcow2` | AMD | clean |
| `OpenCore-amd-verbose.qcow2` | AMD | verbose `-v` |

`mac-vm-launch.sh` reads the host CPU vendor from `/proc/cpuinfo` and picks the
AMD images on an `AuthenticAMD` host, the Intel images otherwise. If an AMD box
is somehow missing its AMD image it warns loudly (it would just hang) and falls
back to the base. Intel is completely unaffected — it keeps booting the
untouched base image, still byte-for-byte the sha256-pinned download.

Two AMD specifics that must line up:
- **Core count.** Four of the 25 patches force `cpuid_cores_per_package` to a
  constant, and it *must* equal the guest's `-smp` core count or XNU panics on
  the mismatch. `patch-opencore-amd.sh` bakes in 4, and the launcher pins the
  AMD guest to exactly 4 cores (Intel keeps the largest-power-of-two-≤8 rule).
  Change one, change the other.
- **`ProvideCurrentCpuInfo=True`**, which AMD_Vanilla's own sample config sets,
  is enabled in the AMD images.

The patch set is **vendored** in the repo (`archiso/amd-vanilla-patches.plist`,
25 patches, sha256 `4bc820109b3d020c3c547fa23c49e0098e4f4a2c625ed6184dd54e390e84e1ab`)
rather than downloaded at build time, so the build is reproducible and works
offline; bump it deliberately to track upstream. `patch-opencore-amd.sh` is
idempotent (never stacks the patches twice) and, like the verbose patcher,
degrades to a warning if `qemu-img`/`mtools` are missing instead of failing the
build.

Validated as far as possible without the hardware: in a sandbox the AMD image
loads OpenCore and reaches the boot picker with all 37 patches present (12 base
+ 25 AMD), the four core-count bytes set to 4, and the quirk on. Whether the
patches actually carry XNU past `EXITBS` can only be confirmed on the AMD
machine — that's the next real-hardware test.

## Verbose boot is now a toggle, not always-on

The earlier approach baked `-v` permanently into the single OpenCore image. Now
that there are per-CPU images anyway, `-v` is just a second prebuilt image per
family (see the table above), and a **`verbose` command** flips between them
with no rebuild and no slow re-patch of the disk — same pattern as `gpu`:

```
verbose            # show the current setting
verbose on         # show XNU's boot log (default while bringing macOS up)
verbose off        # clean Apple-logo boot (the "normal" look)
```

It writes `/var/lib/layerosx/verbose`; the launcher reads it and attaches the
matching image on the next launch (`sudo pkill Xorg`, or reboot). Default is
**on**, because the boot log is what makes a stall diagnosable; switch it off
once macOS boots cleanly. `prepare-opencore.sh` no longer edits the base image
in place — it stays pristine and `build.sh` derives every variant from it.

(OpenCore's own picker has no native "press F2 to toggle verbose" — its boot
menu isn't an editable settings screen — which is why this is a host-side
command instead. It's the reliable equivalent of what a bare-metal Hackintosh
does by holding Cmd+V.)

## Networking: `vmxnet3`, not `virtio-net`

The launcher used `virtio-net-pci`, which macOS has no driver for — the guest
would show a dead card and no network, even though the Linux host's own
connection works fine (QEMU's user-mode NAT is host-agnostic; what matters is
whether the *guest* recognizes the emulated card). Switched to **`vmxnet3`**:
macOS bundles VMware's `AppleVmxnet3Ethernet.kext`, so the NIC is recognized
out of the box and pulls an IP over the same user-mode NAT with zero guest
configuration. `e1000-82545em` is the documented fallback if a future macOS
ever drops vmxnet3.

## General device support (what will and won't work in the guest)

A pass over every virtual device the launcher hands macOS, and whether macOS
can actually drive it:

| area | device | macOS support |
|------|--------|---------------|
| Disk | SATA AHCI (`ich9-ahci`) | native `AppleAHCI` — works |
| USB | xHCI (`qemu-xhci`) + `usb-kbd`/`usb-tablet` | native `AppleUSBXHCI` + HID — works |
| Network | `vmxnet3` | native `AppleVmxnet3Ethernet` — works (this change) |
| Graphics | `vmvga` / `reims-vgpu-pci` | VMware path via WhateverGreen; Reims via stock `AppleParavirtGPU` — works |
| Keyboard/mouse | USB HID (absolute `usb-tablet`) | works, absolute pointer (no mouse-grab) |
| SMC | `isa-applesmc` | required, present |
| Clock | `-rtc base=utc` | works |
| Audio | `usb-audio` (opt-in, off by default) | macOS drives a USB Audio Class device with its built-in `AppleUSBAudio` — no kext, unlike the `intel-hda` + `AppleALC` route. Attached only when `audio on` is set, and the launcher probes first so it's skipped (not fatal) if unsupported. **Caveat:** sound still depends on the custom qemu-macos binary having an audio backend compiled in — it's built for VNC/noVNC, so it may not; if so, that needs a QEMU rebuild (see below). |

Deliberately *not* present because macOS can't use them: `virtio-rng`,
`virtio-balloon`, virtio-serial/clipboard sharing. Nothing here blocks
installing or running macOS; audio is the one everyday feature not there yet.

### Audio: an opt-in `usb-audio` toggle (host side may still need work)

Audio is a whole stack, not one flag, so it's opt-in and off by default. The
guest side is the easy part: `-device usb-audio` presents a USB Audio Class
device that macOS's built-in `AppleUSBAudio` driver binds to with no kext. An
`audio on|off` command (same pattern as `gpu`/`verbose`, writing
`/var/lib/layerosx/audio`) toggles whether the launcher attaches it.

Turning it on is always safe to try: before adding the device the launcher
probes the QEMU binary for a `usb-audio` device *and* a usable audio backend,
and if either is missing it prints a warning and boots **without** audio rather
than feeding QEMU an argument it would reject (which would turn a good boot into
a launch failure). The host packages for the ALSA backend (`alsa-lib`,
`alsa-utils`, `sof-firmware`) are on the ISO.

The remaining unknown is the QEMU binary itself: `qemus/qemu-macos` is built for
VNC/noVNC viewing and may have been compiled with **no audio backend at all**.
If `audio on` boots but stays silent, that's this — the fix is to patch
`prepare-qemu-macos.sh`'s Dockerfile to install `libasound2-dev` and build QEMU
with `--audio-drv-list=alsa`, then rebuild (the 30-60 min Docker step). That
build-side change is deliberately *not* done yet: it's the same fragile
Dockerfile-patching that the SDL enablement needed several tries to get right,
and getting it wrong breaks the whole QEMU build, so it's kept separate from
the guest-side toggle above. The `intel-hda` + `AppleALC.kext` route remains an
alternative if `usb-audio` ever proves unreliable.

## Root cause of the "boots to HANDOFF then dies" freeze: phantom kexts, not the CPU

For a long stretch this looked like an AMD kernel problem — macOS reached
`HANDOFF TO XNU` and then the screen froze with no further output, which is the
textbook signature of an AMD CPU issue, so the AMD_Vanilla patches went in. They
were necessary, but they were not the whole story.

Turning on OpenCore's own logging (see the verbose image below) made the real
error print:

```
OC: Plist Kexts\VoodooPS2Controller.kext\Contents\Info.plist is missing for
    injected kext VoodooPS2Controller.kext
Halting on critical error
```

The base OpenCore image (kholia/OSX-KVM's `OpenCore.qcow2`) lists five kexts in
`Kernel > Add` as **Enabled** that it does **not** actually bundle:
`VoodooPS2Controller.kext` (+ its keyboard plug-in), `AppleMCEReporterDisabler.kext`,
`USBToolBox.kext` and `UTBMap.kext`. OpenCore treats a missing injected kext as a
critical error and **halts before loading the kernel** — so XNU never ran, and
the "freeze after HANDOFF" was OpenCore stopping, not the kernel dying. (This
also explains the intermittent behaviour: whichever missing kext OpenCore hit
first is where it stopped.) None of the five are needed here — the VM uses USB
input, not PS/2 — and the kexts that matter (Lilu, VirtualSMC, WhateverGreen)
are present and stay enabled.

The fix is `patch-opencore-fixup.sh`: it reads the image's actual `Kexts` folder
and disables any `Kernel > Add` entry whose bundle isn't there. It's detection by
filesystem, not a hardcoded list, so it keeps working if the base image changes
what it ships. `build.sh` runs it **in place on the base** before deriving any
variant, so every image — including the clean Intel base that boots directly —
inherits the fix. This affects Intel too: the same phantom-kext halt would hit an
Intel host, so fixing it in the base is what makes "the same ISO also runs on
Intel" actually true.

### Verbose is now the single diagnostics switch

OpenCore's logging (which revealed the halt) and XNU's `-v` are both baked **only
into the verbose images** now (`patch-opencore-verbose.sh` sets `Misc > Debug`
`Target`/`DisplayLevel` alongside adding `-v`). So the non-verbose images
(`OpenCore.qcow2`, `OpenCore-amd.qcow2`) are completely silent, and `verbose off`
turns off *everything* — the Apple-logo boot with no `-v` and no OpenCore log
spam — while `verbose on` turns all of it back on. One command for all
diagnostics. Once macOS boots cleanly, `verbose off` is the polished mode.

## The "no linesize" freeze: the boot framebuffer had no stride

After the phantom-kext halt was fixed and the kernel serial-output patches were
enabled, the serial log finally showed what the macOS kernel does after
`HANDOFF TO XNU`: it prints `no linesize` and stalls. Confirmed identical on
BOTH the vmware and reims display paths, so it isn't display-driver specific.

"linesize" is the framebuffer stride (bytes per scanline). The kernel gets a
boot framebuffer with no valid stride (rowBytes = 0), so its early video
console can't come up -- which shows as a black / frozen screen (and is why the
OpenCore picker also goes black on timeout). The base config set
`UEFI > Output > ProvideConsoleGop = True` but left `Resolution` empty, so
OpenCore never actively established a GOP mode.

`patch-opencore-fixup.sh` now forces `UEFI > Output > Resolution = 1920x1080`
(plus `ProvideConsoleGop` and `ClearScreenOnModeSwitch`) on the base image, so
every derived image hands the kernel a clean framebuffer with a valid stride.
This is the VM's INTERNAL (emulated-GPU) resolution -- QEMU/SDL scales it to the
physical monitor in fullscreen, so it is safe on any monitor size; 1920x1080 is
universally supported by the emulated adapters.

Also: `force-max-refresh.sh` is now idempotent -- it only switches an output's
mode when it isn't already at its max refresh, which stops the screen flicker
that a redundant mode-switch caused on every relaunch.

## Gotcha: qemu-macos rebuild failed to compile (upstream qemu-vmvga master regression)

Rebuilding the custom QEMU (needed to ship the framebuffer fix in a fresh ISO)
failed at the compile step, under `-Werror`:

```
hw/display/vmware_vga_vgpu10.c:11326: error: implicit declaration of function
    'vmsvga3d_screen_target_async_poll_present_live'
... conflicting types for 'vmsvga3d_screen_target_async_poll_present_live'
... static declaration of '...' follows non-static declaration
```

This is **not** caused by anything on our side. The upstream qemu-macos
Dockerfile pulls `qemus/qemu-vmvga` from its `master` branch (`ADD
...qemu-vmvga.git#master`), so every rebuild takes whatever is newest. The
regression was the very latest commit at the time: `2c3cae7` (#508, 2026-09-21,
"D3D9 switch lifetime and SO binding order"). It started **calling** the static
functions `vmsvga3d_screen_target_async_poll_present_live()` and
`vmsvga3d_screen_target_async_discard_live()` from inside
`hw/display/vmware_vga_vgpu10.c` — but that file is `#include`d partway through
`vmware_vga_3d.c` (around line 10144), while those functions are only **defined**
much later (lines ~15068 / ~15296). So they're used before they're declared, and
the build dies. A pure upstream ordering bug.

### Fix: pin qemu-vmvga to a known-good commit instead of tracking `master`

`prepare-qemu-macos.sh` now pins `qemu-vmvga` via a `QEMU_VMVGA_REF` variable
near the top of the script, and patches the upstream Dockerfile's `ADD` line to
use that ref instead of `#master`. It's set to `c51c680`
(`c51c680b5d55f2ed66fc560bc9fd5e3ad962626c`, #507, 2026-09-20, "Implement DX2
whole-surface copy") — the commit **immediately before** the broken one, i.e. the
newest qemu-vmvga that still builds, carrying every fix up to that point. We only
dropped the single regressing commit.

This also makes dependency updates easy (a long-standing want): to move
qemu-vmvga forward, bump `QEMU_VMVGA_REF` to a newer commit once upstream fixes
the ordering; to go back to tracking the branch, set it to `master` (the
Dockerfile patch then becomes a harmless no-op). It can also be overridden for a
single run without editing the file:

```
QEMU_VMVGA_REF=<sha-or-branch> ./prepare-qemu-macos.sh
```

GitHub serves any commit reachable from the default branch to Docker's `ADD`, so
a plain commit SHA works as the ref. The pin is the reason the whole rebuild —
and therefore the untested "no linesize" framebuffer fix — can finally produce a
working ISO again.

## Bug: `relaunch` flicker-looped the screen (killed Xorg instead of the VM)

`relaunch` (used to apply a `gpu`/`verbose`/`audio` change without a full
reboot) did `sudo pkill Xorg`. That tore down the **whole graphical session**,
and then two things raced to bring it back: getty's tty1 autologin re-running
`.xinitrc`, and the launcher's own retry loop. On real hardware this showed up
as the screen **flickering non-stop** after a relaunch (each restart is a blink,
and they kept restarting).

Root of why killing Xorg was even needed: `mac-vm-launch.sh` read the
`gpu`/`verbose`/`audio` toggle files **once, before** its `while` loop, so the
loop's own "QEMU exited → relaunch" path reused the old settings. The only way
to pick up a new toggle was to restart the whole script — hence killing Xorg.

Fix, two parts:
- `mac-vm-launch.sh` now re-reads the toggles **inside** the loop
  (`configure_toggles`, called every iteration), so the OpenCore image + display
  + audio args are recomputed on every (re)launch.
- `relaunch` now signals **QEMU** (`pkill -f /opt/layerosx/bin/qemu-system-x86_64`,
  TERM then KILL for a frozen one), not Xorg. QEMU exits → the launcher's loop
  re-reads the toggles and brings the VM straight back **in the same X session**.
  No Xorg restart, no session race, **no flicker** — just a brief black while
  QEMU comes back.

Also hardened the loop's fast-crash guard: a session that ran for a while and
then exited (or was killed by `relaunch`) resets the retry counter, so a
deliberate relaunch no longer marches toward the 5×→`fatal()` limit that's meant
for a genuine boot-crash loop. The `gpu`/`verbose`/`audio` commands now tell you
to run `relaunch` (not `sudo pkill Xorg`).

Note: `verbose` already defaults to **on** in `mac-vm-launch.sh` — if a boot
comes up non-verbose, there's an explicit `off` saved in
`/var/lib/layerosx/verbose`; `verbose on` + `relaunch` clears it cleanly now.

### Known/next: the tty2 text console runs at a low refresh (monitor ghosting)

Switching to the raw kernel VT (Ctrl+Alt+F2) to read `maclog`/`serial` puts the
monitor on the console's low-refresh mode, which can smear/ghost on some panels.
The in-session F2 log terminal (openbox, inside X) runs at the full refresh, but
isn't always reachable when the fullscreen SDL VM has grabbed input — which is
exactly when you need the VT. Proper fix (setting a sane console mode/refresh)
is still open; tracked in the TODO section.

### Observability: the launcher now logs which OpenCore image it chose

Chasing why `verbose on` sometimes still boots the non-verbose image cost a
round-trip (boot → run commands → photo). The launcher now prints, on every
launch, the exact OpenCore image it selected and the verbose state, e.g.
`OpenCore image: OpenCore-amd-verbose.qcow2  [verbose=on]`, and calls out the
common failure explicitly: `[verbose=ON requested, but
OpenCore-amd-verbose.qcow2 is MISSING/empty -> using non-verbose]`. It goes to
`~/mac-vm.log`, and `maclog` now surfaces the last such line at the top of its
diagnostic view — so a boot that comes up non-verbose explains itself with no
extra diagnostic session.

## "no linesize" is guest-side (XNU) — new `gpu std` A/B test

Reframing the `no linesize` stall after a closer look: it lands in
`~/mac-vm-serial.log`, which is the **guest's COM1** (`-serial file:`), NOT
QEMU's host stderr (that goes to `~/mac-vm.log`). And the format is `%s`-style —
standard C printf, which is XNU's style, not EDK2/OVMF/OpenCore (those use `%a`).
So `no linesize @%s:%d` is almost certainly **the macOS kernel itself**, failing
to bring up its video console because the boot framebuffer it inherited has no
valid stride (rowBytes=0). That strongly implies **macOS is alive but can't
draw** — a framebuffer problem, not "the kernel died at handoff", and not the
host SDL frontend. It also explains why switching vmware↔reims changes nothing
(both hand XNU the same bad framebuffer) and why forcing the GOP resolution
wasn't enough.

New candidate, added as a third `gpu` mode so it needs no per-attempt rebuild:

```
gpu std      # stock std VGA; OVMF's QemuVideoDxe publishes a LINEAR framebuffer
             # GOP with a valid stride, which boot.efi hands to XNU as the boot FB
relaunch
```

`gpu std` uses `-device VGA` (with a build-capability probe that falls back to
vmware if this QEMU lacks it). macOS has no accelerated driver for std VGA, but
that's not the point — the boot/console framebuffer OVMF provides is linear with
a real stride, which is exactly what "no linesize" is missing. So this is the
direct A/B test: **if macOS draws on `gpu std` but not on vmware/reims, the
framebuffer the vmvga/reims GOP hands XNU is the culprit** (and we then fix that
GOP/framebuffer path); if it fails identically on std too, the problem is earlier
than the framebuffer. Either outcome narrows it down without a rebuild per try.

## Getting the KERNEL log: `serial=3` (the framebuffer console is a dead end)

The frozen VM screen at boot is Apple `boot.efi`'s log, and it stops at
`EXITBS:START` — the handoff to the kernel. Past that, XNU takes the framebuffer,
can't bring up its video console (the "no linesize" the boot framebuffer has no
valid stride), and draws nothing — so the screen freezes on boot.efi's last
frame and the kernel is a black box. `-v` alone can't help: it writes to that
same broken framebuffer console.

The fix for *visibility* (not the boot itself): the verbose image now adds
`serial=3` (plus `keepsyms=1 debug=0x108`) to boot-args, so XNU uses the **16550
serial console** (COM1 / 0x3F8 — the port the launcher captures to
`~/mac-vm-serial.log`), which is independent of the framebuffer. `debug=0x108`
is `0x100` (`DB_KERN_DUMP_ON_PANIC`, symbolicated panic on serial) OR `0x08`
(`DB_KPRT`, route the kernel's `kprintf()` stream to serial). The `0x08` bit is
the important one now: it emits the **running boot log**, not just a post-mortem,
so the serial log shows exactly *where* the kernel spins after handoff — we
already know it is alive (qemu pins one core at ~100% CPU), it is just invisible.
This is what the RELEASE OpenCore couldn't give us on its own: OpenCore's *own*
debug log (OC:/OCAK:) needs a DEBUG OpenCore build, but the *kernel's* log only
needs the kernel routed to serial, which a boot-arg does — no OpenCore swap
required.

With this, `verbose on` + rebuild + `maclog` should finally show XNU's own output
after `HANDOFF`, which disambiguates the two possibilities the frozen screen
leaves open: **(a)** the kernel panics/hangs at handoff (the serial log names
where), or **(b)** the kernel is booting fine but invisibly because only its
video console failed (the serial log shows it marching on to the installer). The
fix for the actual stall follows from which one it is.

## Fix: the F2 log terminal stopped working once the VM grabbed the keyboard

F2 opens the in-X (full-refresh) log terminal via an openbox keybind. It quietly
stopped firing once the VM became interactive: clicking into the QEMU/SDL window
(e.g. to pick macOS in the OpenCore menu) makes SDL take an **exclusive keyboard
grab**, after which F2 goes to the guest instead of openbox — leaving only the
raw `Ctrl+Alt+F2` VT, which is low-refresh and ghosts on some monitors.

Fix: launch QEMU with `SDL_GRAB_KEYBOARD=0`, so the SDL window never takes an
exclusive keyboard grab. The openbox F2 keybind keeps working while the VM is
focused, and macOS still receives every other key through normal window focus.
(`Ctrl+Alt+F2` still works too — it's a kernel VT switch, below X entirely.)

## Bug: DEBUG OpenCore swap caused "Already started / Halting on critical error"

The DEBUG swap copies a full `OpenCore.efi` over `\EFI\BOOT\BOOTx64.efi`. With
kholia's `LauncherOption` set, OpenCore launched as BOOTx64 tries to relaunch
`\EFI\OC\OpenCore.efi` (the same image) -> `OC: Found previous image, aborting`
-> `Already started` -> `Halting on critical error`. It booted fine while NVRAM
still pointed straight at `\EFI\OC\OpenCore.efi`, then failed once that changed
(e.g. after the first macOS boot). Fix: the debug config now sets
`Misc>Boot>LauncherOption = Disabled`, so OpenCore runs in place as a single
instance whatever path it was booted from. Debug image only.

## Getting OpenCore's OCAK log: swap the verbose image to a DEBUG OpenCore

kholia's `OpenCore.qcow2` ships a **RELEASE** OpenCore build, which prints
nothing to serial/console/file no matter what `Misc>Debug` is set to. So the
kernel-patch results (`OCAK: ... Success/Not found`) — the definitive answer to
"are the AMD_Vanilla patches actually applying?" — were invisible.

Swapping in a public DEBUG OpenCore hit an "Invalid revision" wall before,
because kholia's build is custom (its version string is the un-substituted
placeholder `REL-XXX-YYYY-MM-DD`) and its drivers are newer than any public
RELEASE, so a public `OpenCore.efi` rejects kholia's drivers. Fix: swap the
**whole** binary set from **one** public DEBUG release (OpenCore.efi + Bootstrap
+ the revision-checked drivers: OpenCanopy, OpenRuntime, OpenPartitionDxe,
ResetNvramEntry, ToggleSipEntry, OpenHfsPlus), so their revisions match each
other. Config, ACPI and kexts stay kholia's.

`patch-opencore-verbose.sh` now does this for the **verbose image only**
(`OC_DEBUG_VER`, pinned to `1.0.5`): it downloads the matching DEBUG release and
mcopies those binaries into the ESP. `verbose off` keeps the clean RELEASE
OpenCore. Verified by booting the swapped image in QEMU/TCG (no KVM needed):
`OC: OpenCore DBG-105-... is loading`, drivers load, config parses, and the full
`OC:/OCB:/OCABC:` log streams to serial — no "Invalid revision".

This is diagnostic scaffolding (tracked for removal in CLAUDE.md). With it,
`verbose on` + rebuild + booting macOS finally shows the `OCAK` kernel-patch
results in `maclog`, so we can see whether the AMD patches apply and where the
kernel actually dies.

## ROOT CAUSE of "no linesize": a CPUID cache panic, not the framebuffer

Every framebuffer theory above was wrong. `no linesize @%s:%d` is a **kernel
panic string** from XNU's `osfmk/i386/cpuid.c`, function
`cpuid_set_cache_info()`:

```c
if (linesizes[L2U])       info_p->cache_linesize = linesizes[L2U];
else if (linesizes[L1D])  info_p->cache_linesize = linesizes[L1D];
else                      panic("no linesize");
```

"linesize" is the **CPU cache line size**, not the framebuffer stride. The
panic fires during early CPU setup, before any console (video or serial kprintf)
exists, which is why nothing followed it on serial and why it was identical on
vmware, reims and std VGA — the display device was never involved.

Why the kernel found no cache line size: the AMD_Vanilla patch
`algrey | _cpuid_set_cache_info | Set CPUID proper instead of 4` rewrites
`mov eax, 4` (Intel's deterministic-cache leaf) into `mov eax, 0x8000001D`
(AMD's cache-topology leaf). That's correct for a guest that *sees* an AMD CPU
(`-cpu host`). But our launcher masks the guest as `Haswell-noTSX,vendor=GenuineIntel`,
whose maximum extended leaf (`xlevel`) is `0x80000008`. For an out-of-range
leaf, QEMU (target/i386/cpu.c, `cpu_x86_cpuid`) follows Intel semantics and
returns the highest **basic** leaf instead — leaf `0xD` (XSAVE). Its fields
never decode as an L1D or L2 cache, so every `linesizes[]` entry stays 0 and XNU
panics. The patch reported `Success` in the OCAK log precisely because it
applied — applying it was the bug.

This also rules out the "our QEMU fork broke the framebuffer" hypothesis: stock
QEMU has the same leaf-clamping behaviour, so it would panic identically.

### Fix

`patch-opencore-amd.sh` now keeps that one patch in `Kernel > Patch` but sets
`Enabled = False` (also on inputs that already carry AMD_Vanilla). The masked
Intel CPU answers leaf 4 correctly on its own (QEMU encodes it for Intel
vendors), so XNU gets real cache geometry. The other AMD_Vanilla patches keep
upstream's own Enabled flags (21 of 25 active). Only the AMD images change; the
Intel base image never carried these patches.

The earlier framebuffer changes (`Resolution=1920x1080`, `DirectGopRendering`,
`gpu std`) are harmless and stay for now; they are no longer believed to be
needed and can be revisited once macOS boots.

Rejected alternative: raising the guest's `xlevel` to `0x8000001D` (+`topoext`)
so the AMD leaf answers. It works in principle, but mixes AMD cache leaves into
an Intel-masked CPU; disabling the one patch is smaller and matches what
Intel-masked macOS-on-KVM setups (OSX-KVM, dockur) run.

## Next blocker after "no linesize": "Haswell pre-C0 steppings are not supported"

With the cache_info patch disabled, the AMD test machine got past `HANDOFF TO
XNU` and hit a new kernel panic on serial:

```
Haswell pre-C0 steppings are not supported @%s:%d
```

Source: xnu `osfmk/i386/machine_check.c`, `mca_get_availability()`:
`if (model == CPUID_MODEL_HASWELL && stepping < 3) panic(...)`. QEMU's
`Haswell-noTSX` model reports family 6, model 0x3C, **stepping 1** — an early
engineering stepping XNU refuses. It was always there; "no linesize" simply
panicked earlier and hid it.

Fix: `mac-vm-launch.sh` adds `stepping=3` (C0, the first production stepping)
to the CPU flags whenever it picks `Haswell-noTSX` (AMD host + Ventura or
older). The Skylake path is untouched.

### Verified on the AMD test machine (stock Arch QEMU, no ISO rebuild)

A/B-tested straight on the CachyOS host with stock `qemu-system-x86_64`, the
launcher's CPU/SMP/SATA/vmware-svga profile, the Ventura 13.5 (22G120)
recovery and the verbose AMD OpenCore image:

| OpenCore AMD image | CPU | Result (serial) |
|---|---|---|
| old (cache_info patch on) | Haswell-noTSX | `no linesize` right after HANDOFF |
| new (cache_info patch off) | Haswell-noTSX | `Haswell pre-C0 steppings are not supported` |
| new | Haswell-noTSX,stepping=3 | boots Recovery to the installer's Language Chooser |

Stock QEMU reproducing the same `no linesize` also clears the custom
qemu-macos/Reims fork of that bug.

## Wi-Fi while the VM is running: `wifi` command + Ctrl+Alt+W

The macOS guest never sees Wi-Fi: it gets a wired `vmxnet3` NIC NATed through
the host, so macOS shows "Ethernet — connected" and its Wi-Fi menu stays empty
(passing the physical Wi-Fi chip through wouldn't help either — macOS has no
driver for it). Networks are therefore chosen on the **host**. Until now the
only place to do that was the first-run wizard's Wi-Fi picker
(`lib/wifi-setup.sh`), so moving the laptop to another network meant no way to
switch in a locked release build.

- New kiosk command **`wifi`**: `wifi` / `wifi status` (current SSID, signal,
  internet check), `wifi pick` (the same zenity picker as first run, or `nmtui
  connect` without a graphical session), `wifi list` (scan, text).
- **Ctrl+Alt+W** opens the picker from anywhere, in **both** build modes.
  `install-f2-keybind.sh` adds it after stripping every other keybind; it runs
  a fixed dialog (not a shell), so the release kiosk stays locked.
- openbox rules keep the picker's zenity dialogs and its "Advanced (nmtui)"
  xterm (title `LayerOSX*`) focused and in the `above` layer, so they open on
  top of the pinned fullscreen QEMU window instead of hidden behind it.
- `wifi-setup.sh --pick` is the new standalone entry point; running it with no
  argument keeps the first-run behaviour (`ensure_internet`).
- No relaunch needed after switching: the guest's NAT link survives the host
  changing its uplink.

Future idea (not implemented): a small macOS menu-bar app inside the guest
talking to a host-side helper (reachable from the guest at the QEMU user-net
gateway, `10.0.2.2`) could list and join the host's networks from inside
macOS, with a Wi-Fi-style menu. A *native* macOS Wi-Fi menu would need a
paravirtual 802.11 driver (IO80211Family), which is far beyond scope.

## Laptop integration: brightness keys, battery guard, lid close

macOS can't see the laptop's panel backlight, battery or lid, so the host
handles them (first step of the "host integration" TODO; the in-macOS UI is the
planned menu-bar app).

- **Brightness keys** — `install-f2-keybind.sh` adds openbox keybinds for
  `XF86MonBrightnessUp/Down` in **both** build modes, running `brightnessctl`
  (new package; the kiosk user is in `video`, which brightnessctl's udev rule
  lets write the backlight). Never below 5%, so the panel can't go black.
  openbox grabs the keys before the VM window, so macOS doesn't see them.
- **Battery guard** — `lib/battery-watch.sh`, started from the kiosk user's
  `.xinitrc` (exits at once without a `BAT*` supply). While discharging:
  zenity warning at 20% and 10% (re-armed when charging), at **5%** it sends
  the guest an ACPI power-button press (`system_powerdown`) so macOS can shut
  down cleanly (its Shut Down then powers the host off via the usual
  `qmp-watch.py` path), and at **3%** — or 3 minutes after the request with
  macOS still up — it does a QMP `quit` (QEMU stops and flushes its disk
  images) and drops `/tmp/layerosx-battery-poweroff`, which makes
  `mac-vm-launch.sh` power the host off instead of relaunching. Log:
  `~/battery-watch.log`. Caveat: how macOS reacts to the ACPI power button
  (shut down vs. a "Shut Down?" dialog) must be checked on hardware; the 3%
  / 3-minute fallback covers the dialog case.
- **Lid close** — `/etc/systemd/logind.conf.d/50-layerosx-lid.conf`: lid close
  suspends the host (on battery and on AC), and does nothing when docked to an
  external monitor. `/usr/lib/systemd/system-sleep/layerosx-vm` pauses the VM
  (QMP `stop`) before the host sleeps and resumes it (`cont`) after it wakes, so
  the guest never runs across the gap. On NVIDIA hosts `10-hardware-detect.sh`
  now sets `NVreg_PreserveVideoMemoryAllocations=1` and enables
  `nvidia-suspend/resume/hibernate.service`, so VRAM (the Reims/Vulkan side)
  survives resume.
- **Second QMP monitor** — both of the above talk to QEMU through
  `/tmp/macvm-ctl.sock`, a second `-qmp` socket, because a QMP unix socket
  serves one client and `qmp-watch.py` holds the first one all session.
  `lib/qmp-cmd.py` is a one-shot client with a fixed allow-list
  (`stop`, `cont`, `system_powerdown`, `quit`).

Verified off-hardware: `qmp-cmd.py` + the sleep hook against a real QEMU
(stop → paused, cont → running, quit → QEMU exits, unknown command refused,
no VM → exit 1), and `battery-watch.sh` against a fake sysfs battery
(19% → warning, 8% → warning, charging → re-armed, 5% → system_powerdown,
3% → quit + flag + poweroff). Brightness keys, the power-button behaviour in
macOS and suspend/resume need the real laptop — see CHECKLIST 5.4c.

## USB passthrough: `usb` command + Ctrl+Alt+U

Anything plugged into the laptop is claimed by the Linux host; the Mac only
sees the VM's virtual xHCI controller. Passthrough hands a physical device
over to macOS (pendrives, phones, webcams, MIDI/audio interfaces, ...).

- **How:** QEMU `usb-host` on the VM's `xhci.0` bus, matched by
  **vendor:product** (qdev id `usb-VVVV-PPPP`), hot-added/removed through the
  control QMP socket (`lib/qmp-cmd.py usb-attach|usb-detach|usb-list`, strict
  hex validation). Matching by vendor:product instead of bus/address means QEMU
  re-attaches the device to the guest by itself when it's re-plugged. The
  custom QEMU build already links libusb and ships `usb-host` (checked in the
  built binary), so no rebuild was needed.
- **UI:** `usb` (list + where each device is), `usb pick` / **Ctrl+Alt+U**
  (zenity picker, both build modes), `usb attach|detach|always|forget
  VVVV:PPPP`. "Always" devices are kept in `/var/lib/layerosx/usb-passthrough`
  and added at every launch by `mac-vm-launch.sh` (absent ones are simply
  waited for). Giving a device back also removes it from "always".
- **Never passed:** hubs, anything with a HID keyboard/mouse interface (the
  laptop's own N-KEY keyboard is USB -- passing it would lock the host out, and
  input already reaches the Mac), and storage with a partition mounted on the
  host. Built-in devices (sysfs `removable=fixed`: webcam, Bluetooth,
  fingerprint) are allowed but labelled "(built-in)".
- **Permissions:** QEMU runs as the kiosk user, so
  `/etc/udev/rules.d/70-layerosx-usb-passthrough.rules` tags USB devices
  `uaccess` (an ACL for the active local session only).
- **Ports:** `qemu-xhci` now has `p2=8,p3=8` (default 4+4) so passthrough
  devices fit next to the keyboard, tablet and optional usb-audio.

Verified off-hardware against a real QEMU + a fake sysfs tree: listing,
attach (idempotent), refusal of keyboard/hub, bad IDs rejected, always/forget
file handling, detach, `usb-list`, and QEMU starting with "always" devices
that aren't plugged in. Real devices in macOS need the laptop -- CHECKLIST 5.4d.

## Maintenance terminal: Ctrl+Alt+T, password-gated in release (`LAYEROSX_TERMINAL`)

A fully locked release build had no terminal at all, which made the VM
unmaintainable: no way to switch `gpu` (e.g. back from an alpha Reims that
black-screens), read logs or run `macdiag` without flashing a debug ISO.

- **Ctrl+Alt+T opens it in every build** (it used to be F2 — see below),
  handled by `lib/maint-terminal.sh`.
  Behaviour is a **build parameter**, independent of the build mode:

  | `LAYEROSX_TERMINAL` | Ctrl+Alt+T does | default for |
  |---|---|---|
  | `open` | opens the terminal directly | `debug` |
  | `password` | asks for the maintenance password, then opens it | `release` |
  | `off` | nothing (fully locked appliance) | — |

  Set it when building: `LAYEROSX_TERMINAL=off ./rebuild.sh release` (or
  `LAYEROSX_TERMINAL=... ./build.sh`). `build.sh` bakes it into
  `/etc/layerosx/terminal` (gitignored, like `/etc/layerosx/mode`); an unknown
  value falls back to `password` (fail closed).
- **The maintenance password is the kiosk user's (`mac`) password.** The
  installer now asks for it (twice) right after the "erase and install"
  confirmation and applies it with `chpasswd` after postinstall (never on a
  command line or in the log). Cancel keeps postinstall's default `mac` —
  fine for testing, not for a machine other people can reach. Change it
  later from the terminal with `passwd`.
- **Verification** uses PAM's `unix_chkpwd` helper (a user may verify their
  own password without root; it refuses a tty, so it's fed through a pipe).
  3 tries per press with a growing delay; attempts are logged (timestamp
  only) to `~/maint-auth.log`. One dialog/terminal at a time (flock).
- Once unlocked the terminal is a normal shell as `mac`, which has
  passwordless sudo — i.e. full host access, which is what maintenance needs.
  VT switching (Ctrl+Alt+F2 → autologin tty2) stays **off** in release, since
  that would bypass the password.
- **Why Ctrl+Alt+T and not F2:** openbox grabs a bound key before the VM
  window sees it, so F2 was lost to macOS (where it's brightness-up, and F2 in
  apps like Excel). Ctrl+Alt+T is the usual Linux "open terminal" chord,
  Control+Option+T isn't a macOS system shortcut (only VoiceOver, off by
  default, uses Control+Option as its prefix), and it matches Ctrl+Alt+W
  (Wi-Fi) / Ctrl+Alt+U (USB). The live ISO installer session (root) opens the
  terminal without a prompt. Older README sections that say "F2" describe the
  same terminal under its old key.

## Kiosk menu (Ctrl+Alt+W) + consistent "current setting"

Ctrl+Alt+W used to open only the Wi-Fi picker. It now opens a **kiosk menu**
(`lib/kiosk-menu.sh`, both build modes, no password) so a locked release build
can be operated without a terminal:

- **Status line**: Wi-Fi network (or wired / not connected), battery % and
  state, graphics, boot log, audio, and whether the Mac is running.
- **Wi-Fi…** (the picker, which now also shows "Connected to: <SSID>" and marks
  that network — it used to give no hint of the current connection),
  **USB devices…**, **Graphics…** (Reims / VMware / std, current one
  pre-selected), **Boot log** and **Audio** switches — each then offers to
  restart the Mac to apply, or applies on the next start.
- **Restart the Mac** — relaunches only the VM (a hard stop for macOS). The
  rescue for a stuck or black screen; when macOS works, Apple menu > Restart is
  the clean way (and restarts the computer too).
- **Restart / Shut down computer** — QMP `quit` stops QEMU with its disk
  images flushed, and `/tmp/layerosx-host-action` tells `mac-vm-launch.sh` to
  reboot/power off instead of relaunching (15 s fallback if the launcher isn't
  there).
- **Save diagnostics to a USB drive** (`macdiag usb`) and **Maintenance
  terminal…** (hidden when `LAYEROSX_TERMINAL=off`; same password policy as
  Ctrl+Alt+T).
- Everything that restarts something asks first; one menu at a time (flock).
- **Navigation:** the menu comes back after every action (Close exits it);
  sub-screens (Wi-Fi, USB, Graphics, confirmations) have a **Back** button;
  every list uses the same size, so moving between screens doesn't jump.
  Only restarting the Mac/computer or opening the terminal leaves the menu.
  (zenity opens one window per screen and can't keep a single window — a
  native single-window GTK menu is the natural next step, and the same UI the
  future in-macOS app would mirror.)

Also fixed while wiring the menu: `gpu`, `verbose`, `audio` and `macstatus`
showed hard-coded fallbacks (vmware / on / off) when no choice was saved, but a
release build actually launches with **reims / off / on**. They now share
`lib/settings.sh` (`effective_setting`, `setting_origin`), which applies the
same per-mode defaults as `mac-vm-launch.sh` and says whether a value is
"saved" or the "build default".

**Preview without building an ISO:** `tools/preview-kiosk-menu.sh` runs the
menu from the repo on any Linux desktop (needs `zenity`). It sets
`LAYEROSX_LIB` to the repo copy and `LAYEROSX_DRY_RUN=1`, so every changing
action only shows what it would run; the Wi-Fi/USB pickers are real.

Verified off-hardware with stubbed zenity/nmcli/sudo: menu status text,
Graphics → vmware (file written, restart offered), Boot log toggle, Restart
the Mac (relaunch), Restart computer (host-action file written), and the
effective-setting defaults for a release build.

## LayerOSX Settings (Ctrl+Alt+W): a System-Settings-style panel

The zenity kiosk menu worked but was a chain of separate dialogs. Ctrl+Alt+W
now opens **LayerOSX Settings**, a single GTK4/libadwaita window modelled on a
simplified macOS System Settings: a sidebar with coloured icon badges, a
content pane of rounded cards, macOS-style "traffic light" window controls
(red = close, yellow = hide — the kiosk has no taskbar to restore a minimized
window, so it closes and Ctrl+Alt+W brings it back — green = disabled), light
theme by default with a **Light / Dark** switch in General › Appearance
(applied instantly, saved in `/var/lib/layerosx/panel-theme`;
`LAYEROSX_PANEL_THEME=light|dark` overrides it for previews). The window has a
**fixed size, like macOS System Settings**: the layout is designed for that
width and maximizing only added empty space, so the green light is greyed out
and does nothing.

| Section | What's there |
|---|---|
| Wi-Fi | Wi-Fi on/off (confirms before cutting the Mac off), connection status, current network, other networks with lock/signal icons and **Connect**, **Other…** for hidden networks |
| Battery | Level + state, and what the low-battery guard does (20/10% warnings, safe shutdown at 5%, last resort at 3%) |
| Displays | Brightness slider; Graphics adapter (Reims / VMware / Standard VGA) as radio rows with explanations |
| Sound | "Sound from the Mac" switch |
| USB Devices | Every device with a switch (on the Mac / on the computer) and a star (always give it to the Mac); keyboards, hubs and mounted drives are disabled with the reason |
| Mac | Running/stopped, "Show startup log" switch, **Restart Mac…** (the black-screen rescue) |
| General | Restart / Shut Down the computer, **Save diagnostics…** (asks which drive), Terminal |
| Terminal | Open the maintenance terminal (password per `LAYEROSX_TERMINAL`), useful commands; hidden when the build has no terminal |
| About | "About This Mac"-style: LayerOSX version/build date/mode; **This Computer** (model, processor + threads, memory, graphics, storage, Linux kernel — read live from DMI, /proc, lspci, lsblk); **The Mac** (macOS version + build, the CPU model/cores, RAM and graphics the VM was given); **Credits** (creator) and **Built With** (the open-source projects LayerOSX builds on); shortcuts |

A banner ("Restart the Mac to apply your changes" + Restart Mac) appears after
changing graphics, sound or the startup log while the Mac runs. Status refreshes
every 5 s; scans and restarts run in worker threads; dialogs are in-window
(`Adw.AlertDialog`).

**Architecture — the bridge to macOS starts here.** Everything the panel shows
or does goes through `opt/layerosx/panel/layerosx_backend.py`: one `Backend`
class with a fixed allow-list (settings, VM restart, host restart/shutdown,
Wi-Fi status/scan/connect/radio, USB list/give/always, battery, brightness,
diagnostics, terminal), reusing the existing pieces (gpu/verbose/audio/
relaunch/macdiag, `lib/qmp-cmd.py`, nmcli, brightnessctl, sysfs). The panel is
only a front-end. The planned in-macOS menu-bar app will be a second front-end
calling the same `Backend` through a small host helper, so no host logic gets
duplicated. `layerosx_backend.py status|wifi|usb` prints JSON (debugging, and
the future helper's shape).

- **Launch:** `kiosk/lib/panel.sh` (bound to Ctrl+Alt+W) checks that GTK4 +
  libadwaita import, runs the panel, and falls back to the zenity
  `kiosk-menu.sh` if GTK is missing or the panel crashes at start-up — the
  machine is never left without a way to switch graphics or restart. Log:
  `~/panel.log`. Single instance via a lock file (the kiosk X session has no
  D-Bus session bus, so the app is `NON_UNIQUE`). The window title
  "LayerOSX Settings" matches the openbox `LayerOSX*` rule, so it opens above
  the fullscreen VM.
- **Packages:** `python-gobject gtk4 libadwaita adwaita-icon-theme librsvg`
  added to `packages.x86_64`.
- **Preview on any desktop, no ISO build:** `tools/preview-panel.sh` (dry run:
  changing actions show "Preview — would run: …"; status and Wi-Fi are real).
  `LAYEROSX_PANEL_PAGE=<section>` opens on a section.
- **Tests:** `tools/test-panel.sh` — 14 backend unit tests against a fake
  machine (settings + per-mode defaults, validation, dry-run changes nothing,
  nmcli parsing incl. escaped `:`, Wi-Fi radio, USB list/blocking/give/always,
  battery, host actions) and, with a display (`xvfb-run`), a UI smoke test
  that opens every section and drives the widgets (graphics, sound, startup
  log, USB, Wi-Fi list, sidebar status). All green; screenshots were checked
  under Xvfb.

### Save diagnostics… asks which drive

General › Save diagnostics… lists the drives the logs can go to and saves a
fresh bundle into a `LayerOSX-logs/` folder on the chosen one (then "you can
unplug the drive").

- **Which drives:** `Backend.log_targets()` reads `lsblk -J` and offers
  partitions with a writable filesystem (vfat, exfat, ntfs, ext2/3/4, btrfs,
  xfs), USB drives first, internal ones labelled as such. Never offered: the
  running system's `/`, `/boot`, `/boot/efi`, swap, the live ISO's own mounts,
  Ventoy's `VTOYEFI`, and anything encrypted/unknown (BitLocker, LUKS).
  `layerosx_backend.py drives` prints the list as JSON.
- **How:** `macdiag bundle` builds the bundle as the kiosk user; then
  `kiosk/lib/save-logs-to.sh <bundle> <partition>` runs via sudo: it mounts
  the partition if needed (and unmounts it afterwards), copies, syncs and
  prints the final path. Because it runs as root it's narrow on purpose: the
  bundle must be a `mac-vm-diag-*` folder in a home directory, the target a
  partition block device, never the system's own root/boot; and the backend
  only passes a device that is in `log_targets()`.
- A Windows NTFS drive left hibernated by Fast Startup refuses to mount
  read-write — the error says so.
- Verified: 17 backend unit tests (targets exclude system/VTOYEFI/BitLocker,
  USB first, sizes; save refuses unlisted devices; dry run), `save-logs-to.sh`
  against a real loop-device partition (mount → copy → unmount; already
  mounted → copy and leave mounted; refuses non-bundles, whole disks and
  non-devices), and the UI smoke test opening the picker.

Also fixed: the traffic-light dots turned grey after a click when a user GTK
theme was installed (a macOS-look theme in `~/.config/gtk-4.0` overrides
button styles at USER priority). The panel's CSS now loads above USER priority
and pins every button state; the dots also no longer take keyboard focus.
Checked by rendering with a deliberately hostile user theme.

### About section: real machine details + credits

`Backend.about()` (`layerosx_backend.py about` prints it as JSON) reads, live:
the machine model from DMI (cleaned up: "ASUSTeK COMPUTER INC." +
"FA507NV_FA507NV" becomes "ASUS TUF Gaming A15 FA507NV"), the CPU model and
thread count from `/proc/cpuinfo`, memory from `/proc/meminfo`, GPUs from
`lspci -mm` (shown as "NVIDIA GeForce RTX 4060 …", "AMD Radeon 680M"), the
system disk model/size via `findmnt`/`lsblk`, and the kernel. For the Mac: the
macOS name + version + build (`/var/lib/layerosx/macos-version` and
`downloaded-version`) and what the VM was given — `mac-vm-launch.sh` now
writes `/tmp/layerosx-vm-profile` (cpu_model, cores, ram_mb, gfx, macos) on
every launch. The LayerOSX version comes from `/etc/layerosx/version`, which
`build.sh` now bakes (`git describe --always --dirty`, build date, mode;
gitignored).

Credits live at the top of `layerosx_backend.py` (`CREATOR`, `CREATOR_LINK`,
`THANKS`) so they're edited in one place. Tests: 20 backend tests (About with a
fake ASUS/Ryzen/RTX machine, before-install state, name clean-up rules).

### Brightness is remembered across reboots

`kiosk/lib/brightness.sh` is now the one place that changes the panel
backlight: the brightness keys (`up`/`down`) and LayerOSX Settings › Displays
(`set <n>`, via `Backend.set_brightness`) go through it, and every change
saves the resulting percentage to `/var/lib/layerosx/brightness`. The kiosk
`.xinitrc` runs `brightness.sh restore` at session start (after a 2 s wait for
the GPU driver) to put the last value back. systemd-backlight does something
similar at boot, but on hybrid AMD+NVIDIA laptops it often misses (the
backlight device changes name between boots, or the driver resets it later);
this runs inside the session, after the drivers are up. Never below 5%.
Tests: 2 more (set/down save, restore after a firmware reset, 5% floor, bad
input) against a fake `brightnessctl` — 23 in total.
