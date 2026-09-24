#!/usr/bin/env python3
"""
LayerOSX host backend: the ONE place that knows how to read the machine's
state and perform the kiosk's host actions. The control panel (Ctrl+Alt+W,
layerosx_panel.py) is a front-end for it, and the planned in-macOS menu-bar
app will be a second front-end talking to the same functions through a small
host helper -- so every action here is part of a fixed allow-list, never an
arbitrary command.

It reuses the existing kiosk pieces rather than re-implementing them:
gpu/verbose/audio/relaunch/macdiag (usr/local/bin), lib/qmp-cmd.py (VM control
over /tmp/macvm-ctl.sock), NetworkManager (nmcli), brightnessctl and sysfs.

Every path is overridable through LAYEROSX_* environment variables (tests and
tools/preview-panel.sh use that), and LAYEROSX_DRY_RUN=1 turns every action
that would change something into a no-op that is only recorded in
Backend.dry_log -- except Wi-Fi scanning/connecting, which is harmless and
real on purpose (the preview's Wi-Fi page works on the developer's machine).

CLI (handy for debugging and for the future helper):
    layerosx_backend.py status          JSON snapshot of the machine
    layerosx_backend.py wifi            JSON list of nearby networks
    layerosx_backend.py usb             JSON list of USB devices
    layerosx_backend.py drives          JSON list of drives diagnostics can be saved to
    layerosx_backend.py about           JSON: this machine, the Mac, versions, credits
"""
import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from typing import List, Optional, Tuple

HEX4 = re.compile(r"^[0-9a-f]{4}$")


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


@dataclass
class Screen:
    """A physical monitor as xrandr sees it (kiosk/lib/displays.py list)."""
    name: str
    label: str
    builtin: bool
    connected: bool
    active: bool
    primary: bool
    width: int
    height: int
    rate: float = 0.0            # current refresh rate (Hz)
    preferred: str = ""          # the monitor's native "WxH"
    modes: list = field(default_factory=list)   # [{"size": "WxH", "rates": [Hz, ...]}], best first


@dataclass
class ReimsGpu:
    """A GPU Reims can be pinned to: `id` is its Vulkan ICD manifest's file
    name (what mac-vm-launch.sh puts in VK_DRIVER_FILES)."""
    id: str
    label: str
    driver: str


@dataclass
class Resources:
    """What the Mac gets (Settings > Mac > Resources). cores/ram_mb are what the
    next launch will use; *_auto what Automatic resolves to; *_choice the saved
    pick (0 = Automatic); *_choices the fixed values offered."""
    threads: int
    host_ram_mb: int
    amd: bool
    reserve: bool
    cores_auto: int
    cores_choice: int
    cores_choices: List[int]
    cores: int
    ram_auto_mb: int
    ram_choice_mb: int
    ram_choices_mb: List[int]
    ram_mb: int


@dataclass
class WifiNetwork:
    ssid: str
    signal: int
    secure: bool
    connected: bool


@dataclass
class UsbDevice:
    vid: str
    pid: str
    name: str
    builtin: bool
    blocked: str          # empty = can be passed to the Mac, else why not
    on_mac: bool
    always: bool

    @property
    def id(self) -> str:
        return f"{self.vid}:{self.pid}"


@dataclass
class LogTarget:
    path: str             # /dev/sdb1
    label: str
    model: str
    size: int             # bytes
    fstype: str
    removable: bool
    mountpoint: str       # "" when not mounted

    @property
    def title(self) -> str:
        return self.label or self.model or os.path.basename(self.path)

    @property
    def size_text(self) -> str:
        n = float(self.size)
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if n < 1000 or unit == "TB":
                return f"{n:.0f} {unit}" if unit in ("B", "KB", "MB") else f"{n:.1f} {unit}"
            n /= 1000.0
        return ""


# Credits shown in LayerOSX Settings > About. Edit here.
CREATOR = "Vini"
CREATOR_LINK = "github.com/vinioliveiras/LayerOSX"
THANKS = [
    ("Reims-vGPU", "accelerated macOS graphics in QEMU"),
    ("qemus/qemu-macos", "the QEMU build LayerOSX ships"),
    ("OSX-KVM (kholia)", "OpenCore image and macOS recovery tooling"),
    ("OpenCore", "the bootloader that starts macOS"),
    ("AMD_Vanilla (AMD-OSX)", "kernel patches for AMD processors"),
    ("Arch Linux", "the system underneath"),
]

MACOS_NAMES = {"high-sierra": "macOS High Sierra", "mojave": "macOS Mojave", "catalina": "macOS Catalina",
               "big-sur": "macOS Big Sur", "monterey": "macOS Monterey", "ventura": "macOS Ventura",
               "sonoma": "macOS Sonoma", "sequoia": "macOS Sequoia", "tahoe": "macOS Tahoe"}


@dataclass
class About:
    layerosx_version: str
    built: str
    mode: str
    machine: str          # vendor + model from DMI
    cpu: str
    cpu_threads: int
    memory_gb: float
    gpus: List[str]
    storage: str          # system disk model + size
    kernel: str
    macos: str            # "macOS Ventura 13.5 (22G120)"
    vm_cpu: str
    vm_cores: int
    vm_ram_gb: float
    vm_graphics: str
    vm_disk_gb: int       # virtual size macOS sees (0 = no disk yet)
    vm_disk_grown_from: int   # >0 when LayerOSX grew the disk (macOS must grow APFS)
    creator: str
    creator_link: str
    thanks: List[Tuple[str, str]]


@dataclass
class Status:
    mode: str
    terminal_policy: str
    gfx: str
    gfx_saved: bool
    verbose: bool
    verbose_saved: bool
    audio: bool
    audio_saved: bool
    vm_running: bool
    wifi_ssid: str
    wifi_signal: int
    wired: bool
    battery_percent: Optional[int]
    battery_status: str
    brightness: Optional[int]


