"""kiosk/lib/monitor.py: the summary it writes from a session's CSVs/events."""
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "monitor", os.path.join(HERE, "..", "..", "archiso", "airootfs", "opt", "layerosx", "kiosk", "lib", "monitor.py"))
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)


class TestSummary(unittest.TestCase):
    def test_summary_from_session(self):
        d = tempfile.mkdtemp()
        w = lambda name, text: open(os.path.join(d, name), "w").write(text)  # noqa: E731
        w("system.csv", "time,cpu_busy_pct,psi_io_full\n" + "".join(f"t{i},{10 * i},{i}\n" for i in range(1, 11)))
        w("reims.csv", "time,fps,presents_asked,refusals\nt1,50,55,0\nt2,30,55,4\n")
        w("gpu.csv", "time,gpu,busy_pct,mem_busy_pct,vram_used_mb,vram_total_mb,gtt_used_mb,core_mhz,mem_mhz,temp_c,power_w\n"
                     "t1,nvidia:0,40,,1000,8192,,,,60,30\nt1,amd:card1,5,,100,512,20,,,50,5\n")
        w("qemu.csv", "time,pid,cpu_pct,rss_mb,threads\nt1,9,400,40000,60\nt2,9,600,40000,60\n")
        w("threads.csv", "time,tid,name,cpu_pct\nt1,1,CPU 0/KVM,90\nt2,1,CPU 0/KVM,70\nt1,2,reims-drain,20\n")
        w("netcheck.csv", "time,gateway,gateway_ms,dns_ms,tcp_ms,status\nt1,10.0.0.1,2,20,15,ok\n")
        w("events.log", "2026-09-25 10:00:00  monitoring started\n"
                        "2026-09-25 10:01:00  MARK: internet caiu\n"
                        "2026-09-25 10:01:05  NETWORK DOWN (host): gateway 10.0.0.1 ping failed\n"
                        "2026-09-25 10:01:35  network back after 30 s\n"
                        "2026-09-25 10:05:00  monitoring stopped\n")
        monitor.write_summary(d)
        s = open(os.path.join(d, "summary.txt")).read()
        self.assertIn("from 2026-09-25 10:00:00 to 2026-09-25 10:05:00", s)
        self.assertRegex(s, r"CPU busy %\s+avg\s+55\.0\s+p95\s+100\.0\s+max\s+100\.0")
        self.assertRegex(s, r"frames shown per second\s+avg\s+40\.0")
        self.assertIn("GPU nvidia:0", s)
        self.assertIn("GPU amd:card1", s)
        self.assertIn("NETWORK DOWN", s)
        self.assertIn("network back after 30 s", s)
        self.assertIn("MARK: internet caiu", s)
        self.assertRegex(s, r"CPU 0/KVM\s+80\.0")      # (90 + 70) / 2 samples

    def test_prune_keeps_newest(self):
        d = tempfile.mkdtemp()
        for i in range(8):
            os.makedirs(os.path.join(d, f"2026092{i}-000000"))
        monitor.prune(d)
        self.assertEqual(sorted(os.listdir(d)), [f"2026092{i}-000000" for i in range(3, 8)])


if __name__ == "__main__":
    unittest.main()
