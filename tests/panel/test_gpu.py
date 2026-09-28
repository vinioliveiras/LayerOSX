"""kiosk/lib/gpu-pick.py and power-mode.sh's GPU clocks against fake sysfs."""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "..", "archiso", "airootfs", "opt", "layerosx", "kiosk", "lib")


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def r(path):
    with open(path) as f:
        return f.read().strip()


class GpuMachine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.drm = os.path.join(self.tmp, "drm")
        self.icd = os.path.join(self.tmp, "icd")
        for n in ("nvidia_icd.json", "radeon_icd.x86_64.json", "intel_icd.x86_64.json"):
            w(os.path.join(self.icd, n), "{}")
        os.environ["LAYEROSX_DRM"] = self.drm
        os.environ["LAYEROSX_VK_ICD_DIRS"] = self.icd
        spec = importlib.util.spec_from_file_location("gpu_pick", os.path.join(LIB, "gpu-pick.py"))
        self.m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.m)

    def tearDown(self):
        shutil.rmtree(self.tmp)
        for k in ("LAYEROSX_DRM", "LAYEROSX_VK_ICD_DIRS"):
            os.environ.pop(k, None)

    def card(self, n, vendor, boot):
        d = os.path.join(self.drm, f"card{n}", "device")
        w(os.path.join(d, "vendor"), vendor + "\n")
        w(os.path.join(d, "boot_vga"), ("1" if boot else "0") + "\n")
        os.makedirs(os.path.join(self.drm, f"card{n}-eDP-1"), exist_ok=True)   # a connector: ignored
        return d


class TestPick(GpuMachine):
    def test_hybrid_laptop(self):
        self.card(0, "0x10de", False)   # RTX 4060
        self.card(1, "0x1002", True)    # Radeon 680M drives the panel
        icd, v, _ = self.m.pick("auto", "eDP-1")
        self.assertEqual((os.path.basename(icd), v), ("radeon_icd.x86_64.json", "0x1002"))
        icd, v, _ = self.m.pick("auto", "HDMI-1-0")          # NVIDIA's HDMI (secondary provider)
        self.assertEqual((os.path.basename(icd), v), ("nvidia_icd.json", "0x10de"))
        # the automatic pick failed before -> Reims' own choice (discrete)
        icd, v, why = self.m.pick("auto", "eDP-1", "radeon_icd.x86_64.json")
        self.assertEqual((icd, v), ("-", "0x10de"))
        self.assertIn("failed", why)
        # a fixed choice: only the vendor is reported
        self.assertEqual(self.m.pick("radeon_icd.x86_64.json", "HDMI-1-0")[:2], ("-", "0x1002"))

    def test_single_and_same_vendor(self):
        self.card(0, "0x1002", True)
        self.assertEqual(self.m.pick("auto", "DP-1")[:2], ("-", "0x1002"))
        self.card(1, "0x1002", False)
        self.assertEqual(self.m.pick("auto", "DP-1")[0], "-")


class TestPowerModeGpu(GpuMachine):
    def run_pm(self, *args):
        env = dict(os.environ, LAYEROSX_STATE_DIR=os.path.join(self.tmp, "state"),
                   LAYEROSX_CPUFREQ=os.path.join(self.tmp, "cpufreq"),
                   LAYEROSX_PLATFORM_PROFILE=os.path.join(self.tmp, "pp"),
                   LAYEROSX_POWER_SUPPLY=os.path.join(self.tmp, "psu"),
                   LAYEROSX_POWER_RUN=os.path.join(self.tmp, "run"),
                   LAYEROSX_REIMS_VENDOR_FILE=os.path.join(self.tmp, "vendor"),
                   LAYEROSX_NV_LOCKED=os.path.join(self.tmp, "nvlocked"),
                   LAYEROSX_NVIDIA_SMI=os.path.join(self.tmp, "nvidia-smi"))
        return subprocess.run(["bash", os.path.join(LIB, "power-mode.sh"), *args], env=env,
                              capture_output=True, text=True)

    def test_clocks_follow_mode_for_reims_gpu_only(self):
        amd = self.card(1, "0x1002", True)
        w(os.path.join(amd, "power_dpm_force_performance_level"), "auto\n")
        self.card(0, "0x10de", False)
        smi = os.path.join(self.tmp, "nvidia-smi")
        w(smi, f"#!/bin/sh\necho \"$*\" >> {self.tmp}/smi.log\ncase \"$*\" in *query*) echo 2370 ;; esac\n")
        os.chmod(smi, 0o755)
        w(os.path.join(self.tmp, "vendor"), "0x1002\n")
        self.run_pm("apply", "performance")
        self.assertEqual(r(os.path.join(amd, "power_dpm_force_performance_level")), "high")
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "smi.log")))     # idle dGPU untouched
        # Reims moves to NVIDIA: AMD back to auto, NVIDIA locked at >= half its max
        w(os.path.join(self.tmp, "vendor"), "0x10de\n")
        self.run_pm("restore")
        self.assertEqual(r(os.path.join(amd, "power_dpm_force_performance_level")), "auto")
        self.assertIn("--lock-gpu-clocks=1185,2370", r(os.path.join(self.tmp, "smi.log")))
        self.run_pm("apply", "balanced")
        self.assertIn("--reset-gpu-clocks", r(os.path.join(self.tmp, "smi.log")))
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "nvlocked")))


if __name__ == "__main__":
    unittest.main()
