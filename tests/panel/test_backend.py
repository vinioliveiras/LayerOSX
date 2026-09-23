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
        self.ps = os.path.join(t, "power")
        write(os.path.join(self.ps, "BAT0", "capacity"), "63\n")
        write(os.path.join(self.ps, "BAT0", "status"), "Discharging\n")
        env = {
            "LAYEROSX_LIB": self.lib, "LAYEROSX_BIN": self.bin, "LAYEROSX_STATE_DIR": self.state,
            "LAYEROSX_ETC_DIR": self.etc, "LAYEROSX_CTL_SOCK": self.sock,
            "LAYEROSX_HOST_ACTION_FILE": os.path.join(t, "host-action"),
            "LAYEROSX_USB_SYSFS": self.usb, "LAYEROSX_POWER_SUPPLY": self.ps,
            "LAYEROSX_DRY_RUN": "0", "PATH": self.bin + os.pathsep + os.environ["PATH"],
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
