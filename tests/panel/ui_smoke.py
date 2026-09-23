"""Headless UI smoke test (needs a display, e.g. Xvfb): opens every section,
drives the widgets like a user would and checks the backend saw it."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "archiso", "airootfs", "opt", "layerosx", "panel"))
import layerosx_panel as P
from gi.repository import GLib, Adw

results = []

def check(name, cond):
    results.append((name, bool(cond)))

def script(win):
    b = win.b
    for sid, *_ in P.SECTIONS:
        win.select(sid)
        check(f"page {sid} built", sid in win.pages)
    win.select("displays")
    win.gfx_checks["vmware"].set_active(True)
    check("gfx saved vmware", b.setting("gfx") == ("vmware", True))
    check("restart banner shown", win.banner.get_revealed())
    win.select("sound")
    win.audio_row.set_active(False)
    check("audio off saved", b.setting("audio") == ("off", True))
    win.select("mac")
    win.verbose_row.set_active(True)
    check("verbose on saved", b.setting("verbose") == ("on", True))
    ok, _ = b.usb_set_always("0781", "5583", True, "SanDisk")
    check("usb always", "0781:5583" in b.usb_always_set())
    win.select("wifi")
    def later():
        check("wifi rows listed", len(win._wifi_rows) >= 3)
        check("sidebar status", "Home:5G" in win.side_status.get_label())
        win.get_application().quit()
        return False
    GLib.timeout_add(2500, later)
    return False

app = P.App()
orig = P.Settings.__init__
def patched(self, *a, **k):
    orig(self, *a, **k)
    GLib.timeout_add(800, lambda: script(self))
P.Settings.__init__ = patched
app.run([sys.argv[0]])
for n, ok in results:
    print(("PASS " if ok else "FAIL ") + n)
sys.exit(0 if all(ok for _, ok in results) else 1)
