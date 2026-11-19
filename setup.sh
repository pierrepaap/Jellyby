#!/usr/bin/env bash
#
# Jellyby setup: turn a fresh Raspberry Pi OS Lite (64-bit) or Armbian
# (Radxa ZERO 3E/3W, vendor kernel) into the Jellyby appliance (kiosk media
# launcher + CEC remote + readsb).
#
# Board: auto-detected from the device tree; override with
#   JELLYBY_BOARD=pi4|zero3   (required in CI chroot builds)
# zero3 only: JELLYBY_MPV_DEBS="<url or path> ..." installs an MPP-enabled
#   mpv/ffmpeg build (.debs) instead of Debian's mpv, which cannot use the
#   RK3566 hardware decoder.
#
# Usage on the board:
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
detect_board() {
  local model
  model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)"
  case "$model" in
    *"Raspberry Pi"*)          echo pi4 ;;
    *"Radxa ZERO 3"*|*"Radxa Zero 3"*) echo zero3 ;;
    *) grep -qi raspberry /proc/cpuinfo 2>/dev/null && echo pi4 || echo unknown ;;
  esac
}
BOARD="${JELLYBY_BOARD:-}"
if [[ -z "$BOARD" ]]; then
  if [[ "${JELLYBY_OFFLINE:-0}" == "1" ]]; then
    echo "JELLYBY_OFFLINE=1 needs JELLYBY_BOARD=pi4|zero3"; exit 1
  fi
  BOARD="$(detect_board)"
  if [[ "$BOARD" == "unknown" ]]; then
    read -r -p "Unknown board. Set up as Raspberry Pi 4 (pi4) or Radxa ZERO 3 (zero3)? [pi4/zero3/N] " ans
    case "$ans" in pi4|zero3) BOARD="$ans" ;; *) exit 1 ;; esac
  fi
fi
case "$BOARD" in pi4|zero3) ;; *) echo "unsupported JELLYBY_BOARD: $BOARD"; exit 1 ;; esac
echo "==> Board: $BOARD"

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
  x11-xserver-utils openbox \
  openssh-server sudo \
  git make gcc pkg-config linux-libc-dev \
  v4l-utils \
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

if [[ "$BOARD" == "zero3" ]]; then
  # Debian's mpv/ffmpeg have no Rockchip MPP support: without an MPP-enabled
  # build, playback works but decodes in software (too slow for 4K/HEVC).
  if [[ -n "${JELLYBY_MPV_DEBS:-}" ]]; then
    echo "==> Installing MPP-enabled mpv/ffmpeg packages"
    debs=()
    for src in $JELLYBY_MPV_DEBS; do
      if [[ "$src" == http* ]]; then
        f="/tmp/$(basename "$src")"; curl -fL -o "$f" "$src"; debs+=("$f")
      else
        debs+=("$src")
      fi
    done
    apt-get install -y "${debs[@]}"
  else
    echo "WARNING: JELLYBY_MPV_DEBS not set — Debian mpv has no Rockchip MPP hwdec;" >&2
    echo "         video will decode in software until an MPP-enabled mpv is installed." >&2
  fi
fi

echo "==> Creating kiosk user 'media'"
if ! id media >/dev/null 2>&1; then
  # Never take UID 1000: on Raspberry Pi OS the first-boot userconf step
  # renames whatever account owns UID 1000 to the login user (pi), which
  # would hijack the kiosk account.
  MEDIA_UID=1001
  while getent passwd "$MEDIA_UID" >/dev/null || getent group "$MEDIA_UID" >/dev/null; do
    MEDIA_UID=$((MEDIA_UID + 1))
  done
  useradd --create-home --shell /bin/bash --uid "$MEDIA_UID" --user-group media
fi
# mpv needs the GPU (renderD128) and the hardware decoder nodes: rpivid V4L2
# on the Pi, /dev/mpp_service + /dev/rga + /dev/dma_heap on Rockchip (the udev
# rule installed below puts those in the video group).
usermod -aG video,audio media
getent group render >/dev/null && usermod -aG render media

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
# Board-specific bits: mpv hwdec profile (included by mpv.conf as ~~/board.conf)
# and /etc/jellyby/board (read by kiosk.sh and the image checks).
install -m 644 "$FILES/opt/jellyby/mpv/board-$BOARD.conf" /opt/jellyby/mpv/board.conf
echo "$BOARD" > /etc/jellyby/board
chmod 644 /etc/jellyby/board
if [[ "$BOARD" == "zero3" ]]; then
  install -d /etc/udev/rules.d
  install -m 644 "$FILES/etc/udev/rules.d/99-jellyby-rockchip.rules" /etc/udev/rules.d/99-jellyby-rockchip.rules
