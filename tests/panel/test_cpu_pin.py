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


if __name__ == "__main__":
    unittest.main()
