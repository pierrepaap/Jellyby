#!/bin/bash
# Boot a Jellyby image in QEMU (raspi4b) and smoke-test it over SSH.
# Run on an x86_64 Linux host with: sudo apt install qemu-system-arm qemu-utils sshpass
#
#   sudo bash scripts/test-image-qemu.sh [image.img] [ssh_port]
#
# Hard checks (fail = image is broken): boots to SSH, jellyby-web active and
# serving the launcher UI + /api/config.
# Soft checks (warn only, need real hardware): headless Chromium renders the
# launcher, readsb/cec-kbd binaries present (no RTL-SDR / CEC adapter in QEMU).
set -euo pipefail

IMG="${1:-jellyby-pi4.img}"
PORT="${2:-2222}"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }

WORK="$(mktemp -d /tmp/jellyby-qemu.XXXXXX)"
echo "workdir: $WORK"

# extract kernel + dtb from the image's boot partition
LOOP=$(sudo losetup -fP --show "$IMG")
sudo mkdir -p /mnt/qb-boot
sudo mount "${LOOP}p1" /mnt/qb-boot
sudo cp /mnt/qb-boot/kernel8.img /mnt/qb-boot/bcm2711-rpi-4-b.dtb "$WORK/"
sudo umount /mnt/qb-boot
sudo losetup -d "$LOOP"

qemu-system-aarch64 -M raspi4b -cpu cortex-a72 -smp 4 -m 4096 \
  -kernel "$WORK/kernel8.img" -dtb "$WORK/bcm2711-rpi-4-b.dtb" \
  -append "rw root=/dev/mmcblk0p2 rootfstype=ext4 rootwait console=ttyAMA0" \
  -drive file="$IMG",format=raw,if=sd \
  -netdev "user,id=n0,hostfwd=tcp::${PORT}-:22" -device usb-net,netdev=n0 \
  -display none -serial "file:$WORK/console.log" &
QPID=$!
trap 'kill "$QPID" 2>/dev/null || true' EXIT

SSH="sshpass -p jellyby ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 pi@127.0.0.1"

echo "waiting for SSH on port $PORT (first boot can take several minutes under TCG)..."
ok=""
i=0
while [ "$i" -lt 90 ]; do
  i=$((i + 1))
  if $SSH true 2>/dev/null; then ok=1; break; fi
  sleep 10
done
if [ -z "$ok" ]; then
  echo "FAIL: no SSH after 15 min; console tail:"
  tail -60 "$WORK/console.log" || true
  exit 1
fi
echo "PASS: booted and SSH reachable"

fail=0
check() { # check <description> <command...>
  local desc="$1"; shift
  if $SSH "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    fail=1
  fi
}
warn() { # warn <description> <command...>
  local desc="$1"; shift
  if $SSH "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "WARN (needs real hardware): $desc"
  fi
}

check "hostname is jellyby"            "[ \"\$(hostname)\" = jellyby ]"
check "jellyby-web service active"     "systemctl is-active --quiet jellyby-web"
check "launcher UI served"              "curl -sf http://127.0.0.1:8901/ | grep -q Jellyby"
check "launcher API returns apps"      "curl -sf http://127.0.0.1:8901/api/config | grep -q '\"apps\"'"
check "static assets served"           "curl -sf http://127.0.0.1:8901/static/app.js | grep -q addEventListener"
check "cec-kbd binary installed"       "test -x /usr/local/bin/cec-kbd"
check "readsb binary installed"        "test -x /usr/local/bin/readsb"
warn  "headless Chromium renders launcher" "timeout 600 sudo -u media chromium --headless=new --no-sandbox --disable-gpu --dump-dom http://127.0.0.1:8901 | grep -q launcher"
warn  "readsb service active (needs RTL-SDR dongle)" "systemctl is-active --quiet readsb"

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED; console tail:"
  tail -60 "$WORK/console.log" || true
  exit 1
fi
echo "SMOKE TEST OK: $IMG boots and serves the launcher (console log: $WORK/console.log)"
