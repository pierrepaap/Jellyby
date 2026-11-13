#!/bin/bash
# Boot a Jellyby image in QEMU and smoke-test it over SSH.
# Run on a Linux host with root: apt install qemu-system-arm qemu-utils sshpass device-tree-compiler
#
#   sudo bash scripts/test-image-qemu.sh [image.img] [ssh_port]
#
# How it boots: QEMU's raspi machines are bare SoC emulators — the image's
# VideoCore firmware never runs and config.txt is ignored. The kernel and DTB
# are therefore loaded explicitly (-kernel/-dtb) from the image's own boot
# partition, and the image's own disable-bt overlay is applied to the DTB with
# fdtoverlay so console=ttyAMA0 lands on the emulated PL011 (on the stock DTB
# the PL011 belongs to Bluetooth and the kernel prints nothing).
#
# Machine: raspi3b preferred (QEMU's raspi4b has no usable network: the Pi 4
# USB controller sits on PCIe, which QEMU does not emulate). raspi3b needs a
# resized power-of-2 *copy* of the image as the emulated SD card. usb-net on
# raspi3b logs benign "failed control transaction" retries but does come up.
#
# The serial console is copied to ./qemu-console.log on exit (CI attaches it).
#
# Hard checks (fail = image broken): boots to SSH, jellyby-web active, launcher
# UI + /api/config served, cec-kbd/readsb binaries present.
# Soft checks (warn; need real hardware): headless Chromium render, readsb
# service active (needs RTL-SDR dongle).
set -euo pipefail

IMG="${1:-jellyby-pi4.img}"
PORT="${2:-2222}"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }
command -v fdtoverlay >/dev/null || { echo "FAIL: fdtoverlay not found (apt install device-tree-compiler)"; exit 1; }

WORK="$(mktemp -d /tmp/jellyby-qemu.XXXXXX)"
echo "workdir: $WORK"

MACHINES=$(qemu-system-aarch64 -machine help 2>/dev/null || true)
if echo "$MACHINES" | grep -qw raspi3b; then
  MACHINE=raspi3b; MEM=1024; EARLYCON="earlycon=pl011,mmio32,0x3f201000"
elif echo "$MACHINES" | grep -qw raspi4b; then
  MACHINE=raspi4b; MEM=2048; EARLYCON="earlycon=pl011,mmio32,0xfe201000"
else
  echo "FAIL: qemu-system-aarch64 has no raspi machine (need raspi3b or raspi4b; QEMU >= 8)"
  exit 1
fi
echo "using machine: $MACHINE (${MEM}M)"

# QEMU's emulated SD card requires a power-of-2 image size; pishrink output is
# not. Boot a resized copy so the release artifact stays untouched.
cp --reflink=auto "$IMG" "$WORK/test.img"
qemu-img resize -f raw "$WORK/test.img" 8G

# Pull kernel, DTB and the disable-bt overlay out of the image's boot partition
# (QEMU never runs the firmware that would normally apply them).
LOOP=$(sudo losetup -fP --show "$WORK/test.img")
sudo mkdir -p /mnt/qb-boot
sudo mount "${LOOP}p1" /mnt/qb-boot
sudo cp /mnt/qb-boot/kernel8.img "$WORK/kernel8.img"
if [ "$MACHINE" = raspi4b ]; then
  sudo cp /mnt/qb-boot/bcm2711-rpi-4-b.dtb "$WORK/base.dtb"
else
  sudo cp /mnt/qb-boot/bcm2710-rpi-3-b.dtb "$WORK/base.dtb"
fi
if sudo test -f /mnt/qb-boot/overlays/disable-bt-overlay.dtbo; then
  sudo cp /mnt/qb-boot/overlays/disable-bt-overlay.dtbo "$WORK/disable-bt.dtbo"
fi
CMDLINE="$(sudo cat /mnt/qb-boot/cmdline.txt)"
sudo umount /mnt/qb-boot
sudo losetup -d "$LOOP"

if [ -f "$WORK/disable-bt.dtbo" ]; then
  fdtoverlay -i "$WORK/base.dtb" -o "$WORK/patched.dtb" "$WORK/disable-bt.dtbo"
else
  cp "$WORK/base.dtb" "$WORK/patched.dtb"
fi

qemu-system-aarch64 -M "$MACHINE" -smp 4 -m "$MEM" \
  -kernel "$WORK/kernel8.img" -dtb "$WORK/patched.dtb" \
  -append "$CMDLINE console=ttyAMA0,115200 $EARLYCON loglevel=8" \
  -drive "file=$WORK/test.img,format=raw,if=sd" \
  -netdev "user,id=n0,hostfwd=tcp::${PORT}-:22" -device usb-net,netdev=n0 \
  -display none -serial "file:$WORK/console.log" &
QPID=$!
trap 'cp "$WORK/console.log" ./qemu-console.log 2>/dev/null || true; kill "$QPID" 2>/dev/null || true' EXIT

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
