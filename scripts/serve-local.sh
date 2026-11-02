#!/bin/bash
# Run the Jellyby launcher on any machine (no Raspberry Pi needed) to test the
# UI with a desktop browser: open http://127.0.0.1:8901 and use the arrow keys,
# Enter, Backspace and F10 — exactly what the CEC remote sends.
#
# The config is seeded from the repo default into a temp file, so testing does
# not modify files/etc/jellyby/apps.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export JELLYBY_WWW_DIR="$REPO_DIR/files/opt/jellyby/www"
export JELLYBY_PORT="${JELLYBY_PORT:-8901}"

TMPCONF="$(mktemp /tmp/jellyby-apps.XXXXXX.json)"
trap 'rm -f "$TMPCONF"' EXIT
cp "$REPO_DIR/files/etc/jellyby/apps.json" "$TMPCONF"
export JELLYBY_CONFIG="$TMPCONF"

echo "Jellyby launcher: http://127.0.0.1:${JELLYBY_PORT}  (Ctrl+C to stop)"
exec python3 "$REPO_DIR/files/opt/jellyby/server.py"