class Backend:
    # Per-mode defaults -- MUST match mac-vm-launch.sh and lib/settings.sh.
    DEFAULTS = {
        "release": {"gfx": "reims", "verbose": "off", "audio": "on"},
        "debug": {"gfx": "vmware", "verbose": "on", "audio": "off"},
    }
    GFX_CHOICES = ("reims", "vmware", "std")

    def __init__(self):
        self.lib = _env("LAYEROSX_LIB", "/opt/layerosx/kiosk/lib")
        self.bin = _env("LAYEROSX_BIN", "/usr/local/bin")
        self.state_dir = _env("LAYEROSX_STATE_DIR", "/var/lib/layerosx")
        self.etc_dir = _env("LAYEROSX_ETC_DIR", "/etc/layerosx")
        self.ctl_sock = _env("LAYEROSX_CTL_SOCK", "/tmp/macvm-ctl.sock")
        self.host_action_file = _env("LAYEROSX_HOST_ACTION_FILE", "/tmp/layerosx-host-action")
        self.usb_sysfs = _env("LAYEROSX_USB_SYSFS", "/sys/bus/usb/devices")
        self.power_supply = _env("LAYEROSX_POWER_SUPPLY", "/sys/class/power_supply")
        self.usb_file = os.path.join(self.state_dir, "usb-passthrough")
        self.proc = _env("LAYEROSX_PROC", "/proc")
        self.dmi = _env("LAYEROSX_DMI", "/sys/class/dmi/id")
        self.vm_profile = _env("LAYEROSX_VM_PROFILE", "/tmp/layerosx-vm-profile")
        self.opencore_dir = _env("LAYEROSX_OPENCORE_DIR", "/opt/layerosx/opencore")
        self.dry_run = _env("LAYEROSX_DRY_RUN", "0") == "1"
        self.dry_log: List[str] = []

    # ------------------------------------------------------------------ utils
    def _run(self, cmd: List[str], changes: bool = True, timeout: int = 30,
             input_text: Optional[str] = None) -> Tuple[int, str]:
        """Run a command. `changes`=True commands are skipped in dry-run."""
        if changes and self.dry_run:
            self.dry_log.append(" ".join(cmd))
            return 0, ""
        try:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=timeout, input=input_text)
            return p.returncode, (p.stdout or "") + (p.stderr or "")
        except (OSError, subprocess.TimeoutExpired) as exc:
            return 1, str(exc)

    def _spawn(self, cmd: List[str]) -> None:
        """Start something detached (survives the panel closing)."""
        if self.dry_run:
            self.dry_log.append(" ".join(cmd))
            return
        subprocess.Popen(cmd, start_new_session=True, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)

    # --------------------------------------------------------------- settings
    @property
    def mode(self) -> str:
        m = _read(os.path.join(self.etc_dir, "mode"))
        return "debug" if m == "debug" else "release"

    @property
    def terminal_policy(self) -> str:
        """Build parameter LAYEROSX_TERMINAL: "off" = no terminal at all,
        anything else = available. Whether it asks for a password is no longer
        a build choice but the user's: the Maintenance password (below). An old
        "password" build means "available" too."""
        return "off" if _read(os.path.join(self.etc_dir, "terminal")) == "off" else "open"

    # ------------------------------------------------ maintenance password
    # Optional, set by the user in Settings > Maintenance. When set it guards
    # that whole section (logs, diagnostics, terminal, text consoles) and the
    # terminal's other doors: Ctrl+Alt+T (lib/maint-terminal.sh) and tty2
    # (lib/tty2-login.sh), which verify it through `layerosx_backend.py
    # check-maint-password`. Stored as scrypt(N=2^14, r=8, p=1) with a random
    # salt in $STATE_DIR/maint-password (0600) -- never the password itself.
    @property
    def _maint_file(self) -> str:
        return os.path.join(self.state_dir, "maint-password")

    def maint_password_set(self) -> bool:
        return bool(_read(self._maint_file))

    @staticmethod
    def _hash_password(pw: str, salt: bytes) -> bytes:
        return hashlib.scrypt(pw.encode("utf-8"), salt=salt, n=2 ** 14, r=8, p=1, dklen=32)

    def check_maint_password(self, pw: str) -> bool:
        rec = _read(self._maint_file)
        try:
            algo, salt_hex, hash_hex = rec.split("$")
            if algo != "scrypt":
                return False
            return hmac.compare_digest(self._hash_password(pw, bytes.fromhex(salt_hex)),
                                       bytes.fromhex(hash_hex))
        except ValueError:
            return False

    def set_maint_password(self, new: str, current: str = "") -> Tuple[bool, str]:
        """Set, change ('' current only when none is set) or remove (new='')."""
        if self.maint_password_set() and not self.check_maint_password(current):
            return False, "The current password is wrong."
        if new and len(new) < 4:
            return False, "Use at least 4 characters."
        if not new:
            return self._write_state("maint-password", None)
        salt = os.urandom(16)
        ok, msg = self._write_state("maint-password",
                                    f"scrypt${salt.hex()}${self._hash_password(new, salt).hex()}")
        if ok and not self.dry_run:
            os.chmod(self._maint_file, 0o600)
        return ok, msg

    def setting(self, name: str) -> Tuple[str, bool]:
        """Effective value + whether the user saved it (vs the build default)."""
        raw = _read(os.path.join(self.state_dir, name))
        saved = bool(raw)
        if not raw:
            raw = self.DEFAULTS[self.mode][name]
        if name == "gfx":
            if raw in ("reims", "reims-vgpu-pci"):
                return "reims", saved
            if raw in ("std", "std-vga", "vga"):
                return "std", saved
            return "vmware", saved
        return ("on" if raw.lower() in ("on", "1", "yes", "true") else "off"), saved

    def set_setting(self, name: str, value: str) -> Tuple[bool, str]:
        if name == "gfx" and value not in self.GFX_CHOICES:
            return False, f"unknown graphics adapter {value!r}"
        if name in ("verbose", "audio") and value not in ("on", "off"):
            return False, f"{name} must be on/off"
        if name not in ("gfx", "verbose", "audio"):
            return False, f"unknown setting {name!r}"
        cmd = {"gfx": "gpu"}.get(name, name)
        rc, out = self._run([os.path.join(self.bin, cmd), value])
        return rc == 0, out.strip()

    # ------------------------------------------------------------ resources
    # Mirrors pick_resources() in mac-vm-launch.sh -- keep the two in sync.
    # State files: cpu-cores (1/2/4/8, absent = Automatic), cpu-reserve
    # (off = Automatic uses every thread), ram-mb (MB, absent = Automatic).
    AMD_FAMILIES = {8: "amd8", 4: "amd", 2: "amd2"}

    def _threads(self) -> int:
        env = os.environ.get("LAYEROSX_NPROC", "")
        if env.isdigit() and int(env) > 0:
            return int(env)
        try:
            return len(os.sched_getaffinity(0))
        except (AttributeError, OSError):
            return os.cpu_count() or 1

    def _host_ram_mb(self) -> int:
        for line in (_read(os.path.join(self.proc, "meminfo")) or "").splitlines():
            if line.startswith("MemTotal:"):
                try:
                    return int(line.split()[1]) // 1024
                except (IndexError, ValueError):
                    break
        return 8192

    def _is_amd(self) -> bool:
        return "AuthenticAMD" in (_read(os.path.join(self.proc, "cpuinfo")) or "")

    def _amd_image(self, cores: int) -> bool:
        fam = self.AMD_FAMILIES.get(cores)
        img = os.path.join(self.opencore_dir, f"OpenCore-{fam}.qcow2") if fam else ""
        return bool(fam) and os.path.isfile(img) and os.path.getsize(img) > 0

    def cpu_reserve(self) -> bool:
        return _read(os.path.join(self.state_dir, "cpu-reserve")).lower() not in ("off", "0", "no", "false")

    def auto_cores(self, threads: int, reserve: bool = True) -> int:
        n = threads if (threads <= 4 or not reserve) else threads - 2
        n = max(1, min(8, n))
        p = 1
        while p * 2 <= n:
            p *= 2
        return p

    def _amd_pin(self, cores: int) -> int:
        """AMD: the core count must match a baked OpenCore image (8/4/2)."""
        cores = max(2, cores)
        for c in (8, 4, 2):
            if c <= cores and self._amd_image(c):
                return c
        return 4

    @staticmethod
    def auto_ram_mb(host_mb: int) -> int:
        reserve = max(4096, host_mb * 12 // 100)
        return max(4096, (host_mb - reserve) // 1024 * 1024)

    def resources(self) -> Resources:
        threads, host_mb, amd = self._threads(), self._host_ram_mb(), self._is_amd()
        reserve = self.cpu_reserve()
        choices = [c for c in (1, 2, 4, 8) if c <= threads]
        if amd:
            choices = [c for c in choices if self._amd_image(c)]
        auto = self.auto_cores(threads, reserve)
        raw = _read(os.path.join(self.state_dir, "cpu-cores"))
        choice = int(raw) if raw in ("1", "2", "4", "8") and int(raw) <= threads else 0
        cores = choice or auto
        if amd:
            auto, cores = self._amd_pin(auto), self._amd_pin(cores)
        ram_auto = self.auto_ram_mb(host_mb)
        top_gb = max(2, (host_mb - 2048) // 1024)          # leave Linux >= 2 GB
        ram_choices = [gb * 1024 for gb in (2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256)
                       if gb <= top_gb]
        rraw = _read(os.path.join(self.state_dir, "ram-mb"))
        ram_choice = int(rraw) if rraw.isdigit() and int(rraw) >= 2048 else 0
        if ram_choice and ram_choice not in ram_choices:
            ram_choices = sorted(ram_choices + [ram_choice])
        return Resources(threads, host_mb, amd, reserve, auto, choice, choices, cores,
                         ram_auto, ram_choice, ram_choices, ram_choice or ram_auto)

    def _write_state(self, name: str, value: Optional[str]) -> Tuple[bool, str]:
        path = os.path.join(self.state_dir, name)
        if self.dry_run:
            self.dry_log.append(f"{name} -> {value if value is not None else 'auto'}")
            return True, ""
        try:
            os.makedirs(self.state_dir, exist_ok=True)
            if value is None:
                if os.path.exists(path):
                    os.remove(path)
            else:
                with open(path, "w") as f:
                    f.write(value + "\n")
            return True, ""
        except OSError as e:
            return False, str(e)

    def set_cores(self, value) -> Tuple[bool, str]:
        """'auto'/0 or one of resources().cores_choices."""
        if value in ("auto", 0, "0", None):
            return self._write_state("cpu-cores", None)
        try:
            n = int(value)
        except (TypeError, ValueError):
            return False, f"invalid core count {value!r}"
        if n not in self.resources().cores_choices:
            return False, f"{n} cores isn't available on this machine"
        return self._write_state("cpu-cores", str(n))

    def set_cpu_reserve(self, on: bool) -> Tuple[bool, str]:
        return self._write_state("cpu-reserve", None if on else "off")

    def set_ram(self, value) -> Tuple[bool, str]:
        """'auto'/0 or a size in MB (>= 2048, leaving Linux at least 2 GB)."""
        if value in ("auto", 0, "0", None):
            return self._write_state("ram-mb", None)
        try:
            mb = int(value)
        except (TypeError, ValueError):
            return False, f"invalid memory size {value!r}"
        if mb < 2048 or mb > self._host_ram_mb() - 2048:
            return False, f"{mb} MB is out of range for this machine"
        return self._write_state("ram-mb", str(mb))

    # ------------------------------------------------ debug features (toggles)
    # One ISO for everyone: what the old debug build baked in is switched here.
    def _flag(self, name: str) -> bool:
        return _read(os.path.join(self.state_dir, name)).lower() in ("on", "1", "yes", "true")

    def diag_logs(self) -> bool:
        """Settings > Mac > Detailed logs: serial kernel log + OpenCore log +
        QEMU guest_errors/unimp (mac-vm-launch.sh boots OpenCore*-diag)."""
        return self._flag("diag-logs")

    def set_diag_logs(self, on: bool) -> Tuple[bool, str]:
        return self._write_state("diag-logs", "on" if on else None)

    def text_consoles(self) -> bool:
        """Settings > General > Text consoles (Ctrl+Alt+F1..F6), as saved --
        kiosk/lib/vt-lock.sh applies it at the next boot."""
        return self._flag("vt-switch")

    def text_consoles_now(self) -> bool:
        """Whether they're unlocked in the running session (no lock file)."""
        return not os.path.exists(os.environ.get(
            "LAYEROSX_VTLOCK_FILE", "/etc/X11/xorg.conf.d/10-layerosx-kiosk-lock.conf"))

    def set_text_consoles(self, on: bool) -> Tuple[bool, str]:
        return self._write_state("vt-switch", "on" if on else None)

    # ------------------------------------------------------------ Mac model
    # SMBIOS model the Mac reports (OpenCore PlatformInfo > SystemProductName).
    # build.sh bakes the default into the images (/etc/layerosx/mac-model);
    # another choice is applied by mac-vm-launch.sh via kiosk/lib/oc-model.sh.
    MAC_MODELS = (
        ("MacBookPro16,2", "MacBook Pro (13-inch, 2020)"),
        ("MacBookPro16,1", "MacBook Pro (16-inch, 2019)"),
        ("iMac20,1", "iMac (27-inch, 2020)"),
        ("iMac19,1", "iMac (27-inch, 2019)"),
        ("iMacPro1,1", "iMac Pro (2017)"),
        ("MacPro7,1", "Mac Pro (2019)"),
    )

    def mac_model_default(self) -> str:
        return _read(os.path.join(self.etc_dir, "mac-model")) or "iMac19,1"

    def mac_model(self) -> str:
        m = _read(os.path.join(self.state_dir, "mac-model"))
        return m if m in dict(self.MAC_MODELS) else self.mac_model_default()

    def set_mac_model(self, model: str) -> Tuple[bool, str]:
        if model not in dict(self.MAC_MODELS):
            return False, f"unknown Mac model {model!r}"
        return self._write_state("mac-model", None if model == self.mac_model_default() else model)

    # --------------------------------------------------------------- screens
    # Which physical screen shows the Mac: display-target (xrandr output name,
    # absent = Automatic) and display-others (off|mirror). Applied by
    # mac-vm-launch.sh (lib/displays.py apply) before each launch.
    def screens(self) -> List[Screen]:
        rc, out = self._run([sys.executable, os.path.join(self.lib, "displays.py"), "list"],
                            changes=False, timeout=15)
        try:
            data = json.loads(out) if rc == 0 else []
        except ValueError:
            data = []
        fields = Screen.__dataclass_fields__
        return [Screen(**{k: d[k] for k in fields if k in d}) for d in data if d.get("connected")]

    def mac_screen(self, screens: Optional[List[Screen]] = None) -> Optional[Screen]:
        """The screen the Mac is (or will be) shown on: the chosen one when
        connected, else the primary, else the first."""
        screens = self.screens() if screens is None else screens
        t = self.screen_target()
        return next((x for x in screens if x.name == t), None) or \
            next((x for x in screens if x.primary), None) or (screens[0] if screens else None)

    def _modes_state(self) -> dict:
        try:
            data = json.loads(_read(os.path.join(self.state_dir, "display-modes")) or "{}")
        except ValueError:
            return {}
        return data if isinstance(data, dict) else {}

    def screen_mode(self, name: str) -> Tuple[Optional[str], Optional[float]]:
        """Saved (size, rate) for a screen; None = automatic."""
        m = self._modes_state().get(name) or {}
        return m.get("size") or None, m.get("rate") or None

    def set_screen_mode(self, name: str, size: Optional[str], rate: Optional[float]) -> Tuple[bool, str]:
        """Fix a screen's resolution (None = its native one) and refresh rate
        (None = the highest for that resolution); both None = automatic."""
        sc = next((x for x in self.screens() if x.name == name), None)
        if sc is None:
            return False, f"screen {name!r} isn't connected"
        if size or rate:
            mode = next((m for m in sc.modes if m["size"] == (size or sc.preferred)), None)
            if mode is None:
                return False, f"{size} isn't a resolution of {sc.label}"
            if rate and not any(abs(r - rate) < 0.5 for r in mode["rates"]):
                return False, f"{rate:g} Hz isn't available at {mode['size']}"
        data = self._modes_state()
        if size or rate:
            data[name] = {"size": size, "rate": rate}
        else:
            data.pop(name, None)
        return self._write_state("display-modes", json.dumps(data) if data else None)

    # Reims' GPU: Vulkan ICD manifests -> the GPUs lspci shows.
    ICD_VENDORS = (("nvidia", "NVIDIA", "NVIDIA driver"), ("nouveau", "NVIDIA", "NVK (Mesa)"),
                   ("radeon", "AMD", "RADV (Mesa)"), ("amd_", "AMD", "AMDVLK"),
                   ("intel", "Intel", "ANV (Mesa)"))

    def reims_gpus(self) -> List[ReimsGpu]:
        dirs = os.environ.get("LAYEROSX_VK_ICD_DIRS", "/usr/share/vulkan/icd.d:/etc/vulkan/icd.d").split(":")
        rc, out = self._run(["lspci", "-mm"], changes=False, timeout=10)
        gpus = []
        for line in out.splitlines() if rc == 0 else []:
            f = re.findall(r'"([^"]*)"', line)
            if len(f) >= 3 and ("VGA" in f[0] or "3D" in f[0] or "Display" in f[0]):
                gpus.append(_gpu_name(f[1], f[2]))
        found, seen = [], set()
        for d in dirs:
            try:
                names = sorted(os.listdir(d))
            except OSError:
                continue
            for fn in names:
                if not fn.endswith(".json") or fn in seen:
                    continue
                vendor = next(((b, drv) for key, b, drv in self.ICD_VENDORS if fn.lower().startswith(key)), None)
                if not vendor:
                    continue                      # software rasterisers, layers, ...
                gpu = next((g for g in gpus if g.startswith(vendor[0])), None)
                if gpu:
                    seen.add(fn)
                    found.append(ReimsGpu(fn, gpu, vendor[1]))
        return found

    def reims_gpu(self) -> str:
        return _read(os.path.join(self.state_dir, "reims-gpu")) or "auto"

    def set_reims_gpu(self, gpu_id: str) -> Tuple[bool, str]:
        if gpu_id in ("auto", "", None):
            return self._write_state("reims-gpu", None)
        if gpu_id not in [g.id for g in self.reims_gpus()]:
            return False, f"no such graphics card {gpu_id!r}"
        return self._write_state("reims-gpu", gpu_id)

    def screen_target(self) -> str:
        t = _read(os.path.join(self.state_dir, "display-target"))
        return t if t and t != "auto" else "auto"

    def screen_others(self) -> str:
        return "mirror" if _read(os.path.join(self.state_dir, "display-others")) == "mirror" else "off"

    def set_screen_target(self, name: str) -> Tuple[bool, str]:
        if name in ("auto", "", None):
            return self._write_state("display-target", None)
        if name not in [s.name for s in self.screens()]:
            return False, f"screen {name!r} isn't connected"
        return self._write_state("display-target", name)

    def set_screen_others(self, value: str) -> Tuple[bool, str]:
        if value not in ("off", "mirror"):
            return False, "other screens must be off or mirror"
        return self._write_state("display-others", None if value == "off" else "mirror")

    # ------------------------------------------------------------ appearance
    def panel_theme(self) -> str:
        """LayerOSX Settings appearance: light (default) or dark. The
        LAYEROSX_PANEL_THEME env var wins (previews/screenshots)."""
        env = os.environ.get("LAYEROSX_PANEL_THEME", "")
        if env in ("light", "dark"):
            return env
        return "dark" if _read(os.path.join(self.state_dir, "panel-theme")) == "dark" else "light"

    def set_panel_theme(self, theme: str) -> Tuple[bool, str]:
        if theme not in ("light", "dark"):
            return False, "theme must be light or dark"
        if self.dry_run:
            self.dry_log.append(f"panel theme -> {theme}")
            return True, ""
        try:
            os.makedirs(self.state_dir, exist_ok=True)
            with open(os.path.join(self.state_dir, "panel-theme"), "w") as f:
                f.write(theme + "\n")
        except OSError as exc:
            return False, str(exc)
        return True, ""

    # --------------------------------------------------------------------- VM
    def vm_running(self) -> bool:
        return os.path.exists(self.ctl_sock)

    def restart_mac(self) -> Tuple[bool, str]:
        rc, out = self._run([os.path.join(self.bin, "relaunch")])
        return rc == 0, out.strip()

    def host_action(self, kind: str) -> Tuple[bool, str]:
        """Restart / shut down the computer: stop QEMU cleanly (QMP quit), let
        mac-vm-launch.sh act on the host-action file, 15 s fallback."""
        if kind not in ("reboot", "poweroff"):
            return False, f"unknown host action {kind!r}"
        if self.dry_run:
            self.dry_log.append(f"qmp quit && systemctl {kind}")
            return True, ""
        with open(self.host_action_file, "w") as f:
            f.write(kind + "\n")
        if self.vm_running():
            rc, _ = self._run([sys.executable, os.path.join(self.lib, "qmp-cmd.py"),
                               self.ctl_sock, "quit"])
            if rc != 0:
                self._run([os.path.join(self.bin, "relaunch")])
        f = self.host_action_file
        self._spawn(["bash", "-c",
                     f'sleep 15; [ -e "{f}" ] && rm -f "{f}" && sudo systemctl {kind}'])
        return True, ""

    # ------------------------------------------------------------------ Wi-Fi
    def wifi_current(self) -> Tuple[str, int, bool]:
        """(ssid, signal, wired)."""
        rc, out = self._run(["nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL", "device", "wifi"],
                            changes=False, timeout=10)
        ssid, sig = "", 0
        if rc == 0:
            for line in out.splitlines():
                parts = _split_nmcli(line)
                if len(parts) >= 3 and parts[0] == "yes":
                    ssid, sig = parts[1], _int(parts[2])
                    break
        rc, out = self._run(["nmcli", "-t", "-f", "TYPE,STATE", "device"],
                            changes=False, timeout=10)
        wired = rc == 0 and any(l.startswith("ethernet:connected") for l in out.splitlines())
        return ssid, sig, wired

    def wifi_scan(self, rescan: bool = True) -> List[WifiNetwork]:
        if rescan:
            self._run(["nmcli", "device", "wifi", "rescan"], changes=False, timeout=15)
        rc, out = self._run(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY",
                             "device", "wifi", "list"], changes=False, timeout=20)
        best = {}
        if rc != 0:
            return []
        for line in out.splitlines():
            parts = _split_nmcli(line)
            if len(parts) < 4 or not parts[1]:
                continue
            inuse, ssid, sig, sec = parts[0] == "*", parts[1], _int(parts[2]), parts[3]
            secure = sec not in ("", "--")
            cur = best.get(ssid)
            if cur is None or sig > cur.signal or inuse:
                best[ssid] = WifiNetwork(ssid, max(sig, cur.signal if cur else 0),
                                         secure, inuse or (cur.connected if cur else False))
        return sorted(best.values(), key=lambda n: (not n.connected, -n.signal, n.ssid.lower()))

    def wifi_connect(self, ssid: str, password: str = "", hidden: bool = False) -> Tuple[bool, str]:
        if not ssid:
            return False, "no network name"
        cmd = ["nmcli", "device", "wifi", "connect", ssid]
        if password:
            cmd += ["password", password]
        if hidden:
            cmd += ["hidden", "yes"]
        # Real even in dry-run: joining a network is harmless and lets the
        # preview's Wi-Fi page work on the developer's machine.
        rc, out = self._run(cmd, changes=False, timeout=45)
        out = out.strip().replace(password, "•••") if password else out.strip()
        return rc == 0, out

    def wifi_enabled(self) -> bool:
        rc, out = self._run(["nmcli", "radio", "wifi"], changes=False, timeout=10)
        return rc == 0 and out.strip().splitlines()[-1:] == ["enabled"]

    def set_wifi_enabled(self, on: bool) -> Tuple[bool, str]:
        rc, out = self._run(["nmcli", "radio", "wifi", "on" if on else "off"])
        return rc == 0, out.strip()

    def internet_ok(self) -> bool:
        rc, _ = self._run(["curl", "-fsS", "--max-time", "5", "-o", "/dev/null",
                           "https://www.apple.com"], changes=False, timeout=8)
        return rc == 0

    # -------------------------------------------------------------------- USB
    def _usb_blocked(self, d: str) -> str:
        if _read(os.path.join(d, "bDeviceClass")) == "09":
            return "hub"
        try:
            entries = os.listdir(d)
        except OSError:
            entries = []
        for e in entries:
            if ":" not in e:
                continue
            itf = os.path.join(d, e)
            if _read(os.path.join(itf, "bInterfaceClass")) == "03" and \
                    _read(os.path.join(itf, "bInterfaceProtocol")) in ("01", "02"):
                return "keyboard/mouse (already shared with the Mac)"
        mounts = _read("/proc/mounts")
        for root, dirs, _files in os.walk(d, followlinks=False):
            if os.path.basename(root) == "block":
                for blk in dirs:
                    if blk.startswith("sd") and re.search(rf"^/dev/{blk}\d* ", mounts, re.M):
                        return f"mounted on the host (/dev/{blk}) -- unmount it first"
            if root.count(os.sep) - d.count(os.sep) >= 6:
                dirs[:] = []
        return ""

    def usb_always_set(self) -> set:
        out = set()
        for line in _read(self.usb_file).splitlines():
            vp = line.split()[0].lower() if line.split() else ""
            if re.match(r"^[0-9a-f]{4}:[0-9a-f]{4}$", vp):
                out.add(vp)
        return out

    def usb_on_mac(self) -> set:
        if not self.vm_running():
            return set()
        rc, out = self._run([sys.executable, os.path.join(self.lib, "qmp-cmd.py"),
                             self.ctl_sock, "usb-list"], changes=False, timeout=10)
        return {":".join(l.split()) for l in out.splitlines() if len(l.split()) == 2} if rc == 0 else set()

    def usb_devices(self) -> List[UsbDevice]:
        always, on_mac = self.usb_always_set(), self.usb_on_mac()
        devs = []
        try:
            names = sorted(os.listdir(self.usb_sysfs))
        except OSError:
            names = []
        for n in names:
            if n.startswith("usb") or ":" in n:
                continue
            d = os.path.join(self.usb_sysfs, n)
            vid, pid = _read(os.path.join(d, "idVendor")).lower(), _read(os.path.join(d, "idProduct")).lower()
            if not (HEX4.match(vid) and HEX4.match(pid)):
                continue
            name = " ".join(x for x in (_read(os.path.join(d, "manufacturer")),
                                        _read(os.path.join(d, "product"))) if x) or f"USB device {vid}:{pid}"
            vp = f"{vid}:{pid}"
            devs.append(UsbDevice(vid, pid, name, _read(os.path.join(d, "removable")) == "fixed",
                                  self._usb_blocked(d), vp in on_mac, vp in always))
        return devs

    def _check_usb(self, vid: str, pid: str) -> Optional[str]:
        vid, pid = vid.lower(), pid.lower()
        if not (HEX4.match(vid) and HEX4.match(pid)):
            return "invalid USB id"
        return None

    def usb_give_to_mac(self, vid: str, pid: str, on: bool) -> Tuple[bool, str]:
        err = self._check_usb(vid, pid)
        if err:
            return False, err
        vid, pid = vid.lower(), pid.lower()
        if on:
            dev = next((d for d in self.usb_devices() if d.vid == vid and d.pid == pid), None)
            if dev and dev.blocked:
                return False, dev.blocked
        if not self.vm_running() and not self.dry_run:
            return False, "the Mac isn't running"
        rc, out = self._run([sys.executable, os.path.join(self.lib, "qmp-cmd.py"), self.ctl_sock,
                             "usb-attach" if on else "usb-detach", vid, pid])
        if rc == 0 and not on:
            self.usb_set_always(vid, pid, False)
        return rc == 0, out.strip()

    def usb_set_always(self, vid: str, pid: str, always: bool, name: str = "") -> Tuple[bool, str]:
        err = self._check_usb(vid, pid)
        if err:
            return False, err
        vp = f"{vid.lower()}:{pid.lower()}"
        lines = [l for l in _read(self.usb_file).splitlines()
                 if l.split() and l.split()[0].lower() != vp]
        if always:
            lines.append(f"{vp}  {name}".rstrip())
        if self.dry_run:
            self.dry_log.append(f"{'remember' if always else 'forget'} USB {vp}")
            return True, ""
        try:
            os.makedirs(self.state_dir, exist_ok=True)
            with open(self.usb_file, "w") as f:
                f.write("".join(l + "\n" for l in lines))
        except OSError as exc:
            return False, str(exc)
        return True, ""

    # ---------------------------------------------------------- power, screen
    def battery(self) -> Tuple[Optional[int], str]:
        try:
            bats = sorted(x for x in os.listdir(self.power_supply) if x.startswith("BAT"))
        except OSError:
            bats = []
        if not bats:
            return None, ""
        b = os.path.join(self.power_supply, bats[0])
        cap = _read(os.path.join(b, "capacity"))
        return (int(cap) if cap.isdigit() else None), _read(os.path.join(b, "status"))

    def brightness(self) -> Optional[int]:
        if not shutil.which("brightnessctl"):
            return None
        rc, out = self._run(["brightnessctl", "-m", "-c", "backlight"], changes=False, timeout=5)
        m = re.search(r",(\d+)%,", out) if rc == 0 else None
        return int(m.group(1)) if m else None

    def set_brightness(self, percent: int) -> Tuple[bool, str]:
        percent = max(5, min(100, int(percent)))   # never fully black
        rc, out = self._run(["brightnessctl", "-q", "-c", "backlight", "set", f"{percent}%"])
        return rc == 0, out.strip()

    # ------------------------------------------------------------ maintenance
    # Filesystems a diagnostics bundle can be written to; everything else
    # (swap, LUKS/BitLocker, squashfs, unknown) is never offered.
    SAVE_FSTYPES = ("vfat", "exfat", "ntfs", "ext4", "ext3", "ext2", "btrfs", "xfs")

    def log_targets(self) -> List[LogTarget]:
        """Drives the user can save diagnostics to: partitions with a writable
        filesystem, never the running system's root/boot, nor Ventoy's tiny
        VTOYEFI partition. Removable (USB) drives first."""
        rc, out = self._run(["lsblk", "-J", "-b", "-o",
                             "NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINTS,RM,HOTPLUG,TRAN,TYPE,MODEL"],
                            changes=False, timeout=10)
        if rc != 0:
            return []
        try:
            tree = json.loads(out)["blockdevices"]
        except (ValueError, KeyError):
            return []
        targets = []

        def walk(nodes, parent):
            for n in nodes:
                kids = n.get("children") or []
                if n.get("type") == "part":
                    mps = [m for m in (n.get("mountpoints") or []) if m]
                    fs = (n.get("fstype") or "").lower()
                    label = n.get("label") or ""
                    system = any(m in ("/", "/boot", "/boot/efi", "[SWAP]") or m.startswith("/run/archiso")
                                 for m in mps)
                    if fs in self.SAVE_FSTYPES and not system and label != "VTOYEFI":
                        removable = bool(parent.get("rm") or parent.get("hotplug") or
                                         (parent.get("tran") or "") == "usb" or n.get("rm") or n.get("hotplug"))
                        targets.append(LogTarget(
                            path=n.get("path") or f"/dev/{n.get('name')}",
                            label=label, model=(parent.get("model") or "").strip(),
                            size=int(n.get("size") or 0), fstype=fs, removable=removable,
                            mountpoint=mps[0] if mps else ""))
                walk(kids, n if n.get("type") == "disk" else parent)
        walk(tree, {})
        return sorted(targets, key=lambda t: (not t.removable, t.path))

    def save_logs_to(self, device: str) -> Tuple[bool, str]:
        """Build a fresh diagnostics bundle and copy it onto `device` (one of
        log_targets(); anything else is refused)."""
        if device not in {t.path for t in self.log_targets()}:
            return False, "that drive isn't available for saving"
        if self.dry_run:
            self.dry_log.append(f"macdiag && sudo save-logs-to.sh <bundle> {device}")
            return True, "preview"
        rc, out = self._run([os.path.join(self.bin, "macdiag"), "bundle"], timeout=120)
        m = re.search(r"^Diagnostics bundle: (.+)$", out, re.M)
        if not m:
            return False, "couldn't collect the diagnostics"
        rc, out = self._run(["sudo", "-n", os.path.join(self.lib, "save-logs-to.sh"),
                             m.group(1).strip(), device], timeout=120)
        lines = [l for l in out.strip().splitlines() if l]
        return rc == 0, (lines[-1] if lines else "")

    def save_diagnostics(self) -> Tuple[bool, str]:
        if self.dry_run:
            self.dry_log.append(os.path.join(self.bin, "macdiag") + " usb")
            return True, "preview"
        rc, out = self._run([os.path.join(self.bin, "macdiag"), "usb"], timeout=120)
        ok = any(l.startswith("Copied") for l in out.splitlines())
        return ok, out.strip() if ok else "Plug in a writable USB drive and try again."

    def open_terminal(self, unlocked: bool = False) -> Tuple[bool, str]:
        """From the panel: `unlocked` = the user already typed the Maintenance
        password there, so open straight away instead of asking again."""
        if self.terminal_policy == "off":
            return False, "this build has no maintenance terminal"
        log = os.path.expanduser("~/mac-vm.log")
        if unlocked or not self.maint_password_set():
            self._spawn([os.path.join(self.lib, "peek-terminal.sh"), log])
        else:
            self._spawn([os.path.join(self.lib, "maint-terminal.sh"), log])
        return True, ""

    # ------------------------------------------------------------------ about
    def about(self) -> About:
        """The real machine, the Mac it runs and the credits (read-only)."""
        kv = lambda text: dict(l.split("=", 1) for l in text.splitlines() if "=" in l)  # noqa: E731
        ver = kv(_read(os.path.join(self.etc_dir, "version")))
        prof = kv(_read(self.vm_profile))

        vendor = _read(os.path.join(self.dmi, "sys_vendor"))
        product = _read(os.path.join(self.dmi, "product_name"))
        family = _read(os.path.join(self.dmi, "product_family"))
        machine = _machine_name(vendor, family, product)

        cpuinfo = _read(os.path.join(self.proc, "cpuinfo"))
        m = re.search(r"^model name\s*:\s*(.+)$", cpuinfo, re.M)
        cpu = re.sub(r"\s+", " ", m.group(1)).strip() if m else "Unknown"
        threads = len(re.findall(r"^processor\s*:", cpuinfo, re.M)) or (os.cpu_count() or 0)
        m = re.search(r"^MemTotal:\s*(\d+) kB", _read(os.path.join(self.proc, "meminfo")), re.M)
        mem = round(int(m.group(1)) / 1024 / 1024, 1) if m else 0.0

        gpus = []
        rc, out = self._run(["lspci", "-mm"], changes=False, timeout=10)
        for line in out.splitlines() if rc == 0 else []:
            f = re.findall(r'"([^"]*)"', line)
            if len(f) >= 3 and ("VGA" in f[0] or "3D" in f[0] or "Display" in f[0]):
                gpus.append(_gpu_name(f[1], f[2]))

        storage = ""
        rc, out = self._run(["findmnt", "-nro", "SOURCE", "/"], changes=False, timeout=5)
        root = out.strip().split("[")[0] if rc == 0 else ""
        if root:
            rc, out = self._run(["lsblk", "-ndo", "PKNAME", root], changes=False, timeout=5)
            disk = "/dev/" + out.strip() if rc == 0 and out.strip() else root
            rc, out = self._run(["lsblk", "-ndbo", "MODEL,SIZE", disk], changes=False, timeout=5)
            if rc == 0 and out.strip():
                parts = out.strip().rsplit(None, 1)
                model = parts[0].strip() if len(parts) == 2 else ""
                size = int(parts[-1]) if parts[-1].isdigit() else 0
                storage = f"{model} · {size / 1e9:.0f} GB".strip(" ·") if size else model

        short = _read(os.path.join(self.state_dir, "macos-version")) or prof.get("macos", "")
        dl = _read(os.path.join(self.state_dir, "downloaded-version"))
        dl_ver, _, dl_build = dl.partition("|")
        macos = MACOS_NAMES.get(short, "macOS")
        if dl_ver and dl_ver != "1.0":   # 1.0 = the recovery image's own version, not macOS's
            macos += f" {dl_ver}"
        if dl_build:
            macos += f" ({dl_build})"
        if not short and not dl:
            macos = "Not installed yet"

        disk_gb = 0
        disk = os.path.join(self.state_dir, "macos.qcow2")
        if os.path.exists(disk):
            rc, out = self._run(["qemu-img", "info", "--output=json", disk], changes=False, timeout=10)
            try:
                disk_gb = int(json.loads(out)["virtual-size"] / 1073741824) if rc == 0 else 0
            except (ValueError, KeyError):
                disk_gb = 0
        grown = kv(_read(os.path.join(self.state_dir, "disk-grown")))

        gfx_names = {"reims-vgpu-pci": "Reims (accelerated)", "reims": "Reims (accelerated)",
                     "vmware-svga": "VMware", "vmware": "VMware", "std-vga": "Standard VGA", "std": "Standard VGA"}
        gfx = prof.get("gfx") or self.setting("gfx")[0]
        return About(
            layerosx_version=ver.get("version", "development"), built=ver.get("built", ""),
            mode=ver.get("mode", self.mode), machine=machine, cpu=cpu, cpu_threads=threads,
            memory_gb=mem, gpus=gpus, storage=storage, kernel=os.uname().release, macos=macos,
            vm_cpu=prof.get("cpu_model", ""), vm_cores=_int(prof.get("cores", "0")),
            vm_ram_gb=round(_int(prof.get("ram_mb", "0")) / 1024, 1),
            vm_graphics=gfx_names.get(gfx, gfx), vm_disk_gb=disk_gb,
            vm_disk_grown_from=_int(grown.get("from_gb", "0")), creator=CREATOR, creator_link=CREATOR_LINK,
            thanks=list(THANKS))

    # ----------------------------------------------------------------- status
    def status(self) -> Status:
        gfx, gfx_saved = self.setting("gfx")
        verbose, verbose_saved = self.setting("verbose")
        audio, audio_saved = self.setting("audio")
        ssid, sig, wired = self.wifi_current()
        bat, bat_status = self.battery()
        return Status(self.mode, self.terminal_policy, gfx, gfx_saved,
                      verbose == "on", verbose_saved, audio == "on", audio_saved,
                      self.vm_running(), ssid, sig, wired, bat, bat_status, self.brightness())


_JUNK_DMI = ("to be filled by o.e.m.", "default string", "system product name", "not applicable", "")


def _machine_name(vendor: str, family: str, product: str) -> str:
    """'ASUSTeK COMPUTER INC.' + 'ASUS TUF Gaming A15 FA507NV_FA507NV' ->
    'ASUS TUF Gaming A15 FA507NV' (drops a vendor the product already names,
    collapses the 'X_X' duplicate some firmwares report)."""
    vendor, family, product = (x.strip() for x in (vendor, family, product))
    if product.lower() in _JUNK_DMI:
        product = ""
    product = re.sub(r"\b(\w+)_\1\b", r"\1", product)
    if family and family.lower() not in _JUNK_DMI and family not in product:
        product = f"{family} {product}".strip()
    first = vendor.split()[0].lower().rstrip(",.") if vendor else ""
    brand = {"asustek": "asus", "hewlett-packard": "hp", "micro-star": "msi"}.get(first, first)
    if product and brand and product.lower().startswith(brand):
        return product
    return " ".join(x for x in (vendor if vendor.lower() not in _JUNK_DMI else "", product) if x) or "Unknown"


def _gpu_name(vendor: str, device: str) -> str:
    """'NVIDIA Corporation' + 'AD107M [GeForce RTX 4060 Max-Q / Mobile]' ->
    'NVIDIA GeForce RTX 4060 Max-Q / Mobile'; AMD/ATI -> 'AMD Radeon 680M'."""
    v = vendor.lower()
    brand = "NVIDIA" if "nvidia" in v else "AMD" if ("advanced micro" in v or re.search(r"\bati\b", v)) else \
        "Intel" if "intel" in v else re.sub(r"\s*(Corporation|Inc\.?|Co\.?,? Ltd\.?)\s*", " ", vendor).strip()
    m = re.search(r"\[([^\]]+)\]", device)
    name = m.group(1) if m else device
    return name if name.lower().startswith(brand.lower()) else f"{brand} {name}"


def _split_nmcli(line: str) -> List[str]:
    """Split nmcli -t output on ':' honouring its '\\:' escapes."""
    parts, cur, esc = [], "", False
    for ch in line:
        if esc:
            cur += ch
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == ":":
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts


def _int(s: str) -> int:
    try:
        return int(s)
    except ValueError:
        return 0


def main(argv: List[str]) -> int:
    b = Backend()
    what = argv[1] if len(argv) > 1 else "status"
    if what == "status":
        print(json.dumps(asdict(b.status()), indent=2))
    elif what == "wifi":
        print(json.dumps([asdict(n) for n in b.wifi_scan()], indent=2))
    elif what == "about":
        print(json.dumps(asdict(b.about()), indent=2))
    elif what == "screens":
        print(json.dumps([asdict(x) for x in b.screens()], indent=2))
    elif what == "check-maint-password":
        # For shell scripts: password on stdin (first line). Exit 0 = right,
        # 1 = wrong, 2 = no password is set.
        if not b.maint_password_set():
            return 2
        return 0 if b.check_maint_password(sys.stdin.readline().rstrip("\n")) else 1
    elif what == "resources":
        print(json.dumps(asdict(b.resources()), indent=2))
    elif what == "drives":
        print(json.dumps([asdict(t) for t in b.log_targets()], indent=2))
    elif what == "usb":
        print(json.dumps([asdict(d) | {"id": d.id} for d in b.usb_devices()], indent=2))
    else:
        print("usage: layerosx_backend.py [status|wifi|usb|drives|about|resources|screens|check-maint-password]", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
