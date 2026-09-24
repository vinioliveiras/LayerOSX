#!/usr/bin/env python3
"""
LayerOSX Settings (Ctrl+Alt+W): a simplified, System-Settings-style window --
a sidebar of sections with coloured icon badges and a content pane of rounded
cards -- built with GTK4/libadwaita.

Sections: Wi-Fi, Battery, Displays (brightness + graphics adapter), Sound,
USB Devices, Mac (status, boot log, restart), General (power, maintenance,
about). Everything it shows or changes goes through layerosx_backend.Backend,
the same fixed allow-list the future in-macOS app will use via a host helper;
this file is only the front-end. Blocking work runs in worker threads.

Runs in the kiosk's X session (openbox pins windows titled "LayerOSX*" above
the fullscreen VM). No D-Bus session bus there, so the app is NON_UNIQUE and a
lock file keeps it single-instance. LAYEROSX_DRY_RUN=1 (tools/preview-panel.sh)
turns changing actions into "would run ..." toasts. LAYEROSX_PANEL_PAGE=<id>
opens a given section (screenshots/tests).
"""
import fcntl
import os
import sys
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from layerosx_backend import Backend  # noqa: E402
from layerosx_style import apply_theme, install_css, traffic_lights  # noqa: E402

APP_ID = "org.layerosx.Settings"
REFRESH_SECONDS = 5

# Sidebar sections: id, title, icon, badge colour class
SECTIONS = [
    ("wifi", "Wi-Fi", "network-wireless-symbolic", "blue"),
    ("battery", "Battery", "battery-full-symbolic", "green"),
    ("displays", "Displays", "display-brightness-symbolic", "blue"),
    ("sound", "Sound", "audio-volume-high-symbolic", "pink"),
    ("usb", "USB Devices", "media-removable-symbolic", "orange"),
    ("mac", "Mac", "computer-symbolic", "graphite"),
    ("general", "General", "emblem-system-symbolic", "gray"),
    ("terminal", "Terminal", "utilities-terminal-symbolic", "black"),
    ("about", "About", "help-about-symbolic", "gray"),
]

CSS = b"""
.badge { border-radius: 7px; padding: 4px; color: white; }
.badge-blue { background: #0a84ff; }
.badge-green { background: #30d158; }
.badge-pink { background: #ff375f; }
.badge-orange { background: #ff9f0a; }
.badge-graphite { background: #636366; }
.badge-gray { background: #8e8e93; }
.badge-black { background: #1c1c1e; box-shadow: inset 0 0 0 1px rgba(255,255,255,.18); }
.badge-big { border-radius: 10px; padding: 8px; }
.dot { border-radius: 99px; min-width: 9px; min-height: 9px; }
.dot-green { background: #30d158; }
.dot-yellow { background: #ffd60a; }
.dot-gray { background: #8e8e93; }
.sidebar-status { padding: 10px 12px 4px 12px; }
.sidebar-status .title { font-weight: 700; }
.sidebar-status .sub { opacity: .65; font-size: .9em; }
.pane-title { font-weight: 800; font-size: 1.35em; }
.about-name { font-weight: 800; font-size: 2em; }
.about-version { opacity: .6; }
.about-hero { margin: 8px 0 4px 0; }
.about-icon { border-radius: 22px; padding: 18px; }
.about-credit { font-weight: 700; }
"""


def run_async(work, done):
    """Run work() in a thread, then done(result) on the GTK main loop."""
    def target():
        try:
            res = work()
        except Exception as exc:  # keep the UI alive whatever happens
            res = exc
        GLib.idle_add(done, res)
    threading.Thread(target=target, daemon=True).start()


def badge(icon, color, big=False):
    img = Gtk.Image.new_from_icon_name(icon)
    img.set_pixel_size(28 if big else 16)
    box = Gtk.Box(css_classes=["badge", f"badge-{color}"] + (["badge-big"] if big else []),
                  valign=Gtk.Align.CENTER, halign=Gtk.Align.CENTER)
    box.append(img)
    return box


def dot(color):
    return Gtk.Box(css_classes=["dot", f"dot-{color}"], valign=Gtk.Align.CENTER)


def wifi_icon(signal):
    for lim, name in ((75, "excellent"), (50, "good"), (25, "ok")):
        if signal >= lim:
            return f"network-wireless-signal-{name}-symbolic"
    return "network-wireless-signal-weak-symbolic"


def battery_icon(pct, status):
    if pct is None:
        return "ac-adapter-symbolic"
    level = min(100, max(0, int(round(pct / 10.0) * 10)))
    return f"battery-level-{level}{'-charging' if status in ('Charging', 'Full') else ''}-symbolic"


def esc(text):
    return GLib.markup_escape_text(text or "")


