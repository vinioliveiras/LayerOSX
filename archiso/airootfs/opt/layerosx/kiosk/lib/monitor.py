#!/usr/bin/env python3
"""
LayerOSX monitoring mode: record everything about a running LayerOSX -- CPU,
GPU, memory, disk, network, the Mac's QEMU process and its threads, Reims'
frame rate, kernel and system logs -- into one organised folder, so a
performance problem or a hang can be read afterwards instead of guessed at.

    monitor.py run [--interval S] [--dir DIR]   collect until SIGTERM/SIGINT
    monitor.py summary <session-dir>            (re)write summary.txt

Started and stopped by Settings > Maintenance > Monitoring mode (Backend.
set_monitoring) and at session start while it's on; `macmonitor` is the
terminal front-end. A session folder (~/monitoring/<YYYYmmdd-HHMMSS>/) holds:

  README.txt         what every file is
  config.txt         host, settings state files, the QEMU command line
  events.log         the timeline: start/stop, network down/up, the Mac
                     (re)started, crashes, pressure/thermal spikes
  system.csv         load, memory, huge pages, dirty/writeback, pressure
                     (PSI cpu/memory/io), CPU temperature and clock
  cpu.csv            per-core busy %
  qemu.csv           the Mac's QEMU process: CPU %, RSS, threads
  threads.csv        QEMU threads above 1% CPU (vCPUs, Reims, main loop, ...)
  gpu.csv            per GPU: busy %, VRAM/GTT, clocks, temperature, power
  disk.csv           per disk: read/write MB/s, busy %
  net.csv            per interface: rx/tx KB/s, errors, drops; Wi-Fi signal
  netcheck.csv       every 5 s: gateway ping, DNS lookup, TCP connect (ms)
  reims.csv          Reims' window: frames shown per second, refusals
  logs/kernel.log    kernel messages (journalctl -k)
  logs/system.log    warnings and errors from every service (journal)
  logs/network.log   NetworkManager / wpa_supplicant
  logs/launcher.log  ~/mac-vm.log as it grows
  logs/macos-serial.log   macOS' own kernel log (serial)
  logs/reims.log     Reims' failure log without its per-second counters
  summary.txt        written at stop: averages / p95 / max per metric,
                     network outages, the busiest threads

Costs: one sample per second (GPU every 2 s, network checks every 5 s) from
/proc and /sys; a few `tail -F` / `journalctl -f` followers. The session
stops writing samples past 1 GB; the newest 5 sessions are kept.
"""
import argparse
import csv
import glob
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
from datetime import datetime

PROC = os.environ.get("LAYEROSX_PROC", "/proc")
SYS = os.environ.get("LAYEROSX_SYS", "/sys")
STATE_DIR = os.environ.get("LAYEROSX_STATE_DIR", "/var/lib/layerosx")
HOME = os.path.expanduser("~")
REIMS_LOG = os.environ.get("LAYEROSX_REIMS_FAIL_LOG", "/tmp/reims-vgpu-fail.log")
QEMU_MATCH = "qemu-system-x86_64"
MAX_BYTES = 1 << 30
KEEP_SESSIONS = 5


