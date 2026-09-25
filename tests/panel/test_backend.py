"""Unit tests for layerosx_backend.py with a fake machine (no root, no VM).

Run: python3 -m unittest discover -s tests   (from the panel directory, or
tools/test-panel-backend.sh from the repo root).
"""
import os
import shutil
import stat
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "archiso", "airootfs", "opt", "layerosx", "panel"))
import layerosx_backend as lb  # noqa: E402


def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


class FakeMachine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        t = self.tmp
        self.bin = os.path.join(t, "bin")
        self.lib = os.path.join(t, "lib")
        self.state = os.path.join(t, "state")
        self.etc = os.path.join(t, "etc")
        self.log = os.path.join(t, "calls.log")
        os.makedirs(self.state)
        x = stat.S_IRWXU
        # gpu/verbose/audio behave like the real ones: write the state file.
        for cmd, fname in (("gpu", "gfx"), ("verbose", "verbose"), ("audio", "audio")):
            write(os.path.join(self.bin, cmd),
                  f'#!/bin/sh\necho "{cmd} $*" >> {self.log}\necho "$1" > {self.state}/{fname}\n', x)
        write(os.path.join(self.bin, "relaunch"), f'#!/bin/sh\necho relaunch >> {self.log}\n', x)
        write(os.path.join(self.bin, "macdiag"), '#!/bin/sh\necho "Copied the bundle to /run/media/x"\n', x)
        write(os.path.join(self.bin, "nmcli"), textwrap.dedent(r'''            #!/bin/sh
            case "$*" in
              "-t -f ACTIVE,SSID,SIGNAL device wifi") printf 'no:Cafe:40\nyes:Home\\:5G:77\n' ;;
              "-t -f TYPE,STATE device") printf 'wifi:connected\nethernet:unavailable\n' ;;
              "-t -f IN-USE,SSID,SIGNAL,SECURITY device wifi list")
                 printf ' :Cafe:40:--\n*:Home\\:5G:77:WPA2\n :Home\\:5G:60:WPA2\n :Neighbour:81:WPA3\n :::--\n' ;;
              "device wifi rescan") ;;
              "radio wifi") echo enabled ;;
              "radio wifi off") echo "radio off" >> /dev/null ;;
              "device wifi connect Neighbour password hunter2") echo "Device wlan0 successfully activated" ;;
              *) echo "unexpected nmcli $*" >&2; exit 9 ;;
            esac
            '''), x)
        # qmp-cmd.py stub: usb-list says one device is on the Mac; logs calls.
        write(os.path.join(self.lib, "qmp-cmd.py"), textwrap.dedent(f'''            import sys
            open("{self.log}", "a").write("qmp " + " ".join(sys.argv[2:]) + "\\n")
            if sys.argv[2] == "usb-list":
                print("0781 5583")
            '''))
        self.sock = os.path.join(t, "ctl.sock")
        # USB sysfs: pendrive, laptop keyboard, hub, built-in webcam, root hub
        self.usb = os.path.join(t, "usb")

        def dev(name, vid, pid, man, prod, removable, cls="00", itf=None):
            d = os.path.join(self.usb, name)
            for k, v in (("idVendor", vid), ("idProduct", pid), ("manufacturer", man),
                         ("product", prod), ("removable", removable), ("bDeviceClass", cls)):
                write(os.path.join(d, k), v + "\n")
            if itf:
                write(os.path.join(d, name + ":1.0", "bInterfaceClass"), itf[0] + "\n")
                write(os.path.join(d, name + ":1.0", "bInterfaceProtocol"), itf[1] + "\n")
        dev("1-1", "0781", "5583", "SanDisk", "Ultra Fit", "removable")
        dev("1-2", "0b05", "19b6", "ASUSTek", "N-KEY Device", "fixed", itf=("03", "01"))
        dev("1-3", "05e3", "0610", "Genesys", "USB2.1 Hub", "removable", cls="09")
        dev("3-1", "3277", "0059", "Shinetech", "HD UVC WebCam", "fixed")
        write(os.path.join(self.usb, "usb1", "idVendor"), "1d6b\n")
        # lsblk: laptop NVMe (Windows BitLocker, CachyOS root, ESP, DATA ntfs),
        # a USB stick (exfat, not mounted), Ventoy (exfat data + VTOYEFI).
        lsblk = {"blockdevices": [
            {"name": "nvme0n1", "path": "/dev/nvme0n1", "type": "disk", "rm": False, "hotplug": False,
             "tran": "nvme", "model": "WD SN560", "size": 1000204886016, "children": [
                {"name": "nvme0n1p1", "path": "/dev/nvme0n1p1", "type": "part", "fstype": "vfat",
                 "label": None, "size": 209715200, "mountpoints": ["/boot/efi"]},
                {"name": "nvme0n1p3", "path": "/dev/nvme0n1p3", "type": "part", "fstype": "BitLocker",
                 "label": None, "size": 727000000000, "mountpoints": [None]},
                {"name": "nvme0n1p6", "path": "/dev/nvme0n1p6", "type": "part", "fstype": "ext4",
                 "label": "layerosx", "size": 170000000000, "mountpoints": ["/"]},
                {"name": "nvme0n1p7", "path": "/dev/nvme0n1p7", "type": "part", "fstype": "ntfs",
                 "label": "DATA", "size": 4000000000000, "mountpoints": [None]}]},
            {"name": "sda", "path": "/dev/sda", "type": "disk", "rm": True, "hotplug": True, "tran": "usb",
             "model": "SanDisk 3.2Gen1", "size": 123000000000, "children": [
                {"name": "sda1", "path": "/dev/sda1", "type": "part", "fstype": "exfat",
                 "label": "Ventoy", "size": 123000000000, "mountpoints": [None]},
                {"name": "sda2", "path": "/dev/sda2", "type": "part", "fstype": "vfat",
                 "label": "VTOYEFI", "size": 33554432, "mountpoints": [None]}]},
        ]}
        write(os.path.join(t, "lsblk.json"), __import__("json").dumps(lsblk))
        write(os.path.join(self.bin, "lsblk"), textwrap.dedent(f"""\
            #!/bin/sh
            case "$*" in
              "-ndo PKNAME /dev/nvme0n1p6") echo nvme0n1 ;;
              "-ndbo MODEL,SIZE /dev/nvme0n1") echo "WD PC SN560 SDDPNQE-1T00-1002 1000204886016" ;;
              *) cat {t}/lsblk.json ;;
            esac
            """), x)
        # About: DMI, /proc, lspci, findmnt, VM profile, version file
        write(os.path.join(t, "dmi", "sys_vendor"), "ASUSTeK COMPUTER INC.\n")
        write(os.path.join(t, "dmi", "product_name"), "ASUS TUF Gaming A15 FA507NV_FA507NV\n")
        write(os.path.join(t, "dmi", "product_family"), "ASUS TUF Gaming A15\n")
        write(os.path.join(t, "proc", "cpuinfo"),
              "".join(f"processor\t: {i}\nmodel name\t: AMD Ryzen 7 7735HS with Radeon Graphics\n\n" for i in range(16)))
        write(os.path.join(t, "proc", "meminfo"), "MemTotal:       65218560 kB\n")
        write(os.path.join(self.bin, "lspci"), textwrap.dedent("""\
            #!/bin/sh
            echo '01:00.0 "VGA compatible controller" "NVIDIA Corporation" "AD107M [GeForce RTX 4060 Max-Q / Mobile]" -ra1 "ASUSTeK" "x"'
            echo '05:00.0 "VGA compatible controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Rembrandt [Radeon 680M]" -rc7 "ASUSTeK" "x"'
            echo '00:14.0 "SMBus" "Advanced Micro Devices, Inc. [AMD]" "FCH SMBus Controller" -r71 "" ""'
            """), x)
        write(os.path.join(self.bin, "findmnt"), "#!/bin/sh\necho /dev/nvme0n1p6\n", x)
        write(os.path.join(self.state, "macos-version"), "ventura\n")
        write(os.path.join(self.state, "downloaded-version"), "13.5|22G120\n")
        write(os.path.join(t, "vm-profile"), "cpu_model=Haswell-noTSX\ncores=4\nram_mb=8192\ngfx=reims-vgpu-pci\nmacos=ventura\n")
        write(os.path.join(self.etc, "version"), "version=4cac427\nbuilt=2026-09-24\nmode=release\n")
        self.ps = os.path.join(t, "power")
        write(os.path.join(self.ps, "BAT0", "capacity"), "63\n")
        write(os.path.join(self.ps, "BAT0", "status"), "Discharging\n")
        env = {
            "LAYEROSX_LIB": self.lib, "LAYEROSX_BIN": self.bin, "LAYEROSX_STATE_DIR": self.state,
            "LAYEROSX_ETC_DIR": self.etc, "LAYEROSX_CTL_SOCK": self.sock,
            "LAYEROSX_HOST_ACTION_FILE": os.path.join(t, "host-action"),
            "LAYEROSX_USB_SYSFS": self.usb, "LAYEROSX_POWER_SUPPLY": self.ps,
            "LAYEROSX_DRY_RUN": "0", "LAYEROSX_DMI": os.path.join(t, "dmi"),
            "LAYEROSX_PROC": os.path.join(t, "proc"), "LAYEROSX_NPROC": "16",
            "LAYEROSX_OPENCORE_DIR": os.path.join(t, "opencore"), "LAYEROSX_VM_PROFILE": os.path.join(t, "vm-profile"), "PATH": self.bin + os.pathsep + os.environ["PATH"],
        }
        self._old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)

    def tearDown(self):
        for k, v in self._old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def vm_up(self):
        write(self.sock, "")


