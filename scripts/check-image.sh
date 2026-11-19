#!/bin/bash
# Hard image checks without booting: mount the built image and verify the
# appliance is fully installed. Any FAIL here means the image is broken and
# must not be published. Complements scripts/test-image-qemu.sh, which boots
# the image (best-effort under QEMU; no emulated Pi networking on raspi4b).
#
# Run on a Linux host with root:
#   sudo bash scripts/check-image.sh <image.img> [pi4|zero3]    (default: pi4)
#
# pi4:   Raspberry Pi OS layout — p1 = FAT boot (config.txt), p2 = rootfs.
# zero3: Armbian layout — single ext4 rootfs on p1 with /boot inside it.
set -euo pipefail

IMG="${1:?usage: check-image.sh <image> [pi4|zero3]}"
BOARD="${2:-pi4}"
[ -f "$IMG" ] || { echo "image not found: $IMG"; exit 1; }
case "$BOARD" in pi4|zero3) ;; *) echo "unknown board: $BOARD"; exit 1 ;; esac

LOOP=$(sudo losetup -fP --show "$IMG")
# The partition nodes (${LOOP}p1, p2) appear asynchronously: wait for them,
# or the mount below races and fails with "special device does not exist".
sudo partprobe "$LOOP" 2>/dev/null || true
sudo udevadm settle 2>/dev/null || true
for _ in $(seq 1 20); do
  [ -b "${LOOP}p1" ] && break
  sleep 0.5
done
MNT=$(mktemp -d /tmp/jellyby-check.XXXXXX)
cleanup() {
  sudo umount "$MNT/boot/firmware" 2>/dev/null || true
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

if [ "$BOARD" = "pi4" ]; then
  sudo mount "${LOOP}p2" "$MNT"
  sudo mkdir -p "$MNT/boot/firmware"
  sudo mount "${LOOP}p1" "$MNT/boot/firmware"
else
  sudo mount "${LOOP}p1" "$MNT"
fi

fail=0
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    fail=1
  fi
}

check "root filesystem present"           sudo test -d "$MNT/etc/systemd/system"
check "board marker is $BOARD"            test "$(sudo cat "$MNT/etc/jellyby/board" 2>/dev/null)" = "$BOARD"
check "mpv board profile installed"       sudo cmp -s "$MNT/opt/jellyby/mpv/board.conf" "$MNT/opt/jellyby/mpv/board-$BOARD.conf"

if [ "$BOARD" = "pi4" ]; then
  CFG="$MNT/boot/firmware/config.txt"
  check "boot config present"               sudo test -f "$CFG"
  check "boot config has vc4-kms-v3d"       sudo grep -q 'dtoverlay=vc4-kms-v3d' "$CFG"
  check "boot config has gpu_mem=256"       sudo grep -q 'gpu_mem=256' "$CFG"
  check "boot config has max_framebuffers=2" sudo grep -q 'max_framebuffers=2' "$CFG"
  check "boot config has disable_splash=1"  sudo grep -q 'disable_splash=1' "$CFG"
  check "kernel cmdline has root="           sudo grep -q 'root=' "$MNT/boot/firmware/cmdline.txt"
  check "HDMI audio default (asound.conf)"  sudo grep -q 'vc4hdmi0' "$MNT/etc/asound.conf"
  check "SSH enabled at first boot"         sudo test -f "$MNT/boot/firmware/ssh"
  check "default user configured"           sudo test -f "$MNT/boot/firmware/userconf.txt"
else
  check "armbianEnv.txt present"            sudo test -f "$MNT/boot/armbianEnv.txt"
  check "kernel image present in /boot"     sudo sh -c "ls '$MNT'/boot/vmlinuz-* >/dev/null 2>&1 || ls '$MNT'/boot/Image >/dev/null 2>&1"
  check "Rockchip udev rule installed"      sudo test -f "$MNT/etc/udev/rules.d/99-jellyby-rockchip.rules"
  check "Armbian first-login wizard disabled" sudo test ! -e "$MNT/root/.not_logged_in_yet"
  check "default user pi exists"            sudo grep -q '^pi:' "$MNT/etc/passwd"
  check "pi user is in sudo group"          sudo grep -Eq "^sudo:[^:]*:[^:]*:([^,]*,)?pi(,.*)?$" "$MNT/etc/group"