def rd(path, default=""):
    try:
        with open(path, errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


class Csv:
    """A CSV file with a fixed header, flushed every row (a crash or power
    loss keeps everything up to the last second)."""

    def __init__(self, path, header):
        self.f = open(path, "w", newline="")
        self.w = csv.writer(self.f)
        self.w.writerow(header)
        self.f.flush()

    def row(self, values):
        self.w.writerow([f"{v:.1f}" if isinstance(v, float) else v for v in values])
        self.f.flush()


# ------------------------------------------------------------------ probes
def cpu_times():
    """{cpu name: (busy, total)} from /proc/stat."""
    out = {}
    for line in rd(f"{PROC}/stat").splitlines():
        if not line.startswith("cpu"):
            continue
        p = line.split()
        v = [int(x) for x in p[1:9]]
        idle = v[3] + v[4]
        out[p[0]] = (sum(v) - idle, sum(v))
    return out


def meminfo():
    m = {}
    for line in rd(f"{PROC}/meminfo").splitlines():
        k, _, v = line.partition(":")
        v = v.split()
        if v:
            m[k] = int(v[0])
    return m


def psi(kind):
    """(some avg10, full avg10) from /proc/pressure/<kind>."""
    some = full = ""
    for line in rd(f"{PROC}/pressure/{kind}").splitlines():
        m = re.search(r"avg10=([\d.]+)", line)
        if m:
            if line.startswith("some"):
                some = float(m.group(1))
            elif line.startswith("full"):
                full = float(m.group(1))
    return some, full


def cpu_temp():
    for hw in sorted(glob.glob(f"{SYS}/class/hwmon/hwmon*")):
        if rd(f"{hw}/name") in ("k10temp", "coretemp", "zenpower"):
            t = rd(f"{hw}/temp1_input")
            if t.isdigit():
                return int(t) / 1000.0
    return ""


def cpu_mhz():
    f = [int(x) / 1000.0 for x in (rd(p) for p in glob.glob(f"{SYS}/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq")) if x.isdigit()]
    return (sum(f) / len(f), max(f)) if f else ("", "")


def qemu_pid():
    for d in os.listdir(PROC):
        if d.isdigit() and QEMU_MATCH in rd(f"{PROC}/{d}/cmdline").replace("\0", " ").split(" ", 1)[0]:
            return int(d)
    return None


def proc_ticks(path):
    """utime+stime of /proc/<pid>[/task/<tid>]/stat."""
    s = rd(f"{path}/stat")
    if not s:
        return None
    rest = s.rsplit(")", 1)[-1].split()
    try:
        return int(rest[11]) + int(rest[12])
    except (IndexError, ValueError):
        return None


def disks():
    """{disk: (sectors read, sectors written, io_ms)} for whole disks."""
    out = {}
    for line in rd(f"{PROC}/diskstats").splitlines():
        p = line.split()
        if len(p) < 14:
            continue
        name = p[2]
        if not os.path.exists(f"{SYS}/block/{name}") or name.startswith(("loop", "ram", "zram", "dm-", "sr")):
            continue
        out[name] = (int(p[5]), int(p[9]), int(p[12]))
    return out


def ifaces():
    out = {}
    for line in rd(f"{PROC}/net/dev").splitlines()[2:]:
        name, _, rest = line.partition(":")
        name = name.strip()
        if name == "lo" or not rest:
            continue
        v = [int(x) for x in rest.split()]
        out[name] = (v[0], v[8], v[2] + v[10], v[3] + v[11])   # rx bytes, tx bytes, errs, drops
    return out


def wifi_signal():
    out = {}
    for line in rd(f"{PROC}/net/wireless").splitlines()[2:]:
        p = line.split()
        if len(p) >= 4:
            out[p[0].rstrip(":")] = p[3].rstrip(".")
    return out


def default_gateway():
    for line in rd(f"{PROC}/net/route").splitlines()[1:]:
        p = line.split()
        if len(p) > 2 and p[1] == "00000000":
            g = int(p[2], 16)
            return socket.inet_ntoa(g.to_bytes(4, "little"))
    return ""


def amd_gpus():
    out = []
    for dev in sorted(glob.glob(f"{SYS}/class/drm/card[0-9]*/device")):
        busy = rd(f"{dev}/gpu_busy_percent")
        if not busy:
            continue
        hw = (glob.glob(f"{dev}/hwmon/hwmon*") or [""])[0]
        temp = rd(f"{hw}/temp1_input") if hw else ""
        power = rd(f"{hw}/power1_average") or rd(f"{hw}/power1_input") if hw else ""
        sclk = next((l.split(":")[1].strip() for l in rd(f"{dev}/pp_dpm_sclk").splitlines() if "*" in l), "")
        mb = lambda x: round(int(x) / 1048576) if x.isdigit() else ""   # noqa: E731
        out.append(["amd:" + os.path.basename(os.path.dirname(dev)), busy, "",
                    mb(rd(f"{dev}/mem_info_vram_used")), mb(rd(f"{dev}/mem_info_vram_total")),
                    mb(rd(f"{dev}/mem_info_gtt_used")), sclk.replace("Mhz", "").replace("*", "").strip(), "",
                    int(temp) / 1000.0 if temp.isdigit() else "",
                    round(int(power) / 1e6, 1) if power.isdigit() else ""])
    return out


def nvidia_gpus():
    if not shutil.which("nvidia-smi"):
        return []
    try:
        r = subprocess.run(["nvidia-smi", "--query-gpu=index,utilization.gpu,utilization.memory,memory.used,"
                            "memory.total,clocks.gr,clocks.mem,temperature.gpu,power.draw",
                            "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return []
    out = []
    for line in r.stdout.splitlines():
        p = [x.strip() for x in line.split(",")]
        if len(p) == 9:
            out.append(["nvidia:" + p[0], p[1], p[2], p[3], p[4], "", p[5], p[6], p[7], p[8]])
    return out


# --------------------------------------------------------------- collector
class Monitor:
    def __init__(self, root, interval):
        self.root = root
        self.interval = interval
        self.stop = threading.Event()
        self.children = []
        os.makedirs(f"{root}/logs", exist_ok=True)
        self.events = open(f"{root}/events.log", "a", buffering=1)
        self.over_budget = False
        self.seen_refusals = set()

    def event(self, msg):
        self.events.write(f"{now()}  {msg}\n")

    # -------------------------------------------------------------- setup
    def write_readme_and_config(self):
        with open(f"{self.root}/README.txt", "w") as f:
            f.write(__doc__.split("A session folder", 1)[1].split("Costs:", 1)[0].strip() + "\n")
        lines = [f"started {now()}", f"host {rd('/etc/hostname')} kernel {os.uname().release}",
                 f"cpu {next((l.split(':',1)[1].strip() for l in rd(f'{PROC}/cpuinfo').splitlines() if l.startswith('model name')), '?')}"
                 f" threads {os.cpu_count()}", f"mem_total_mb {meminfo().get('MemTotal', 0) // 1024}", "", "[settings]"]
        for p in sorted(glob.glob(f"{STATE_DIR}/*")):
            if os.path.isfile(p) and os.path.getsize(p) < 512 and not p.endswith(("maint-password", ".qcow2", ".fd")):
                lines.append(f"{os.path.basename(p)} = {rd(p)}")
        cmd = [l for l in rd(f"{HOME}/mac-vm.log").splitlines() if "QEMU cmdline:" in l]
        lines += ["", "[last QEMU command line]", cmd[-1] if cmd else "(none yet)"]
        with open(f"{self.root}/config.txt", "w") as f:
            f.write("\n".join(lines) + "\n")

    def follow(self, name, argv, filt=None):
        """Run argv, write its lines to logs/<name> (filtered)."""
        try:
            p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                 errors="replace", start_new_session=True)
        except OSError:
            return
        self.children.append(p)

        def pump():
            with open(f"{self.root}/logs/{name}", "a", buffering=1) as out:
                for line in p.stdout:
                    if filt is None or filt(line):
                        out.write(line)
                    if name == "launcher.log":
                        self.launcher_line(line)
        threading.Thread(target=pump, daemon=True).start()

    def launcher_line(self, line):
        for key in ("CRASH:", "QEMU ended:", "QMP: SHUTDOWN", "macOS asked", "FATAL", "RAM:", "I/O:",
                    "Reims couldn't map", "Launch profile:"):
            if key in line:
                self.event("launcher: " + line.strip()[:300])
                return

    def start_followers(self):
        sudo = ["sudo", "-n"] if os.geteuid() != 0 else []
        self.follow("kernel.log", sudo + ["journalctl", "-k", "-f", "-n", "200", "-o", "short-iso"])
        self.follow("system.log", sudo + ["journalctl", "-f", "-n", "200", "-p", "warning", "-o", "short-iso"])
        self.follow("network.log", sudo + ["journalctl", "-f", "-n", "100", "-o", "short-iso",
                                           "-u", "NetworkManager", "-u", "wpa_supplicant", "-u", "iwd"])
        self.follow("launcher.log", ["tail", "-n", "0", "-F", f"{HOME}/mac-vm.log"])
        self.follow("macos-serial.log", ["tail", "-n", "0", "-F", f"{HOME}/mac-vm-serial.log"])
        self.follow("reims.log", ["tail", "-n", "0", "-F", REIMS_LOG], filt=lambda l: not l.startswith("OFF "))

    # --------------------------------------------------------------- loops
    def sample_loop(self):
        n = os.cpu_count() or 1
        cores = [f"cpu{i}" for i in range(n)]
        sysc = Csv(f"{self.root}/system.csv", ["time", "load1", "mem_used_mb", "mem_avail_mb", "shmem_mb",
                   "shmem_hugepages_mb", "anon_hugepages_mb", "dirty_mb", "writeback_mb", "swap_used_mb",
                   "psi_cpu_some", "psi_mem_some", "psi_mem_full", "psi_io_some", "psi_io_full",
                   "cpu_temp_c", "cpu_mhz_avg", "cpu_mhz_max", "cpu_busy_pct",
                   "thp_file_alloc", "thp_file_fallback", "qemu_shmem_pmd_mb"])
        cpuc = Csv(f"{self.root}/cpu.csv", ["time"] + cores)
        qc = Csv(f"{self.root}/qemu.csv", ["time", "pid", "cpu_pct", "rss_mb", "threads"])
        tc = Csv(f"{self.root}/threads.csv", ["time", "tid", "name", "cpu_pct"])
        dc = Csv(f"{self.root}/disk.csv", ["time", "disk", "read_mb_s", "write_mb_s", "busy_pct"])
        nc = Csv(f"{self.root}/net.csv", ["time", "iface", "rx_kb_s", "tx_kb_s", "errors", "drops", "wifi_signal_dbm"])
        rc = Csv(f"{self.root}/reims.csv", ["time", "fps", "presents_asked", "refusals"])
        gc = Csv(f"{self.root}/gpu.csv", ["time", "gpu", "busy_pct", "mem_busy_pct", "vram_used_mb", "vram_total_mb",
                  "gtt_used_mb", "core_mhz", "mem_mhz", "temp_c", "power_w"])
        hz = os.sysconf("SC_CLK_TCK")
        prev_cpu, prev_disk, prev_net = cpu_times(), disks(), ifaces()
        pid, prev_q, prev_t = None, None, {}
        reims_pos = os.path.getsize(REIMS_LOG) if os.path.exists(REIMS_LOG) else 0
        t0 = time.monotonic()
        tick = 0
        high_psi = hot = False
        while not self.stop.wait(self.interval):
            tick += 1
            dt = time.monotonic() - t0
            t0 = time.monotonic()
            ts = now()
            if self.budget_exceeded():
                continue
            cur = cpu_times()
            busy = {k: 100.0 * (cur[k][0] - prev_cpu.get(k, cur[k])[0]) / max(1, cur[k][1] - prev_cpu.get(k, cur[k])[1])
                    for k in cur}
            prev_cpu = cur
            cpuc.row([ts] + [busy.get(c, "") for c in cores])
            m = meminfo()
            mb = lambda k: m.get(k, 0) // 1024   # noqa: E731
            ps = [psi("cpu")[0], *psi("memory"), *psi("io")]
            temp = cpu_temp()
            mhz = cpu_mhz()
            vm = dict(l.split() for l in rd(f"{PROC}/vmstat").splitlines() if l.count(" ") == 1)
            pmd = ""
            if pid and tick % 10 == 0:
                sm = re.search(r"ShmemPmdMapped:\s+(\d+)", rd(f"{PROC}/{pid}/smaps_rollup"))
                pmd = int(sm.group(1)) // 1024 if sm else ""
            sysc.row([ts, rd(f"{PROC}/loadavg").split(" ")[0], mb("MemTotal") - mb("MemAvailable"), mb("MemAvailable"),
                      mb("Shmem"), mb("ShmemHugePages"), mb("AnonHugePages"), mb("Dirty"), mb("Writeback"),
                      mb("SwapTotal") - mb("SwapFree"), *ps, temp, *mhz, busy.get("cpu", ""),
                      vm.get("thp_file_alloc", ""), vm.get("thp_file_fallback", ""), pmd])
            if isinstance(ps[2], float) and ps[2] > 10 and not high_psi:
                self.event(f"memory pressure: {ps[2]}% of time fully stalled on memory (avg10)")
            if isinstance(ps[4], float) and ps[4] > 20 and not high_psi:
                self.event(f"I/O pressure: {ps[4]}% of time fully stalled on I/O (avg10)")
            high_psi = (isinstance(ps[2], float) and ps[2] > 10) or (isinstance(ps[4], float) and ps[4] > 20)
            if isinstance(temp, float) and temp >= 90 and not hot:
                self.event(f"CPU temperature {temp:.0f} C")
            hot = isinstance(temp, float) and temp >= 90

            # QEMU and its threads
            p = qemu_pid()
            if p != pid:
                self.event(f"the Mac's QEMU {'started, pid ' + str(p) if p else 'is not running'}")
                pid, prev_q, prev_t = p, None, {}
            if pid:
                q = proc_ticks(f"{PROC}/{pid}")
                status = rd(f"{PROC}/{pid}/status")
                rss = re.search(r"VmRSS:\s+(\d+)", status)
                thr = re.search(r"Threads:\s+(\d+)", status)
                if q is not None and prev_q is not None:
                    qc.row([ts, pid, 100.0 * (q - prev_q) / hz / dt, int(rss.group(1)) // 1024 if rss else "",
                            thr.group(1) if thr else ""])
                prev_q = q
                cur_t = {}
                for tdir in glob.glob(f"{PROC}/{pid}/task/*"):
                    tid = os.path.basename(tdir)
                    tk = proc_ticks(tdir)
                    if tk is None:
                        continue
                    cur_t[tid] = tk
                    if tid in prev_t:
                        pct = 100.0 * (tk - prev_t[tid]) / hz / dt
                        if pct >= 1:
                            tc.row([ts, tid, rd(f"{tdir}/comm"), pct])
                prev_t = cur_t

            # disks
            cd = disks()
            for d, (r, w, io) in cd.items():
                if d in prev_disk:
                    pr, pw, pio = prev_disk[d]
                    dc.row([ts, d, (r - pr) * 512 / 1048576 / dt, (w - pw) * 512 / 1048576 / dt,
                            min(100.0, (io - pio) / 10.0 / dt)])
            prev_disk = cd
            # network interfaces
            cn, sig = ifaces(), wifi_signal()
            for i, (rx, tx, er, drp) in cn.items():
                if i in prev_net:
                    prx, ptx, _, _ = prev_net[i]
                    nc.row([ts, i, (rx - prx) / 1024 / dt, (tx - ptx) / 1024 / dt, er, drp, sig.get(i, "")])
            prev_net = cn
            # Reims frames
            reims_pos = self.reims_sample(rc, ts, reims_pos)
            # GPUs every 2 s
            if tick % 2 == 0:
                for g in nvidia_gpus() + amd_gpus():
                    gc.row([ts] + g)

    def reims_sample(self, rc, ts, pos):
        try:
            size = os.path.getsize(REIMS_LOG)
        except OSError:
            return 0
        if size < pos:
            pos = 0
        if size == pos:
            return pos
        with open(REIMS_LOG, "rb") as f:
            f.seek(pos)
            raw = f.read(min(size - pos, 8 << 20))
        chunk = raw.decode("utf-8", "replace")
        fresh = asked = ms = 0
        for m in re.finditer(r"host_window_loop win_ms=(\d+)\b.*?\bredraws_asked=(\d+).*?\bdraws_fresh=(\d+)", chunk):
            ms += int(m.group(1))
            asked += int(m.group(2))
            fresh += int(m.group(3))
        refusals = len(re.findall(r"refused_by=|_declined|import_exceeds_heap|fail_event", chunk))
        if ms:
            rc.row([ts, fresh * 1000.0 / ms, asked, refusals])
        # Reims' per-second counters carry "device_lost=0"; only a non-zero
        # count or a line of its own is a lost device.
        if re.search(r"device_lost=[1-9]|^(?!OFF )\S*device_lost", chunk, re.M):
            self.event("Reims: GPU device lost")
        for reason in sorted(set(re.findall(r"refused_by=(\w+)|reason=(linear_tex_fmt_storage|draw_prepare_texture_resolve_missing|import_exceeds_heap)", chunk))):
            r = reason[0] or reason[1]
            if r not in self.seen_refusals:
                self.seen_refusals.add(r)
                self.event(f"Reims: first refusal of kind {r} (drawing/compute it can't translate yet)")
        return pos + len(raw)

    def netcheck_loop(self):
        nc = Csv(f"{self.root}/netcheck.csv", ["time", "gateway", "gateway_ms", "dns_ms", "tcp_ms", "status"])
        down_since = None
        while not self.stop.wait(5):
            if self.over_budget:
                continue
            gw = default_gateway()
            g_ms = self._ping(gw) if gw else None
            d_ms = self._timed(lambda: socket.getaddrinfo("apple.com", 443), 3)
            t_ms = self._timed(lambda: socket.create_connection(("1.1.1.1", 443), timeout=3).close(), 3)
            ok = d_ms is not None or t_ms is not None
            status = "ok" if ok else ("no-gateway" if not gw else "down")
            nc.row([now(), gw, g_ms if g_ms is not None else "", d_ms if d_ms is not None else "",
                    t_ms if t_ms is not None else "", status])
            if not ok and down_since is None:
                down_since = time.time()
                self.event(f"NETWORK DOWN (host): gateway {gw or 'none'} ping "
                           f"{'ok' if g_ms is not None else 'failed'}, DNS failed, TCP failed")
            elif ok and down_since is not None:
                self.event(f"network back after {time.time() - down_since:.0f} s")
                down_since = None

    @staticmethod
    def _ping(host):
        try:
            r = subprocess.run(["ping", "-c1", "-W1", host], capture_output=True, text=True, timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            return None
        m = re.search(r"time=([\d.]+)", r.stdout)
        return float(m.group(1)) if r.returncode == 0 and m else None

    @staticmethod
    def _timed(fn, timeout):
        res = {}

        def run():
            t = time.monotonic()
            try:
                fn()
                res["ms"] = round((time.monotonic() - t) * 1000, 1)
            except OSError:
                pass
        th = threading.Thread(target=run, daemon=True)
        th.start()
        th.join(timeout)
        return res.get("ms")

    def budget_exceeded(self):
        if self.over_budget:
            return True
        total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(self.root) for f in fs)
        if total > MAX_BYTES:
            self.over_budget = True
            self.event("session reached 1 GB -- samples stopped (logs keep following)")
        return self.over_budget

    def run(self):
        self.write_readme_and_config()
        self.event(f"monitoring started, sampling every {self.interval:g} s")
        self.start_followers()
        threads = [threading.Thread(target=self.sample_loop, daemon=True),
                   threading.Thread(target=self.netcheck_loop, daemon=True)]
        for t in threads:
            t.start()
        signal.signal(signal.SIGTERM, lambda *_: self.stop.set())
        signal.signal(signal.SIGINT, lambda *_: self.stop.set())
        while not self.stop.wait(1):
            pass
        for t in threads:
            t.join(10)
        for p in self.children:
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except OSError:
                pass
        self.event("monitoring stopped")
        write_summary(self.root)


# ----------------------------------------------------------------- summary
def _stats(vals):
    v = sorted(x for x in vals if x is not None)
    if not v:
        return None
    return {"avg": statistics.fmean(v), "p95": v[min(len(v) - 1, int(len(v) * 0.95))], "max": v[-1]}


def _col(path, name, where=None):
    out = []
    try:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                if where and not where(r):
                    continue
                try:
                    out.append(float(r[name]))
                except (KeyError, ValueError, TypeError):
                    pass
    except OSError:
        pass
    return out


def write_summary(root):
    lines = [f"LayerOSX monitoring summary -- {os.path.basename(root)}", ""]
    ev = rd(f"{root}/events.log").splitlines()
    if ev:
        lines += [f"from {ev[0][:19]} to {ev[-1][:19]}", ""]

    def block(title, path, cols, where=None):
        rows = []
        for c, label in cols:
            s = _stats(_col(f"{root}/{path}", c, where))
            if s:
                rows.append(f"  {label:<28} avg {s['avg']:8.1f}   p95 {s['p95']:8.1f}   max {s['max']:8.1f}")
        if rows:
            lines.append(title)
            lines.extend(rows)
            lines.append("")

    block("System", "system.csv", [("cpu_busy_pct", "CPU busy %"), ("load1", "load (1 min)"),
          ("mem_used_mb", "memory used MB"), ("shmem_hugepages_mb", "Mac RAM in 2 MB pages MB"),
          ("dirty_mb", "dirty page cache MB"), ("psi_cpu_some", "CPU pressure %"),
          ("psi_mem_full", "memory stall (full) %"), ("psi_io_full", "I/O stall (full) %"),
          ("cpu_temp_c", "CPU temperature C"), ("cpu_mhz_avg", "CPU clock avg MHz")])
    block("The Mac's QEMU process", "qemu.csv", [("cpu_pct", "CPU % (100 = one core)"), ("rss_mb", "RSS MB")])
    block("Reims", "reims.csv", [("fps", "frames shown per second"), ("refusals", "refusals per sample")])
    gpus = sorted({r for r in _names(f"{root}/gpu.csv", "gpu")})
    for g in gpus:
        block(f"GPU {g}", "gpu.csv", [("busy_pct", "busy %"), ("vram_used_mb", "VRAM used MB"),
              ("temp_c", "temperature C"), ("power_w", "power W")], where=lambda r, g=g: r.get("gpu") == g)
    for d in sorted(_names(f"{root}/disk.csv", "disk")):
        block(f"Disk {d}", "disk.csv", [("read_mb_s", "read MB/s"), ("write_mb_s", "write MB/s"),
              ("busy_pct", "busy %")], where=lambda r, d=d: r.get("disk") == d)
    for i in sorted(_names(f"{root}/net.csv", "iface")):
        block(f"Network {i}", "net.csv", [("rx_kb_s", "receive KB/s"), ("tx_kb_s", "send KB/s"),
              ("wifi_signal_dbm", "Wi-Fi signal dBm")], where=lambda r, i=i: r.get("iface") == i)
    block("Connectivity (every 5 s)", "netcheck.csv", [("gateway_ms", "gateway ping ms"), ("dns_ms", "DNS lookup ms"),
          ("tcp_ms", "TCP connect ms")])
    downs = [e for e in ev if "NETWORK DOWN" in e or "network back" in e]
    lines.append("Network outages (host side):" if downs else "Network outages (host side): none")
    lines += ["  " + e for e in downs] + [""]
    # busiest threads
    tot = {}
    try:
        with open(f"{root}/threads.csv", newline="") as f:
            for r in csv.DictReader(f):
                try:
                    tot[r["name"]] = tot.get(r["name"], 0.0) + float(r["cpu_pct"])
                except (KeyError, ValueError):
                    pass
    except OSError:
        pass
    samples = max(1, len(_col(f"{root}/qemu.csv", "cpu_pct")))
    if tot:
        lines.append("Busiest QEMU threads (average CPU %, 100 = one core):")
        for name, v in sorted(tot.items(), key=lambda kv: -kv[1])[:12]:
            lines.append(f"  {name:<28} {v / samples:6.1f}")
        lines.append("")
    notable = [e for e in ev if any(k in e for k in ("MARK:", "NETWORK DOWN", "network back", "CRASH", "pressure", "Reims:",
                                                     "temperature", "device lost",
                                                     "QEMU started", "not running", "FATAL", "Reims couldn't"))]
    if notable:
        lines.append("Events:")
        lines += ["  " + e for e in notable[-40:]]
    with open(f"{root}/summary.txt", "w") as f:
        f.write("\n".join(lines) + "\n")


def _names(path, col):
    out = set()
    try:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                if r.get(col):
                    out.add(r[col])
    except OSError:
        pass
    return out


def prune(base):
    sessions = sorted(glob.glob(f"{base}/2*"))
    for old in sessions[:-KEEP_SESSIONS]:
        shutil.rmtree(old, ignore_errors=True)


def main(argv):
    ap = argparse.ArgumentParser(prog="monitor.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--interval", type=float, default=1.0)
    r.add_argument("--dir", default=os.path.join(HOME, "monitoring"))
    s = sub.add_parser("summary")
    s.add_argument("session")
    a = ap.parse_args(argv)
    if a.cmd == "summary":
        write_summary(a.session)
        print(os.path.join(a.session, "summary.txt"))
        return 0
    root = os.path.join(a.dir, datetime.now().strftime("%Y%m%d-%H%M%S"))
    os.makedirs(root, exist_ok=True)
    prune(a.dir)
    print(root, flush=True)
    Monitor(root, a.interval).run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