class TestSettings(FakeMachine):
    def test_release_defaults(self):
        b = lb.Backend()
        self.assertEqual(b.mode, "release")
        self.assertEqual(b.setting("gfx"), ("reims", False))
        self.assertEqual(b.setting("verbose"), ("off", False))
        self.assertEqual(b.setting("audio"), ("on", False))
        self.assertEqual(b.terminal_policy, "open")   # a password is the user's choice now

    def test_debug_defaults_and_policy_file(self):
        write(os.path.join(self.etc, "mode"), "debug\n")
        b = lb.Backend()
        self.assertEqual(b.setting("gfx"), ("vmware", False))
        self.assertEqual(b.terminal_policy, "open")
        write(os.path.join(self.etc, "terminal"), "off\n")
        self.assertEqual(lb.Backend().terminal_policy, "off")

    def test_set_setting_saves_and_validates(self):
        b = lb.Backend()
        self.assertTrue(b.set_setting("gfx", "vmware")[0])
        self.assertEqual(b.setting("gfx"), ("vmware", True))
        self.assertFalse(b.set_setting("gfx", "voodoo")[0])
        self.assertFalse(b.set_setting("verbose", "maybe")[0])
        self.assertFalse(b.set_setting("rm -rf", "on")[0])
        self.assertIn("gpu vmware", self.calls())

    def test_dry_run_changes_nothing(self):
        os.environ["LAYEROSX_DRY_RUN"] = "1"
        b = lb.Backend()
        b.set_setting("gfx", "vmware")
        b.restart_mac()
        b.host_action("reboot")
        b.set_brightness(50)
        b.usb_set_always("0781", "5583", True, "SanDisk")
        self.assertEqual(self.calls(), [])
        self.assertEqual(b.setting("gfx"), ("reims", False))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "host-action")))
        self.assertEqual(len(b.dry_log), 5)


class TestWifi(FakeMachine):
    def test_current_with_escaped_colon(self):
        self.assertEqual(lb.Backend().wifi_current(), ("Home:5G", 77, False))

    def test_scan_dedup_sort(self):
        nets = lb.Backend().wifi_scan()
        self.assertEqual([n.ssid for n in nets], ["Home:5G", "Neighbour", "Cafe"])
        self.assertTrue(nets[0].connected and nets[0].secure and nets[0].signal == 77)
        self.assertFalse(nets[2].secure)

    def test_radio(self):
        b = lb.Backend()
        self.assertTrue(b.wifi_enabled())
        self.assertTrue(b.set_wifi_enabled(False)[0])
        os.environ["LAYEROSX_DRY_RUN"] = "1"
        d = lb.Backend()
        d.set_wifi_enabled(True)
        self.assertEqual(d.dry_log, ["nmcli radio wifi on"])

    def test_connect_hides_password(self):
        ok, msg = lb.Backend().wifi_connect("Neighbour", "hunter2")
        self.assertTrue(ok)
        self.assertNotIn("hunter2", msg)
        self.assertFalse(lb.Backend().wifi_connect("")[0])


class TestUsb(FakeMachine):
    def test_list_and_blocking(self):
        self.vm_up()
        devs = {d.id: d for d in lb.Backend().usb_devices()}
        self.assertEqual(set(devs), {"0781:5583", "0b05:19b6", "05e3:0610", "3277:0059"})
        self.assertEqual(devs["0781:5583"].blocked, "")
        self.assertTrue(devs["0781:5583"].on_mac)
        self.assertIn("keyboard", devs["0b05:19b6"].blocked)
        self.assertEqual(devs["05e3:0610"].blocked, "hub")
        self.assertTrue(devs["3277:0059"].builtin)

    def test_give_take_always(self):
        b = lb.Backend()
        self.assertFalse(b.usb_give_to_mac("0781", "5583", True)[0])  # VM not running
        self.vm_up()
        self.assertTrue(b.usb_give_to_mac("3277", "0059", True)[0])
        self.assertFalse(b.usb_give_to_mac("0b05", "19b6", True)[0])  # keyboard refused
        self.assertFalse(b.usb_give_to_mac("zz", "0059", True)[0])
        self.assertTrue(b.usb_set_always("3277", "0059", True, "WebCam")[0])
        self.assertIn("3277:0059", b.usb_always_set())
        self.assertTrue(b.usb_give_to_mac("3277", "0059", False)[0])  # detach also forgets
        self.assertNotIn("3277:0059", b.usb_always_set())
        self.assertIn("qmp usb-attach 3277 0059", self.calls())
        self.assertIn("qmp usb-detach 3277 0059", self.calls())

    def _phone(self):
        d = os.path.join(self.usb, "1-4")
        for k, v in (("idVendor", "18d1"), ("idProduct", "4ee7"), ("manufacturer", "Google"),
                     ("product", "Pixel"), ("removable", "removable"), ("bDeviceClass", "00")):
            write(os.path.join(d, k), v + "\n")

    def test_automatic_usb(self):
        self._phone()
        b = lb.Backend()
        self.assertTrue(b.usb_auto())                    # on for a new install
        self.assertEqual(b.usb_auto_once(), [])          # Mac not running: nothing
        self.vm_up()
        # pendrive already on the Mac; keyboard, hub and built-in webcam skipped
        self.assertEqual(b.usb_auto_once(), ["18d1:4ee7"])
        self.assertIn("qmp usb-attach 18d1 4ee7", self.calls())
        # switched back to Linux -> automatic USB leaves it there
        self.assertTrue(b.usb_give_to_mac("18d1", "4ee7", False)[0])
        self.assertEqual(b.usb_keep_on_linux(), {"18d1:4ee7"})
        self.assertEqual(b.usb_auto_once(), [])
        # switched on again -> forgotten from the keep list
        self.assertTrue(b.usb_give_to_mac("18d1", "4ee7", True)[0])
        self.assertEqual(b.usb_keep_on_linux(), set())
        self.assertTrue(b.set_usb_auto(False)[0])
        self.assertFalse(lb.Backend().usb_auto())
        self.assertEqual(lb.Backend().usb_auto_once(), [])
        self.assertTrue(b.set_usb_auto(True)[0])
        self.assertFalse(os.path.exists(os.path.join(self.state, "usb-auto")))