fi

for f in \
  /usr/local/bin/cec-kbd \
  /usr/local/bin/readsb \
  /usr/local/bin/readsb-wrapper \
  /usr/bin/mpv \
  /usr/bin/openbox \
  /usr/bin/xset \
  /usr/local/share/jellyby/readsb-rtlsdr \
  /etc/modprobe.d/jellyby-rtlsdr.conf \
  /opt/jellyby/server.py \
  /opt/jellyby/kiosk.sh \
  /opt/jellyby/play.sh \
  /opt/jellyby/resolve_stream.py \
  /opt/jellyby/netapply.sh \
  /opt/jellyby/mpv/mpv.conf \
  /opt/jellyby/mpv/board.conf \
  /etc/jellyby/board \
  /opt/jellyby/mpv/input.conf \
  /opt/jellyby/www/index.html \
  /opt/jellyby/www/app.js \
  /etc/jellyby/apps.json \
  /etc/jellyby/cec-keymap.conf \
  /etc/jellyby/players.json \
  /etc/sudoers.d/jellyby \
  /etc/X11/xorg.conf.d/99-jellyby.conf \
  /etc/default/readsb; do
  check "installed: $f" sudo test -e "$MNT$f"
done

for s in jellyby-web jellyby-x jellyby-kiosk cec-kbd readsb; do
  check "service enabled: $s" sudo test -L "$MNT/etc/systemd/system/multi-user.target.wants/$s.service"
done
check "ssh service enabled" sudo test -L "$MNT/etc/systemd/system/multi-user.target.wants/ssh.service"

check "media user in video group" sudo grep -Eq "^video:[^:]*:[^:]*:([^,]*,)?media(,.*)?$" "$MNT/etc/group"
check "media user in audio group" sudo grep -Eq "^audio:[^:]*:[^:]*:([^,]*,)?media(,.*)?$" "$MNT/etc/group"
# stat -c %U/%G would resolve names against the HOST passwd, not the image's,
# so compare numeric uid/gid taken from the image's own passwd/group.
MEDIA_UID=$(sudo sed -n 's/^media:[^:]*:\([0-9]*\):.*/\1/p' "$MNT/etc/passwd")
MEDIA_GID=$(sudo sed -n 's/^media:[^:]*:\([0-9]*\):.*/\1/p' "$MNT/etc/group")
check "media user exists" test -n "$MEDIA_UID"
check "media user is not UID 1000 (Pi userconf renames UID 1000)" test "$MEDIA_UID" != "1000"
check "/etc/jellyby owned by media (launcher saves settings)" test "$(sudo stat -c '%u' "$MNT/etc/jellyby")" = "$MEDIA_UID"
check "cec-kbd does not need libcec" sudo sh -c "! grep -q libcec '$MNT/usr/local/bin/cec-kbd'"
check "players.json is media:media 0600" test "$(sudo stat -c '%u %g %a' "$MNT/etc/jellyby/players.json")" = "$MEDIA_UID $MEDIA_GID 600"
check "sudoers syntax valid" sudo visudo -cf "$MNT/etc/sudoers.d/jellyby"
check "apps.json is valid JSON" sudo python3 -m json.tool "$MNT/etc/jellyby/apps.json"
check "players.json is valid JSON" sudo python3 -m json.tool "$MNT/etc/jellyby/players.json"

if [ "$fail" -ne 0 ]; then
  echo "IMAGE CHECKS FAILED: $IMG"
  exit 1
fi
echo "IMAGE CHECKS OK: $IMG"