fi
chmod 755 /opt/jellyby/kiosk.sh /opt/jellyby/server.py /opt/jellyby/play.sh /opt/jellyby/resolve_stream.py /opt/jellyby/netapply.sh

install -m 755 "$FILES/usr/local/bin/readsb-wrapper.sh" /usr/local/bin/readsb-wrapper
install -m 644 "$FILES/etc/default/readsb" /etc/default/readsb
install -m 440 "$FILES/etc/sudoers.d/jellyby" /etc/sudoers.d/jellyby
install -d /etc/X11/xorg.conf.d
install -m 644 "$FILES/etc/X11/xorg.conf.d/99-jellyby.conf" /etc/X11/xorg.conf.d/99-jellyby.conf

for unit in jellyby-web jellyby-x jellyby-kiosk cec-kbd readsb; do
  install -m 644 "$FILES/etc/systemd/system/$unit.service" "/etc/systemd/system/$unit.service"
done

# The launcher (user 'media') saves apps.json and players.json atomically via
# a temp file + rename in /etc/jellyby, so it must own the directory too.
# players.json stays media:media 0600 (credentials).
chown media:media /etc/jellyby /etc/jellyby/apps.json /etc/jellyby/cec-keymap.conf

# RTL-SDR dongles get grabbed by the kernel's DVB-T driver, which blocks readsb.
install -m 644 "$FILES/etc/modprobe.d/jellyby-rtlsdr.conf" /etc/modprobe.d/jellyby-rtlsdr.conf

# Pi 4: default ALSA output (mpv, Chromium) -> HDMI0. Without it audio goes to
# the first ALSA card, often the headphone jack. Not overwritten on re-runs.
if [[ "$BOARD" == "pi4" && ! -f /etc/asound.conf ]]; then
  install -m 644 "$FILES/etc/asound-pi4.conf" /etc/asound.conf
fi

echo "==> Compiling CEC keyboard daemon"
# Kernel CEC API only (/dev/cecN via <linux/cec.h>): no libcec needed.
gcc -O2 -Wall -o /usr/local/bin/cec-kbd "$FILES/opt/jellyby/cec_kbd.c"

echo "==> Building readsb from source"
# Marker: builds from before RTLSDR=yes lacked dongle support -> rebuild once.
READSB_MARKER=/usr/local/share/jellyby/readsb-rtlsdr
if [[ ! -x /usr/local/bin/readsb || ! -f "$READSB_MARKER" ]]; then
  rm -rf /opt/readsb-src
  git clone --depth 1 https://github.com/wiedehopf/readsb.git /opt/readsb-src
  # RTLSDR=yes is required: readsb's Makefile defaults to no SDR support, and
  # "--device-type rtlsdr" would then be rejected at runtime.
  make -C /opt/readsb-src -j"$(nproc)" RTLSDR=yes
  install -m 755 /opt/readsb-src/readsb /usr/local/bin/readsb
  install -d "$(dirname "$READSB_MARKER")" && touch "$READSB_MARKER"
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
if [[ "$BOARD" == "pi4" ]]; then
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
else
  # Armbian (Rockchip): no config.txt. The vendor kernel's DT already enables
  # HDMI, the GPU and the MPP/RGA decoders. If /dev/cec0 is missing on the
  # board, a CEC overlay goes into /boot/armbianEnv.txt ("overlays=...").
  echo "==> Armbian boot config left as shipped (/boot/armbianEnv.txt)"
  # Keep the vendor kernel: an upgrade to a kernel without MPP would silently
  # drop hardware decode.
  if [[ "${JELLYBY_HOLD_KERNEL:-1}" == "1" ]]; then
    mapfile -t kpkgs < <( (dpkg-query -W -f='${db:Status-Abbrev}|${Package}\n' 'linux-image-*' 'linux-dtb-*' 2>/dev/null || true) | awk -F'|' '$1 ~ /^ii/ {print $2}')
    if [[ ${#kpkgs[@]} -gt 0 ]]; then
      apt-mark hold "${kpkgs[@]}"
    fi
  fi
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
  echo "    Jellyfin/Emby tiles play natively in MPV (hardware HEVC decode); Plex/browser tiles open in Chromium."
  echo "  - Media server credentials for MPV: /etc/jellyby/players.json (media:media 0600)."
  echo "  - Network (static/DHCP): Settings in the launcher, or over SSH:"
  echo "    sudo /opt/jellyby/netapply.sh eth0 dhcp   # revert escape hatch"
  echo "  - readsb: edit /etc/default/readsb over SSH, then 'sudo systemctl restart readsb'."
  echo "  - CEC keymap: /etc/jellyby/cec-keymap.conf, then 'sudo systemctl restart cec-kbd'."
fi
