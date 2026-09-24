# kiosk/ (lives at `/opt/layerosx/kiosk` on the installed system)

- **`mac-vm-launch.sh`** — runs instead of a desktop, autologin of the
  `mac` user on tty1 (see `postinstall/40-kiosk-autologin.sh`). Makes
  sure a VM exists (otherwise calls the wizard), launches QEMU in
  fullscreen, and waits for a QMP `SHUTDOWN` event to find out whether
  macOS asked to Shut Down (`reason: guest-shutdown` → a real
  `systemctl poweroff`) or Restart (`reason: guest-reset`/`guest-panic` →
  the Mac starts again; the computer stays on — restarting the computer
  is Settings › General). If QEMU ends for any other reason it just
  relaunches the VM; after 5 fast failures in a row it stops and leaves
  the screen still so the terminal stays usable.
- **`qmp-watch.py`** — speaks raw QMP (JSON lines) over a Unix socket,
  returns `host-poweroff` / `host-reboot` / `vm-only` on stdout.
- **`macos-source-wizard.sh`** — runs once, on first run (while no VM
  disk exists yet). Asks, via a `zenity` window, whether you want to:
  download the recovery image directly from Apple, point to a VM/disk
  you already have, or point to an installer `.dmg` you already have —
  so you can always use whatever's newest that you downloaded from
  Apple's site / the App Store on another Mac.
- **`lib/fetch-recovery.sh`** — uses OSX-KVM's `fetch-macOS.py` to
  download the recovery image directly from Apple's servers, onto your
  own disk.
- **`lib/extract-dmg-installer.sh`** — **experimental**. Tries to
  extract a bootable installer from a `.dmg` you already have. The
  hard part is the filesystem inside it (HFS+ usually works, APFS
  support on Linux is still limited) — see `docs/CHECKLIST.md`.

## On licensing

Nothing here contains any Apple files. Whatever gets downloaded or
used (recovery image, `.dmg`) always comes directly from Apple or from
your own file, onto your own disk, at the moment YOU run the wizard —
never bundled inside the ISO this project generates. This is the same
line OSX-KVM and the wider macOS-VM community has always followed:
automate the download/install, never redistribute anything from Apple.
It's still against Apple's EULA to run macOS outside Apple hardware —
this doesn't change that reality, it just automates the technical
steps on the Linux side.
