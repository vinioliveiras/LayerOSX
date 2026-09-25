# LayerOSX

An installer ISO for a deliberately empty Arch Linux whose only job is to boot
straight into an accelerated macOS VM: QEMU from
[qemus/qemu-macos](https://github.com/qemus/qemu-macos) with the
[Reims-vGPU](https://reims-vgpu.com/) paravirtual GPU. Turn the laptop on, see
macOS — no Linux desktop, no manual steps after install other than choosing
where macOS comes from, once.

- **Any x86-64 laptop/PC:** Intel or AMD (Ryzen) CPU; NVIDIA, AMD or Intel
  GPU. Reims accelerates over Vulkan on the host, so it isn't tied to a
  vendor. The installer detects the CPU (KVM module) and GPU (driver config)
  and configures only that.
- **Nothing from Apple is in the ISO.** macOS is downloaded from Apple's own
  servers (or taken from a disk/installer you already have), onto your disk,
  when you run the first-run wizard. Running macOS on non-Apple hardware is
  still against Apple's EULA; this project only automates the Linux side.

> **History:** how every piece got here — bugs, root causes, decisions — is in
> [DEVLOG.md](DEVLOG.md). This README describes the current state.

## Status

Boots and runs macOS (Ventura tested) on real hardware — an ASUS TUF A15
(Ryzen 7 7735HS, RTX 4060 + Radeon 680M) — with Reims acceleration. Still
alpha: Reims itself is alpha, and several
recent features are marked "not yet on hardware" in
[docs/CHECKLIST.md](docs/CHECKLIST.md), the step-by-step test plan.

## Install

1. Build the ISO (see [Build](#build)) and copy it to a
   [Ventoy](https://www.ventoy.net/) USB drive (or `dd` it).
2. Boot it. The installer opens **GParted**: make (or keep) a partition for
   LayerOSX and reuse the existing EFI partition — don't format the EFI one.
   The Mac's disk lives on the LayerOSX partition, so give it room
   (100 GB+).
3. Pick the root and EFI partitions and a password for the Linux user `mac`
   (text console / sudo; Cancel keeps `mac`). Everything else — copy, fstab,
   locale `en_US`, keyboard `us`, GRUB (with other OSes via os-prober), the
   kiosk — is automatic.
4. Reboot into LayerOSX.

**Reinstalling without losing the Mac:** don't format the LayerOSX partition
in GParted. The installer finds the existing Mac and asks **Keep my Mac /
Erase it**; Keep preserves `/var/lib/layerosx` (macOS disk, NVRAM, settings)
and replaces everything else. A backup of `macos.qcow2` + `OVMF_VARS.fd` to
another drive first never hurts.

## First boot

The first-run wizard asks where macOS comes from:

1. **Download from Apple** (default) — pick a version (High Sierra → Tahoe,
   Ventura pre-selected); Wi-Fi can be set up right there.
2. **I already have a macOS VM/disk** — qcow2, raw, VMware (vmdk), VirtualBox
   (vdi), Hyper-V (vhd/vhdx), from any drive.
3. **I already have an installer .dmg** — experimental.

The Mac then starts in fullscreen and **you** take over: Disk Utility, install
macOS, Setup Assistant. The Mac's disk is sized to the partition's free space
(minus a margin) and grown automatically later if the partition has room; grow
APFS inside macOS with `sudo diskutil apfs resizeContainer <container> 0`.

## Everyday use

| | |
|---|---|
| **Ctrl+Alt+W** | LayerOSX Settings (below). Falls back to a zenity menu if GTK can't start. |
| **Ctrl+Alt+T** | Maintenance terminal (open, unless a Maintenance password is set). One at a time: pressing it again brings the open one back. |
| **Ctrl+Alt+U** | USB picker: give a device to the Mac or take it back. |
| **Ctrl+Alt+M** | With monitoring mode on: mark this moment in the timeline. |
| Brightness / volume keys | Handled by Linux, work while the Mac has focus. |
| Apple menu › **Restart** | Restarts the Mac only (the computer stays on). |
| Apple menu › **Shut Down** | Shuts the computer down. |
| Settings › General › Restart | Restarts the computer. |
| Lid close | Laptop suspends, the Mac is paused and resumed around it. |
| Low battery | Warnings at 20% / 10%, clean macOS shutdown at 5%, forced stop at 3%. |

The Mac always has internet through the host (a wired NAT link inside
macOS); Wi-Fi is chosen in Settings.

## LayerOSX Settings

A GTK4/libadwaita window styled after macOS System Settings (light/dark in
General). "Applies when the Mac restarts" changes show a **Restart the Mac**
banner.

| Section | What's there |
|---|---|
| Wi-Fi | On/off, current network, nearby networks (refreshed every 10 s while the page is open), hidden networks. |
| Battery | Level, state, what the low-battery guard does; **Power mode** — Automatic (Performance on the charger, Balanced on battery), Performance, Balanced, Power Saver. |
| Displays | Brightness; **Screens** — which monitor shows the Mac (Automatic: an external monitor when one is plugged in, else the built-in screen — plugging/unplugging moves the Mac by itself), other screens off or mirrored, resolution and refresh rate; **Graphics** — Reims / VMware / Standard VGA; **Graphics card** — which GPU Reims draws with; **Performance** — the Mac's frame rate (Reims) and **Window effects** (animations/rounded corners, live on/off; windows opened while it's off stay square until reopened). |
| Sound | Sound from the Mac (on by default); **Volume** slider + mute (live); **Output** — speakers/headphones (automatic) or an HDMI screen. |
| USB Devices | **Give new devices to the Mac** (on by default); every device with a switch (Mac / computer) and a star (always to the Mac). Built-in devices, keyboards, mice, hubs and mounted drives stay on Linux. |
| Mac | State, **Model** (MacBook Pro 13" 2020 by default; MacBook Pro 16", iMac, iMac Pro, Mac Pro), **Resources** — cores, "Keep 2 threads for Linux", memory (automatic or fixed), **Restart the Mac** (the black-screen rescue). |
| General | Appearance, Restart / Shut Down the computer. |
| Maintenance | **Logs** — Show startup log, Detailed logs, **Monitoring mode** (records everything, below), Save diagnostics to a drive; **Terminal**; **Advanced** — text consoles (Ctrl+Alt+F1…F6, next boot); **Password** — an optional Maintenance password that locks this whole section, the terminal and tty2. |
| About | This computer (model, CPU, RAM, GPUs, disk), the Mac (macOS version, what the VM got), credits. |

Defaults on a new install: Reims graphics, Apple-logo boot, sound on,
power mode Automatic,
automatic USB, all cores but 2 (max 8, power of two), RAM minus 12%
(min 4 GB) — on Reims capped to what its GPU can map (below) — no
Maintenance password.

## Terminal commands

From the Ctrl+Alt+T terminal (user `mac`). Settings are plain files in
`/var/lib/layerosx/`, so everything is scriptable. `commands` lists them all.

| Command | What it does |
|---|---|
| `relaunch` | Restart just the Mac (applies graphics/log/sound changes). |
| `gpu reims\|vmware\|std` | Graphics for the next launch. |
| `verbose on\|off`, `audio on\|off` | Startup log / sound. |
| `usb [list\|attach\|detach\|always\|forget] [VVVV:PPPP]` | USB passthrough. |
| `wifi [status\|pick\|list]` | Host Wi-Fi (`pick` opens Settings › Wi-Fi). |
| `maclog [tail\|oc\|err\|launch\|qemu\|all]` | Boot / launcher logs. |
| `macfps [--once]` | The Mac's frame rate on Reims, live. |
| `macmonitor [on\|off\|status\|mark\|summary]` | Monitoring mode (below). |
| `echo N > /var/lib/layerosx/audio-buffer-ms` | Sound buffer in ms (default 128; then `relaunch`). |
| `macdiag [usb]` | Full diagnostics bundle (optionally onto a USB drive). |
| `macstatus` | Current settings and VM disk state. |
| `erasevm [-y]` | Delete the Mac (disk, recovery, NVRAM) so the first-run wizard runs again. |

## Troubleshooting

- **Black screen / stuck Mac:** Settings › Mac › Restart the Mac, or
  `relaunch`. If Reims shows nothing, switch Displays › Graphics to VMware
  (works everywhere, no acceleration) and collect logs.
- **Logs:** `~/mac-vm.log` (launcher: exact QEMU command line, why QEMU
  ended), `~/mac-vm-serial.log` (macOS kernel, with Detailed logs),
  `~/mac-vm-qemu.log` (QEMU / Reims messages), `/tmp/reims-vgpu-fail.log`
  (Reims translation refusals), `~/usb-auto.log`. `macdiag` bundles them all
  with host info; Maintenance › Save diagnostics copies the bundle to a drive.
  A bundle is also saved to any USB drive after every Mac session.
- **Something fails the same way 5 times in a row:** the launcher stops and
  leaves the screen still, so the terminal (Ctrl+Alt+T) stays usable.

## Monitoring mode

For chasing slowdowns, drops and crashes with data instead of guesses.
Settings › Maintenance › Monitoring mode (or `macmonitor on`) records, every
second, into `~/monitoring/<YYYYmmdd-HHMMSS>/`:

| File | What |
|---|---|
| `summary.txt` | written at stop: avg / p95 / max of everything below, network outages, busiest QEMU threads, marked moments |
| `events.log` | timeline: the Mac (re)started, crashes, network down/up, memory/I/O pressure, CPU ≥ 90 °C, **Ctrl+Alt+M** marks |
| `system.csv` / `cpu.csv` | load, memory, huge pages, dirty/writeback, PSI pressure (cpu/memory/io), CPU temperature and clock; per-core busy % |
| `qemu.csv` / `threads.csv` | the Mac's QEMU: CPU %, RSS; each thread above 1% (vCPUs, Reims, main loop) |
| `gpu.csv` | NVIDIA (nvidia-smi) and AMD (sysfs): busy %, VRAM/GTT, clocks, temperature, power (every 2 s) |
| `disk.csv` / `net.csv` | per disk MB/s and busy %; per interface KB/s, errors, drops, Wi-Fi signal |
| `netcheck.csv` | every 5 s: gateway ping, DNS lookup, TCP connect — tells a host Wi-Fi drop from a problem inside the Mac's NAT |
| `reims.csv` | Reims' frames shown per second and refusals |
| `logs/` | kernel, system warnings, NetworkManager/Wi-Fi, launcher, macOS serial, Reims (followed live) |

It stays on across reboots until turned off; the newest 5 sessions are
kept, a session stops sampling at 1 GB, and Save diagnostics / `macdiag`
include the newest session. `kiosk/lib/monitor.py` is the collector.

## How it works

```
ISO (live, from USB) ── install-wizard.sh: GParted → pick partitions → rsync
                        the live system → postinstall/ (chroot: user "mac",
                        hardware detection, GRUB, kiosk autologin)

Installed system: tty1 autologin → startx → .xinitrc
  openbox (locked down: no desktop, no stray shortcuts) + picom (animations)
  + displays.py watch + usb-auto-watch + brightness restore + battery guard
  └─ mac-vm-launch.sh (loop)
       no Mac yet → macos-source-wizard.sh
       pick resources / OpenCore image / model / graphics / sound / USB
       QEMU (KVM, OpenCore, Reims host window or SDL) ── QMP ── qmp-watch.py
         guest-shutdown → power off · guest-reset → start the Mac again
         anything else → relaunch (5 fast failures → stop and wait)
```

- **Panel:** `opt/layerosx/panel/layerosx_backend.py` holds all the logic (one
  `Backend` class with a fixed allow-list of actions; also a JSON CLI used by
  the shell scripts); `layerosx_panel.py` is only the front-end. A planned
  in-macOS menu-bar app would be a second front-end on the same backend.
- **OpenCore:** images per CPU family (`OpenCore`, AMD 2/4/8-core with
  AMD_Vanilla patches), each also `-verbose` and `-diag`; the Mac model is
  written into a cached copy (`lib/oc-model.sh`, qemu-img + mtools).
- **Reims:** runs in its own Vulkan window (`REIMS_VGPU_WINDOW=1`, QEMU
  `-display none`). Our QEMU build keeps Reims' `host-window` feature and
  applies `archiso/patches/reims/*.patch` (0001: release held keys on focus
  loss; 0002: keep Caps Lock in sync with the host's LED). `build.sh`
  rebuilds QEMU whenever those patches or the QEMU build options change
  (`qemu-inputs-hash.sh`, stamp `bin/.qemu-inputs`). Shader translation needs `llvm-dis`
  and `spirv-val` at runtime (in the ISO). The bundled Debian libraries are
  linked in only where the host lacks them (`lib/qemu-libdir.sh`), so the
  host's own Vulkan drivers win.
- **CPU clock:** macOS can't manage it (its cores are host threads), so the
  host does: `lib/power-mode.sh` sets the cpufreq governor / EPP hint and the
  laptop's ACPI platform profile (fan/power limits) per Settings › Battery ›
  Power mode — at boot (`layerosx-power-mode.service`), on charger
  plug/unplug (udev) and from the panel (sudo).
- **Guest RAM vs Reims:** Reims maps the Mac's RAM into the GPU (zero-copy)
  only if all of it fits the GPU's largest importable heap; otherwise it
  copies every guest buffer, and everything lags. So on Reims the automatic
  RAM is capped: the budget Reims reported for this GPU choice
  (`reims-import-budget`, learned after a run that didn't fit) minus 1 GB,
  else 70% of the host. A fixed RAM above it gets a warning in Settings.
- **Disk and network:** the Mac's disk runs with `cache=none,aio=io_uring`
  (no host page cache — big downloads used to fill it and stall the host),
  a 32 MB qcow2 L2 cache and TRIM (`discard=unmap`). Network: QEMU's
  built-in NAT (slirp); `passt` (NAT in its own process) is opt-in — it made
  the internet drop on the test laptop. Wi-Fi power saving is off
  (NetworkManager). Overrides: `disk-cache` (none|writeback), `net`
  (user|passt) state files.
- **Crash guard:** when QEMU crashes (Reims) or macOS panics, the Mac is
  started again, a diagnostics bundle goes to `~/crash-reports` (newest 5)
  and a notice says what happened.
- **Guest RAM pages:** Reims needs the RAM in a shared memfd, which is
  shmem — 4 KB pages unless shmem transparent huge pages are allowed.
  `etc/tmpfiles.d/layerosx-hugepages.conf` sets `shmem_enabled=advise`, so
  QEMU's `MADV_HUGEPAGE` gives the Mac 2 MB pages (and only the Mac).
- **State:** `/var/lib/layerosx/` — `macos.qcow2`, `OVMF_VARS.fd`,
  `macos-recovery.qcow2`, and one small file per setting (`gfx`, `verbose`,
  `audio`, `audio-output`, `audio-volume`, `power-mode`, `compositor`, `usb-auto`, `usb-passthrough`,
  `usb-keep-on-linux`, `cpu-cores`, `ram-mb`, `mac-model`, `reims-gpu`,
  `display-*`, `diag-logs`, `vt-switch`, `maint-password`, …). Absent file =
  default.

## Build

Needs an Arch-based Linux with `archiso` and Docker (for the one-time QEMU
build). On Arch/CachyOS:

```sh
git clone https://github.com/vinioliveiras/LayerOSX.git
cd LayerOSX
./rebuild.sh
```

`rebuild.sh` runs `setup-build-host.sh` (installs `archiso docker
docker-buildx qemu-img mtools git python curl`, starts Docker, checks for
~30 GB free) and then `archiso/build.sh`. The first build compiles QEMU +
Reims in Docker (**30–60+ min**); later builds reuse it. The ISO lands in
`archiso/out/`.

Build options (environment variables):

| Variable | Default | |
|---|---|---|
| `LAYEROSX_TERMINAL` | `open` | `off` removes the maintenance terminal entirely. |
| `LAYEROSX_MAC_MODEL` | `MacBookPro16,2` | Default Mac model baked into OpenCore. |
| `LAYEROSX_BOOT_COLOR` | `1C1C1C` | Colour of the first (firmware) screen. |
| `LAYEROSX_REIMS_HOST_WINDOW` | `1` | `0` builds Reims without its own window (SDL only). |

On Windows, the same works inside WSL2 (`wsl --install -d ArchLinux`), cloned
into WSL's own filesystem (not `/mnt/c`), since the ISO build needs loop
devices.

**Gotchas:** scripts must keep their exec bit (`git ls-files -s | grep -E
'\.(sh|py)$' | grep ^100644` should print nothing); Docker must use BuildKit
(`prepare-qemu-macos.sh` forces it).

## Testing

- [docs/CHECKLIST.md](docs/CHECKLIST.md) — what to check on hardware, per
  feature.
- `tools/run-mac-here.sh` — run an installed LayerOSX's Mac on the build
  machine itself (read-only snapshot of the partition; `--gfx`, `--gpu`,
  `--model`, `--cores`, `--ram`, …). Logs in `test-runs/`.
- `tools/preview-panel.sh` — the Settings window on any desktop, dry run.
- `tools/test-panel.sh` / `python3 -m unittest` in `tests/panel` — backend
  tests against a fake machine (sysfs, `/proc/asound`, nmcli, amixer, QMP).

## Repository layout

- `archiso/` — the archiso profile. `build.sh`, `prepare-qemu-macos.sh`
  (QEMU + Reims build), `prepare-opencore.sh` and `patch-opencore-*.sh`
  (OpenCore images), `patches/reims/` (our Reims patches), `packages.x86_64`.
- `archiso/airootfs/opt/layerosx/kiosk/` — launcher, installer, first-run
  wizard, QMP watcher, `lib/` helpers.
- `archiso/airootfs/opt/layerosx/panel/` — LayerOSX Settings (backend + UI).
- `archiso/airootfs/root/postinstall/` — runs once, chrooted, on the
  installed system.
- `archiso/airootfs/usr/local/bin/` — the terminal commands.
- `tests/`, `tools/`, `docs/CHECKLIST.md`, `DEVLOG.md`.

## TODO

**Priority**

- **YouTube video lags, and the sound with it** (Safari, Reims). It plays,
  but the whole Mac stalls — software decoding (the Mac has no hardware video
  decoder) on top of Reims uploading every video frame. First fix in: 2 MB
  pages for the guest RAM (shmem THP, below). Next: compare 720p vs 1080p,
  Chrome vs Safari, Detailed logs off, VMware vs Reims; then Reims' video
  surface path (2-plane `420f` IOSurfaces).
- **Audio stutters** — worse while macOS draws a lot (better with Spotify /
  YouTube minimised). First fix in: usb-audio buffer 32 → 128 ms and a 5 ms
  audio timer (`audio-buffer-ms` / `audio-timer-us` state files to
  experiment). If it still stutters: move the audio off QEMU's busy main
  loop, or feed PipeWire instead of raw ALSA.
- **Microphone** — QEMU's usb-audio is output-only. Works today: a USB
  microphone, headset or webcam goes to the Mac with automatic USB and
  macOS drives it natively. The laptop's built-in mic (on the host's audio
  chip) needs an emulated input device: `intel-hda` + `hda-duplex` with a
  macOS HDA driver (VoodooHDA/AppleALC) in OpenCore — to evaluate.

- **3D in the browser (WebGL games like venge.io / krunker.io) and
  Photomator RAW editing** — broken drawing, one crash. Reims translation
  gaps, measured (DEVLOG, "First monitoring session"): texture descriptors
  with 32769 mip levels (`draw_prepare_texture_resolve_missing`, draws
  skipped) and compute writes to storage texture format 0x6e
  (`linear_tex_fmt_storage`). Report upstream with those lines.
- **Freezes of several seconds** — macOS stops submitting frames while the
  host is idle (guest-side). Retest with Detailed logs off and on the AMD
  iGPU; check whether they follow Reims refusals.
- **Huge pages not applied** (`ShmemHugePages` 0 despite `[advise]`) —
  next monitoring run records THP counters to find out why.

**Next**

- **Bluetooth audio through Linux** — bluez + PipeWire in the kiosk, QEMU's
  audio on the `pipewire` backend when a Bluetooth sink is chosen, a Bluetooth
  section in Settings (scan, pair, connect, battery) and the volume slider on
  the PipeWire sink. Watch A2DP latency, reconnect after reboot, the mic
  (HFP) later. Today: a Broadcom (BCM20702) USB dongle goes to the Mac with
  automatic USB and pairs in macOS.
- **Reims frame rate** — first measurement (DEVLOG, "Frame rate: first
  numbers"): ~55 fps while animating, 0 on a still screen (normal), ~30 in
  the first minute. Reims' host side isn't the limit (drain ~15% busy, the
  window never waits on a present, FIFO present on 144/180 Hz screens). Next:
  retest with Detailed logs off, Window effects on vs off, Performance power
  mode, NVIDIA vs AMD; then look at the guest side (vCPUs, VBL pacing).
- **Reboot from the terminal hangs** — the launcher should exit when the
  system is stopping and stop QEMU cleanly through QMP.
- **Installer and first-run wizard in GTK** — one window like Settings (steps,
  guided disk page with GParted as "Advanced…", real progress bars), zenity as
  fallback.
- **Update without the USB** — today an update is "reinstall, Keep my Mac";
  later a downloadable, signed update (A/B root or pacman-based), with kernel
  + NVIDIA moving together.
- **Easy dependency updates** — one command to bump qemu-macos/Reims, the
  OpenCore pin and AMD_Vanilla patches; forks or a release archive so a
  deleted upstream repo can't break the build.
- **Per-install SMBIOS identity** — unique serial/MLB/UUID per install
  (iMessage/App Store).
- **Host disks in macOS** — an SMB share over the NAT link first; read-only
  disk passthrough later.
- **LayerOSX menu-bar app in macOS** — Wi-Fi, battery, brightness, Bluetooth,
  USB from inside the Mac, through a small host helper using the same
  `Backend` allow-list.
- **Smaller items** — battery level inside macOS; macOS Sleep → host suspend;
  qcow2 snapshots before macOS updates; OpenCore picker default/timeout;
  pre-boot cursor duplication; tty2 refresh rate.
