#!/usr/bin/env python3
"""Resolve a playable stream URL from a Jellyfin/Emby server (stdlib only).

Usage:
  resolve_stream.py <jellyfin|emby> <base-url> <username> <password> [item-id]

Prints the stream URL on stdout and exits 0. Exits 3 when nothing playable
could be resolved (caller should fall back to the browser UI).

Flow: authenticate (POST /Users/AuthenticateByName) -> pick item (given id, or
latest Movie/Episode) -> direct-play stream URL (/Videos/{id}/stream?static=true).
"""
import json
import sys
import urllib.error
import urllib.request

TIMEOUT = 10
CLIENT_HDR = ('MediaBrowser Client="Jellyby", Device="jellyby-pi", '
              'DeviceId="jellyby-pi-439574", Version="1.0"')


def _req(url, method="GET", payload=None, token=None):
    data = None
    headers = {"X-Emby-Authorization": CLIENT_HDR, "Accept": "application/json"}
    if token:
        headers["X-Emby-Token"] = token
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        body = r.read()
    return json.loads(body.decode("utf-8")) if body else {}


def main():
    if len(sys.argv) < 5:
        print("usage: resolve_stream.py <jellyfin|emby> <base-url> <user> <pass> [item-id]",
              file=sys.stderr)
        return 2
    kind, base, user, pw = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3], sys.argv[4]
    item = sys.argv[5] if len(sys.argv) > 5 else ""
    if kind not in ("jellyfin", "emby"):
        print(f"unsupported server kind {kind!r}", file=sys.stderr)
        return 2
    try:
        auth = _req(f"{base}/Users/AuthenticateByName", method="POST",
                    payload={"Username": user, "Pw": pw})
        token = auth.get("AccessToken", "")
        uid = (auth.get("User") or {}).get("Id", "")
        if not token:
            print("no access token", file=sys.stderr)
            return 3
        if not item:
            q = (f"{base}/Items?UserId={uid}&Recursive=true"
                 f"&IncludeItemTypes=Movie,Episode&SortBy=DateCreated"
                 f"&SortOrder=Descending&Limit=1&api_key={token}")
            res = _req(q)
            items = res.get("Items") or []
            if not items:
                print("no playable items found", file=sys.stderr)
                return 3
            item = items[0]["Id"]
        url = f"{base}/Videos/{item}/stream?static=true&api_key={token}"
        # verify the URL actually answers (HEAD via GET with 1-byte read)
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            r.read(1)
        print(url)
        return 0
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} from {kind} server", file=sys.stderr)
        return 3
    except Exception as e:
        print(f"resolve failed: {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
