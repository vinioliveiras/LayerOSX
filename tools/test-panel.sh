#!/usr/bin/env bash
# Run the LayerOSX Settings tests: backend unit tests (fake machine, no root,
# no VM) and, when a display is available, the headless UI smoke test.
#   tools/test-panel.sh            backend tests (+ UI test if $DISPLAY is set)
#   xvfb-run tools/test-panel.sh   UI test on a virtual display
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/tests/panel"
python3 -m unittest -v test_backend test_monitor
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    python3 - <<'PY'
import os, subprocess, sys, tempfile
sys.path.insert(0, ".")
import test_backend as t
fm = t.FakeMachine("setUp"); fm.setUp()
open(os.path.join(fm.tmp, "ctl.sock"), "w").close()   # pretend the Mac is running
env = dict(os.environ)
sys.exit(subprocess.call([sys.executable, "ui_smoke.py"], env=env))
PY
else
    echo "(no display: skipped the UI smoke test -- run under xvfb-run to include it)"
fi