class Settings(Adw.ApplicationWindow):
    def __init__(self, app, backend: Backend):
        super().__init__(application=app, title="LayerOSX Settings")
        self.b = backend
        self.status = None
        self._updating = False
        self._bright_src = None
        # Fixed size, like macOS System Settings (which can't be zoomed): the
        # layout is designed for this width, so maximizing only added gaps.
        self.set_default_size(900, 640)
        self.set_resizable(False)

        self.toasts = Adw.ToastOverlay()
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.banner = Adw.Banner(title="Restart the Mac to apply your changes")
        self.banner.set_button_label("Restart Mac")
        self.banner.connect("button-clicked", lambda *_: self.on_restart_mac())
        root.append(self.banner)

        self.split = Adw.NavigationSplitView(vexpand=True)
        self.split.set_min_sidebar_width(230)
        self.split.set_max_sidebar_width(260)
        self.split.set_sidebar(self._sidebar())
        root.append(self.split)
        self.toasts.set_child(root)
        self.set_content(self.toasts)

        self.pages = {}
        key = Gtk.EventControllerKey()
        key.connect("key-pressed", self._on_key)
        self.add_controller(key)

        start = os.environ.get("LAYEROSX_PANEL_PAGE", "wifi")
        self.select(start if start in dict((s[0], s) for s in SECTIONS) else "wifi")
        self.refresh()
        GLib.timeout_add_seconds(REFRESH_SECONDS, lambda: self.refresh() or True)

    # ------------------------------------------------------------ plumbing
    def toast(self, text):
        t = Adw.Toast(title=esc(text))
        t.set_timeout(3)
        self.toasts.add_toast(t)

    def after_action(self, ok, msg, success_text):
        if self.b.dry_run and self.b.dry_log:
            self.toast("Preview — would run: " + self.b.dry_log[-1])
        elif ok:
            if success_text:
                self.toast(success_text)
        else:
            self.toast(msg or "That didn't work.")

    def _dialog(self, heading, body):
        if hasattr(Adw, "AlertDialog"):
            return Adw.AlertDialog(heading=heading, body=body)
        return Adw.MessageDialog(transient_for=self, heading=heading, body=body)

    def _present(self, d):
        d.present(self) if hasattr(Adw, "AlertDialog") else d.present()

    def confirm(self, heading, body, action_label, callback, destructive=False):
        d = self._dialog(heading, body)
        d.add_response("cancel", "Cancel")
        d.add_response("ok", action_label)
        d.set_response_appearance("ok", Adw.ResponseAppearance.DESTRUCTIVE if destructive
                                  else Adw.ResponseAppearance.SUGGESTED)
        d.set_default_response("cancel")
        d.set_close_response("cancel")
        d.connect("response", lambda _d, r: callback() if r == "ok" else None)
        self._present(d)

    def ask_text(self, heading, body, callback, password=False, placeholder="", ok_label="Join"):
        entry = Gtk.PasswordEntry(show_peek_icon=True) if password else Gtk.Entry(placeholder_text=placeholder)
        d = self._dialog(heading, body)
        d.set_extra_child(entry)
        d.add_response("cancel", "Cancel")
        d.add_response("ok", ok_label)
        d.set_response_appearance("ok", Adw.ResponseAppearance.SUGGESTED)
        d.set_default_response("ok")
        d.set_close_response("cancel")
        d.connect("response", lambda _d, r: callback(entry.get_text()) if r == "ok" else None)
        entry.connect("activate", lambda *_: d.response("ok") if hasattr(d, "response") else None)
        self._present(d)
        entry.grab_focus()

    def _on_key(self, _ctl, keyval, _code, _state):
        if keyval == Gdk.KEY_Escape:
            self.close()
            return True
        return False

    # -------------------------------------------------------------- sidebar
    def _traffic_lights(self):
        """Close / hide / zoom -- "hide" closes the panel (Ctrl+Alt+W reopens it;
        the kiosk has no taskbar to restore a minimized window); zoom is greyed
        out like System Settings (fixed-size window)."""
        self.traffic = traffic_lights(self.close, self.close, None, dark=self.b.panel_theme() == "dark")
        return self.traffic

    def _sidebar(self):
        tv = Adw.ToolbarView()
        hb = Adw.HeaderBar(show_title=False, show_start_title_buttons=False, show_end_title_buttons=False)
        hb.pack_start(self._traffic_lights())
        tv.add_top_bar(hb)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)

        # "Account"-style status card at the top of the sidebar
        card = Gtk.Box(spacing=10, css_classes=["sidebar-status"])
        card.append(badge("computer-symbolic", "graphite", big=True))
        texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, valign=Gtk.Align.CENTER)
        texts.append(Gtk.Label(label="LayerOSX", xalign=0, css_classes=["title"]))
        self.side_status = Gtk.Label(label="…", xalign=0, css_classes=["sub"])
        texts.append(self.side_status)
        card.append(texts)
        box.append(card)

        self.listbox = Gtk.ListBox(css_classes=["navigation-sidebar"], vexpand=True)
        self.rows = {}
        for i, (sid, title, icon, color) in enumerate(SECTIONS):
            if sid == "terminal" and self.b.terminal_policy == "off":
                continue  # this build ships without a maintenance terminal
            if sid in ("mac",):  # visual gap before the Mac/General block, like System Settings
                sep = Gtk.ListBoxRow(selectable=False, activatable=False)
                sep.set_child(Gtk.Box(margin_top=2))
                self.listbox.append(sep)
            row = Gtk.ListBoxRow()
            row.sid = sid
            h = Gtk.Box(spacing=10, margin_top=4, margin_bottom=4, margin_start=2)
            h.append(badge(icon, color))
            h.append(Gtk.Label(label=title, xalign=0))
            row.set_child(h)
            self.listbox.append(row)
            self.rows[sid] = row
        self.listbox.connect("row-selected", self._on_row)
        box.append(self.listbox)
        tv.set_content(Gtk.ScrolledWindow(child=box, hscrollbar_policy=Gtk.PolicyType.NEVER))
        return Adw.NavigationPage(title="LayerOSX Settings", child=tv)

    def _on_row(self, _lb, row):
        if row is not None and getattr(row, "sid", None):
            self.select(row.sid, from_sidebar=True)

    def select(self, sid, from_sidebar=False):
        if not from_sidebar:
            self.listbox.select_row(self.rows[sid])  # re-enters via _on_row
            return
        builder = getattr(self, f"_page_{sid}")
        if sid not in self.pages:
            self.pages[sid] = builder()
        page = self.pages[sid]
        if self.split.get_content() is not page:
            self.split.set_content(page)
        self.split.set_show_content(True)
        if sid == "wifi":
            self._scan_wifi()
        elif sid == "usb":
            self._load_usb()

    def _pane(self, title, content, header_extra=None):
        tv = Adw.ToolbarView()
        hb = Adw.HeaderBar(show_start_title_buttons=False, show_end_title_buttons=False)
        hb.set_title_widget(Adw.WindowTitle(title=title,
                                            subtitle="Preview — nothing is changed" if self.b.dry_run else ""))
        if header_extra:
            hb.pack_end(header_extra)
        tv.add_top_bar(hb)
        tv.set_content(content)
        return Adw.NavigationPage(title=title, child=tv)

    # ---------------------------------------------------------------- Wi-Fi
    def _page_wifi(self):
        page = Adw.PreferencesPage()
        top = Adw.PreferencesGroup()
        self.wifi_switch_row = Adw.ActionRow(
            title="Wi-Fi",
            subtitle="The Mac is always online through this computer's connection — "
                     "choose a network here and macOS follows it.")
        self.wifi_switch_row.add_prefix(badge("network-wireless-symbolic", "blue", big=True))
        self.wifi_switch = Gtk.Switch(valign=Gtk.Align.CENTER)
        self.wifi_switch.connect("state-set", self._on_wifi_radio)
        self.wifi_switch_row.add_suffix(self.wifi_switch)
        top.add(self.wifi_switch_row)
        self.wifi_state_row = Adw.ActionRow(title="…")
        self.wifi_state_dot = dot("gray")
        self.wifi_state_row.add_prefix(self.wifi_state_dot)
        top.add(self.wifi_state_row)
        page.add(top)

        self.wifi_known = Adw.PreferencesGroup(title="Current Network")
        self.wifi_other = Adw.PreferencesGroup(title="Other Networks")
        page.add(self.wifi_known)
        page.add(self.wifi_other)
        self._wifi_rows = []

        other = Adw.PreferencesGroup()
        btn = Gtk.Button(label="Other…", halign=Gtk.Align.END, css_classes=["pill"])
        btn.connect("clicked", lambda *_: self._join_hidden())
        other.add(btn)
        page.add(other)

        self.wifi_spinner = Gtk.Spinner()
        scan = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Scan for networks")
        scan.connect("clicked", lambda *_: self._scan_wifi())
        extra = Gtk.Box(spacing=6)
        extra.append(self.wifi_spinner)
        extra.append(scan)
        return self._pane("Wi-Fi", page, extra)

    def _scan_wifi(self):
        if "wifi" not in self.pages:
            return
        self.wifi_spinner.set_spinning(True)
        run_async(lambda: (self.b.wifi_enabled(), self.b.wifi_scan()), self._show_wifi)

    def _show_wifi(self, res):
        self.wifi_spinner.set_spinning(False)
        for grp, row in self._wifi_rows:
            grp.remove(row)
        self._wifi_rows = []
        if isinstance(res, Exception):
            return False
        enabled, nets = res
        self._updating = True
        self.wifi_switch.set_active(enabled)
        self._updating = False
        cur = [n for n in nets if n.connected]
        others = [n for n in nets if not n.connected]
        self.wifi_known.set_visible(bool(cur))
        self.wifi_other.set_visible(enabled)
        for n in cur:
            self._add_net(self.wifi_known, n)
        for n in others:
            self._add_net(self.wifi_other, n)
        if enabled and not others:
            r = Adw.ActionRow(title="No other networks found")
            self.wifi_other.add(r)
            self._wifi_rows.append((self.wifi_other, r))
        return False

    def _add_net(self, grp, n):
        r = Adw.ActionRow(title=esc(n.ssid))
        if n.connected:
            r.add_prefix(Gtk.Image.new_from_icon_name("object-select-symbolic"))
        else:
            r.add_prefix(Gtk.Box(width_request=16))
            join = Gtk.Button(label="Connect", valign=Gtk.Align.CENTER)
            join.connect("clicked", lambda *_: self._join(n))
            r.add_suffix(join)
        # The lock slot is always there (invisible on open networks) so the
        # Connect buttons line up in one column, like System Settings.
        lock = Gtk.Image.new_from_icon_name("system-lock-screen-symbolic")
        lock.set_opacity(1.0 if n.secure else 0.0)
        lock.set_tooltip_text("Secured" if n.secure else None)
        r.add_suffix(lock)
        r.add_suffix(Gtk.Image.new_from_icon_name(wifi_icon(n.signal)))
        grp.add(r)
        self._wifi_rows.append((grp, r))

    def _on_wifi_radio(self, _sw, state):
        if self._updating:
            return False
        if not state:
            self.confirm("Turn Wi-Fi off?", "The Mac loses its internet connection too (unless a cable is plugged in).",
                         "Turn Off", lambda: self._set_radio(False), destructive=True)
            return True  # keep the switch on until confirmed
        self._set_radio(True)
        return False

    def _set_radio(self, on):
        ok, msg = self.b.set_wifi_enabled(on)
        self.after_action(ok, msg, "Wi-Fi on" if on else "Wi-Fi off")
        GLib.timeout_add(1500, lambda: self._scan_wifi() or self.refresh() or False)

    def _join(self, n):
        if n.secure:
            self.ask_text(f"Join “{n.ssid}”", "Enter the network password.",
                          lambda pw: self._do_join(n.ssid, pw), password=True)
        else:
            self._do_join(n.ssid, "")

    def _join_hidden(self):
        self.ask_text("Join Other Network", "Enter the name of the network.",
                      lambda ssid: ssid and self.ask_text(
                          f"Join “{ssid}”", "Password (leave empty if the network is open).",
                          lambda pw: self._do_join(ssid, pw, hidden=True), password=True),
                      placeholder="Network name", ok_label="Next")

    def _do_join(self, ssid, pw, hidden=False):
        self.toast(f"Connecting to {ssid}…")
        self.wifi_spinner.set_spinning(True)

        def done(r):
            ok = not isinstance(r, Exception) and r[0]
            self.toast(f"Connected to {ssid}" if ok else f"Couldn't connect to {ssid}")
            self.refresh()
            GLib.timeout_add(1200, lambda: self._scan_wifi() or False)
            return False
        run_async(lambda: self.b.wifi_connect(ssid, pw, hidden), done)

    # -------------------------------------------------------------- Battery
    def _page_battery(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        self.bat_row = Adw.ActionRow(title="Battery")
        self.bat_row.add_prefix(badge("battery-full-symbolic", "green", big=True))
        self.bat_level = Gtk.LevelBar(min_value=0, max_value=100, valign=Gtk.Align.CENTER, width_request=180)
        self.bat_row.add_suffix(self.bat_level)
        g.add(self.bat_row)
        page.add(g)
        p = Adw.PreferencesGroup(title="Low battery protection",
                                 description="macOS can't see this computer's battery, so LayerOSX watches it.")
        for icon, title, sub in (
                ("dialog-warning-symbolic", "Warnings", "A notice at 20% and at 10%."),
                ("system-shutdown-symbolic", "Safe shutdown at 5%", "macOS is asked to shut down cleanly before the battery runs out."),
                ("media-flash-symbolic", "Last resort at 3%", "The Mac is stopped with its disk saved and the computer turns off.")):
            r = Adw.ActionRow(title=title, subtitle=sub)
            r.add_prefix(Gtk.Image.new_from_icon_name(icon))
            p.add(r)
        page.add(p)
        return self._pane("Battery", page)

    # ------------------------------------------------------------- Displays
    def _page_displays(self):
        page = Adw.PreferencesPage()
        self.bright_group = Adw.PreferencesGroup(title="Brightness")
        r = Adw.ActionRow()
        r.add_prefix(Gtk.Image.new_from_icon_name("display-brightness-symbolic"))
        self.bright = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 5, 100, 5)
        self.bright.set_hexpand(True)
        self.bright.set_draw_value(False)
        self.bright.connect("value-changed", self._on_brightness)
        r.add_suffix(self.bright)
        self.bright_group.add(r)
        page.add(self.bright_group)

        g = Adw.PreferencesGroup(title="Graphics",
                                 description="How the Mac draws its screen. Changes apply when the Mac restarts.")
        self.gfx_checks = {}
        first = None
        for key, title, sub in (
                ("reims", "Reims", "Hardware-accelerated. The fastest option (alpha)."),
                ("vmware", "VMware", "Not accelerated, very reliable. Use it if the screen stays black."),
                ("std", "Standard VGA", "Basic display, for diagnostics only.")):
            row = Adw.ActionRow(title=title, subtitle=sub, activatable=True)
            chk = Gtk.CheckButton(valign=Gtk.Align.CENTER)
            if first:
                chk.set_group(first)
            first = first or chk
            chk.connect("toggled", self._on_gfx, key)
            row.add_prefix(chk)
            row.set_activatable_widget(chk)
            g.add(row)
            self.gfx_checks[key] = chk
        page.add(g)
        self._sync_displays()
        return self._pane("Displays", page)

    def _sync_displays(self):
        s = self.status
        if not s or not hasattr(self, "gfx_checks"):
            return
        self._updating = True
        self.gfx_checks[s.gfx].set_active(True)
        self.bright_group.set_visible(s.brightness is not None)
        if s.brightness is not None and self._bright_src is None:
            self.bright.set_value(s.brightness)
        self._updating = False

    def _on_gfx(self, chk, key):
        if self._updating or not chk.get_active():
            return
        ok, msg = self.b.set_setting("gfx", key)
        self.after_action(ok, msg, "Graphics changed — applies when the Mac restarts")
        if ok:
            self._pending_restart()
        self.refresh()

    def _on_brightness(self, scale):
        if self._updating:
            return
        if self._bright_src:
            GLib.source_remove(self._bright_src)

        def apply():
            self._bright_src = None
            ok, msg = self.b.set_brightness(int(scale.get_value()))
            if not ok:
                self.toast(msg or "Couldn't change the brightness")
            elif self.b.dry_run:
                self.after_action(ok, msg, "")
            return False
        self._bright_src = GLib.timeout_add(150, apply)

    # ---------------------------------------------------------------- Sound
    def _page_sound(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup(description="Sound plays through this computer's speakers or headphones. "
                                             "Changes apply when the Mac restarts.")
        self.audio_row = Adw.SwitchRow(title="Sound from the Mac",
                                       subtitle="Gives the Mac a USB sound card")
        self.audio_row.add_prefix(badge("audio-volume-high-symbolic", "pink", big=True))
        self.audio_row.connect("notify::active", self._on_switch, "audio", "Sound")
        g.add(self.audio_row)
        page.add(g)
        self._sync_switches()
        return self._pane("Sound", page)

    # ------------------------------------------------------------------ USB
    def _page_usb(self):
        page = Adw.PreferencesPage()
        self.usb_group = Adw.PreferencesGroup(
            title="Devices",
            description="Switch a device on to give it to the Mac. The star gives it to the Mac "
                        "automatically every time it's plugged in.")
        page.add(self.usb_group)
        self._usb_rows = []
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh")
        refresh.connect("clicked", lambda *_: self._load_usb())
        return self._pane("USB Devices", page, refresh)

    def _load_usb(self):
        if "usb" in self.pages:
            run_async(self.b.usb_devices, self._show_usb)

    def _show_usb(self, devs):
        for r in self._usb_rows:
            self.usb_group.remove(r)
        self._usb_rows = []
        running = self.b.vm_running() or self.b.dry_run
        if isinstance(devs, Exception) or not devs:
            devs = []
            r = Adw.ActionRow(title="No USB devices found")
            self.usb_group.add(r)
            self._usb_rows.append(r)
        if not running:
            r = Adw.ActionRow(title="The Mac isn't running", subtitle="Devices can be given to it once it starts.")
            r.add_prefix(dot("yellow"))
            self.usb_group.add(r)
            self._usb_rows.append(r)
        for d in devs:
            sub = d.id + (" · built-in" if d.builtin else "") + (f" · {d.blocked}" if d.blocked else "")
            r = Adw.ActionRow(title=esc(d.name), subtitle=esc(sub))
            icon = ("input-keyboard-symbolic" if "keyboard" in d.blocked else
                    "camera-web-symbolic" if "cam" in d.name.lower() else "media-removable-symbolic")
            r.add_prefix(Gtk.Image.new_from_icon_name(icon))
            star = Gtk.ToggleButton(icon_name="starred-symbolic" if d.always else "non-starred-symbolic",
                                    active=d.always, valign=Gtk.Align.CENTER, css_classes=["flat"],
                                    tooltip_text="Always give this device to the Mac",
                                    sensitive=not d.blocked)
            sw = Gtk.Switch(active=d.on_mac, valign=Gtk.Align.CENTER, sensitive=not d.blocked and running)
            star.connect("toggled", self._on_usb_star, d)
            sw.connect("state-set", self._on_usb_switch, d)
            r.add_suffix(star)
            r.add_suffix(sw)
            self.usb_group.add(r)
            self._usb_rows.append(r)
        return False

    def _on_usb_switch(self, _sw, state, d):
        ok, msg = self.b.usb_give_to_mac(d.vid, d.pid, state)
        self.after_action(ok, msg, f"{d.name} is now on the {'Mac' if state else 'computer'}")
        GLib.timeout_add(400, lambda: self._load_usb() or False)
        return not ok

    def _on_usb_star(self, star, d):
        on = star.get_active()
        ok, msg = self.b.usb_set_always(d.vid, d.pid, on, d.name)
        star.set_icon_name("starred-symbolic" if on else "non-starred-symbolic")
        self.after_action(ok, msg, f"{d.name}: " + ("always given to the Mac" if on else "no longer automatic"))

    # ------------------------------------------------------------------ Mac
    def _page_mac(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        self.mac_row = Adw.ActionRow(title="Mac")
        self.mac_row.add_prefix(badge("computer-symbolic", "graphite", big=True))
        self.mac_dot = dot("gray")
        self.mac_row.add_suffix(self.mac_dot)
        g.add(self.mac_row)
        page.add(g)
        s = Adw.PreferencesGroup(title="Startup", description="Applies when the Mac restarts.")
        self.verbose_row = Adw.SwitchRow(title="Show startup log",
                                         subtitle="Text log instead of the logo while macOS starts — useful when something goes wrong")
        self.verbose_row.connect("notify::active", self._on_switch, "verbose", "Startup log")
        s.add(self.verbose_row)
        page.add(s)
        page.add(self._resources_group())
        r = Adw.PreferencesGroup(title="Restart")
        rr = Adw.ActionRow(title="Restart the Mac",
                           subtitle="Use this if macOS is stuck or the screen is black. Otherwise use Apple menu › Restart.")
        btn = Gtk.Button(label="Restart Mac…", valign=Gtk.Align.CENTER, css_classes=["destructive-action"])
        btn.connect("clicked", lambda *_: self.on_restart_mac())
        rr.add_suffix(btn)
        r.add(rr)
        page.add(r)
        self._sync_switches()
        return self._pane("Mac", page)

    # ---------------------------------------------------------- Resources
    def _resources_group(self):
        res = self.b.resources()
        host_gb = round(res.host_ram_mb / 1024)
        g = Adw.PreferencesGroup(
            title="Resources",
            description=f"This computer: {res.threads} threads, {host_gb} GB memory. "
                        "Automatic leaves some for Linux. Applies when the Mac restarts.")
        self.cpu_row = Adw.ComboRow(title="Processor")
        self.cpu_row.add_prefix(Gtk.Image.new_from_icon_name("system-run-symbolic"))
        self.cpu_row.connect("notify::selected", self._on_cores)
        g.add(self.cpu_row)
        self.reserve_row = Adw.SwitchRow(
            title="Keep 2 threads for Linux",
            subtitle="Automatic leaves 2 threads for Linux, QEMU and the graphics on machines with more than 4. "
                     "Turn off to give the Mac every thread.")
        self.reserve_row.connect("notify::active", self._on_reserve)
        g.add(self.reserve_row)
        self.ram_row = Adw.ComboRow(title="Memory")
        self.ram_row.add_prefix(Gtk.Image.new_from_icon_name("drive-harddisk-solidstate-symbolic"))
        self.ram_row.connect("notify::selected", self._on_ram)
        g.add(self.ram_row)
        self._sync_resources()
        return g

    @staticmethod
    def _set_choices(row, labels, index):
        """Swap a ComboRow's labels/selection only when they differ -- replacing
        the model from inside its own notify::selected handler hangs GTK."""
        m = row.get_model()
        cur = [m.get_string(i) for i in range(m.get_n_items())] if m else None
        if cur != labels:
            row.set_model(Gtk.StringList.new(labels))
        if row.get_selected() != index:
            row.set_selected(index)

    def _sync_resources(self):
        res = self.b.resources()
        self._updating = True
        try:
            n = lambda c: "1 core" if c == 1 else f"{c} cores"
            self._cpu_values = [0] + res.cores_choices
            self._set_choices(self.cpu_row,
                              [f"Automatic — {n(res.cores_auto)}"] + [n(c) for c in res.cores_choices],
                              self._cpu_values.index(res.cores_choice) if res.cores_choice in self._cpu_values else 0)
            sub = []
            if res.amd:
                sub.append("AMD: 2, 4 or 8 cores (the OpenCore image must match)")
            if res.cores_choice and res.cores != res.cores_choice:
                sub.append(f"will use {n(res.cores)}")
            self.cpu_row.set_subtitle(" · ".join(sub))
            self.reserve_row.set_active(res.reserve)
            self.reserve_row.set_sensitive(res.threads > 4 and not res.cores_choice)
            gb = lambda mb: f"{mb / 1024:g} GB"
            self._ram_values = [0] + res.ram_choices_mb
            self._set_choices(self.ram_row,
                              [f"Automatic — {gb(res.ram_auto_mb)}"] + [gb(m) for m in res.ram_choices_mb],
                              self._ram_values.index(res.ram_choice_mb) if res.ram_choice_mb in self._ram_values else 0)
        finally:
            self._updating = False
        return False

    def _resource_changed(self, ok, msg, what):
        self.after_action(ok, msg, f"{what} — applies when the Mac restarts")
        if ok:
            self._pending_restart()
        GLib.idle_add(self._sync_resources)   # not from inside the row's own handler

    def _on_cores(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._cpu_values):
            return
        v = self._cpu_values[i]
        ok, msg = self.b.set_cores(v or "auto")
        self._resource_changed(ok, msg, f"Processor: {v} cores" if v else "Processor: Automatic")

    def _on_reserve(self, row, _pspec):
        if self._updating:
            return
        on = row.get_active()
        ok, msg = self.b.set_cpu_reserve(on)
        self._resource_changed(ok, msg, "Keeping 2 threads for Linux" if on else "The Mac gets every thread")

    def _on_ram(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._ram_values):
            return
        v = self._ram_values[i]
        ok, msg = self.b.set_ram(v or "auto")
        self._resource_changed(ok, msg, f"Memory: {v / 1024:g} GB" if v else "Memory: Automatic")

    # -------------------------------------------------------------- General
    def _page_general(self):
        page = Adw.PreferencesPage()
        ap = Adw.PreferencesGroup(title="Appearance")
        row = Adw.ActionRow(title="Appearance", subtitle="How LayerOSX Settings looks")
        row.add_prefix(Gtk.Image.new_from_icon_name("preferences-desktop-appearance-symbolic"))
        seg = Gtk.Box(css_classes=["linked"], valign=Gtk.Align.CENTER)
        self.theme_buttons = {}
        first = None
        for key, label in (("light", "Light"), ("dark", "Dark")):
            b = Gtk.ToggleButton(label=label, active=self.b.panel_theme() == key)
            if first:
                b.set_group(first)
            first = first or b
            b.connect("toggled", self._on_theme, key)
            seg.append(b)
            self.theme_buttons[key] = b
        row.add_suffix(seg)
        ap.add(row)
        page.add(ap)
        p = Adw.PreferencesGroup(title="Power", description="Save your work in macOS first — it will be stopped.")
        for icon, title, kind, css in (("system-reboot-symbolic", "Restart", "reboot", None),
                                       ("system-shutdown-symbolic", "Shut Down", "poweroff", "destructive-action")):
            r = Adw.ActionRow(title=title)
            r.add_prefix(Gtk.Image.new_from_icon_name(icon))
            b = Gtk.Button(label=f"{title}…", valign=Gtk.Align.CENTER, css_classes=[css] if css else [])
            b.connect("clicked", lambda _b, k=kind: self.on_host(k))
            r.add_suffix(b)
            p.add(r)
        page.add(p)
        m = Adw.PreferencesGroup(title="Maintenance")
        d = Adw.ActionRow(title="Save diagnostics", subtitle="Copies the logs to a drive you choose, for troubleshooting")
        d.add_prefix(Gtk.Image.new_from_icon_name("document-save-symbolic"))
        db = Gtk.Button(label="Save…", valign=Gtk.Align.CENTER)
        db.connect("clicked", lambda *_: self.on_diag())
        d.add_suffix(db)
        m.add(d)
        if self.b.terminal_policy != "off":
            t = Adw.ActionRow(title="Terminal",
                              subtitle="Asks for the maintenance password" if self.b.terminal_policy == "password"
                              else "For advanced maintenance")
            t.add_prefix(Gtk.Image.new_from_icon_name("utilities-terminal-symbolic"))
            tb = Gtk.Button(label="Open…", valign=Gtk.Align.CENTER)
            tb.connect("clicked", lambda *_: self.on_terminal())
            t.add_suffix(tb)
            m.add(t)
        page.add(m)
        return self._pane("General", page)

    # ------------------------------------------------------------- Terminal
    def _page_terminal(self):
        page = Adw.PreferencesPage()
        g = Adw.PreferencesGroup()
        pw = self.b.terminal_policy == "password"
        r = Adw.ActionRow(title="Terminal",
                          subtitle="A command line on this computer (the Linux underneath the Mac), for "
                                   "maintenance and troubleshooting.")
        r.add_prefix(badge("utilities-terminal-symbolic", "black", big=True))
        g.add(r)
        o = Adw.ActionRow(title="Open Terminal",
                          subtitle="Asks for the maintenance password" if pw else "Opens right away")
        b = Gtk.Button(label="Open…", valign=Gtk.Align.CENTER, css_classes=["suggested-action"])
        b.connect("clicked", lambda *_: self.on_terminal())
        o.add_suffix(b)
        g.add(o)
        page.add(g)
        h = Adw.PreferencesGroup(title="Useful commands",
                                 description="Type `commands` in the terminal for the full list.")
        for cmd, what in (("gpu vmware", "Switch to the reliable display (then: relaunch)"),
                          ("relaunch", "Restart the Mac to apply a change"),
                          ("maclog", "Show the Mac's startup log"),
                          ("macdiag usb", "Save a diagnostics bundle to a USB drive"),
                          ("passwd", "Change the maintenance password")):
            row = Adw.ActionRow(title=cmd, subtitle=what, title_selectable=True)
            h.add(row)
        page.add(h)
        k = Adw.PreferencesGroup()
        k.add(Adw.ActionRow(title="Shortcut", subtitle="Ctrl+Alt+T opens it from anywhere"))
        page.add(k)
        return self._pane("Terminal", page)

    # ---------------------------------------------------------------- About
    def _page_about(self):
        page = Adw.PreferencesPage()
        self.about_page = page
        hero = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, halign=Gtk.Align.CENTER,
                       css_classes=["about-hero"])
        icon = Gtk.Image.new_from_icon_name("computer-symbolic")
        icon.set_pixel_size(64)
        ib = Gtk.Box(css_classes=["badge", "badge-graphite", "about-icon"], halign=Gtk.Align.CENTER)
        ib.append(icon)
        hero.append(ib)
        hero.append(Gtk.Label(label="LayerOSX", css_classes=["about-name"]))
        self.about_version = Gtk.Label(label="", css_classes=["about-version"])
        hero.append(self.about_version)
        hg = Adw.PreferencesGroup()
        hg.add(hero)
        page.add(hg)
        self.about_groups = []
        run_async(self.b.about, self._show_about)
        return self._pane("About", page)

    def _show_about(self, a):
        if isinstance(a, Exception):
            return False
        for g in self.about_groups:
            self.about_page.remove(g)
        self.about_groups = []
        mode = {"release": "Release", "debug": "Debug"}.get(a.mode, a.mode)
        self.about_version.set_label(
            f"Version {a.layerosx_version}" + (f" · built {a.built}" if a.built else "") + f" · {mode}")

        def group(title, rows, description=None):
            g = Adw.PreferencesGroup(title=title, description=description)
            for key, value in rows:
                if not value:
                    continue
                r = Adw.ActionRow(title=esc(key))
                long = max(len(x) for x in value.split("\n")) > 34
                v = Gtk.Label(label=value, xalign=1, wrap=long, selectable=True,
                              css_classes=["dim-label"], justify=Gtk.Justification.RIGHT)
                if long:
                    v.set_max_width_chars(40)
                r.add_suffix(v)
                g.add(r)
            self.about_page.add(g)
            self.about_groups.append(g)
            return g

        group("This Computer", [
            ("Model", a.machine),
            ("Processor", f"{a.cpu} · {a.cpu_threads} threads"),
            ("Memory", f"{a.memory_gb:g} GB"),
            ("Graphics", "\n".join(a.gpus)),
            ("Storage", a.storage),
            ("Linux kernel", a.kernel),
        ])
        vm_cpu = f"{a.vm_cpu} · {a.vm_cores} cores" if a.vm_cpu else ""
        group("The Mac", [
            ("macOS", a.macos),
            ("Processor", vm_cpu),
            ("Memory", f"{a.vm_ram_gb:g} GB" if a.vm_ram_gb else ""),
            ("Graphics", a.vm_graphics),
            ("Disk", f"{a.vm_disk_gb} GB" if a.vm_disk_gb else ""),
        ], description=(None if a.vm_cpu else "Details appear after the Mac has started once.") if not
           a.vm_disk_grown_from else
           f"The Mac's disk grew from {a.vm_disk_grown_from} GB to {a.vm_disk_gb} GB. To use the new space, "
           "open Terminal in macOS and run: sudo diskutil apfs resizeContainer disk0s2 0 "
           "(check the container name with: diskutil list).")
        cg = Adw.PreferencesGroup(title="Credits")
        who = Adw.ActionRow(title=f"Created by {esc(a.creator)}", subtitle=esc(a.creator_link),
                            subtitle_selectable=True)
        who.add_css_class("about-credit")
        who.add_prefix(Gtk.Image.new_from_icon_name("emblem-favorite-symbolic"))
        cg.add(who)
        self.about_page.add(cg)
        self.about_groups.append(cg)
        tg = group("Built With", a.thanks,
                   description="LayerOSX stands on these open-source projects — thank you.")
        sg = group("Shortcuts", [("Ctrl+Alt+W", "LayerOSX Settings"), ("Ctrl+Alt+T", "Terminal"),
                                 ("Ctrl+Alt+U", "USB devices")])
        return False

    # --------------------------------------------------------- status sync
    def refresh(self):
        run_async(self.b.status, self._apply_status)

    def _apply_status(self, s):
        if isinstance(s, Exception):
            return False
        self.status = s
        net = s.wifi_ssid or ("Wired" if s.wired else "Offline")
        self.side_status.set_label(f"Mac {'running' if s.vm_running else 'stopped'} · {net}")
        if "wifi" in self.pages:
            if s.wifi_ssid:
                self.wifi_state_row.set_title(f"Connected to {esc(s.wifi_ssid)}")
                self._set_dot(self.wifi_state_row, "wifi_state_dot", "green")
            else:
                self.wifi_state_row.set_title("Using a wired connection" if s.wired else "Not connected")
                self._set_dot(self.wifi_state_row, "wifi_state_dot", "green" if s.wired else "yellow")
        if "battery" in self.pages:
            if s.battery_percent is None:
                self.bat_row.set_subtitle("This computer has no battery")
                self.bat_level.set_visible(False)
            else:
                st = {"Charging": "Charging", "Full": "Fully charged", "Discharging": "On battery",
                      "Not charging": "Plugged in, not charging"}.get(s.battery_status, s.battery_status)
                self.bat_row.set_title(f"{s.battery_percent}%")
                self.bat_row.set_subtitle(st)
                self.bat_level.set_value(s.battery_percent)
        if "mac" in self.pages:
            self.mac_row.set_subtitle("Running" if s.vm_running else "Stopped")
            self._set_dot(self.mac_row, "mac_dot", "green" if s.vm_running else "gray", suffix=True)
        if hasattr(self, "gfx_checks"):
            self._sync_displays()
        self._sync_switches()
        return False

    def _set_dot(self, row, attr, color, suffix=False):
        old = getattr(self, attr)
        new = dot(color)
        (row.remove(old))
        (row.add_suffix(new) if suffix else row.add_prefix(new))
        setattr(self, attr, new)

    def _sync_switches(self):
        s = self.status
        if not s:
            return
        self._updating = True
        if hasattr(self, "audio_row"):
            self.audio_row.set_active(s.audio)
        if hasattr(self, "verbose_row"):
            self.verbose_row.set_active(s.verbose)
        self._updating = False

    def _pending_restart(self):
        if self.status and self.status.vm_running:
            self.banner.set_revealed(True)

    def _on_switch(self, row, _pspec, name, label):
        if self._updating:
            return
        value = "on" if row.get_active() else "off"
        ok, msg = self.b.set_setting(name, value)
        self.after_action(ok, msg, f"{label} {value} — applies when the Mac restarts")
        if ok:
            self._pending_restart()
        self.refresh()

    def _on_theme(self, btn, key):
        if not btn.get_active():
            return
        ok, msg = self.b.set_panel_theme(key)
        if not ok:
            self.toast(msg)
        apply_theme(key)
        self.traffic.remove_css_class("dark")
        if key == "dark":
            self.traffic.add_css_class("dark")

    # ------------------------------------------------------- power actions
    def on_restart_mac(self):
        self.confirm("Restart the Mac?",
                     "macOS is stopped and starts again — unsaved work is lost. Use this if it's stuck; "
                     "otherwise use Apple menu › Restart.", "Restart Mac", self._do_restart_mac, destructive=True)

    def _do_restart_mac(self):
        ok, msg = self.b.restart_mac()
        self.banner.set_revealed(False)
        self.after_action(ok, msg, "Restarting the Mac…")
        if ok and not self.b.dry_run:
            GLib.timeout_add(900, lambda: self.close() or False)

    def on_host(self, kind):
        verb = "Restart" if kind == "reboot" else "Shut down"
        self.confirm(f"{verb} the computer?", "Save your work in macOS first — it will be stopped.",
                     verb, lambda: self.after_action(*self.b.host_action(kind),
                                                     "Restarting…" if kind == "reboot" else "Shutting down…"),
                     destructive=True)

    def on_diag(self):
        """Ask which drive to save the diagnostics bundle to, then save it."""
        run_async(self.b.log_targets, self._choose_drive)

    def _choose_drive(self, targets):
        if isinstance(targets, Exception):
            targets = []
        d = self._dialog("Save Diagnostics",
                         "Choose where to save the logs. They go into a “LayerOSX-logs” folder on that drive."
                         if targets else
                         "No drive to save to. Plug in a USB drive and try again.")
        chosen = {"path": targets[0].path if targets else None}
        if targets:
            lb = Gtk.ListBox(css_classes=["boxed-list"], selection_mode=Gtk.SelectionMode.NONE)
            first = None
            for t in targets:
                row = Adw.ActionRow(title=esc(t.title), activatable=True,
                                    subtitle=esc(" · ".join(x for x in (
                                        t.size_text, t.fstype.upper(),
                                        "USB drive" if t.removable else "internal drive",
                                        os.path.basename(t.path)) if x)))
                chk = Gtk.CheckButton(valign=Gtk.Align.CENTER, active=first is None)
                if first:
                    chk.set_group(first)
                first = first or chk
                chk.connect("toggled", lambda c, p=t.path: c.get_active() and chosen.update(path=p))
                row.add_prefix(chk)
                row.set_activatable_widget(chk)
                row.add_suffix(Gtk.Image.new_from_icon_name(
                    "media-removable-symbolic" if t.removable else "drive-harddisk-symbolic"))
                lb.append(row)
            d.set_extra_child(lb)
            d.add_response("cancel", "Cancel")
            d.add_response("save", "Save")
            d.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED)
            d.set_default_response("save")
        else:
            d.add_response("cancel", "OK")
        d.set_close_response("cancel")
        d.connect("response", lambda _d, r: r == "save" and chosen["path"] and self._save_to(chosen["path"]))
        self._present(d)
        return False

    def _save_to(self, device):
        self.toast("Saving diagnostics…")

        def done(r):
            ok, msg = r if not isinstance(r, Exception) else (False, str(r))
            if self.b.dry_run:
                self.after_action(ok, msg, "")
            elif ok:
                self.toast("Diagnostics saved — you can unplug the drive")
            else:
                self.toast(msg or "Couldn't save the diagnostics")
            return False
        run_async(lambda: self.b.save_logs_to(device), done)

    def on_terminal(self):
        ok, msg = self.b.open_terminal()
        self.after_action(ok, msg, "")
        if ok and not self.b.dry_run:
            self.close()



class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.connect("activate", self._on_activate)

    def _on_activate(self, app):
        install_css(CSS.decode())
        backend = Backend()
        theme = backend.panel_theme()
        apply_theme(theme)
        Settings(app, backend).present()


def main():
    lock = open(f"/tmp/layerosx-panel-{os.getuid()}.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    return App().run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
