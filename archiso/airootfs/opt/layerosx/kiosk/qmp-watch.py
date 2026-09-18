#!/usr/bin/env python3
"""
Liga-se ao socket QMP de uma VM QEMU já a correr e fica à espera do
evento SHUTDOWN. Imprime em stdout uma palavra que o mac-vm-launch.sh
usa para decidir o que fazer:

  host-poweroff  -> o guest (macOS) pediu para desligar
  host-reboot    -> o guest (macOS) pediu para reiniciar (ou fez panic)
  vm-only        -> QEMU saiu por outro motivo (morto de fora, erro do
                     host, etc.) — não mexe na máquina física

Depende de a VM ter sido lançada com `-no-reboot`: isso faz o QEMU
sair (em vez de reiniciar o próprio processo sozinho) quando o guest
pede reboot, e o evento SHUTDOWN chega com reason="guest-reset" em vez
de o processo continuar a correr como se nada fosse. Sem essa flag,
isto não consegue distinguir um Restart de continuar ligado.
"""
import json
import socket
import sys

GUEST_SHUTDOWN_REASONS = {"guest-shutdown"}
GUEST_REBOOT_REASONS = {"guest-reset", "guest-panic"}


def main() -> None:
    if len(sys.argv) != 2:
        print("uso: qmp-watch.py <socket-qmp>", file=sys.stderr)
        sys.exit(2)

    sock_path = sys.argv[1]

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(15)
        sock.connect(sock_path)
    except OSError as exc:
        print(f"não consegui ligar ao QMP: {exc}", file=sys.stderr)
        print("vm-only")
        return

    buf = sock.makefile("rwb")

    def read_json():
        line = buf.readline()
        if not line:
            return None
        return json.loads(line.decode("utf-8", "replace"))

    try:
        read_json()  # banner de capabilities
        buf.write(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
        buf.flush()
        read_json()  # resposta ao qmp_capabilities
    except (OSError, json.JSONDecodeError) as exc:
        print(f"handshake QMP falhou: {exc}", file=sys.stderr)
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
            print("vm-only")
            return
        if msg.get("event") == "SHUTDOWN":
            reason = msg.get("data", {}).get("reason", "")
            if reason in GUEST_SHUTDOWN_REASONS:
                print("host-poweroff")
            elif reason in GUEST_REBOOT_REASONS:
                print("host-reboot")
            else:
                # host-qmp-quit, host-signal, host-error, host-ui: fomos
                # nós (ou algo externo) que matámos a VM, não o guest.
                print("vm-only")
            return


if __name__ == "__main__":
    main()
