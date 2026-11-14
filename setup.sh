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
  mpv \
  xserver-xorg xserver-xorg-input-libinput xserver-xorg-video-fbdev \
  openssh-server sudo \
  git make gcc pkg-config \
  libcec-dev cec-utils \
  libusb-1.0-0-dev librtlsdr-dev libncurses-dev zlib1g-dev libzstd-dev \
  python3

# Optional polished front-ends (secondary; system mpv stays the primary decode
# path). Off by default to keep the image lean: JELLYBY_THEATER=1 sudo ./setup.sh
if [[ "${JELLYBY_THEATER:-0}" == "1" ]]; then
  echo "==> Installing optional theater front-ends (flatpak JMP + Emby Theater .deb)"
  apt-get install -y flatpak
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
  flatpak install -y flathub dev.jellyfin.JellyfinMediaPlayer || echo "JMP flatpak install failed; mpv remains the player" >&2
  curl -fL -o /tmp/emby-theater.deb https://github.com/MediaBrowser/Emby.Releases/releases/latest/download/emby-theater-arm64.deb \
    && dpkg -i /tmp/emby-theater.deb || echo "Emby Theater .deb install failed; mpv remains the player" >&2
fi

echo "==> Creating kiosk user 'media'"
if ! id media >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash media
fi
# mpv needs the GPU (renderD128) and the rpivid V4L2 decoder nodes (video group)
usermod -aG video,audio media

echo "==> Installing Jellyby files"
install -d /etc/jellyby /opt/jellyby/www /usr/local/bin

# Do not overwrite user-edited config on re-runs
[[ -f /etc/jellyby/apps.json ]]      || install -m 644 "$FILES/etc/jellyby/apps.json" /etc/jellyby/apps.json
[[ -f /etc/jellyby/cec-keymap.conf ]] || install -m 644 "$FILES/etc/jellyby/cec-keymap.conf" /etc/jellyby/cec-keymap.conf
# players.json holds media-server credentials (and, once gained, auth tokens):
# media:media 0600, never overwritten — the launcher (user media) persists
# tokens itself after authenticating; root still edits it over SSH
[[ -f /etc/jellyby/players.json ]]   || install -m 600 -o media -g media "$FILES/etc/jellyby/players.json" /etc/jellyby/players.json

cp -r "$FILES/opt/jellyby/." /opt/jellyby/
chmod 755 /opt/jellyby/kiosk.sh /opt/jellyby/server.py /opt/jellyby/play.sh /opt/jellyby/resolve_stream.py /opt/jellyby/netapply.sh

install -m 755 "$FILES/usr/local/bin/readsb-wrapper.sh" /usr/local/bin/readsb-wrapper
install -m 644 "$FILES/etc/default/readsb" /etc/default/readsb
install -m 440 "$FILES/etc/sudoers.d/jellyby" /etc/sudoers.d/jellyby
install -d /etc/X11/xorg.conf.d
install -m 644 "$FILES/etc/X11/xorg.conf.d/99-jellyby.conf" /etc/X11/xorg.conf.d/99-jellyby.conf

for unit in jellyby-web jellyby-x jellyby-kiosk cec-kbd readsb; do
  install -m 644 "$FILES/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.service"
done

# The launcher web app saves /etc/jellyby/apps.json as user 'media'
# (players.json keeps media:media 0600 — it contains credentials)
chown media:media /etc/jellyby/apps.json /etc/jellyby/cec-keymap.conf 2>/dev/null || chown -R media:media /etc/jellyby

echo "==> Compiling CEC keyboard daemon"
# libcec.pc on Debian/Raspberry Pi OS declares "Requires: p8-platform" but does
# not ship that .pc, so pkg-config fails; fall back to plain -lcec.
CEC_LIBS="$(pkg-config --libs libcec 2>/dev/null || true)"
if [[ -z "${CEC_LIBS// }" ]]; then
  CEC_LIBS="-lcec"
fi
read -r -a CEC_LIB_ARGS <<< "$CEC_LIBS"
gcc -O2 -Wall -o /usr/local/bin/cec-kbd "$FILES/opt/jellyby/cec_kbd.c" "${CEC_LIB_ARGS[@]}"

echo "==> Building readsb from source"
if [[ ! -x /usr/local/bin/readsb ]]; then
  rm -rf /opt/readsb-src
  git clone --depth 1 https://github.com/wiedehopf/readsb.git /opt/readsb-src
  make -C /opt/readsb-src -j"$(nproc)" readsb || make -C /opt/readsb-src -j"$(nproc)"
  install -m 755 /opt/readsb-src/readsb /usr/local/bin/readsb
fi

# Boot config (idempotent, also in chroot via JELLYBY_BOOT_DIR bind mount):
# vc4-kms-v3d exposes the Pi 4 GPU + rpivid HEVC decoder to mpv and makes Xorg
# modesetting GPU-accelerated; gpu_mem=256 for 4K decode headroom.
ensure_boot_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 0
  local line key
  for line in "dtoverlay=vc4-kms-v3d" "gpu_mem=256" "max_framebuffers=2" "disable_splash=1"; do
    key="${line%%=*}"
    if ! grep -qE "^[[:space:]]*${key}=" "$cfg"; then
      echo "$line" >> "$cfg"
    fi
  done
}
BOOT_DIR="${JELLYBY_BOOT_DIR:-}"
if [[ -z "$BOOT_DIR" ]]; then
  for d in /boot/firmware /boot; do
    [[ -d "$d" ]] && BOOT_DIR="$d" && break
  done
fi
if [[ -n "$BOOT_DIR" ]]; then
  echo "==> Ensuring boot config in $BOOT_DIR/config.txt"
  ensure_boot_config "$BOOT_DIR/config.txt"
fi

if [[ "${JELLYBY_OFFLINE:-0}" != "1" ]]; then
  echo "==> Setting hostname"
  hostnamectl set-hostname jellyby 2>/dev/null || true
fi

echo "==> Enabling services"
if [[ "${JELLYBY_OFFLINE:-0}" == "1" ]]; then
  systemctl enable ssh jellyby-web cec-kbd jellyby-x jellyby-kiosk readsb
  apt-get clean
  rm -rf /var/lib/apt/lists/* /opt/readsb-src
else
  systemctl daemon-reload
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
  echo "  - Add/edit your Emby / Jellyfin / Plex servers in the on-screen settings."
  echo "    Jellyfin/Emby tiles play natively in MPV (Pi 4 HEVC hwdec); Plex/browser tiles open in Chromium."
  echo "  - Media server credentials for MPV: /etc/jellyby/players.json (media:media 0600)."
  echo "  - Network (static/DHCP): Settings in the launcher, or over SSH:"
  echo "    sudo /opt/jellyby/netapply.sh eth0 dhcp   # revert escape hatch"
  echo "  - readsb: edit /etc/default/readsb over SSH, then 'sudo systemctl restart readsb'."
  echo "  - CEC keymap: /etc/jellyby/cec-keymap.conf, then 'sudo systemctl restart cec-kbd'."
fi
