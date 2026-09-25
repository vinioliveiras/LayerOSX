#!/usr/bin/env python3
"""Which physical screen shows the Mac (LayerOSX Settings > Displays > Screens).

The Mac has ONE display (Reims advertises a single display port, VMware/VGA
have one head), so with several monitors plugged in the question is only which
one shows it and what the others do. The choice lives in the state dir:

  display-target   xrandr output name (e.g. HDMI-1-0); absent/"auto" =
                   Automatic: an external screen when one is plugged in (the
                   one plugged in last), else the built-in one -- plugging or
                   unplugging a monitor moves the Mac by itself. A machine
                   with no built-in screen and only external ones is left as
                   Xorg lays it out.
  display-others   "off" (default) or "mirror" (same picture as the Mac's screen)
  display-modes    JSON {output: {"size": "WxH" | null, "rate": Hz | null}} --
                   a fixed resolution / refresh rate per screen (null size =
                   the screen's preferred resolution, null rate = the highest
                   that resolution supports). Absent = automatic.

Commands:
  list    JSON list of outputs: name, label, builtin, connected, active,
          primary, width, height, x, y, rate (current Hz), preferred ("WxH"),
          modes ([{size, rates}] best first) (label = EDID monitor name when there
          is one, else "Built-in display" / "HDMI" / "DisplayPort" ...)
  apply   put the Mac's screen at 0,0 as primary and turn off / mirror the
          others; if the saved screen isn't connected, turn every connected
          screen back on (never leave the user with nothing lit). No-op when
          the layout already matches (no flicker on every relaunch).
  watch   poll every 3 s (xrandr --current: no re-probe); when screens are
          plugged/unplugged, apply again, move the Mac's window onto its
          screen (re-fullscreened there, so Reims scales to the new size) and
          say where the Mac went. Started from .xinitrc.

Run by mac-vm-launch.sh before each launch (apply) and by the panel (list).
Env: LAYEROSX_STATE_DIR overrides the state dir (tests). stdlib only.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time

STATE_DIR = os.environ.get("LAYEROSX_STATE_DIR", "/var/lib/layerosx")
BUILTIN = re.compile(r"^(eDP|LVDS|DSI)", re.I)
KINDS = (("HDMI", "HDMI"), ("DP", "DisplayPort"), ("DVI", "DVI"), ("VGA", "VGA"),
         ("USB", "USB-C"), ("Virtual", "Virtual"))
MAC_WINDOWS = ("^Reims vGPU$", "^QEMU")
LAST_PLUGGED = os.environ.get("LAYEROSX_DISPLAY_LAST", f"/tmp/layerosx-display-last-plugged-{os.getuid()}")


def _read(name):
    try:
        with open(os.path.join(STATE_DIR, name)) as f:
            return f.read().strip()
    except OSError:
        return ""


def _edid_name(hexdump):
    """Monitor name (descriptor tag 0xFC) from an EDID hex dump, or ''."""
    try:
        raw = bytes.fromhex(hexdump)
    except ValueError:
        return ""
    for off in (54, 72, 90, 108):
        d = raw[off:off + 18]
        if len(d) == 18 and d[0:3] == b"\x00\x00\x00" and d[3] == 0xFC:
            return d[5:].split(b"\n")[0].decode("ascii", "replace").strip()
    return ""


def _pixels(size):
    w, _, h = size.partition("x")
    return int(w) * int(h) if w.isdigit() and h.isdigit() else 0


def query():
    """Parse `xrandr --query --prop` into a list of output dicts."""
    if not shutil.which("xrandr"):
        return []
    try:
        out = subprocess.run(["xrandr", "--query", "--prop"], capture_output=True,
                             text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    outs, cur, edid = [], None, None
    for line in out.splitlines():
        m = re.match(r"^(\S+) (connected|disconnected)( primary)?(?: (\d+)x(\d+)\+(\d+)\+(\d+))?", line)
        if m:
            cur = {"name": m.group(1), "connected": m.group(2) == "connected",
                   "primary": bool(m.group(3)), "active": m.group(4) is not None,
                   "width": int(m.group(4) or 0), "height": int(m.group(5) or 0),
                   "x": int(m.group(6) or 0), "y": int(m.group(7) or 0), "monitor": "",
                   "rate": 0.0, "preferred": "", "modes": []}
            outs.append(cur)
            edid = None
            continue
        if cur is None:
            continue
        mm = re.match(r"^\s+(\d+)x(\d+)\s+(\d.*)$", line)
        if mm:
            if edid is not None:          # mode lines end the EDID block
                cur["monitor"] = _edid_name(edid)
                edid = None
            size = f"{mm.group(1)}x{mm.group(2)}"
            rates = []
            for r, flags in re.findall(r"(\d+\.\d+)([*+ ]*)", mm.group(3)):
                rates.append(float(r))
                if "*" in flags:
                    cur["rate"] = float(r)
                if "+" in flags:
                    cur["preferred"] = size
            m_old = next((m for m in cur["modes"] if m["size"] == size), None)
            if m_old:
                m_old["rates"] = sorted(set(m_old["rates"] + rates), reverse=True)
            else:
                cur["modes"].append({"size": size, "rates": sorted(set(rates), reverse=True)})
            continue
        if re.match(r"^\s+EDID:\s*$", line):
            edid = ""
            continue
        if edid is not None:
            h = line.strip()
            if re.fullmatch(r"[0-9a-fA-F]{32}", h):
                edid += h
                continue
            cur["monitor"] = _edid_name(edid)
            edid = None
    if cur is not None and edid:
        cur["monitor"] = _edid_name(edid)
    for o in outs:
        o["modes"].sort(key=lambda m: -_pixels(m["size"]))
        if not o["preferred"] and o["modes"]:
            o["preferred"] = o["modes"][0]["size"]
        o["builtin"] = bool(BUILTIN.match(o["name"]))
        kind = "Built-in display" if o["builtin"] else next(
            (label for pre, label in KINDS if o["name"].upper().startswith(pre.upper())), o["name"])
        o["label"] = o.pop("monitor") or kind
        if o["builtin"]:
            o["label"] = "Built-in display"
    return outs


def settings():
    target = _read("display-target")
    others = "mirror" if _read("display-others") == "mirror" else "off"
    return ("" if target in ("", "auto") else target), others


def saved_modes():
    try:
        data = json.loads(_read("display-modes") or "{}")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def wanted_mode(o, choice):
    """(size, rate) a saved choice resolves to on output `o`, or None when the
    choice is automatic or doesn't fit this screen (unplugged monitor swapped
    for another one on the same port, ...)."""
    if not isinstance(choice, dict) or (not choice.get("size") and not choice.get("rate")):
        return None
    size = choice.get("size") or o.get("preferred")
    mode = next((m for m in o.get("modes", []) if m["size"] == size), None)
    if not mode or not mode["rates"]:
        return None
    rate = choice.get("rate")
    if not isinstance(rate, (int, float)) or not any(abs(r - rate) < 0.5 for r in mode["rates"]):
        rate = mode["rates"][0]
    else:
        rate = min(mode["rates"], key=lambda r: abs(r - rate))
    return size, rate


def plan(outs, target, others, modes=None):
    """xrandr arguments that realise the choice, or [] when nothing to do."""
    modes = modes or {}
    connected = [o for o in outs if o["connected"]]
    if not connected:
        return []
    per = {}                      # output -> its xrandr options, target first
    t = next((o for o in connected if o["name"] == target), None) if target else None
    if target and t is None:
        # Saved screen is unplugged: light up every connected screen again,
        # unless they already all are.
        if not all(o["active"] for o in connected):
            return ["--auto"]
    if t is not None:
        ok = t["active"] and t["primary"] and (t["x"], t["y"]) == (0, 0)
        for o in outs:
            if o is t:
                continue
            if others == "off" or not o["connected"]:
                ok = ok and not o["active"]
            else:
                ok = ok and o["active"] and (o["x"], o["y"]) == (0, 0)
        if not ok:
            per[t["name"]] = ["--auto", "--primary", "--pos", "0x0"]
            for o in outs:
                if o is t:
                    continue
                if others == "mirror" and o["connected"]:
                    per[o["name"]] = ["--auto", "--same-as", t["name"]]
                elif o["active"] or o["connected"]:
                    per[o["name"]] = ["--off"]
    # Fixed resolution / refresh rate (Settings > Displays > Screens).
    for o in connected:
        want = wanted_mode(o, modes.get(o["name"]))
        if not want:
            continue
        if per.get(o["name"]) == ["--off"] or (o["name"] not in per and not o["active"]):
            continue                                  # screen is (being) turned off
        size, rate = want
        mode_args = ["--mode", size, "--rate", f"{rate:.2f}"]
        if o["name"] in per:
            per[o["name"]] = [a for a in per[o["name"]] if a != "--auto"] + mode_args
        elif not (o["active"] and f'{o["width"]}x{o["height"]}' == size and abs(o["rate"] - rate) < 0.5):
            per[o["name"]] = mode_args
    args = []
    for name, opts in per.items():
        args += ["--output", name] + opts
    return args


def effective_target(outs, target):
    """The output the Mac should be on: the chosen one; on Automatic, an
    external screen when one is connected (the last one plugged in, else the
    first by name), else the built-in one. "" = leave Xorg's layout alone (no
    built-in screen, nothing external either: a desktop's own arrangement)."""
    if target:
        return target
    connected = [o for o in outs if o["connected"]]
    ext = [o for o in connected if not o["builtin"]]
    builtin = next((o for o in connected if o["builtin"]), None)
    if ext and builtin:
        last = _read_path(LAST_PLUGGED)
        return next((o["name"] for o in ext if o["name"] == last), ext[0]["name"])
    return ""


