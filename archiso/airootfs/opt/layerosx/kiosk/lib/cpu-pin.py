#!/usr/bin/env python3
"""Give each of the Mac's vCPUs a physical core of its own.

    cpu-pin.py plan  <vcpus>                          print the layout (no changes)
    cpu-pin.py apply <qmp-ctl-socket> <qemu-pid> <vcpus>
    cpu-pin.py reset                                  everything back on every CPU

Without pinning, Linux moves the vCPU threads between cores and lets QEMU's
other threads, Reims' render/present threads, Xorg and the audio path run on
the same core as a busy vCPU -- the guest sees that as short, random stalls.

Layout (from /sys/devices/system/cpu/cpu*/topology): physical cores, fastest
first (hybrid Intel: P-cores before E-cores), core 0 last (most IRQs and
housekeeping land there). vCPU i gets the first thread of the i-th core.
Everything else in QEMU (main loop, I/O, Reims, audio) gets the "host set":
the cores the Mac doesn't use, or -- when it uses them all -- the SMT sibling
threads of its cores. With fewer physical cores than vCPUs nothing is pinned.

`apply` runs next to QEMU as the same user (sched_setaffinity needs no root
for your own threads): it asks QMP for the vCPU thread IDs, pins them, puts
every other QEMU thread on the host set, and keeps doing the latter every
few seconds while QEMU runs (threads created later -- Reims starts some when
the guest driver loads -- inherit their creator's CPU and could otherwise
land on a vCPU's core). The rest of the kiosk session (Xorg, openbox, picom,
the panel -- same user) goes on the host set too, and host-cpus.sh (sudo)
moves IRQs, kernel workqueues and system services there, so the Mac's cores
run little besides the Mac. Writes nothing; logs to stdout.
"""
import glob
import json
import os
import socket
import sys
import time

SYS = os.environ.get("LAYEROSX_SYS_CPU", "/sys/devices/system/cpu")
PROC = os.environ.get("LAYEROSX_PROC", "/proc")
SWEEP_SECONDS = 5
USER_SWEEP_EVERY = 6          # session processes: every 6th sweep (30 s)
HOST_CPUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "host-cpus.sh")


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _cpulist(text):
    out = []
    for part in text.split(","):
        if "-" in part:
            a, b = part.split("-")
            out.extend(range(int(a), int(b) + 1))
        elif part.strip():
            out.append(int(part))
    return out


def cores():
    """Physical cores as sorted thread lists, in pinning order."""
    online = _cpulist(_read(os.path.join(SYS, "online")) or "0")
    seen, result = set(), []
    for cpu in online:
        if cpu in seen:
            continue
        sib = _cpulist(_read(os.path.join(SYS, f"cpu{cpu}", "topology", "thread_siblings_list")) or str(cpu))
        sib = sorted(c for c in sib if c in online) or [cpu]
        seen.update(sib)
        freq = int(_read(os.path.join(SYS, f"cpu{cpu}", "cpufreq", "cpuinfo_max_freq")) or 0)
        result.append((freq, sib))
    # fastest first; among equals keep topology order but move core 0 to the end
    result.sort(key=lambda fs: (-fs[0], 0 in fs[1], fs[1][0]))
    return [s for _, s in result]


def plan(vcpus):
    """([cpu for vCPU 0..n-1], host set) or (None, None) when pinning can't help."""
    cs = cores()
    if vcpus < 1 or len(cs) < vcpus:
        return None, None
    used, rest = cs[:vcpus], cs[vcpus:]
    pins = [c[0] for c in used]
    host = sorted(t for c in rest for t in c)
    if len(host) < 2:                      # every core busy: the SMT siblings
        host = sorted(set(host) | {t for c in used for t in c[1:]})
    if not host:                           # no SMT and no spare core
        return None, None
    return pins, host


