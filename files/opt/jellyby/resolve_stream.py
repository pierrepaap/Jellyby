#!/usr/bin/env python3
"""Resolve a playable stream URL from a Jellyfin/Emby server (stdlib only).

Usage:
  resolve_stream.py <jellyfin|emby> <base-url> <username> <password> [item-id]

Prints the stream URL on stdout and exits 0. Exits 3 when nothing playable
could be resolved (caller should fall back to the browser UI).

Thin wrapper around mediaclient.py: authenticate -> pick item (given id, or
latest Movie/Episode) -> direct-play stream URL (/Videos/{id}/stream?static=true).
"""
import sys

from mediaclient import MediaClient, MediaError


def main():
    if len(sys.argv) < 5:
        print("usage: resolve_stream.py <jellyfin|emby> <base-url> <user> <pass> [item-id]",
              file=sys.stderr)
        return 2
    kind, base, user, pw = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    item = sys.argv[5] if len(sys.argv) > 5 else ""
    try:
        c = MediaClient(kind, base)
        c.authenticate(user, pw)
        if not item:
            items = c.latest(1)
            if not items:
                print("no playable items found", file=sys.stderr)
                return 3
            item = items[0]["id"]
        url, _ = c.resolve_stream(item)
        print(url)
        return 0
    except MediaError as e:
        print(str(e), file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
