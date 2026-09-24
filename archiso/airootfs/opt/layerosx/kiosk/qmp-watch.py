#!/usr/bin/env python3
"""
Connects to the QMP socket of an already-running QEMU VM and waits for
a SHUTDOWN event. Prints a word to stdout that mac-vm-launch.sh uses
to decide what to do:

  host-poweroff  -> the guest (macOS) asked to shut down
  host-reboot    -> the guest (macOS) asked to reboot (or panicked)
  vm-only        -> QEMU exited for some other reason (killed
                     externally, host error, etc.) — don't touch the
                     physical machine

Relies on the VM having been launched with `-no-reboot`: that makes
QEMU exit (instead of resetting the process itself) when the guest
asks to reboot, and the SHUTDOWN event arrives with
reason="guest-reset" instead of the process just carrying on as if
nothing happened. Without that flag, there's no way to tell a Restart
apart from staying powered on.
"""
import json
import socket
import sys

GUEST_SHUTDOWN_REASONS = {"guest-shutdown"}
GUEST_REBOOT_REASONS = {"guest-reset", "guest-panic"}


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: qmp-watch.py <qmp-socket>", file=sys.stderr)
        sys.exit(2)

    sock_path = sys.argv[1]

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(15)
        sock.connect(sock_path)
    except OSError as exc:
        print(f"could not connect to QMP: {exc}", file=sys.stderr)
        print("vm-only")
        return

    buf = sock.makefile("rwb")

    def read_json():
        line = buf.readline()
        if not line:
            return None
        return json.loads(line.decode("utf-8", "replace"))

    try:
        read_json()  # capabilities banner
        buf.write(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
        buf.flush()
        read_json()  # response to qmp_capabilities
    except (OSError, json.JSONDecodeError) as exc:
        print(f"QMP handshake failed: {exc}", file=sys.stderr)
        print("vm-only")
        return

    sock.settimeout(None)
    while True:
        try:
            msg = read_json()
        except (OSError, json.JSONDecodeError):
            print("vm-only")
            return
        if msg is None:
            # QMP closed with no SHUTDOWN event first: QEMU died (crash,
            # SIGKILL) -- mac-vm-launch.sh logs its exit status next.
            print("QMP: connection closed without a SHUTDOWN event (QEMU crashed or was killed)", file=sys.stderr)
            print("vm-only")
            return
        if msg.get("event") == "SHUTDOWN":
            reason = msg.get("data", {}).get("reason", "")
            # Say WHY in the log: host-ui = the display window was closed (for
            # Reims' own window that's a WM_DELETE/CloseRequested), host-signal
            # = something killed it, host-error = QEMU gave up, guest-* = macOS.
            print(f"QMP: SHUTDOWN reason={reason or '?'} guest={msg.get('data', {}).get('guest')}", file=sys.stderr)
            if reason in GUEST_SHUTDOWN_REASONS:
                print("host-poweroff")
            elif reason in GUEST_REBOOT_REASONS:
                print("host-reboot")
            else:
                # host-qmp-quit, host-signal, host-error, host-ui: it
                # was us (or something external) that killed the VM,
                # not the guest.
                print("vm-only")
            return


if __name__ == "__main__":
    main()
