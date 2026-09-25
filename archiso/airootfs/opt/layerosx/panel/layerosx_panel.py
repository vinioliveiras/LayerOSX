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
from layerosx_style import apply_theme, install_css, present_animated, traffic_lights  # noqa: E402

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
    ("maintenance", "Maintenance", "applications-engineering-symbolic", "gray"),
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


WIFI_REFRESH_SECONDS = 10      # Wi-Fi list refresh while that page is open


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
        self._maint_unlocked = False   # Settings > Maintenance, once the password is typed
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
        start = {"terminal": "maintenance"}.get(start, start)   # the old Terminal section
        self.select(start if start in dict((s[0], s) for s in SECTIONS) else "wifi")
        self.refresh()
        GLib.timeout_add_seconds(REFRESH_SECONDS, lambda: self.refresh() or True)
        GLib.timeout_add_seconds(WIFI_REFRESH_SECONDS, self._wifi_autorefresh)

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
        self.current_sid = sid
        if sid == "wifi":
            self._wifi_key = None
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
        # notify::active, not state-set: returning True from state-set to hold
        # the switch while asking left "active" and "state" apart, which GTK
        # draws as a coloured switch in the off position.
        self.wifi_switch.connect("notify::active", self._on_wifi_radio)
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

    def _scan_wifi(self, rescan=True):
        if "wifi" not in self.pages:
            return
        if rescan:
            self.wifi_spinner.set_spinning(True)
        run_async(lambda: (self.b.wifi_enabled(), self.b.wifi_scan(rescan=rescan)), self._show_wifi)

    def _wifi_autorefresh(self):
        """Every WIFI_REFRESH_SECONDS while the Wi-Fi page is on screen: re-read
        NetworkManager's list (it scans by itself; a forced rescan only every
        third time) and redraw only if something changed."""
        if getattr(self, "current_sid", "") == "wifi" and self.get_visible() \
                and not self.wifi_spinner.get_spinning():
            self._wifi_ticks = getattr(self, "_wifi_ticks", 0) + 1
            self._scan_wifi(rescan=self._wifi_ticks % 3 == 0)
        return True

    def _show_wifi(self, res):
        self.wifi_spinner.set_spinning(False)
        if not isinstance(res, Exception):
            key = (res[0], tuple((n.ssid, n.connected, n.secure, wifi_icon(n.signal)) for n in res[1]))
            if key == getattr(self, "_wifi_key", None):
                return False                 # nothing changed: don't redraw under the pointer
            self._wifi_key = key
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

    def _on_wifi_radio(self, sw, _pspec):
        if self._updating:
            return
        if not sw.get_active():
            # Back on until the user confirms; then off for real.
            self._updating = True
            sw.set_active(True)
            self._updating = False

            def off():
                self._updating = True
                sw.set_active(False)
                self._updating = False
                self._set_radio(False)
            self.confirm("Turn Wi-Fi off?", "The Mac loses its internet connection too (unless a cable is plugged in).",
                         "Turn Off", off, destructive=True)
            return
        self._set_radio(True)

    def _set_radio(self, on):
        self._wifi_key = None                # redraw after the change
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
            self._wifi_key = None
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
        page.add(self._power_mode_group())
        return self._pane("Battery", page)

    def _power_mode_group(self):
        g = Adw.PreferencesGroup(
            title="Power mode",
            description="How fast this computer's processor runs. macOS can't control it, so it's set "
                        "here. Performance makes the Mac feel quicker; Power Saver lasts longer on battery.")
        self.power_row = Adw.ComboRow(title="Mode")
        self.power_row.add_prefix(Gtk.Image.new_from_icon_name("power-profile-balanced-symbolic"))
        self._power_values = [m[0] for m in self.b.POWER_MODES]
        self.power_row.set_model(Gtk.StringList.new([m[1] for m in self.b.POWER_MODES]))
        self.power_row.connect("notify::selected", self._on_power_mode)
        g.add(self.power_row)
        self._sync_power_mode()
        return g

    def _sync_power_mode(self):
        cur = self.b.power_mode()
        self._updating = True
        try:
            if self.power_row.get_selected() != self._power_values.index(cur):
                self.power_row.set_selected(self._power_values.index(cur))
        finally:
            self._updating = False
        run_async(self.b.power_status, self._show_power_status)
        return False

    def _show_power_status(self, st):
        if isinstance(st, Exception) or not st:
            self.power_row.set_subtitle(dict((m[0], m[2]) for m in self.b.POWER_MODES)[self.b.power_mode()])
            return False
        names = {m[0]: m[1] for m in self.b.POWER_MODES}
        now = names.get(st.get("effective", ""), st.get("effective", ""))
        bits = [f"Now: {now}" + (" (on the charger)" if st.get("saved") == "auto" and st.get("on_ac") == "yes"
                                 else " (on battery)" if st.get("saved") == "auto" else "")]
        if st.get("driver"):
            bits.append(f"{st['driver']} · {st.get('governor', '')}" + (f" · {st['epp']}" if st.get("epp") else ""))
        if st.get("profile"):
            bits.append(f"profile {st['profile']}")
        self.power_row.set_subtitle(" — ".join(bits))
        return False

    def _on_power_mode(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._power_values):
            return
        v = self._power_values[i]
        ok, msg = self.b.set_power_mode(v)
        self.after_action(ok, msg, f"Power mode: {row.get_selected_item().get_string()}")
        GLib.idle_add(self._sync_power_mode)

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
        page.add(self._screens_group())

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
        page.add(self._reims_gpu_group())
        page.add(self._performance_group())
        self._sync_displays()
        return self._pane("Displays", page)

    # ------------------------------------------------------ Performance
    def _performance_group(self):
        g = Adw.PreferencesGroup(title="Performance")
        self.fps_row = Adw.ActionRow(title="Frame rate", subtitle="Shown while the Mac runs on Reims")
        self.fps_row.add_prefix(Gtk.Image.new_from_icon_name("video-display-symbolic"))
        self.fps_label = Gtk.Label(label="—", css_classes=["dim-label"])
        self.fps_row.add_suffix(self.fps_label)
        g.add(self.fps_row)
        self.effects_row = Adw.SwitchRow(
            title="Window effects",
            subtitle="Animations and rounded corners for these windows. If the Mac feels slow, "
                     "turn this off and compare the frame rate. Changes right away.")
        self.effects_row.add_prefix(Gtk.Image.new_from_icon_name("preferences-desktop-appearance-symbolic"))
        self.effects_row.set_active(self.b.effects())
        self.effects_row.connect("notify::active", self._on_effects)
        g.add(self.effects_row)
        self._sync_fps()
        return g

    def _sync_fps(self):
        run_async(self.b.mac_fps, self._show_fps)

    def _show_fps(self, v):
        if hasattr(self, "fps_label"):
            self.fps_label.set_label("—" if v is None or isinstance(v, Exception) else f"{v:g} fps")
        return False

    def _on_effects(self, row, _pspec):
        on = row.get_active()
        ok, msg = self.b.set_effects(on)
        self.after_action(ok, msg, "Window effects on" if on else "Window effects off")

    # ------------------------------------------------------------ Screens
    def _screens_group(self):
        g = Adw.PreferencesGroup(
            title="Screens",
            description="The Mac has one display. Choose which screen shows it. "
                        "Applies when the Mac restarts.")
        self.screen_row = Adw.ComboRow(title="Show the Mac on")
        self.screen_row.add_prefix(Gtk.Image.new_from_icon_name("video-display-symbolic"))
        self.screen_row.connect("notify::selected", self._on_screen)
        g.add(self.screen_row)
        self.others_row = Adw.ComboRow(title="Other screens")
        self.others_row.add_prefix(Gtk.Image.new_from_icon_name("view-dual-symbolic"))
        self.others_row.connect("notify::selected", self._on_others)
        g.add(self.others_row)
        self.res_row = Adw.ComboRow(title="Resolution")
        self.res_row.add_prefix(Gtk.Image.new_from_icon_name("view-fullscreen-symbolic"))
        self.res_row.connect("notify::selected", self._on_mode)
        g.add(self.res_row)
        self.rate_row = Adw.ComboRow(title="Refresh rate")
        self.rate_row.add_prefix(Gtk.Image.new_from_icon_name("preferences-system-time-symbolic"))
        self.rate_row.connect("notify::selected", self._on_mode)
        g.add(self.rate_row)
        self._sync_screens()
        return g

    def _sync_screens(self):
        screens = self.b.screens()
        target, others = self.b.screen_target(), self.b.screen_others()
        self._updating = True
        try:
            def label(sc):
                return sc.label
            names = [sc.name for sc in screens]
            # A saved screen that's unplugged right now stays listed, so the
            # choice isn't silently lost.
            self._screen_values = ["auto"] + names + ([target] if target != "auto" and target not in names else [])
            labels = ["Automatic"] + [label(sc) for sc in screens] + \
                     ([f"{target} (not connected)"] if target != "auto" and target not in names else [])
            self._set_choices(self.screen_row, labels, self._screen_values.index(target))
            if target == "auto":
                sub = ("An external screen when one is plugged in, else the built-in one — "
                       "plugging or unplugging moves the Mac" if len(screens) > 1 else "")
            elif target not in names:
                sub = "Not connected — every screen is turned on instead"
            else:
                sc = next(sc for sc in screens if sc.name == target)
                sub = f"{sc.name} · {sc.width}×{sc.height}" if sc.width else sc.name
            if len(screens) <= 1 and target == "auto":
                sub = "Only one screen connected — plug in another and the Mac moves to it"
            self.screen_row.set_subtitle(sub)
            self._others_values = ["off", "mirror"]
            self._set_choices(self.others_row, ["Turn off", "Mirror the Mac"],
                              self._others_values.index(others))
            self.others_row.set_sensitive(True)
            self.others_row.set_visible(len(screens) > 1 or target != "auto")
            self._sync_modes(screens)
        finally:
            self._updating = False
        return False

    def _sync_modes(self, screens):
        """Resolution / refresh rate of the Mac's screen (the chosen one, or
        the primary on Automatic). Called with _updating set."""
        sc = self.b.mac_screen(screens)
        self._mode_screen = sc
        for row in (self.res_row, self.rate_row):
            row.set_visible(bool(sc and sc.modes))
        if not sc or not sc.modes:
            return
        size, rate = self.b.screen_mode(sc.name)
        pretty = lambda sz: sz.replace("x", " × ")
        self._res_values = [None] + [m["size"] for m in sc.modes]
        self._set_choices(self.res_row,
                          [f"Automatic — {pretty(sc.preferred)}"] +
                          [pretty(m["size"]) + (" (native)" if m["size"] == sc.preferred else "") for m in sc.modes],
                          self._res_values.index(size) if size in self._res_values else 0)
        self.res_row.set_subtitle(sc.label if len(screens) > 1 else "")
        eff = size or sc.preferred
        rates = next((m["rates"] for m in sc.modes if m["size"] == eff), [])
        hz = lambda r: f"{r:.0f} Hz" if abs(r - round(r)) < 0.05 else f"{r:.2f} Hz"
        self._rate_values = [None] + rates
        pick = 0
        if rate:
            pick = next((i for i, r in enumerate(self._rate_values) if r and abs(r - rate) < 0.5), 0)
        self._set_choices(self.rate_row,
                          [f"Highest — {hz(rates[0])}" if rates else "Highest"] + [hz(r) for r in rates], pick)

    def _on_mode(self, row, _pspec):
        if self._updating or not getattr(self, "_mode_screen", None):
            return
        ri, ti = self.res_row.get_selected(), self.rate_row.get_selected()
        if ri >= len(self._res_values) or ti >= len(self._rate_values):
            return
        size = self._res_values[ri]
        rate = self._rate_values[ti] if row is self.rate_row else None   # new resolution -> highest rate
        ok, msg = self.b.set_screen_mode(self._mode_screen.name, size, rate)
        what = (f"{size.replace('x', ' × ')}" if size else "Resolution: Automatic") + \
               (f" at {rate:g} Hz" if rate else "")
        self._resource_changed_screens(ok, msg, what)

    # ------------------------------------------------------- Reims GPU
    def _reims_gpu_group(self):
        g = Adw.PreferencesGroup(
            title="Graphics card",
            description="Which GPU draws the Mac when Graphics is Reims. Automatic lets Reims choose "
                        "(it prefers a dedicated GPU). Applies when the Mac restarts.")
        self.gpu_row = Adw.ComboRow(title="Draw with")
        self.gpu_row.add_prefix(Gtk.Image.new_from_icon_name("video-display-symbolic"))
        self.gpu_row.connect("notify::selected", self._on_reims_gpu)
        g.add(self.gpu_row)
        self._reims_gpu_list = self.b.reims_gpus()
        g.set_visible(bool(self._reims_gpu_list))
        self._sync_reims_gpu()
        return g

    def _sync_reims_gpu(self):
        gpus, cur = self._reims_gpu_list, self.b.reims_gpu()
        self._updating = True
        try:
            self._gpu_values = ["auto"] + [x.id for x in gpus]
            labels = ["Automatic"] + [x.label for x in gpus]
            if cur not in self._gpu_values:
                self._gpu_values.append(cur)
                labels.append(f"{cur} (not found)")
            self._set_choices(self.gpu_row, labels, self._gpu_values.index(cur))
            g = next((x for x in gpus if x.id == cur), None)
            self.gpu_row.set_subtitle(f"{g.driver} · {g.id}" if g else "")
        finally:
            self._updating = False
        return False

    def _on_reims_gpu(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._gpu_values):
            return
        v = self._gpu_values[i]
        ok, msg = self.b.set_reims_gpu(v)
        self.after_action(ok, msg, ("Reims: Automatic GPU" if v == "auto"
                                    else f"Reims will draw with {row.get_selected_item().get_string()}")
                          + " — applies when the Mac restarts")
        if ok:
            self._pending_restart()
        GLib.idle_add(self._sync_reims_gpu)

    def _on_screen(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._screen_values):
            return
        v = self._screen_values[i]
        ok, msg = self.b.set_screen_target(v)
        what = "The Mac's screen: Automatic" if v == "auto" else f"The Mac will show on {row.get_selected_item().get_string()}"
        self._resource_changed_screens(ok, msg, what)

    def _on_others(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._others_values):
            return
        v = self._others_values[i]
        ok, msg = self.b.set_screen_others(v)
        self._resource_changed_screens(ok, msg, "Other screens: " + ("off" if v == "off" else "mirror the Mac"))

    def _resource_changed_screens(self, ok, msg, what):
        self.after_action(ok, msg, f"{what} — applies when the Mac restarts")
        if ok:
            self._pending_restart()
        GLib.idle_add(self._sync_screens)

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
        page.add(self._volume_group())
        page.add(self._audio_output_group())
        self._sync_switches()
        return self._pane("Sound", page)

    def _volume_group(self):
        """This computer's volume (host ALSA mixer), live. macOS's own slider
        still works on top of it."""
        self.vol_group = Adw.PreferencesGroup(
            title="Volume",
            description="This computer's volume. It changes right away; the Mac's own volume works on top of it.")
        r = Adw.ActionRow()
        self.vol_mute = Gtk.ToggleButton(icon_name="audio-volume-high-symbolic", valign=Gtk.Align.CENTER,
                                         tooltip_text="Mute")
        self.vol_mute.add_css_class("flat")
        self.vol_mute.connect("toggled", self._on_mute)
        r.add_prefix(self.vol_mute)
        self.vol = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 5)
        self.vol.set_hexpand(True)
        self.vol.set_draw_value(False)
        self.vol.connect("value-changed", self._on_volume)
        r.add_suffix(self.vol)
        self.vol_group.add(r)
        self._vol_src = None
        self._sync_volume()
        return self.vol_group

    def _sync_volume(self):
        v = self.b.volume()
        self.vol_group.set_visible(v is not None)
        if v is None or self._vol_src is not None:
            return False
        self._updating = True
        try:
            self.vol.set_value(v[0])
            self.vol_mute.set_active(v[1])
            self._vol_icon(v[0], v[1])
        finally:
            self._updating = False
        return False

    def _vol_icon(self, pct, muted):
        name = ("audio-volume-muted-symbolic" if muted or pct == 0 else
                "audio-volume-low-symbolic" if pct < 34 else
                "audio-volume-medium-symbolic" if pct < 67 else "audio-volume-high-symbolic")
        self.vol_mute.set_icon_name(name)
        self.vol_mute.set_tooltip_text("Unmute" if muted else "Mute")

    def _on_volume(self, scale):
        if self._updating:
            return
        if self._vol_src:
            GLib.source_remove(self._vol_src)
        self._vol_icon(int(scale.get_value()), self.vol_mute.get_active())

        def apply():
            self._vol_src = None
            ok, msg = self.b.set_volume(int(scale.get_value()))
            if not ok:
                self.toast(msg or "Couldn't change the volume")
            elif self.b.dry_run:
                self.after_action(ok, msg, "")
            return False
        self._vol_src = GLib.timeout_add(100, apply)

    def _on_mute(self, btn):
        if self._updating:
            return
        muted = btn.get_active()
        ok, msg = self.b.set_volume(muted=muted)
        if not ok:
            self.toast(msg or "Couldn't mute")
        self._vol_icon(int(self.vol.get_value()), muted)

    def _audio_output_group(self):
        g = Adw.PreferencesGroup(
            title="Output",
            description="Where the Mac's sound plays. Automatic uses the speakers / headphone jack, "
                        "never an HDMI screen. Applies when the Mac restarts.")
        self.audio_out_row = Adw.ComboRow(title="Play through")
        self.audio_out_row.add_prefix(Gtk.Image.new_from_icon_name("audio-speakers-symbolic"))
        self.audio_out_row.connect("notify::selected", self._on_audio_output)
        g.add(self.audio_out_row)
        self._audio_out_list = self.b.audio_outputs()
        g.set_visible(bool(self._audio_out_list))
        self._sync_audio_output()
        return g

    def _sync_audio_output(self):
        outs, cur = self._audio_out_list, self.b.audio_output()
        self._updating = True
        try:
            self._audio_out_values = ["auto"] + [o.id for o in outs]
            labels = ["Automatic"] + [o.label for o in outs]
            if cur not in self._audio_out_values:
                self._audio_out_values.append(cur)
                labels.append(f"{cur} (not found)")
            self._set_choices(self.audio_out_row, labels, self._audio_out_values.index(cur))
            now = self.b.audio_output_now()
            self.audio_out_row.set_subtitle(f"Now: {now.label}" if cur == "auto" and now else "")
        finally:
            self._updating = False
        return False

    def _on_audio_output(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._audio_out_values):
            return
        v = self._audio_out_values[i]
        ok, msg = self.b.set_audio_output(v)
        self.after_action(ok, msg, ("Sound: Automatic output" if v == "auto"
                                    else f"Sound will play through {row.get_selected_item().get_string()}")
                          + " — applies when the Mac restarts")
        if ok:
            self._pending_restart()
        GLib.idle_add(self._sync_audio_output)
        GLib.idle_add(self._sync_volume)

    # ------------------------------------------------------------------ USB
    def _on_monitoring(self, row, _pspec):
        if self._updating:
            return
        on = row.get_active()

        def done(res):
            ok, msg = res if isinstance(res, tuple) else (False, str(res))
            m = self.b.monitoring()
            self.after_action(ok, msg, (f"Monitoring on — {os.path.basename(m['session'])}" if on and m["running"]
                                        else "Monitoring on" if on else "Monitoring off — summary saved"))
            return False
        run_async(lambda: self.b.set_monitoring(on), done)

    def _page_usb(self):
        page = Adw.PreferencesPage()
        auto_g = Adw.PreferencesGroup()
        self.usb_auto_row = Adw.SwitchRow(
            title="Give new devices to the Mac",
            subtitle="Anything plugged into a USB port goes to the Mac. Built-in devices, "
                     "keyboards and mice stay on this computer; a device you switch off stays off.")
        self.usb_auto_row.add_prefix(Gtk.Image.new_from_icon_name("media-removable-symbolic"))
        self.usb_auto_row.set_active(self.b.usb_auto())
        self.usb_auto_row.connect("notify::active", self._on_usb_auto)
        auto_g.add(self.usb_auto_row)
        page.add(auto_g)
        self.usb_group = Adw.PreferencesGroup(
            title="Devices",
            description="Switch a device on to give it to the Mac. The star gives it to the Mac "
                        "automatically every time it's plugged in.")
        page.add(self.usb_group)
        self._usb_rows = []
        refresh = Gtk.Button(icon_name="view-refresh-symbolic", tooltip_text="Refresh")
        refresh.connect("clicked", lambda *_: self._load_usb())
        return self._pane("USB Devices", page, refresh)

    def _on_usb_auto(self, row, _pspec):
        on = row.get_active()
        ok, msg = self.b.set_usb_auto(on)
        self.after_action(ok, msg, "New USB devices go to the Mac" if on else "New USB devices stay on this computer")
        if ok and on:
            # Give what's already plugged in right away, then show it.
            run_async(self.b.usb_auto_once, lambda _r: self._load_usb())

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
        page.add(self._model_group())
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

    # ------------------------------------------------------------- Model
    def _model_group(self):
        g = Adw.PreferencesGroup(
            title="Model",
            description="Which Mac this one reports itself as. Changing it makes macOS see a different "
                        "computer: iCloud and Keychain may ask you to sign in again. Your files stay. "
                        "Applies when the Mac restarts.")
        self.model_row = Adw.ComboRow(title="Mac model")
        self.model_row.add_prefix(Gtk.Image.new_from_icon_name("computer-symbolic"))
        self.model_row.connect("notify::selected", self._on_model)
        g.add(self.model_row)
        self._sync_model()
        return g

    def _sync_model(self):
        default, cur = self.b.mac_model_default(), self.b.mac_model()
        self._model_values = [m for m, _ in self.b.MAC_MODELS]
        labels = [label + (" — default" if m == default else "") for m, label in self.b.MAC_MODELS]
        self._updating = True
        try:
            self._set_choices(self.model_row, labels,
                              self._model_values.index(cur) if cur in self._model_values else 0)
            self.model_row.set_subtitle(cur)
        finally:
            self._updating = False
        return False

    def _on_model(self, row, _pspec):
        if self._updating:
            return
        i = row.get_selected()
        if i >= len(self._model_values):
            return
        v = self._model_values[i]
        ok, msg = self.b.set_mac_model(v)
        self.after_action(ok, msg, f"Mac model: {dict(self.b.MAC_MODELS)[v]} — applies when the Mac restarts")
        if ok:
            self._pending_restart()
        GLib.idle_add(self._sync_model)

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
            if res.ram_cap_mb and res.ram_mb > res.ram_cap_mb:
                self.ram_row.set_subtitle(f"Above what Reims can map into the GPU ({gb(res.ram_cap_mb)}): "
                                          "the Mac will be slower. Choose Automatic.")
            elif res.ram_cap_mb:
                self.ram_row.set_subtitle(f"With Reims, at most {gb(res.ram_cap_mb)} — the most its GPU can map")
            else:
                self.ram_row.set_subtitle("")
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
        return self._pane("General", page)

    def _vt_subtitle(self):
        base = ("Ctrl+Alt+F1–F6 switch to Linux text consoles (Ctrl+Alt+F2 asks for the Maintenance "
                "password, if one is set). Off keeps the computer locked to the Mac.")
        pending = self.b.text_consoles() != self.b.text_consoles_now()
        self.vt_row.set_subtitle(base + (" Takes effect after restarting the computer." if pending else ""))

    def _on_text_consoles(self, row, _pspec):
        if self._updating:
            return
        on = row.get_active()
        ok, msg = self.b.set_text_consoles(on)
        self.after_action(ok, msg, ("Text consoles on" if on else "Text consoles off")
                          + " — after restarting the computer")
        self._vt_subtitle()

    def _on_diag_logs(self, row, _pspec):
        if self._updating:
            return
        on = row.get_active()
        ok, msg = self.b.set_diag_logs(on)
        self.after_action(ok, msg, ("Detailed logs on" if on else "Detailed logs off")
                          + " — applies when the Mac restarts")
        if ok:
            self._pending_restart()

    # ------------------------------------------------------------- Terminal
    def _page_maintenance(self):
        """Everything for troubleshooting in one place: logs, diagnostics,
        terminal, text consoles -- and the optional password that guards it
        (plus Ctrl+Alt+T and tty2). Locked until unlocked when one is set."""
        if self.b.maint_password_set() and not self._maint_unlocked:
            return self._pane("Maintenance", self._maint_lock_view())
        page = Adw.PreferencesPage()
        lg = Adw.PreferencesGroup(title="Logs", description="Log switches apply when the Mac restarts.")
        self.verbose_row = Adw.SwitchRow(title="Show startup log",
                                         subtitle="Text log instead of the logo while macOS starts — useful when something goes wrong")
        self.verbose_row.connect("notify::active", self._on_switch, "verbose", "Startup log")
        lg.add(self.verbose_row)
        self.diag_row = Adw.SwitchRow(
            title="Detailed logs",
            subtitle="For troubleshooting: macOS's kernel log (~/mac-vm-serial.log), OpenCore's log and "
                     "QEMU diagnostics (~/mac-vm-qemu.log). Also shows the startup log.")
        self.diag_row.set_active(self.b.diag_logs())
        self.diag_row.connect("notify::active", self._on_diag_logs)
        lg.add(self.diag_row)
        self.mon_row = Adw.SwitchRow(
            title="Monitoring mode",
            subtitle="Records CPU, graphics, memory, disk, network and every log each second into "
                     "~/monitoring — for finding slowdowns and drops. Ctrl+Alt+M marks a moment. "
                     "Save diagnostics includes it.")
        self.mon_row.add_prefix(Gtk.Image.new_from_icon_name("utilities-system-monitor-symbolic"))
        self.mon_row.set_active(self.b.monitoring()["saved"])
        self.mon_row.connect("notify::active", self._on_monitoring)
        lg.add(self.mon_row)
        d = Adw.ActionRow(title="Save diagnostics", subtitle="Copies the logs to a drive you choose")
        d.add_prefix(Gtk.Image.new_from_icon_name("document-save-symbolic"))
        db = Gtk.Button(label="Save…", valign=Gtk.Align.CENTER)
        db.connect("clicked", lambda *_: self.on_diag())
        d.add_suffix(db)
        lg.add(d)
        page.add(lg)

        if self.b.terminal_policy != "off":
            tg = Adw.PreferencesGroup(title="Terminal",
                                      description="A command line on this computer (the Linux underneath the Mac). "
                                                  "Ctrl+Alt+T opens it from anywhere; type `commands` for the list.")
            o = Adw.ActionRow(title="Open Terminal")
            o.add_prefix(Gtk.Image.new_from_icon_name("utilities-terminal-symbolic"))
            b = Gtk.Button(label="Open…", valign=Gtk.Align.CENTER, css_classes=["suggested-action"])
            b.connect("clicked", lambda *_: self.on_terminal())
            o.add_suffix(b)
            tg.add(o)
            ex = Adw.ExpanderRow(title="Useful commands")
            for cmd, what in (("gpu vmware", "Switch to the reliable display (then: relaunch)"),
                              ("relaunch", "Restart the Mac to apply a change"),
                              ("maclog", "Show the Mac's startup log"),
                              ("macdiag usb", "Save a diagnostics bundle to a USB drive")):
                ex.add_row(Adw.ActionRow(title=cmd, subtitle=what, title_selectable=True))
            tg.add(ex)
            page.add(tg)

        ag = Adw.PreferencesGroup(title="Advanced")
        self.vt_row = Adw.SwitchRow(title="Text consoles")
        self.vt_row.add_prefix(Gtk.Image.new_from_icon_name("input-keyboard-symbolic"))
        self.vt_row.set_active(self.b.text_consoles())
        self._vt_subtitle()
        self.vt_row.connect("notify::active", self._on_text_consoles)
        ag.add(self.vt_row)
        page.add(ag)

        pg = Adw.PreferencesGroup(title="Password")
        on = self.b.maint_password_set()
        pr = Adw.ActionRow(
            title="Maintenance password",
            subtitle=("On — needed to open Maintenance, the terminal (Ctrl+Alt+T) and the text console"
                      if on else "Off — anyone at this computer can use Maintenance and the terminal"))
        pr.add_prefix(Gtk.Image.new_from_icon_name("system-lock-screen-symbolic"))
        box = Gtk.Box(spacing=6, valign=Gtk.Align.CENTER)
        if on:
            ch = Gtk.Button(label="Change…")
            ch.connect("clicked", lambda *_: self._maint_password_dialog(change=True))
            rm = Gtk.Button(label="Turn Off…", css_classes=["destructive-action"])
            rm.connect("clicked", lambda *_: self._maint_password_dialog(remove=True))
            box.append(ch)
            box.append(rm)
        else:
            st = Gtk.Button(label="Set…")
            st.connect("clicked", lambda *_: self._maint_password_dialog())
            box.append(st)
        pr.add_suffix(box)
        pg.add(pr)
        page.add(pg)
        self._sync_switches()
        return self._pane("Maintenance", page)

    def _maint_lock_view(self):
        sp = Adw.StatusPage(icon_name="system-lock-screen-symbolic", title="Maintenance is locked",
                            description="Enter the Maintenance password to see logs, diagnostics and the terminal.")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, halign=Gtk.Align.CENTER)
        entry = Gtk.PasswordEntry(show_peek_icon=True, width_chars=24)
        btn = Gtk.Button(label="Unlock", css_classes=["suggested-action", "pill"], halign=Gtk.Align.CENTER)
        self._maint_entry = entry

        def unlock(*_):
            if self.b.check_maint_password(entry.get_text()):
                self._maint_unlocked = True
                self._rebuild_page("maintenance")
            else:
                entry.set_text("")
                entry.add_css_class("error")
                self.toast("Wrong password")
        entry.connect("activate", unlock)
        btn.connect("clicked", unlock)
        box.append(entry)
        box.append(btn)
        sp.set_child(box)
        GLib.idle_add(lambda: (entry.grab_focus(), False)[1])
        return sp

    def _rebuild_page(self, sid):
        self.pages.pop(sid, None)
        self.select(sid, from_sidebar=True)

    def _maint_password_dialog(self, change=False, remove=False):
        heading = ("Turn off the Maintenance password?" if remove
                   else "Change the Maintenance password" if change else "Set a Maintenance password")
        body = ("Anyone at this computer will be able to use Maintenance and the terminal." if remove
                else "Needed to open Maintenance, the terminal (Ctrl+Alt+T) and the text console. "
                     "It's separate from your macOS password.")
        d = self._dialog(heading, body)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        cur = new = rep = None
        if change or remove:
            cur = Gtk.PasswordEntry(show_peek_icon=True, placeholder_text="Current password")
            box.append(cur)
        if not remove:
            new = Gtk.PasswordEntry(show_peek_icon=True, placeholder_text="New password")
            rep = Gtk.PasswordEntry(show_peek_icon=True, placeholder_text="Repeat new password")
            box.append(new)
            box.append(rep)
        d.set_extra_child(box)
        d.add_response("cancel", "Cancel")
        d.add_response("ok", "Turn Off" if remove else "Save")
        d.set_response_appearance("ok", Adw.ResponseAppearance.DESTRUCTIVE if remove
                                  else Adw.ResponseAppearance.SUGGESTED)
        d.set_default_response("ok")
        d.set_close_response("cancel")

        def done(_d, r):
            if r != "ok":
                return
            if new is not None and new.get_text() != rep.get_text():
                self.toast("The new passwords don't match")
                return
            ok, msg = self.b.set_maint_password(new.get_text() if new is not None else "",
                                                cur.get_text() if cur is not None else "")
            if ok:
                self._maint_unlocked = True
                self.toast("Maintenance password turned off" if remove else "Maintenance password saved")
                self._rebuild_page("maintenance")
            else:
                self.toast(msg)
        d.connect("response", done)
        self._present(d)
        (cur or new).grab_focus()

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
        # One ISO for everyone now; only an old debug build still says so.
        mode = " · Debug build" if a.mode == "debug" else ""
        self.about_version.set_label(
            f"Version {a.layerosx_version}" + (f" · built {a.built}" if a.built else "") + mode)

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
        if "battery" in self.pages and hasattr(self, "power_row"):
            run_async(self.b.power_status, self._show_power_status)   # charger plugged/unplugged
        if "displays" in self.pages and hasattr(self, "fps_label"):
            self._sync_fps()                # refreshed with the 5 s status
        if "sound" in self.pages and hasattr(self, "vol_group"):
            self._sync_volume()             # volume keys change it outside the panel
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
        ok, msg = self.b.open_terminal(unlocked=self._maint_unlocked)
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
        present_animated(Settings(app, backend))


def main():
    lock = open(f"/tmp/layerosx-panel-{os.getuid()}.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    return App().run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
