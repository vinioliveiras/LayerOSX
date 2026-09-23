#!/usr/bin/env python3
"""
Send ONE command to the running macOS VM over its control QMP socket
(/tmp/macvm-ctl.sock -- a second QMP monitor next to the one qmp-watch.py
holds open, since a QMP unix socket serves a single client at a time).

  qmp-cmd.py <socket> stop              pause the VM (host about to suspend)
  qmp-cmd.py <socket> cont              resume it (host woke up)
  qmp-cmd.py <socket> system_powerdown  ACPI power button (critical battery)
  qmp-cmd.py <socket> quit              stop QEMU cleanly, flushing its disks

Deliberately a fixed allow-list, not a generic QMP client: it is called from
root's systemd-sleep hook and from the battery watcher. Exit 0 on success, 1 if
the VM isn't running / the socket is gone (callers treat that as "nothing to
do"), 2 on usage errors.
"""
import json
import socket
import sys

ALLOWED = {"stop", "cont", "system_powerdown", "quit"}


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[2] not in ALLOWED:
        print(f"usage: qmp-cmd.py <socket> <{'|'.join(sorted(ALLOWED))}>", file=sys.stderr)
        return 2
    path, cmd = sys.argv[1], sys.argv[2]
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(path)
        f = sock.makefile("rwb")
        f.readline()  # greeting
        for command in ("qmp_capabilities", cmd):
            f.write(json.dumps({"execute": command}).encode() + b"\n")
            f.flush()
            while True:  # skip async events until the command's reply
                line = f.readline()
                if not line:
                    return 0 if command == "quit" else 1
                msg = json.loads(line.decode("utf-8", "replace"))
                if "return" in msg:
                    break
                if "error" in msg:
                    print(f"QMP {command}: {msg['error'].get('desc', msg)}", file=sys.stderr)
                    return 1
        return 0
    except (OSError, ValueError) as exc:
        print(f"qmp-cmd: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
