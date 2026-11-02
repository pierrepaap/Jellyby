#!/bin/bash
# Launch the kiosk browser against the local Jellyby launcher.
set -euo pipefail

BIN="$(command -v chromium || command -v chromium-browser)"

exec "$BIN" \
  --kiosk \
  --no-sandbox \
  --disable-breakpad \
  --no-first-run \
  --no-default-browser-check \
  --disable-session-crashed-bubble \
  --noerrdialogs \
  --disable-infobars \
  --autoplay-policy=no-user-gesture-required \
  --user-data-dir=/home/media/.config/jellyby \
  "http://127.0.0.1:8901/"