def vcpu_threads(sock_path, timeout=60):
    """{cpu-index: thread-id} from QMP query-cpus-fast (waits for the socket)."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(5)
            s.connect(sock_path)
            f = s.makefile("rwb")
            f.readline()
            for cmd in ("qmp_capabilities", "query-cpus-fast"):
                f.write(json.dumps({"execute": cmd}).encode() + b"\n")
                f.flush()
                while True:
                    msg = json.loads(f.readline() or b"{}")
                    if "return" in msg or "error" in msg or not msg:
                        break
            s.close()
            if isinstance(msg.get("return"), list) and msg["return"]:
                return {c["cpu-index"]: c["thread-id"] for c in msg["return"]}
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(1)
    return {}


def _tasks(pid):
    try:
        return [int(t) for t in os.listdir(os.path.join(PROC, str(pid), "task"))]
    except OSError:
        return []


def _alive(pid):
    """Running (not gone, not a zombie waiting to be reaped)."""
    st = _read(os.path.join(PROC, str(pid), "stat")).rsplit(")", 1)[-1].split()
    return bool(st) and st[0] != "Z"


def _set(tid, cpus):
    try:
        if os.sched_getaffinity(tid) != set(cpus):
            os.sched_setaffinity(tid, cpus)
        return True
    except OSError:
        return False


def _cpulist_text(cpus):
    return ",".join(map(str, sorted(cpus)))


def move_session(qemu_pid, host):
    """Our other processes (Xorg, openbox, picom, panel...) onto the host set."""
    me = os.getuid()
    for d in os.listdir(PROC):
        if not d.isdigit() or int(d) == qemu_pid:
            continue
        try:
            if os.stat(os.path.join(PROC, d)).st_uid != me:
                continue
        except OSError:
            continue
        for tid in _tasks(int(d)):
            _set(tid, host)


def host_work(host):
    """IRQs, workqueues, system services -> host set (root helper, best effort)."""
    import subprocess
    try:
        subprocess.run(["sudo", "-n", HOST_CPUS, "apply", _cpulist_text(host)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        pass


def _reset_host_work():
    import subprocess
    try:
        subprocess.run(["sudo", "-n", HOST_CPUS, "reset"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        pass


def apply(sock_path, pid, vcpus):
    pins, host = plan(vcpus)
    if pins is None:
        print(f"CPU pinning: skipped ({len(cores())} physical cores for {vcpus} vCPUs).")
        _reset_host_work()
        return 0
    threads = vcpu_threads(sock_path)
    if len(threads) != vcpus:
        print(f"CPU pinning: skipped (QMP gave {len(threads)} vCPU threads, expected {vcpus}).")
        return 0
    vtids = {threads[i]: pins[i] for i in range(vcpus)}
    for tid in _tasks(pid):
        _set(tid, vtids.get(tid) and [vtids[tid]] or host)
    for tid, cpu in vtids.items():
        _set(tid, [cpu])
    move_session(pid, host)
    host_work(host)
    print("CPU pinning: vCPU " + ", ".join(f"{i}->cpu{pins[i]}" for i in range(vcpus))
          + f"; QEMU/Reims threads on cpus {','.join(map(str, host))}.")
    sys.stdout.flush()
    n = 0
    while _alive(pid):
        time.sleep(SWEEP_SECONDS)
        for tid in _tasks(pid):
            if tid not in vtids:
                _set(tid, host)
        n += 1
        if n % USER_SWEEP_EVERY == 0:
            move_session(pid, host)
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == "plan":
        pins, host = plan(int(argv[2]))
        print(json.dumps({"vcpus": pins, "host": host, "cores": cores()}))
        return 0
    if len(argv) >= 2 and argv[1] == "reset":
        every = _cpulist(_read(os.path.join(SYS, "online")) or "0")
        move_session(-1, every)
        _reset_host_work()
        return 0
    if len(argv) >= 5 and argv[1] == "apply":
        return apply(argv[2], int(argv[3]), int(argv[4]))
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
