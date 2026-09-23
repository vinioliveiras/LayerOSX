#!/usr/bin/env python3
"""
Send ONE command to the running macOS VM over its control QMP socket
(/tmp/macvm-ctl.sock -- a second QMP monitor next to the one qmp-watch.py
holds open, since a QMP unix socket serves a single client at a time).

  qmp-cmd.py <socket> stop              pause the VM (host about to suspend)
  qmp-cmd.py <socket> cont              resume it (host woke up)
  qmp-cmd.py <socket> system_powerdown  ACPI power button (critical battery)
  qmp-cmd.py <socket> quit              stop QEMU cleanly, flushing its disks
  qmp-cmd.py <socket> usb-attach VID PID  hand a host USB device to the guest
  qmp-cmd.py <socket> usb-detach VID PID  take it back
  qmp-cmd.py <socket> usb-list            print "VID PID" of attached ones

Deliberately a fixed allow-list, not a generic QMP client: it is called from
root's systemd-sleep hook, the battery watcher and the USB picker. USB
passthrough uses `usb-host` matched by vendor/product id (qdev id
usb-VVVV-PPPP), so the guest gets the device back automatically whenever it's
re-plugged; VID/PID must be 4 hex digits. Exit 0 on success, 1 if
the VM isn't running / the socket is gone (callers treat that as "nothing to
do"), 2 on usage errors.
"""
import json
import re
import socket
import sys

SIMPLE = {"stop", "cont", "system_powerdown", "quit"}
USB = {"usb-attach", "usb-detach", "usb-list"}
HEX4 = re.compile(r"^[0-9a-f]{4}$")
USB_ID = re.compile(r"^usb-([0-9a-f]{4})-([0-9a-f]{4})$")


def usage() -> int:
    print("usage: qmp-cmd.py <socket> <stop|cont|system_powerdown|quit>\n"
          "       qmp-cmd.py <socket> <usb-attach|usb-detach> VID PID\n"
          "       qmp-cmd.py <socket> usb-list", file=sys.stderr)
    return 2


def build(argv):
    """Return (list of (command, arguments) to run, printer) or None."""
    if len(argv) == 1 and argv[0] in SIMPLE:
        return [(argv[0], None)]
    if len(argv) == 1 and argv[0] == "usb-list":
        return [("qom-list", {"path": "/machine/peripheral"})]
    if len(argv) == 3 and argv[0] in ("usb-attach", "usb-detach"):
        vid, pid = argv[1].lower(), argv[2].lower()
        if not (HEX4.match(vid) and HEX4.match(pid)):
            return None
        qid = f"usb-{vid}-{pid}"
        if argv[0] == "usb-attach":
            return [("device_add", {"driver": "usb-host", "bus": "xhci.0",
                                    "vendorid": int(vid, 16), "productid": int(pid, 16),
                                    "id": qid})]
        return [("device_del", {"id": qid})]
    return None


def main() -> int:
    if len(sys.argv) < 3:
        return usage()
    path, argv = sys.argv[1], sys.argv[2:]
    plan = build(argv)
    if plan is None:
        return usage()
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(path)
        f = sock.makefile("rwb")
        f.readline()  # greeting
        for command, args in [("qmp_capabilities", None)] + plan:
            req = {"execute": command}
            if args is not None:
                req["arguments"] = args
            f.write(json.dumps(req).encode() + b"\n")
            f.flush()
            while True:  # skip async events until the command's reply
                line = f.readline()
                if not line:
                    return 0 if command == "quit" else 1
                msg = json.loads(line.decode("utf-8", "replace"))
                if "return" in msg:
                    if command == "qom-list":
                        for child in msg["return"]:
                            m = USB_ID.match(child.get("name", ""))
                            if m:
                                print(m.group(1), m.group(2))
                    break
                if "error" in msg:
                    desc = msg["error"].get("desc", str(msg))
                    # Attaching something already attached is not a failure.
                    if command == "device_add" and "Duplicate" in desc:
                        break
                    print(f"QMP {command}: {desc}", file=sys.stderr)
                    return 1
        return 0
    except (OSError, ValueError) as exc:
        print(f"qmp-cmd: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
