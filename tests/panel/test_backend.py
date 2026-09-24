"""Unit tests for layerosx_backend.py with a fake machine (no root, no VM).

Run: python3 -m unittest discover -s tests   (from the panel directory, or
tools/test-panel-backend.sh from the repo root).
"""
import os
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
        self.assertEqual(b.terminal_policy, "password")

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
