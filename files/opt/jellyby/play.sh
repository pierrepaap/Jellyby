#!/bin/bash
# play.sh <app-name> [--url-file <file>] [--start <seconds>]
#
# Resolve the stream for a Jellyfin/Emby app and play it with the SYSTEM mpv
# in fullscreen on DISPLAY :0 (Pi 4 rpivid V4L2 hwdec), returning to the
# launcher when mpv exits (remote exit key = Ctrl+W -> 'quit' in input.conf).
#
# --url-file: play the (already resolved) URL contained in <file> instead of
#   resolving here. The URL carries the api_key in its query string, so it is
#   passed to mpv via --playlist=<file> — never on the command line, where
#   other users could see it in /proc/<pid>/cmdline. The file is deleted.
# --start: resume position in seconds for mpv --start=.
#
# Exit codes: 0 = mpv launched, 3 = resolution failed (caller falls back to
# the browser URL), 2 = usage/config error.
#
# Credentials/item come from /etc/jellyby/players.json (media:media 0600),
# keyed by app name; the app entry in /etc/jellyby/apps.json carries
# {type: "mpv", server: "jellyfin"|"emby", url: ...}.
set -euo pipefail

APPS_JSON="${JELLYBY_CONFIG:-/etc/jellyby/apps.json}"
PLAYERS_JSON="${JELLYBY_PLAYERS:-/etc/jellyby/players.json}"
MPV_CONFIG_DIR="${JELLYBY_MPV_CONFIG:-/opt/jellyby/mpv}"
RESOLVE="${JELLYBY_RESOLVE:-/opt/jellyby/resolve_stream.py}"

APP="${1:?usage: play.sh <app-name> [--url-file <file>] [--start <seconds>]}"
shift || true
URL_FILE=""
START=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --url-file) URL_FILE="${2:?--url-file needs a value}"; shift 2 ;;
    --start)    START="${2:?--start needs a value}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

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

if [ -n "$URL_FILE" ]; then
  [ -r "$URL_FILE" ] || { echo "url file not readable: $URL_FILE" >&2; exit 2; }
else
  if [ "$SERVER" != "jellyfin" ] && [ "$SERVER" != "emby" ]; then
    echo "app '$APP' is not a jellyfin/emby mpv app" >&2
    exit 2
  fi
  URL_FILE="$(mktemp /tmp/jellyby-url.XXXXXX)" || exit 2
  chmod 600 "$URL_FILE"
  if ! python3 "$RESOLVE" "$SERVER" "$BASE" "$USER" "$PASS" "$ITEM" > "$URL_FILE" 2>/dev/null; then
    rm -f "$URL_FILE"
    echo "could not resolve a stream from $BASE — browser fallback" >&2
    exit 3
  fi
fi

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

START_ARG=()
if [ -n "$START" ]; then
  START_ARG=(--start="+${START}")
fi

# Launch mpv detached so this script returns immediately; the launcher UI stays
# underneath and is visible again when mpv exits. The stream URL (with its
# api_key) is handed over via the playlist file, not via argv.
nohup mpv --config-dir="$MPV_CONFIG_DIR" --playlist="$URL_FILE" \
  "${START_ARG[@]}" >/dev/null 2>&1 &
echo "mpv launched (pid $!) for $APP"
# mpv reads the playlist at startup; give it a moment before wiping the key
(sleep 5; rm -f "$URL_FILE") >/dev/null 2>&1 &
exit 0