class TestSaveLogs(FakeMachine):
    def test_targets_exclude_system(self):
        t = lb.Backend().log_targets()
        self.assertEqual([x.path for x in t], ["/dev/sda1", "/dev/nvme0n1p7"])  # USB first
        usb, data = t
        self.assertTrue(usb.removable and not data.removable)
        self.assertEqual((usb.title, usb.fstype, usb.mountpoint), ("Ventoy", "exfat", ""))
        self.assertEqual(data.size_text, "4.0 TB")

    def test_save_refuses_unlisted(self):
        b = lb.Backend()
        self.assertFalse(b.save_logs_to("/dev/nvme0n1p6")[0])   # the system root
        self.assertFalse(b.save_logs_to("/dev/sda2")[0])        # VTOYEFI
        self.assertFalse(b.save_logs_to("/etc/shadow")[0])

    def test_save_dry_run(self):
        os.environ["LAYEROSX_DRY_RUN"] = "1"
        b = lb.Backend()
        self.assertTrue(b.save_logs_to("/dev/sda1")[0])
        self.assertIn("/dev/sda1", b.dry_log[-1])


class TestBrightnessScript(FakeMachine):
    """kiosk/lib/brightness.sh against a fake brightnessctl (value in a file)."""
    SCRIPT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "archiso", "airootfs",
                          "opt", "layerosx", "kiosk", "lib", "brightness.sh")

    def setUp(self):
        super().setUp()
        self.val = os.path.join(self.tmp, "bl")
        write(self.val, "40\n")
        write(os.path.join(self.bin, "brightnessctl"), textwrap.dedent(f"""\
            #!/bin/sh
            v=$(cat {self.val})
            for a in "$@"; do case "$a" in
              10%+) v=$((v+10)) ;; 10%-) v=$((v-10)) ;; *%) case "$a" in --*) ;; *) v=${{a%\%}} ;; esac ;;
            esac; done
            [ "$v" -gt 100 ] && v=100; [ "$v" -lt 5 ] && v=5
            echo $v > {self.val}
            case "$*" in *-m*) echo "amdgpu_bl1,backlight,1,$v%,255" ;; esac
            """), stat.S_IRWXU)
        os.environ["LAYEROSX_BRIGHTNESS_DELAY"] = "0"

    def sh(self, *args):
        import subprocess
        return subprocess.run(["bash", self.SCRIPT, *args], capture_output=True, text=True).stdout.strip()

    def saved(self):
        with open(os.path.join(self.state, "brightness")) as f:
            return f.read().strip()

    def test_set_saves_and_restore_reapplies(self):
        self.sh("set", "70")
        self.assertEqual(self.saved(), "70")
        self.sh("down")
        self.assertEqual(self.saved(), "60")
        write(self.val, "100\n")            # e.g. the firmware reset it at boot
        self.sh("restore")
        self.assertEqual(self.sh("get"), "60")

    def test_never_black_and_bad_input(self):
        self.sh("set", "1")
        self.assertEqual(self.saved(), "5")
        self.assertEqual(self.sh("set", "abc"), "")
        self.assertEqual(self.saved(), "5")


