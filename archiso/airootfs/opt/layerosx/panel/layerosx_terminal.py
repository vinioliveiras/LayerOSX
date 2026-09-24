#!/usr/bin/env python3
"""
LayerOSX Terminal: the maintenance terminal as a GTK4/libadwaita window with
the same macOS-style frame as LayerOSX Settings (traffic lights, rounded
client-side corners and shadow, light/dark following Settings > Appearance),
built on VTE (the GNOME terminal widget, package vte4).

    layerosx_terminal.py [log-file]

Runs an interactive bash with the same helpers the old xterm had (`logs`
follows the given log, `serial` the guest's serial console) and closes when
the shell exits. Opened by lib/peek-terminal.sh (which falls back to xterm if
GTK/VTE can't start); access control stays in lib/maint-terminal.sh.
Window title "LayerOSX — terminal" is what openbox centers and what
lib/raise-window.sh finds to bring it back.

Shortcuts: Ctrl+Shift+C / Ctrl+Shift+V copy/paste, Ctrl+plus / Ctrl+minus /
Ctrl+0 zoom, Ctrl+Shift+W close.
"""
import os
import sys
import tempfile

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Vte", "3.91")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango, Vte  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from layerosx_backend import Backend  # noqa: E402
from layerosx_style import apply_theme, install_css, traffic_lights  # noqa: E402

TITLE = "LayerOSX — terminal"

CSS = """
.term-header { min-height: 38px; }
.term-title { font-weight: 700; }
"""

# macOS Terminal-ish palettes ("Basic" light / dark)
PALETTES = {
    "light": ("#1d1d1f", "#ffffff"),
    "dark": ("#f2f2f7", "#1e1e1e"),
}
ANSI = ["#000000", "#c23621", "#25bc24", "#adad27", "#492ee1", "#d338d3", "#33bbc8", "#cbcccd",
        "#818383", "#fc391f", "#31e722", "#eaec23", "#5833ff", "#f935f8", "#14f0f0", "#e9ebeb"]


def rc_file(log: str) -> str:
    """The bash rcfile: same helpers and greeting the xterm terminal had."""
    fd, path = tempfile.mkstemp(prefix="layerosx-term-", suffix=".rc")
    with os.fdopen(fd, "w") as f:
        f.write(f'''[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
export LOG={GLib.shell_quote(log)}
export SERIAL_LOG="$HOME/mac-vm-serial.log"
logs()   {{ tail -n 200 -f "$LOG" 2>/dev/null || echo "Nothing to show yet."; }}
serial() {{ tail -n 200 -f "$SERIAL_LOG" 2>/dev/null || echo "No guest serial log yet."; }}
PS1='\\[\\e[1m\\]\\u@layerosx\\[\\e[0m\\] \\w \\$ '
echo "LayerOSX terminal — last lines of $LOG:"
echo
tail -n 20 "$LOG" 2>/dev/null || echo "(nothing logged yet)"
echo
echo "Type 'commands' for the LayerOSX commands, 'logs' to follow the log live,"
echo "'serial' for the Mac's own boot log (Ctrl-C stops watching)."
rm -f {GLib.shell_quote(path)}
''')
    return path


class Terminal(Adw.ApplicationWindow):
    def __init__(self, app, log: str, theme: str):
        super().__init__(application=app, title=TITLE)
        self.set_default_size(880, 540)

        tv = Adw.ToolbarView()
        hb = Adw.HeaderBar(show_start_title_buttons=False, show_end_title_buttons=False,
                           css_classes=["term-header"])
        hb.pack_start(traffic_lights(self.close, self.close, self._toggle_zoom, dark=theme == "dark"))
        hb.set_title_widget(Adw.WindowTitle(title="Terminal", subtitle="LayerOSX"))
        tv.add_top_bar(hb)

        self.term = Vte.Terminal(vexpand=True, hexpand=True)
        self.term.set_font(Pango.FontDescription.from_string("Monospace 11"))
        self.term.set_scrollback_lines(10000)
        self.term.set_cursor_blink_mode(Vte.CursorBlinkMode.ON)
        fg, bg = PALETTES["dark" if theme == "dark" else "light"]
        self.term.set_colors(_rgba(fg), _rgba(bg), [_rgba(c) for c in ANSI])
        self.term.connect("child-exited", lambda *_: self.close())
        self.term.set_margin_start(6)
        self.term.set_margin_end(2)
        tv.set_content(self.term)
        self.set_content(tv)

        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self._on_key)
        self.add_controller(keys)

        rc = rc_file(log)
        argv = ["/bin/bash", "--rcfile", rc, "-i"]
        self.term.spawn_async(Vte.PtyFlags.DEFAULT, os.path.expanduser("~"), argv, None,
                              GLib.SpawnFlags.DEFAULT, None, None, -1, None, None, None)
        self.term.grab_focus()

    def _toggle_zoom(self):
        self.unmaximize() if self.is_maximized() else self.maximize()

    def _on_key(self, _ctl, keyval, _code, state):
        ctrl = state & Gdk.ModifierType.CONTROL_MASK
        shift = state & Gdk.ModifierType.SHIFT_MASK
        k = Gdk.keyval_to_lower(keyval)
        if ctrl and shift and k == Gdk.KEY_c:
            self.term.copy_clipboard_format(Vte.Format.TEXT)
            return True
        if ctrl and shift and k == Gdk.KEY_v:
            self.term.paste_clipboard()
            return True
        if ctrl and shift and k == Gdk.KEY_w:
            self.close()
            return True
        if ctrl and k in (Gdk.KEY_plus, Gdk.KEY_equal, Gdk.KEY_KP_Add):
            self.term.set_font_scale(min(3.0, self.term.get_font_scale() + 0.1))
            return True
        if ctrl and k in (Gdk.KEY_minus, Gdk.KEY_KP_Subtract):
            self.term.set_font_scale(max(0.5, self.term.get_font_scale() - 0.1))
            return True
        if ctrl and k == Gdk.KEY_0:
            self.term.set_font_scale(1.0)
            return True
        return False


def _rgba(hex_color: str) -> Gdk.RGBA:
    c = Gdk.RGBA()
    c.parse(hex_color)
    return c


class App(Adw.Application):
    def __init__(self, log: str):
        super().__init__(application_id="org.layerosx.Terminal", flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.log = log
        self.connect("activate", self._on_activate)

    def _on_activate(self, app):
        install_css(CSS)
        theme = Backend().panel_theme()
        apply_theme(theme)
        Terminal(app, self.log, theme).present()


def main():
    log = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/mac-vm.log")
    return App(log).run([sys.argv[0]])


if __name__ == "__main__":
    sys.exit(main())
