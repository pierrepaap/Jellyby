#!/usr/bin/env bash
#
# Jellyby setup: turn a fresh Raspberry Pi OS Lite (64-bit) into the Jellyby
# appliance (kiosk media launcher + CEC remote + readsb).
#
# Usage on the Pi:
#   git clone https://github.com/pierrepaap/Jellyby.git
#   cd Jellyby
#   sudo ./setup.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$REPO_DIR/files"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./setup.sh"
  exit 1
fi

# JELLYBY_OFFLINE=1: running inside a chroot (image build in CI). Skip the
# hardware check, hostnamectl and "systemctl enable --now" (no systemd running).
if [[ "${JELLYBY_OFFLINE:-0}" != "1" ]] && ! grep -qi raspberry /proc/device-tree/model 2>/dev/null && ! grep -qi raspberry /proc/cpuinfo 2>/dev/null; then
  read -r -p "This does not look like a Raspberry Pi. Proceed anyway? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

echo "==> Updating package lists"
export DEBIAN_FRONTEND=noninteractive
apt-get update

CHROMIUM_PKG="chromium"
if ! apt-cache show "$CHROMIUM_PKG" >/dev/null 2>&1; then
  CHROMIUM_PKG="chromium-browser"
fi

echo "==> Installing packages (browser: $CHROMIUM_PKG)"
apt-get install -y \
  "$CHROMIUM_PKG" \
  xserver-xorg xserver-xorg-input-libinput xserver-xorg-video-fbdev \
  openssh-server sudo \
  git make gcc pkg-config \
  libcec-dev cec-utils \
  libusb-1.0-0-dev librtlsdr-dev libncurses-dev zlib1g-dev \
  python3

echo "==> Creating kiosk user 'media'"
if ! id media >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash media
fi

echo "==> Installing Jellyby files"
install -d /etc/jellyby /opt/jellyby/www /usr/local/bin

# Do not overwrite user-edited config on re-runs
[[ -f /etc/jellyby/apps.json ]]      || install -m 644 "$FILES/etc/jellyby/apps.json" /etc/jellyby/apps.json
[[ -f /etc/jellyby/cec-keymap.conf ]] || install -m 644 "$FILES/etc/jellyby/cec-keymap.conf" /etc/jellyby/cec-keymap.conf

cp -r "$FILES/opt/jellyby/." /opt/jellyby/
chmod 755 /opt/jellyby/kiosk.sh /opt/jellyby/server.py

install -m 755 "$FILES/usr/local/bin/readsb-wrapper.sh" /usr/local/bin/readsb-wrapper
install -m 644 "$FILES/etc/default/readsb" /etc/default/readsb
install -m 440 "$FILES/etc/sudoers.d/jellyby" /etc/sudoers.d/jellyby
install -d /etc/X11/xorg.conf.d
install -m 644 "$FILES/etc/X11/xorg.conf.d/99-jellyby.conf" /etc/X11/xorg.conf.d/99-jellyby.conf

for unit in jellyby-web jellyby-x jellyby-kiosk cec-kbd readsb; do
  install -m 644 "$FILES/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.service"
done

# The launcher web app saves /etc/jellyby/apps.json as user 'media'
chown -R media:media /etc/jellyby

echo "==> Compiling CEC keyboard daemon"
gcc -O2 -Wall -o /usr/local/bin/cec-kbd "$FILES/opt/jellyby/cec_kbd.c" $(pkg-config --cflags --libs libcec)

echo "==> Building readsb from source"
if [[ ! -x /usr/local/bin/readsb ]]; then
  rm -rf /opt/readsb-src
  git clone --depth 1 https://github.com/wiedehopf/readsb.git /opt/readsb-src
  make -C /opt/readsb-src -j"$(nproc)" readsb || make -C /opt/readsb-src -j"$(nproc)"
  install -m 755 /opt/readsb-src/readsb /usr/local/bin/readsb
fi

if [[ "${JELLYBY_OFFLINE:-0}" != "1" ]]; then
  echo "==> Setting hostname and disabling boot splash"
  hostnamectl set-hostname jellyby 2>/dev/null || true
  for cfg in /boot/firmware/config.txt /boot/config.txt; do
    if [[ -f "$cfg" ]] && ! grep -q "^disable_splash=1" "$cfg"; then
      echo "disable_splash=1" >> "$cfg"
    fi
  done
fi

echo "==> Enabling services"
systemctl daemon-reload
if [[ "${JELLYBY_OFFLINE:-0}" == "1" ]]; then
  systemctl enable ssh jellyby-web cec-kbd jellyby-x jellyby-kiosk readsb
else
  systemctl enable --now ssh
  systemctl enable --now jellyby-web cec-kbd jellyby-x jellyby-kiosk readsb
fi

echo
if [[ "${JELLYBY_OFFLINE:-0}" == "1" ]]; then
  echo "Jellyby setup complete (offline/image-build mode: services enabled, they start on first boot)."
else
  echo "Jellyby setup complete."
  echo "  - Reboot now (sudo reboot) to enter the kiosk: the launcher appears on HDMI."
  echo "  - Navigate with your projector remote (HDMI-CEC). Menu key = settings."
  echo "  - Add/edit your Emby / Jellyfin / Plex URLs in the on-screen settings."
  echo "  - readsb: edit /etc/default/readsb over SSH, then 'sudo systemctl restart readsb'."
  echo "  - CEC keymap: /etc/jellyby/cec-keymap.conf, then 'sudo systemctl restart cec-kbd'."
fi
