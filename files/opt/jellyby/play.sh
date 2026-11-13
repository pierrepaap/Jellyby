#!/bin/bash
# play.sh <app-name> — resolve the stream for a Jellyfin/Emby app and play it
# with the SYSTEM mpv in fullscreen on DISPLAY :0 (Pi 4 rpivid V4L2 hwdec).
#
# Exit codes: 0 = mpv launched (or URL resolved), 3 = resolution failed
# (caller falls back to the browser URL), 2 = usage/config error.
#
# Credentials/item come from /etc/jellyby/players.json (root:media 0640),
# keyed by app name; the app entry in /etc/jellyby/apps.json carries
# {type: "mpv", server: "jellyfin"|"emby", url: ...}.
set -euo pipefail

APPS_JSON="${JELLYBY_CONFIG:-/etc/jellyby/apps.json}"
PLAYERS_JSON="${JELLYBY_PLAYERS:-/etc/jellyby/players.json}"
MPV_CONFIG_DIR="${JELLYBY_MPV_CONFIG:-/opt/jellyby/mpv}"
RESOLVE="${JELLYBY_RESOLVE:-/opt/jellyby/resolve_stream.py}"

APP="${1:?usage: play.sh <app-name>}"

# prints: server base-url username password item   (item last: it may be empty)
read -r SERVER BASE USER PASS ITEM < <(python3 - "$APPS_JSON" "$PLAYERS_JSON" "$APP" <<'PY'
import json, sys
apps = json.load(open(sys.argv[1]))["apps"]
app = next((a for a in apps if a.get("name") == sys.argv[3]), None)
if app is None:
    sys.exit(2)
players = {}
try:
    players = json.load(open(sys.argv[2]))["players"]
except Exception:
    pass
cred = players.get(app["name"], {})
print(app.get("server", "url"), app.get("url", ""),
      cred.get("username", ""), cred.get("password", ""),
      app.get("item") or cred.get("item", ""))
PY
) || exit 2

if [ "$SERVER" != "jellyfin" ] && [ "$SERVER" != "emby" ]; then
  echo "app '$APP' is not a jellyfin/emby mpv app" >&2
  exit 2
fi

URL="$(python3 "$RESOLVE" "$SERVER" "$BASE" "$USER" "$PASS" "$ITEM" 2>/dev/null)" || {
  echo "could not resolve a stream from $BASE — browser fallback" >&2
  exit 3
}

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Launch mpv detached so this script returns immediately; the launcher UI stays
# underneath and is visible again when mpv exits (remote exit key = Ctrl+W,
# mapped to 'quit' in mpv/input.conf).
nohup mpv --config-dir="$MPV_CONFIG_DIR" "$URL" >/dev/null 2>&1 &
echo "mpv launched (pid $!) for $APP: $URL"
exit 0
