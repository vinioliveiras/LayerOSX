#!/usr/bin/env bash
# Runs INSIDE the chroot of the system install-wizard.sh just rsync'd
# onto the target disk (via arch-chroot). A single log; one script
# failing doesn't block the others — better to end up with an
# almost-fully-ready system than none at all.
set -uo pipefail
LOG=/var/log/layerosx-postinstall.log
exec > >(tee -a "$LOG") 2>&1

echo "===== LayerOSX postinstall: $(date -Is) ====="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for step in "$SCRIPT_DIR"/[0-9][0-9]-*.sh; do
    echo "--- running: $step ---"
    if ! bash "$step"; then
        echo "!!! $step failed (see above) — continuing anyway rather than blocking the whole install."
    fi
done

echo "===== postinstall done: $(date -Is) ====="
echo "Full log at /var/log/layerosx-postinstall.log"
