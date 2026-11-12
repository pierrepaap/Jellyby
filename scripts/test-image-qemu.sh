#!/bin/bash
# Boot a Jellyby image in QEMU and smoke-test it over SSH.
# Run on an x86_64 Linux host with root: apt install qemu-system-arm qemu-utils sshpass
#
#   sudo bash scripts/test-image-qemu.sh [image.img] [ssh_port]
#
# How it boots: QEMU's raspi machines run the image's own VideoCore firmware from
# the SD card (no -kernel/-dtb), which honours config.txt — that matters because
# with a stock DTB the Pi 3's PL011 UART is routed to Bluetooth and the kernel
# prints nothing under QEMU. We boot a resized *copy* (emulated SD needs a
# power-of-2 size) with enable_uart=1 + dtoverlay=disable-bt + console=ttyAMA0
# added to the copy's boot partition.
#
# Machine: raspi4b on QEMU >= 9, else raspi3b (Ubuntu 24.04 ships QEMU 8.x,
# which has no raspi4b). usb-net on raspi3b logs benign "failed control
# transaction" retries but does come up.
#
# Hard checks (fail = image broken): boots to SSH, jellyby-web active, launcher
# UI + /api/config served, cec-kbd/readsb binaries present.
# Soft checks (warn; need real hardware): headless Chromium render, readsb
# service active (needs RTL-SDR dongle).
set -euo pipefail

IMG="${1:-jellyby-pi4.img}"
PORT="${2:-2222}"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }

WORK="$(mktemp -d /tmp/jellyby-qemu.XXXXXX)"
echo "workdir: $WORK"

MACHINES=$(qemu-system-aarch64 -machine help 2>/dev/null || true)
if echo "$MACHINES" | grep -qw raspi4b; then
  MACHINE=raspi4b; MEM=4096
elif echo "$MACHINES" | grep -qw raspi3b; then
  MACHINE=raspi3b; MEM=1024
else
  echo "FAIL: qemu-system-aarch64 has no raspi machine (need raspi4b or raspi3b; QEMU >= 8)"
  exit 1
fi
echo "using machine: $MACHINE (${MEM}M)"

# QEMU's emulated SD card requires a power-of-2 image size; pishrink output is
# not. Boot a resized copy so the release artifact stays untouched.
cp --reflink=auto "$IMG" "$WORK/test.img"
qemu-img resize "$WORK/test.img" 8G

# make the copy's firmware put the console on the PL011 UART (ttyAMA0)
LOOP=$(sudo losetup -fP --show "$WORK/test.img")
sudo mkdir -p /mnt/qb-boot
sudo mount "${LOOP}p1" /mnt/qb-boot
printf 'enable_uart=1\ndtoverlay=disable-bt\n' | sudo tee -a /mnt/qb-boot/config.txt
sudo sed -i 's|$| console=ttyAMA0,115200 earlyprintk loglevel=8|' /mnt/qb-boot/cmdline.txt
sudo umount /mnt/qb-boot
sudo losetup -d "$LOOP"

qemu-system-aarch64 -M "$MACHINE" -smp 4 -m "$MEM" \
  -drive "file=$WORK/test.img,format=raw,if=sd" \
  -netdev "user,id=n0,hostfwd=tcp::${PORT}-:22" -device usb-net,netdev=n0 \
  -display none -serial "file:$WORK/console.log" &
QPID=$!
trap 'kill "$QPID" 2>/dev/null || true' EXIT

SSH="sshpass -p jellyby ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 pi@127.0.0.1"

echo "waiting for SSH on port $PORT (first boot under TCG can take a while)..."
ok=""
i=0
while [ "$i" -lt 120 ]; do
  i=$((i + 1))
  if $SSH true 2>/dev/null; then ok=1; break; fi
  if grep -qi "kernel panic" "$WORK/console.log" 2>/dev/null; then
    echo "FAIL: kernel panic in console log"
    break
  fi
  sleep 10
done
if [ -z "$ok" ]; then
  echo "FAIL: no SSH after 20 min; console tail:"
  tail -60 "$WORK/console.log" 2>/dev/null || echo "(console log empty)"
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
check "mpv installed (native player)"  "command -v mpv"
check "play.sh + netapply.sh present"  "test -x /opt/jellyby/play.sh -a -x /opt/jellyby/netapply.sh"
check "boot config has vc4-kms-v3d"    "grep -q 'dtoverlay=vc4-kms-v3d' /boot/firmware/config.txt"
check "boot config has gpu_mem=256"    "grep -q 'gpu_mem=256' /boot/firmware/config.txt"
check "media user in video group"      "id -nG media | grep -qw video"
warn  "headless Chromium renders launcher" "timeout 600 sudo -u media chromium --headless=new --no-sandbox --disable-gpu --dump-dom http://127.0.0.1:8901 | grep -q launcher"
warn  "readsb service active (needs RTL-SDR dongle)" "systemctl is-active --quiet readsb"

if [ "$fail" -ne 0 ]; then
  echo "SMOKE TEST FAILED; console tail:"
  tail -60 "$WORK/console.log" 2>/dev/null || true
  exit 1
fi
echo "SMOKE TEST OK: $IMG boots and serves the launcher (console log: $WORK/console.log)"
