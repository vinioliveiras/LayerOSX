"""kiosk/lib/cpu-pin.py layout against fake sysfs CPU topologies."""
import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(HERE, "..", "..", "archiso", "airootfs", "opt", "layerosx", "kiosk", "lib", "cpu-pin.py")


def load(sys_dir):
    os.environ["LAYEROSX_SYS_CPU"] = sys_dir
    spec = importlib.util.spec_from_file_location("cpu_pin", PATH)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


class TestPlan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)
        os.environ.pop("LAYEROSX_SYS_CPU", None)

    def topo(self, siblings, freqs=None):
        n = max(max(s) for s in siblings) + 1
        with open(os.path.join(self.tmp, "online"), "w") as f:
            f.write(f"0-{n - 1}\n")
        for i, s in enumerate(siblings):
            for cpu in s:
                d = os.path.join(self.tmp, f"cpu{cpu}")
                os.makedirs(os.path.join(d, "topology"), exist_ok=True)
                os.makedirs(os.path.join(d, "cpufreq"), exist_ok=True)
                with open(os.path.join(d, "topology", "thread_siblings_list"), "w") as f:
                    f.write(",".join(map(str, s)) + "\n")
                with open(os.path.join(d, "cpufreq", "cpuinfo_max_freq"), "w") as f:
                    f.write(str((freqs or {}).get(i, 4800000)) + "\n")
        return load(self.tmp)

    def test_ryzen_8c16t_all_cores(self):
        m = self.topo([[i, i + 8] for i in range(8)])      # 7735HS
        pins, host = m.plan(8)
        self.assertEqual(pins, [1, 2, 3, 4, 5, 6, 7, 0])    # core 0 last
        self.assertEqual(host, list(range(8, 16)))          # the SMT siblings

    def test_spare_cores_keep_siblings_idle(self):
        m = self.topo([[i, i + 8] for i in range(8)])
        pins, host = m.plan(4)
        self.assertEqual(pins, [1, 2, 3, 4])
        self.assertEqual(host, [0, 5, 6, 7, 8, 13, 14, 15])

    def test_hybrid_prefers_p_cores(self):
        # 2 P-cores (HT) + 4 E-cores
        m = self.topo([[0, 1], [2, 3], [4], [5], [6], [7]],
                      freqs={0: 5000000, 1: 5000000, 2: 3800000, 3: 3800000, 4: 3800000, 5: 3800000})
        pins, host = m.plan(4)
        self.assertEqual(pins, [2, 0, 4, 5])
        self.assertEqual(host, [6, 7])

    def test_not_enough_cores(self):
        m = self.topo([[0, 4], [1, 5], [2, 6], [3, 7]])
        self.assertEqual(m.plan(8), (None, None))
        m = self.topo([[0], [1], [2], [3]])                 # no SMT, no spare
        self.assertEqual(m.plan(4), (None, None))


LIB = os.path.join(HERE, "..", "..", "archiso", "airootfs", "opt", "layerosx", "kiosk", "lib")


class TestHelpers(unittest.TestCase):
    """hugepages.sh / host-cpus.sh against fake sysfs/procfs files."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_sh(self, script, *args, env=None):
        import subprocess
        e = dict(os.environ, **(env or {}))
        p = subprocess.run(["bash", os.path.join(LIB, script), *args], env=e, capture_output=True, text=True)
        return p.returncode, p.stdout.strip()

    def w(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def r(self, path):
        with open(path) as f:
            return f.read().strip()

    def hp_env(self, avail_kb, grant=None):
        hp = os.path.join(self.tmp, "hp")
        self.w(os.path.join(hp, "nr_hugepages"), "0\n")
        self.w(os.path.join(hp, "free_hugepages"), "0\n")
        self.w(os.path.join(self.tmp, "meminfo"), f"MemAvailable: {avail_kb} kB\n")
        os.makedirs(os.path.join(self.tmp, "vm"))
        return hp, {"LAYEROSX_HUGEPAGES_SYSFS": hp, "LAYEROSX_PROC_VM": os.path.join(self.tmp, "vm"),
                    "LAYEROSX_MEMINFO": os.path.join(self.tmp, "meminfo")}

    def test_hugepages_reserve(self):
        hp, env = self.hp_env(40 * 1024 * 1024)
        # a fake kernel: free pages follow nr_hugepages (run through a tiny wrapper)
        wrapper = os.path.join(self.tmp, "hp.sh")
        self.w(wrapper, f"""set_nr_hook() {{ :; }}
source <(sed 's|^set_nr() {{.*|set_nr() {{ echo "$1" > "$HP/nr_hugepages"; echo "$1" > "$HP/free_hugepages"; }}|' {os.path.join(LIB, "hugepages.sh")})
""")
        import subprocess
        e = dict(os.environ, **env)
        p = subprocess.run(["bash", wrapper, "reserve", "16384"], env=e, capture_output=True, text=True)
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "8192"))
        self.assertEqual(self.r(os.path.join(hp, "nr_hugepages")), "8192")
        # already reserved (a Mac restart): nothing changes
        p = subprocess.run(["bash", wrapper, "reserve", "16384"], env=e, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        # too big for what's available -> refused, pool unchanged
        p = subprocess.run(["bash", wrapper, "reserve", "60000"], env=e, capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertEqual(self.r(os.path.join(hp, "nr_hugepages")), "8192")

    def test_hugepages_fragmented(self):
        hp, env = self.hp_env(40 * 1024 * 1024)   # kernel grants nothing: free stays 0
        rc, out = self.run_sh("hugepages.sh", "reserve", "8192", env=env)
        self.assertEqual(rc, 1)
        self.assertIn("fragmented", out)
        self.assertEqual(self.r(os.path.join(hp, "nr_hugepages")), "0")   # put back

    def test_hugepages_bad_args(self):
        _, env = self.hp_env(1 << 20)
        self.assertEqual(self.run_sh("hugepages.sh", "reserve", "12;rm", env=env)[0], 2)
        self.assertEqual(self.run_sh("hugepages.sh", "reserve", env=dict(env, LAYEROSX_HUGEPAGES_SYSFS="/nope"))[0], 2)

    def test_host_cpus(self):
        proc = os.path.join(self.tmp, "proc")
        for irq in ("1", "24", "130"):
            self.w(os.path.join(proc, "irq", irq, "smp_affinity_list"), "0-15\n")
        wq = os.path.join(self.tmp, "wq")
        self.w(wq, "ffff\n")
        env = {"LAYEROSX_PROC": proc, "LAYEROSX_WQ_CPUMASK": wq, "LAYEROSX_SYSTEMCTL": "true"}
        rc, out = self.run_sh("host-cpus.sh", "apply", "8-15", env=env)
        self.assertEqual(rc, 0)
        self.assertIn("3 IRQs moved", out)
        self.assertEqual(self.r(os.path.join(proc, "irq", "24", "smp_affinity_list")), "8-15")
        self.assertEqual(self.r(wq), "ff00")
        self.assertEqual(self.run_sh("host-cpus.sh", "apply", "8-15; reboot", env=env)[0], 2)


if __name__ == "__main__":
    unittest.main()
