#!/bin/bash
# Launch the kiosk browser against the local Jellyby launcher.
# Sandbox stays ENABLED (the launcher loads remote web UIs). On Pi OS Bookworm
# unprivileged user namespaces are on by default (kernel.unprivileged_userns_clone=1);
# if Chromium ever complains, set that sysctl — do NOT re-add --no-sandbox.
set -euo pipefail

BIN="$(command -v chromium || command -v chromium-browser)"

# wait for X to be ready instead of relying on Restart=always
echo "waiting for X display :0 ..."
for _ in $(seq 1 30); do
  if [ -e /tmp/.X11-unix/X0 ] && xset -display :0 q >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Low-RAM boards (Radxa ZERO 3, 1-2 GB) share memory with mpv: cap renderers.
EXTRA_FLAGS=()
if [ "$(cat /etc/jellyby/board 2>/dev/null || true)" = "zero3" ]; then
  EXTRA_FLAGS=(--renderer-process-limit=2 --disable-features=BackForwardCache)
fi

exec "$BIN" \
  "${EXTRA_FLAGS[@]}" \
  --kiosk \
  --disable-breakpad \
  --no-first-run \
  --no-default-browser-check \
  --disable-session-crashed-bubble \
  --noerrdialogs \
  --disable-infobars \
  --autoplay-policy=no-user-gesture-required \
  --user-data-dir=/home/media/.config/jellyby \
  "http://127.0.0.1:8901/"