class TestResources(FakeMachine):
    def test_auto_rule(self):
        b = lb.Backend()
        # <= 4 threads: all of them; more: threads - 2; power of two; cap 8
        self.assertEqual([b.auto_cores(n) for n in (1, 2, 3, 4, 6, 8, 12, 16, 64)],
                         [1, 2, 2, 4, 4, 4, 8, 8, 8])
        self.assertEqual([b.auto_cores(n, reserve=False) for n in (6, 8, 16)], [4, 8, 8])
        self.assertEqual(b.auto_ram_mb(65218560 // 1024), 55296)   # 64 GB laptop -> 54 GB
        self.assertEqual(b.auto_ram_mb(8032), 4096)

    def test_defaults_and_overrides(self):
        b = lb.Backend()
        r = b.resources()
        self.assertEqual((r.threads, r.cores_auto, r.cores, r.cores_choice, r.reserve), (16, 8, 8, 0, True))
        self.assertEqual(r.cores_choices, [1, 2, 4, 8])
        self.assertEqual(r.ram_mb, r.ram_auto_mb)
        self.assertEqual(max(r.ram_choices_mb), 48 * 1024)      # host 62 GB - 2 GB for Linux
        self.assertTrue(b.set_cores(4)[0])
        self.assertEqual(lb.Backend().resources().cores, 4)
        self.assertFalse(b.set_cores(16)[0])
        self.assertFalse(b.set_cores(3)[0])
        self.assertTrue(b.set_cores("auto")[0])
        self.assertFalse(os.path.exists(os.path.join(self.state, "cpu-cores")))
        self.assertTrue(b.set_ram(16384)[0])
        self.assertEqual(lb.Backend().resources().ram_mb, 16384)
        self.assertFalse(b.set_ram(1024)[0])
        self.assertFalse(b.set_ram(10 ** 7)[0])
        self.assertTrue(b.set_ram("auto")[0])
        self.assertEqual(lb.Backend().resources().ram_choice_mb, 0)

    def test_reserve_toggle(self):
        os.environ["LAYEROSX_NPROC"] = "8"
        b = lb.Backend()
        self.assertEqual(b.resources().cores_auto, 4)
        self.assertTrue(b.set_cpu_reserve(False)[0])
        self.assertEqual(lb.Backend().resources().cores_auto, 8)
        self.assertTrue(b.set_cpu_reserve(True)[0])
        self.assertFalse(os.path.exists(os.path.join(self.state, "cpu-reserve")))

    def test_dual_core_uses_both(self):
        os.environ["LAYEROSX_NPROC"] = "2"
        r = lb.Backend().resources()
        self.assertEqual((r.cores_auto, r.cores_choices), (2, [1, 2]))

    def test_amd_needs_matching_image(self):
        write(os.path.join(self.tmp, "proc", "cpuinfo"), "vendor_id\t: AuthenticAMD\n")
        oc = os.path.join(self.tmp, "opencore")
        write(os.path.join(oc, "OpenCore-amd.qcow2"), "x")
        write(os.path.join(oc, "OpenCore-amd2.qcow2"), "x")
        b = lb.Backend()
        r = b.resources()
        self.assertTrue(r.amd)
        self.assertEqual(r.cores_choices, [2, 4])     # no amd8 image -> 8 not offered
        self.assertEqual((r.cores_auto, r.cores), (4, 4))
        self.assertFalse(b.set_cores(8)[0])
        write(os.path.join(oc, "OpenCore-amd8.qcow2"), "x")
        self.assertEqual(lb.Backend().resources().cores_auto, 8)


def _edid(name):
    """128-byte EDID hex with a monitor-name (0xFC) descriptor at offset 72."""
    raw = bytearray(128)
    raw[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    raw[72:77] = b"\x00\x00\x00\xfc\x00"
    raw[77:90] = (name.encode() + b"\n").ljust(13, b" ")
    h = raw.hex()
    return "".join("\t\t" + h[i:i + 32] + "\n" for i in range(0, len(h), 32))


XRANDR = ("Screen 0: minimum 320 x 200, current 4480 x 1600, maximum 16384 x 16384\n"
          "eDP-1 connected primary 2560x1600+0+0 (normal left inverted right) 344mm x 215mm\n"
          "\tEDID: \n" + _edid("") +
          "\tscaling mode: Full aspect \n"
          "   2560x1600    165.00*+  60.00  \n"
          "HDMI-1-0 connected 1920x1080+2560+0 (normal left inverted right) 527mm x 296mm\n"
          "\tEDID: \n" + _edid("LG ULTRAGEAR") +
          "   1920x1080    144.00*+  60.00    59.94  \n"
          "   1280x720      60.00  \n"
          "DP-1 disconnected (normal left inverted right x axis y axis)\n")


class TestScreens(FakeMachine):
    LIBSRC = os.path.join(os.path.dirname(os.path.dirname(HERE)), "archiso", "airootfs",
                          "opt", "layerosx", "kiosk", "lib")

    def setUp(self):
        super().setUp()
        shutil.copy(os.path.join(self.LIBSRC, "displays.py"), self.lib)
        write(os.path.join(self.tmp, "xrandr.txt"), XRANDR)
        write(os.path.join(self.bin, "xrandr"),
              f'#!/bin/sh\ncase "$*" in "--query --prop") cat {self.tmp}/xrandr.txt ;; '
              f'*) echo "xrandr $*" >> {self.log} ;; esac\n', stat.S_IRWXU)
        write(os.path.join(self.bin, "xdotool"), f'#!/bin/sh\necho "xdotool $*" >> {self.log}\n', stat.S_IRWXU)
        sys.path.insert(0, self.lib)
        import importlib, displays
        self.d = importlib.reload(displays)
        self.d.STATE_DIR = self.state

    def test_list_names_from_edid(self):
        sc = lb.Backend().screens()
        self.assertEqual([(s.name, s.label, s.builtin) for s in sc],
                         [("eDP-1", "Built-in display", True), ("HDMI-1-0", "LG ULTRAGEAR", False)])
        self.assertEqual((sc[1].width, sc[1].height), (1920, 1080))

    def test_settings_validate(self):
        b = lb.Backend()
        self.assertEqual((b.screen_target(), b.screen_others()), ("auto", "off"))
        self.assertTrue(b.set_screen_target("HDMI-1-0")[0])
        self.assertFalse(b.set_screen_target("DP-1")[0])        # not connected
        self.assertTrue(b.set_screen_others("mirror")[0])
        self.assertFalse(b.set_screen_others("extend")[0])
        b2 = lb.Backend()
        self.assertEqual((b2.screen_target(), b2.screen_others()), ("HDMI-1-0", "mirror"))
        self.assertTrue(b.set_screen_target("auto")[0])
        self.assertTrue(b.set_screen_others("off")[0])
        self.assertEqual(os.listdir(self.state), [f for f in os.listdir(self.state)
                                                  if not f.startswith("display-")])

    def test_plan(self):
        outs = self.d.query()
        self.assertEqual(self.d.plan(outs, "", "off"), [])                  # Automatic: hands off
        self.assertEqual(self.d.plan(outs, "HDMI-1-0", "off"),
                         ["--output", "HDMI-1-0", "--auto", "--primary", "--pos", "0x0",
                          "--output", "eDP-1", "--off"])
        self.assertEqual(self.d.plan(outs, "HDMI-1-0", "mirror"),
                         ["--output", "HDMI-1-0", "--auto", "--primary", "--pos", "0x0",
                          "--output", "eDP-1", "--auto", "--same-as", "HDMI-1-0"])
        # already laid out that way -> nothing (no flicker on relaunch)
        done = [dict(o, active=(o["name"] == "HDMI-1-0"), primary=(o["name"] == "HDMI-1-0"),
                     x=0, y=0) for o in outs]
        self.assertEqual(self.d.plan(done, "HDMI-1-0", "off"), [])
        # the chosen screen is unplugged -> light everything up again
        gone = [dict(o, connected=o["name"] != "HDMI-1-0", active=False) for o in outs]
        self.assertEqual(self.d.plan(gone, "HDMI-1-0", "off"), ["--auto"])

    def test_apply_runs_xrandr_and_moves_the_mac(self):
        write(os.path.join(self.state, "display-target"), "HDMI-1-0\n")
        self.d.time.sleep = lambda *_: None
        self.d.apply(quiet=True)
        calls = self.calls()
        self.assertIn("xrandr --output HDMI-1-0 --auto --primary --pos 0x0 --output eDP-1 --off", calls)
        self.assertTrue(any(c.startswith("xdotool mousemove") for c in calls))


class TestAutomaticScreen(TestScreens):
    def test_automatic_follows_an_external_screen(self):
        self.d.LAST_PLUGGED = os.path.join(self.tmp, "last-plugged")
        outs = self.d.query()                       # eDP-1 + HDMI-1-0 connected
        self.assertEqual(self.d.effective_target(outs, ""), "HDMI-1-0")
        self.assertEqual(self.d.effective_target(outs, "eDP-1"), "eDP-1")   # a choice wins
        unplugged = [dict(o, connected=o["connected"] and o["name"] != "HDMI-1-0") for o in outs]
        self.assertEqual(self.d.effective_target(unplugged, ""), "eDP-1")    # back to the laptop screen
        dp = dict(outs[1], name="DP-2", label="DisplayPort")
        three = outs + [dp]
        self.assertEqual(self.d.effective_target(three, ""), "HDMI-1-0")    # first external by default
        write(self.d.LAST_PLUGGED, "DP-2\n")
        self.assertEqual(self.d.effective_target(three, ""), "DP-2")        # ... unless one was plugged last
        desktop = [dict(o, builtin=False) for o in outs]
        self.assertEqual(self.d.effective_target(desktop, ""), "")          # no built-in screen: hands off

    def test_unplugged_screen_in_use(self):
        outs = self.d.query()
        # The Mac was on HDMI, laptop screen off; HDMI is pulled out but X still
        # has it laid out (active, disconnected).
        pulled = [dict(o, connected=o["connected"] and o["name"] != "HDMI-1-0",
                       active=o["name"] == "HDMI-1-0", primary=o["name"] == "HDMI-1-0") for o in outs]
        t = self.d.effective_target(pulled, "")
        self.assertEqual(t, "eDP-1")
        self.assertEqual(self.d.plan(pulled, t, "off"),
                         ["--output", "HDMI-1-0", "--off",
                          "--output", "eDP-1", "--auto", "--primary", "--pos", "0x0"])
        # a fixed choice that got unplugged: light everything, drop the dead one
        self.assertEqual(self.d.plan(pulled, "HDMI-1-0", "off"), ["--auto"])
        # hands-off (desktop, no built-in) still clears the dead monitor
        desk = [dict(o, builtin=False) for o in pulled]
        self.assertEqual(self.d.plan(desk, self.d.effective_target(desk, ""), "off"),
                         ["--output", "HDMI-1-0", "--off"])

    def test_apply_on_automatic_moves_the_mac_and_refullscreens_it(self):
        self.d.LAST_PLUGGED = os.path.join(self.tmp, "last-plugged")
        self.d.time.sleep = lambda *_: None
        write(os.path.join(self.bin, "xdotool"),
              f'#!/bin/sh\necho "xdotool $*" >> {self.log}\n'
              f'[ "$1" = search ] && echo 4242\nexit 0\n', stat.S_IRWXU)
        self.d.apply(quiet=True)
        calls = self.calls()
        self.assertIn("xrandr --output HDMI-1-0 --auto --primary --pos 0x0 --output eDP-1 --off", calls)
        self.assertIn("xdotool windowstate --remove FULLSCREEN 4242", calls)
        self.assertIn("xdotool windowstate --add FULLSCREEN 4242", calls)


class TestModesAndGpu(TestScreens):
    def test_modes_listed(self):
        sc = {x.name: x for x in lb.Backend().screens()}
        h = sc["HDMI-1-0"]
        self.assertEqual((h.preferred, h.rate), ("1920x1080", 144.0))
        self.assertEqual(h.modes, [{"size": "1920x1080", "rates": [144.0, 60.0, 59.94]},
                                   {"size": "1280x720", "rates": [60.0]}])
        self.assertEqual(sc["eDP-1"].modes[0], {"size": "2560x1600", "rates": [165.0, 60.0]})

    def test_set_mode_validates_and_saves(self):
        b = lb.Backend()
        self.assertTrue(b.set_screen_mode("HDMI-1-0", "1920x1080", 60.0)[0])
        self.assertEqual(lb.Backend().screen_mode("HDMI-1-0"), ("1920x1080", 60.0))
        self.assertFalse(b.set_screen_mode("HDMI-1-0", "3840x2160", None)[0])
        self.assertFalse(b.set_screen_mode("HDMI-1-0", "1280x720", 144.0)[0])
        self.assertFalse(b.set_screen_mode("DP-1", "1920x1080", None)[0])
        self.assertTrue(b.set_screen_mode("HDMI-1-0", None, None)[0])
        self.assertFalse(os.path.exists(os.path.join(self.state, "display-modes")))

    def test_plan_with_modes(self):
        outs = self.d.query()
        # Automatic layout + a fixed rate on the (active) laptop panel
        self.assertEqual(self.d.plan(outs, "", "off", {"eDP-1": {"size": None, "rate": 60.0}}),
                         ["--output", "eDP-1", "--mode", "2560x1600", "--rate", "60.00"])
        # already at that mode -> nothing
        self.assertEqual(self.d.plan(outs, "", "off", {"HDMI-1-0": {"size": "1920x1080", "rate": None}}), [])
        # chosen screen + fixed mode: --auto replaced by the mode, others off
        self.assertEqual(self.d.plan(outs, "HDMI-1-0", "off", {"HDMI-1-0": {"size": "1280x720", "rate": None},
                                                                 "eDP-1": {"size": None, "rate": 60.0}}),
                         ["--output", "HDMI-1-0", "--primary", "--pos", "0x0", "--mode", "1280x720",
                          "--rate", "60.00", "--output", "eDP-1", "--off"])
        # a mode the screen doesn't have is ignored
        self.assertEqual(self.d.plan(outs, "", "off", {"HDMI-1-0": {"size": "800x600", "rate": None}}), [])

    def test_reims_gpus_from_icds(self):
        icd = os.path.join(self.tmp, "icd.d")
        for fn in ("nvidia_icd.json", "radeon_icd.x86_64.json", "lvp_icd.x86_64.json", "intel_icd.x86_64.json"):
            write(os.path.join(icd, fn), "{}")
        os.environ["LAYEROSX_VK_ICD_DIRS"] = icd
        try:
            b = lb.Backend()
            gpus = b.reims_gpus()
            # llvmpipe skipped; Intel skipped (no Intel GPU in lspci)
            self.assertEqual([(g.id, g.label, g.driver) for g in gpus],
                             [("nvidia_icd.json", "NVIDIA GeForce RTX 4060 Max-Q / Mobile", "NVIDIA driver"),
                              ("radeon_icd.x86_64.json", "AMD Radeon 680M", "RADV (Mesa)")])
            self.assertEqual(b.reims_gpu(), "auto")
            self.assertTrue(b.set_reims_gpu("radeon_icd.x86_64.json")[0])
            self.assertEqual(lb.Backend().reims_gpu(), "radeon_icd.x86_64.json")
            self.assertFalse(b.set_reims_gpu("intel_icd.x86_64.json")[0])
            self.assertTrue(b.set_reims_gpu("auto")[0])
            self.assertFalse(os.path.exists(os.path.join(self.state, "reims-gpu")))
        finally:
            os.environ.pop("LAYEROSX_VK_ICD_DIRS", None)


class TestAudioOutputs(FakeMachine):
    def _asound(self):
        a = os.path.join(self.tmp, "proc", "asound")
        write(os.path.join(a, "cards"),
              " 0 [Generic        ]: HDA-Intel - HD-Audio Generic\n"
              "                      HD-Audio Generic at 0xd0ac8000 irq 91\n"
              " 1 [Generic_1      ]: HDA-Intel - HD-Audio Generic\n"
              "                      HD-Audio Generic at 0xd0ac0000 irq 92\n")
        write(os.path.join(a, "card0", "id"), "Generic\n")
        write(os.path.join(a, "card1", "id"), "Generic_1\n")
        write(os.path.join(a, "card0", "pcm3p", "info"), "card: 0\ndevice: 3\nid: HDMI 0\nname: HDMI 0\n")
        write(os.path.join(a, "card1", "pcm0p", "info"), "card: 1\ndevice: 0\nid: ALC256 Analog\nname: ALC256 Analog\n")
        write(os.path.join(a, "card1", "pcm0c", "info"), "card: 1\ndevice: 0\nid: ALC256 Analog\n")

    def test_hdmi_card_zero_is_not_the_default(self):
        self._asound()
        b = lb.Backend()
        outs = b.audio_outputs()
        # capture PCMs ignored; speakers first even though HDMI is card 0
        self.assertEqual([(o.id, o.hdmi, o.alsa) for o in outs],
                         [("Generic_1:0", False, "plughw:CARD=Generic_1,DEV=0"),
                          ("Generic:3", True, "plughw:CARD=Generic,DEV=3")])
        self.assertEqual(b.audio_output(), "auto")
        self.assertEqual(b.audio_output_now().id, "Generic_1:0")
        self.assertTrue(b.set_audio_output("Generic:3")[0])
        self.assertEqual(lb.Backend().audio_output_now().alsa, "plughw:CARD=Generic,DEV=3")
        self.assertFalse(b.set_audio_output("Nope:0")[0])
        self.assertTrue(b.set_audio_output("auto")[0])
        self.assertFalse(os.path.exists(os.path.join(self.state, "audio-output")))

    def test_saved_output_gone_falls_back(self):
        self._asound()
        write(os.path.join(self.state, "audio-output"), "USB:0\n")
        self.assertEqual(lb.Backend().audio_output_now().id, "Generic_1:0")

    def _fake_amixer(self, controls=("Master", "PCM", "Speaker")):
        # State in files: <tmp>/mix/<control> = "pct on|off"; logs every call.
        mix = os.path.join(self.tmp, "mix")
        os.makedirs(mix, exist_ok=True)
        for c in controls:
            write(os.path.join(mix, c), "0 off")
        write(os.path.join(self.bin, "amixer"), textwrap.dedent(f"""\
            #!/usr/bin/env python3
            import os, sys
            mix = {mix!r}
            open(os.path.join(mix, "calls"), "a").write(" ".join(sys.argv[1:]) + "\\n")
            a = [x for x in sys.argv[1:] if x != "-q"]
            card, cmd, rest = a[1], a[2], a[3:]
            if cmd == "scontrols":
                for c in sorted(os.listdir(mix)):
                    if c != "calls":
                        print(f"Simple mixer control '{{c}}',0")
                sys.exit(0)
            p = os.path.join(mix, rest[0])
            if not os.path.exists(p):
                sys.exit(1)
            pct, sw = open(p).read().split()
            if cmd == "sget":
                print(f"  Front Left: Playback 50 [{{pct}}%] [-10.00dB] [{{sw}}]")
                sys.exit(0)
            for x in rest[1:]:
                if x.endswith("%"): pct = x[:-1]
                elif x == "mute": sw = "off"
                elif x == "unmute": sw = "on"
            open(p, "w").write(f"{{pct}} {{sw}}")
            """))
        os.chmod(os.path.join(self.bin, "amixer"), 0o755)
        return mix

    def test_volume_live_and_saved(self):
        self._asound()
        mix = self._fake_amixer()
        b = lb.Backend()
        self.assertEqual(b.volume(), (0, True))
        # launch: path opened fully, Master at the default level, unmuted
        self.assertTrue(b.apply_volume()[0])
        self.assertEqual(open(os.path.join(mix, "Speaker")).read(), "100 on")
        self.assertEqual(open(os.path.join(mix, "PCM")).read(), "100 on")
        self.assertEqual(b.volume(), (lb.Backend.VOLUME_DEFAULT, False))
        self.assertIn("-c 1", open(os.path.join(mix, "calls")).read())   # the speakers' card, not HDMI card 0
        self.assertTrue(b.set_volume(35)[0])
        self.assertTrue(b.set_volume(muted=True)[0])
        self.assertEqual(b.volume(), (35, True))
        self.assertEqual(lb.Backend().saved_volume(), (35, True))
        self.assertTrue(b.set_volume(150, muted=False)[0])
        self.assertEqual(b.volume(), (100, False))
        # next launch restores the saved level
        write(os.path.join(mix, "Master"), "0 off")
        lb.Backend().apply_volume()
        self.assertEqual(b.volume(), (100, False))

    def test_volume_keys_cli(self):
        self._asound()
        self._fake_amixer()
        b = lb.Backend()
        b.set_volume(50, muted=False)
        self.assertEqual(lb.main(["x", "volume", "up"]), 0)
        self.assertEqual(b.volume(), (55, False))
        self.assertEqual(lb.main(["x", "volume", "mute"]), 0)
        self.assertEqual(b.volume(), (55, True))
        self.assertEqual(lb.main(["x", "volume", "down"]), 0)   # a volume key also unmutes
        self.assertEqual(b.volume(), (50, False))

    def test_output_without_mixer_has_no_volume(self):
        self._asound()
        self._fake_amixer(controls=("IEC958",))
        b = lb.Backend()
        self.assertIsNone(b.volume())
        self.assertFalse(b.set_volume(50)[0])

    def test_no_sound_card(self):
        self.assertEqual(lb.Backend().audio_outputs(), [])
        self.assertIsNone(lb.Backend().audio_output_now())


class TestPerformance(FakeMachine):
    def test_fps_from_reims_loop_census(self):
        log = os.path.join(self.tmp, "reims-fail.log")
        lines = ["OFF m2v refused_by=m2v_vertex_translate\n"]
        lines += [f"OFF host_window_loop win_ms=1000 ticks=90 redraws_asked=31 draws=31 "
                  f"draws_fresh={n} draws_stale=1 draws_held=0\n" for n in [5] * 5 + [30] * 10]
        write(os.path.join(log), "".join(lines))
        os.environ["LAYEROSX_REIMS_FAIL_LOG"] = log
        try:
            b = lb.Backend()
            self.assertEqual(b.mac_fps(), 30.0)          # last 10 s only
            self.assertEqual(b.mac_fps(seconds=15), 21.7)
            os.utime(log, (1, 1))                        # stale log: Mac stopped
            self.assertIsNone(b.mac_fps())
            os.environ["LAYEROSX_REIMS_FAIL_LOG"] = os.path.join(self.tmp, "none.log")
            self.assertIsNone(lb.Backend().mac_fps())
        finally:
            os.environ.pop("LAYEROSX_REIMS_FAIL_LOG", None)

    def test_window_effects_switch(self):
        b = lb.Backend()
        self.assertTrue(b.effects())
        self.assertTrue(b.set_effects(False)[0])
        self.assertEqual(open(os.path.join(self.state, "compositor")).read().strip(), "off")
        self.assertFalse(lb.Backend().effects())
        self.assertTrue(b.set_effects(True)[0])
        self.assertFalse(os.path.exists(os.path.join(self.state, "compositor")))


class TestPowerMode(FakeMachine):
    def test_modes_via_the_root_helper(self):
        real = os.path.join(os.path.dirname(__file__), "..", "..", "archiso", "airootfs",
                            "opt", "layerosx", "kiosk", "lib", "power-mode.sh")
        write(os.path.join(self.lib, "power-mode.sh"), open(real).read(), stat.S_IRWXU)
        write(os.path.join(self.bin, "sudo"), '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n', stat.S_IRWXU)
        cpu = os.path.join(self.tmp, "cpufreq")
        for i in (0, 1):
            d = os.path.join(cpu, f"policy{i}")
            write(os.path.join(d, "scaling_available_governors"), "performance powersave\n")
            write(os.path.join(d, "scaling_governor"), "powersave\n")
            write(os.path.join(d, "scaling_driver"), "amd-pstate-epp\n")
            write(os.path.join(d, "energy_performance_available_preferences"),
                  "default performance balance_performance balance_power power\n")
            write(os.path.join(d, "energy_performance_preference"), "balance_performance\n")
        pp = os.path.join(self.tmp, "platform_profile")
        write(pp, "balanced\n")
        write(pp + "_choices", "quiet balanced performance\n")
        env = {"LAYEROSX_CPUFREQ": cpu, "LAYEROSX_PLATFORM_PROFILE": pp,
               "LAYEROSX_POWER_RUN": os.path.join(self.tmp, "power-run")}
        os.environ.update(env)
        try:
            b = lb.Backend()
            self.assertEqual(b.power_mode(), "auto")
            rd = lambda *p: open(os.path.join(*p)).read().strip()
            # the fake machine has a battery; put it on the charger
            write(os.path.join(self.ps, "AC0", "type"), "Mains\n")
            write(os.path.join(self.ps, "AC0", "online"), "1\n")
            self.assertTrue(b.set_power_mode("auto")[0])
            st = b.power_status()
            self.assertEqual((st["effective"], st["on_ac"]), ("performance", "yes"))
            self.assertEqual(rd(cpu, "policy1", "scaling_governor"), "performance")
            self.assertEqual(rd(pp), "performance")
            self.assertTrue(b.set_power_mode("power-saver")[0])
            self.assertEqual(lb.Backend().power_mode(), "power-saver")
            self.assertEqual(rd(cpu, "policy0", "scaling_governor"), "powersave")
            self.assertEqual(rd(cpu, "policy0", "energy_performance_preference"), "power")
            self.assertEqual(rd(pp), "quiet")
            self.assertFalse(b.set_power_mode("turbo")[0])
            self.assertTrue(b.set_power_mode("auto")[0])
            self.assertEqual(b.power_mode(), "auto")
            write(os.path.join(self.ps, "AC0", "online"), "0\n")      # unplugged -> Balanced
            self.assertTrue(b.set_power_mode("auto")[0])
            self.assertEqual(rd(cpu, "policy0", "energy_performance_preference"), "balance_performance")
            self.assertEqual(rd(pp), "balanced")
        finally:
            for k in env:
                os.environ.pop(k, None)


class TestReimsRamCap(FakeMachine):
    def test_auto_ram_stays_under_the_gpu_import_heap(self):
        b = lb.Backend()
        host = b.resources().host_ram_mb
        # gfx defaults to reims: without a learned budget, 70% of the host
        self.assertEqual(b.ram_cap_mb(63641), 44032)
        write(os.path.join(self.state, "reims-import-budget"), "47645 auto\n")
        self.assertEqual(lb.Backend().ram_cap_mb(63641), 46080)
        r = lb.Backend().resources()
        self.assertLessEqual(r.ram_auto_mb, r.ram_cap_mb)
        self.assertEqual(r.ram_mb, r.ram_auto_mb)
        # a budget learned on another GPU choice doesn't apply
        write(os.path.join(self.state, "reims-gpu"), "nvidia_icd.json\n")
        self.assertEqual(lb.Backend().ram_cap_mb(63641), 44032)
        # not on Reims: no cap
        write(os.path.join(self.state, "gfx"), "vmware\n")
        self.assertEqual(lb.Backend().ram_cap_mb(63641), 0)
        self.assertEqual(lb.Backend().resources().ram_auto_mb, lb.Backend.auto_ram_mb(host))


class TestDebugToggles(FakeMachine):
    def test_detailed_logs_and_text_consoles(self):
        lock = os.path.join(self.tmp, "10-layerosx-kiosk-lock.conf")
        write(lock, "locked")
        os.environ["LAYEROSX_VTLOCK_FILE"] = lock
        try:
            b = lb.Backend()
            self.assertFalse(b.diag_logs())
            self.assertTrue(b.set_diag_logs(True)[0])
            self.assertTrue(lb.Backend().diag_logs())
            self.assertTrue(b.set_diag_logs(False)[0])
            self.assertFalse(os.path.exists(os.path.join(self.state, "diag-logs")))
            # consoles: saved choice vs what the running session has
            self.assertEqual((b.text_consoles(), b.text_consoles_now()), (False, False))
            self.assertTrue(b.set_text_consoles(True)[0])
            self.assertEqual((lb.Backend().text_consoles(), b.text_consoles_now()), (True, False))
            os.remove(lock)                                    # what vt-lock.sh does at boot
            self.assertTrue(b.text_consoles_now())
            self.assertTrue(b.set_text_consoles(False)[0])
            self.assertFalse(os.path.exists(os.path.join(self.state, "vt-switch")))
        finally:
            os.environ.pop("LAYEROSX_VTLOCK_FILE", None)


class TestVtLockScript(FakeMachine):
    SCRIPT = os.path.join(os.path.dirname(os.path.dirname(HERE)), "archiso", "airootfs",
                          "opt", "layerosx", "kiosk", "lib", "vt-lock.sh")

    def test_writes_or_removes_the_xorg_lock(self):
        import subprocess
        conf = os.path.join(self.tmp, "x", "10-layerosx-kiosk-lock.conf")
        with open(self.SCRIPT) as f:
            body = f.read().replace("/etc/X11/xorg.conf.d/10-layerosx-kiosk-lock.conf", conf)
        script = os.path.join(self.tmp, "vt-lock.sh")
        write(script, body)
        run = lambda: subprocess.run(["bash", script], capture_output=True, text=True,
                                     env=dict(os.environ, LAYEROSX_STATE_DIR=self.state)).stdout
        self.assertIn("locked", run())
        with open(conf) as f:
            self.assertIn('Option "DontVTSwitch" "on"', f.read())
        write(os.path.join(self.state, "vt-switch"), "on\n")
        self.assertIn("ENABLED", run())
        self.assertFalse(os.path.exists(conf))


class TestMacModel(FakeMachine):
    def test_default_choice_and_validation(self):
        b = lb.Backend()
        self.assertEqual((b.mac_model_default(), b.mac_model()), ("iMac19,1", "iMac19,1"))   # old ISO
        write(os.path.join(self.etc, "mac-model"), "MacBookPro16,2\n")
        self.assertEqual(lb.Backend().mac_model(), "MacBookPro16,2")
        self.assertTrue(b.set_mac_model("MacPro7,1")[0])
        self.assertEqual(lb.Backend().mac_model(), "MacPro7,1")
        self.assertFalse(b.set_mac_model("MacBookAir9,1")[0])
        self.assertFalse(b.set_mac_model("x;rm -rf /")[0])
        self.assertTrue(b.set_mac_model("MacBookPro16,2")[0])            # back to the default
        self.assertFalse(os.path.exists(os.path.join(self.state, "mac-model")))
        write(os.path.join(self.state, "mac-model"), "garbage\n")
        self.assertEqual(lb.Backend().mac_model(), "MacBookPro16,2")


class TestMaintenancePassword(FakeMachine):
    def test_set_check_change_remove(self):
        b = lb.Backend()
        self.assertFalse(b.maint_password_set())
        self.assertFalse(b.check_maint_password(""))
        self.assertFalse(b.set_maint_password("abc")[0])                 # too short
        self.assertTrue(b.set_maint_password("hunter22")[0])
        f = os.path.join(self.state, "maint-password")
        self.assertEqual(stat.S_IMODE(os.stat(f).st_mode), 0o600)
        with open(f) as fh:
            rec = fh.read()
        self.assertTrue(rec.startswith("scrypt$") and "hunter22" not in rec)
        b2 = lb.Backend()
        self.assertTrue(b2.maint_password_set())
        self.assertTrue(b2.check_maint_password("hunter22"))
        self.assertFalse(b2.check_maint_password("hunter2"))
        self.assertFalse(b2.set_maint_password("newpass1", current="wrong")[0])
        self.assertTrue(b2.set_maint_password("newpass1", current="hunter22")[0])
        self.assertTrue(lb.Backend().check_maint_password("newpass1"))
        self.assertFalse(b2.set_maint_password("", current="hunter22")[0])
        self.assertTrue(b2.set_maint_password("", current="newpass1")[0])
        self.assertFalse(os.path.exists(f))

    def test_cli_for_shell_scripts(self):
        import subprocess
        cli = lambda pw: subprocess.run([sys.executable, lb.__file__, "check-maint-password"],
                                        input=pw + "\n", capture_output=True, text=True).returncode
        self.assertEqual(cli("x"), 2)                                      # none set
        lb.Backend().set_maint_password("s3cret!")
        self.assertEqual((cli("s3cret!"), cli("nope")), (0, 1))

    def test_terminal_skips_the_prompt_when_unlocked_in_the_panel(self):
        os.environ["LAYEROSX_DRY_RUN"] = "1"
        try:
            b = lb.Backend()
            b.open_terminal()
            self.assertIn("peek-terminal.sh", b.dry_log[-1])           # no password set
            b2 = lb.Backend()
            b2.dry_run = False
            b2.set_maint_password("s3cret!")
            b2.dry_run = True
            b2.open_terminal()
            self.assertIn("maint-terminal.sh", b2.dry_log[-1])         # asks
            b2.open_terminal(unlocked=True)
            self.assertIn("peek-terminal.sh", b2.dry_log[-1])          # already unlocked
        finally:
            os.environ["LAYEROSX_DRY_RUN"] = "0"


class TestTheme(FakeMachine):
    def test_theme_default_save_env(self):
        os.environ.pop("LAYEROSX_PANEL_THEME", None)
        b = lb.Backend()
        self.assertEqual(b.panel_theme(), "light")
        self.assertTrue(b.set_panel_theme("dark")[0])
        self.assertEqual(lb.Backend().panel_theme(), "dark")
        self.assertFalse(b.set_panel_theme("neon")[0])
        os.environ["LAYEROSX_PANEL_THEME"] = "light"
        self.assertEqual(lb.Backend().panel_theme(), "light")
        os.environ.pop("LAYEROSX_PANEL_THEME")


class TestAbout(FakeMachine):
    def test_about_real_machine_fields(self):
        a = lb.Backend().about()
        self.assertEqual(a.machine, "ASUS TUF Gaming A15 FA507NV")
        self.assertEqual(a.cpu, "AMD Ryzen 7 7735HS with Radeon Graphics")
        self.assertEqual(a.cpu_threads, 16)
        self.assertEqual(a.memory_gb, 62.2)
        self.assertEqual(a.gpus, ["NVIDIA GeForce RTX 4060 Max-Q / Mobile", "AMD Radeon 680M"])
        self.assertEqual(a.storage, "WD PC SN560 SDDPNQE-1T00-1002 · 1000 GB")
        self.assertEqual(a.macos, "macOS Ventura 13.5 (22G120)")
        self.assertEqual((a.vm_cpu, a.vm_cores, a.vm_ram_gb, a.vm_graphics),
                         ("Haswell-noTSX", 4, 8.0, "Reims (accelerated)"))
        self.assertEqual((a.layerosx_version, a.built), ("4cac427", "2026-09-24"))
        self.assertEqual((a.vm_disk_gb, a.vm_disk_grown_from), (0, 0))

    def test_about_disk(self):
        write(os.path.join(self.state, "macos.qcow2"), "")
        write(os.path.join(self.bin, "qemu-img"), '#!/bin/sh\necho \'{"virtual-size": 256698499072}\'\n', stat.S_IRWXU)
        write(os.path.join(self.state, "disk-grown"), "from_gb=128\nto_gb=239\n")
        a = lb.Backend().about()
        self.assertEqual((a.vm_disk_gb, a.vm_disk_grown_from), (239, 128))
        self.assertTrue(a.creator and a.thanks)

    def test_name_cleanup(self):
        self.assertEqual(lb._machine_name("LENOVO", "ThinkPad X1", "21CB"), "LENOVO ThinkPad X1 21CB")
        self.assertEqual(lb._machine_name("Micro-Star International Co., Ltd.", "", "MSI Katana"), "MSI Katana")
        self.assertEqual(lb._machine_name("System manufacturer", "", "System Product Name"),
                         "System manufacturer")
        self.assertEqual(lb._gpu_name("Intel Corporation", "Alder Lake-P GT2 [Iris Xe Graphics]"),
                         "Intel Iris Xe Graphics")

    def test_about_before_install(self):
        os.remove(os.path.join(self.state, "macos-version"))
        os.remove(os.path.join(self.state, "downloaded-version"))
        os.remove(os.path.join(self.tmp, "vm-profile"))
        a = lb.Backend().about()
        self.assertEqual(a.macos, "Not installed yet")
        self.assertEqual(a.vm_cores, 0)


class TestPowerAndStatus(FakeMachine):
    def test_battery_and_status(self):
        b = lb.Backend()
        self.assertEqual(b.battery(), (63, "Discharging"))
        s = b.status()
        self.assertEqual((s.wifi_ssid, s.battery_percent, s.gfx, s.vm_running),
                         ("Home:5G", 63, "reims", False))

    def test_no_battery(self):
        os.environ["LAYEROSX_POWER_SUPPLY"] = os.path.join(self.tmp, "nope")
        self.assertEqual(lb.Backend().battery(), (None, ""))

    def test_host_action(self):
        self.vm_up()
        b = lb.Backend()
        spawned = []
        b._spawn = spawned.append
        self.assertTrue(b.host_action("reboot")[0])
        with open(os.path.join(self.tmp, "host-action")) as f:
            self.assertEqual(f.read(), "reboot\n")
        self.assertIn("qmp quit", self.calls())
        self.assertIn("systemctl reboot", spawned[0][-1])
        self.assertFalse(b.host_action("format-disk")[0])

    def test_restart_and_diag(self):
        b = lb.Backend()
        self.assertTrue(b.restart_mac()[0])
        self.assertIn("relaunch", self.calls())
        self.assertTrue(b.save_diagnostics()[0])


if __name__ == "__main__":
    unittest.main()