def _read_path(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _mac_screen(outs, target):
    t = next((o for o in outs if o["name"] == target and o["active"]), None)
    return t or next((o for o in outs if o["primary"] and o["active"]), None) \
        or next((o for o in outs if o["active"]), None)


def follow(outs, target):
    """Point the mouse (openbox places new windows there) and the Mac's window
    at the Mac's screen. Best effort: needs xdotool."""
    s = _mac_screen(outs, target)
    if not s or not shutil.which("xdotool"):
        return
    subprocess.run(["xdotool", "mousemove", str(s["x"] + s["width"] // 2),
                    str(s["y"] + s["height"] // 2)], capture_output=True)
    for pattern in MAC_WINDOWS:
        ids = subprocess.run(["xdotool", "search", "--name", pattern],
                             capture_output=True, text=True).stdout.split()
        for wid in ids:
            # A fullscreen window is pinned to its old monitor's geometry:
            # drop fullscreen, move/size it onto the Mac's screen, fullscreen
            # it again there (Reims then scales the Mac to the new size).
            subprocess.run(["xdotool", "windowstate", "--remove", "FULLSCREEN", wid], capture_output=True)
            subprocess.run(["xdotool", "windowmove", wid, str(s["x"]), str(s["y"]),
                            "windowsize", wid, str(s["width"]), str(s["height"])],
                           capture_output=True)
            subprocess.run(["xdotool", "windowstate", "--add", "FULLSCREEN", wid], capture_output=True)


def apply(quiet=False):
    target, others = settings()
    outs = query()
    target = effective_target(outs, target)
    args = plan(outs, target, others, saved_modes())
    if args:
        if not quiet:
            print("displays: xrandr " + " ".join(args))
        subprocess.run(["xrandr"] + args, capture_output=True)
        time.sleep(1)
        outs = query()
        # --auto picks each screen's preferred mode; bring the refresh rate
        # back up the way .xinitrc does (it leaves screens with a fixed
        # mode in display-modes alone).
        fmr = os.path.join(os.path.dirname(os.path.abspath(__file__)), "force-max-refresh.sh")
        if os.path.exists(fmr):
            subprocess.Popen(["bash", fmr], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    if target or args:
        follow(outs, target)
    return args


def connected_now():
    """Names of connected outputs WITHOUT making the driver re-probe.

    `xrandr --query` (RRGetScreenResources) makes the X driver re-detect every
    output and re-read EDIDs over DDC; on NVIDIA that stalls the display for a
    moment. Doing it every few seconds froze the screen periodically in every
    graphics mode (seen on hardware). `--current` (RRGetScreenResourcesCurrent)
    only reads the server's state, which the driver updates by itself on
    hotplug -- cheap enough to poll."""
    if not shutil.which("xrandr"):
        return ()
    try:
        out = subprocess.run(["xrandr", "--current"], capture_output=True,
                             text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ()
    return tuple(sorted(m.group(1) for m in re.finditer(r"^(\S+) connected", out, re.M)))


def notify(text):
    """A short notice above the Mac (openbox keeps LayerOSX* windows on top)."""
    if shutil.which("zenity"):
        subprocess.Popen(["zenity", "--info", "--width=380", "--timeout=6", "--no-wrap",
                          "--title=LayerOSX — Displays", f"--text={text}"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def watch():
    """Re-apply the screen choice on plug/unplug. Polls the cheap
    connected_now(); the full query() (a real probe) runs only when something
    actually changed."""
    last = None
    while True:
        seen = connected_now()
        if last is not None and seen != last:
            plugged = [n for n in seen if n not in last and not BUILTIN.match(n)]
            if plugged:
                try:
                    with open(LAST_PLUGGED, "w") as f:
                        f.write(plugged[-1] + "\n")
                except OSError:
                    pass
            time.sleep(2)                # EDID settling right after a plug
            q = query()
            before = _mac_screen(q, effective_target(q, settings()[0]))
            apply(quiet=True)
            outs = query()
            s = _mac_screen(outs, effective_target(outs, settings()[0]))
            if s and (not before or before["name"] != s["name"] or plugged):
                hint = ("\nOn a 4K screen, macOS can switch to 3840 × 2160 in System Settings › Displays."
                        if s["width"] >= 3840 else "")
                notify(f"The Mac is now on {s['label']} ({s['width']} × {s['height']}).{hint}")
        last = seen
        time.sleep(3)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "list"
    if cmd == "list":
        print(json.dumps(query(), indent=2))
    elif cmd == "apply":
        apply()
    elif cmd == "watch":
        watch()
    else:
        print("usage: displays.py [list|apply|watch]", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
