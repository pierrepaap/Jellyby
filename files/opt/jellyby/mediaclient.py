#!/usr/bin/env python3
"""Small stdlib Jellyfin/Emby client for the Jellyby launcher.

Imported by server.py; also usable standalone (resolve_stream.py wraps it).
Talks to the configured server base URL only, using urllib.request.

Auth model: username+password live in /etc/jellyby/players.json (0600,
owned by 'media'). On first use we authenticate once and keep the returned
AccessToken + UserId; the caller persists them back so the password is
only needed when the token goes stale.

Playback progress is NOT reported back to the server in v1 (TODO:
POST /Sessions/Playing{,/Progress,/Stopped} so "resume" syncs everywhere).
"""
import json
import urllib.error
import urllib.request

TIMEOUT = 10
CLIENT_HDR = ('MediaBrowser Client="Jellyby", Device="jellyby-pi", '
              'DeviceId="jellyby-pi-439574", Version="1.0"')
PLAYABLE_TYPES = ("Movie", "Episode", "Video", "MusicVideo", "Audio")


class MediaError(Exception):
    """Any failure talking to the media server (auth, HTTP, parse)."""


def _norm_item(it):
    """Normalize a Jellyfin/Emby item to the small JSON the UI needs."""
    tags = it.get("ImageTags") or {}
    ud = it.get("UserData") or {}
    return {
        "id": str(it.get("Id", "")),
        "name": str(it.get("Name", "")),
        "type": str(it.get("Type", "")),
        "isFolder": bool(it.get("IsFolder")),
        "series": str(it.get("SeriesName", "") or ""),
        "series_id": str(it.get("SeriesId", "") or ""),
        "poster": bool(tags.get("Primary")),
        "resume": int(ud.get("PlaybackPositionTicks", 0) or 0),
    }


class MediaClient:
    """Jellyfin/Emby API client for one server."""

    def __init__(self, kind, base):
        if kind not in ("jellyfin", "emby"):
            raise MediaError(f"unsupported server kind {kind!r}")
        self.kind = kind
        self.base = base.rstrip("/")
        # Emby is often served under /emby; probe both prefixes once.
        self._prefixes = ["/emby", ""] if kind == "emby" else [""]
        self._prefix = None
        self.token = ""
        self.user_id = ""

    def set_auth(self, token, user_id):
        self.token = token
        self.user_id = user_id

    # ---- low level ------------------------------------------------------

    def _req(self, path, method="GET", payload=None, token=None, raw=False):
        data = None
        headers = {"X-Emby-Authorization": CLIENT_HDR, "Accept": "application/json"}
        if token is None:
            token = self.token
        if token:
            headers["X-Emby-Token"] = token
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        prefixes = [self._prefix] if self._prefix else self._prefixes
        last_err = None
        for p in prefixes:
            try:
                req = urllib.request.Request(self.base + p + path, data=data,
                                              headers=headers, method=method)
                with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                    body = r.read()
                if self._prefix is None:
                    self._prefix = p
                if raw:
                    return body
                return json.loads(body.decode("utf-8")) if body else {}
            except urllib.error.HTTPError as e:
                last_err = e
                # 401/403 = auth problem: no point trying other prefixes
                if e.code in (401, 403):
                    raise MediaError(f"HTTP {e.code} from {self.kind} server")
            except Exception as e:  # noqa: BLE001 - report and try next prefix
                last_err = e
        raise MediaError(f"{self.kind} request failed: {last_err}")

    def _get_items(self, path):
        res = self._req(path)
        items = res.get("Items") or []
        return [_norm_item(i) for i in items if isinstance(i, dict) and i.get("Id")]

    # ---- auth -----------------------------------------------------------

    def authenticate(self, username, password):
        auth = self._req("/Users/AuthenticateByName", method="POST",
                         payload={"Username": username, "Pw": password},
                         token=None)
        token = str(auth.get("AccessToken", ""))
        uid = str((auth.get("User") or {}).get("Id", ""))
        if not token or not uid:
            raise MediaError("server returned no access token")
        self.set_auth(token, uid)
        return token, uid

    def check_auth(self):
        """Raise if the current token does not work anymore."""
        if not self.token or not self.user_id:
            raise MediaError("not authenticated")
        self._req(f"/Users/{self.user_id}/Views")

    # ---- browse ---------------------------------------------------------

    def libraries(self):
        res = self._req(f"/Users/{self.user_id}/Views")
        items = res.get("Items") or []
        return [_norm_item(i) for i in items if isinstance(i, dict) and i.get("Id")]

    def children(self, parent_id, parent_type="", series_id=""):
        """Children of a view/folder, or Seasons/Episodes for shows."""
        uid = self.user_id
        if parent_type == "Season" and series_id:
            return self._get_items(
                f"/Shows/{series_id}/Episodes?SeasonId={parent_id}"
                f"&UserId={uid}&Fields=SeriesId")
        if parent_type == "Series":
            return self._get_items(f"/Shows/{parent_id}/Seasons?UserId={uid}")
        return self._get_items(
            f"/Users/{uid}/Items?ParentId={parent_id}"
            f"&SortBy=SortName&SortOrder=Ascending&Fields=SeriesId")

    def latest(self, limit=1):
        """Most recently added playable items (used when no item is pinned)."""
        return self._get_items(
            f"/Items?UserId={self.user_id}&Recursive=true"
            f"&IncludeItemTypes=Movie,Episode&SortBy=DateCreated"
            f"&SortOrder=Descending&Limit={limit}")

    def resume(self):
        return self._get_items(
            f"/Users/{self.user_id}/Items/Resume?Limit=20&Fields=SeriesId")

    def item(self, item_id):
        res = self._req(f"/Users/{self.user_id}/Items/{item_id}")
        return _norm_item(res)

    # ---- play -----------------------------------------------------------

    def resolve_stream(self, item_id):
        """Direct-play URL for mpv: the original file, no server transcode.

        Returns (url, start_ticks). The api_key rides in the query string so
        mpv's plain HTTP GET is authorized; the caller keeps it out of argv.
        """
        start = 0
        try:
            it = self.item(item_id)
            start = int(((it or {}).get("resume") or 0))
        except MediaError:
            pass
        url = (f"{self.base}{self._prefix or ''}/Videos/{item_id}"
               f"/stream?static=true&api_key={self.token}")
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                r.read(1)
        except Exception as e:  # noqa: BLE001
            raise MediaError(f"stream not playable: {e}")
        return url, start

    def poster(self, item_id, maxwidth=400):
        """Primary image bytes for an item (proxied; token stays server-side)."""
        return self._req(
            f"/Items/{item_id}/Images/Primary"
            f"?MaxWidth={maxwidth}&quality=90", raw=True)
