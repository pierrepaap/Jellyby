#!/usr/bin/env python3
"""End-to-end tests for the launcher API (files/opt/jellyby/server.py).

Runs the real server against a fake Jellyfin server, with play.sh replaced by
a stub that records how it was called. No Pi, mpv or network needed:

    python3 -m unittest discover -s tests -v
"""
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN, UID = "tok123", "u1"
MOVIE = {"Id": "m1", "Name": "Film", "Type": "Movie", "IsFolder": False,
         "ImageTags": {"Primary": "x"}, "UserData": {"PlaybackPositionTicks": 600_000_000}}
LIBRARY = {"Id": "lib1", "Name": "Movies", "Type": "CollectionFolder", "IsFolder": True}


class FakeJellyfin(BaseHTTPRequestHandler):
    auth_calls = 0

    def log_message(self, *a):
        pass

    def _out(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authed(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        return self.headers.get("X-Emby-Token") == TOKEN or q.get("api_key") == [TOKEN]

    def do_POST(self):
        if self.path == "/Users/AuthenticateByName":
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            FakeJellyfin.auth_calls += 1
            if body == {"Username": "alice", "Pw": "secret"}:
                return self._out(200, {"AccessToken": TOKEN, "User": {"Id": UID}})
            return self._out(401, {})
        self._out(404, {})

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._authed():
            return self._out(401, {})
        routes = {
            f"/Users/{UID}/Views": {"Items": [LIBRARY]},
            f"/Users/{UID}/Items": {"Items": [MOVIE]},
            f"/Users/{UID}/Items/Resume": {"Items": [MOVIE]},
            f"/Users/{UID}/Items/m1": MOVIE,
        }
        if path in routes:
            return self._out(200, routes[path])
        if path == "/Videos/m1/stream":
            return self._out(200, b"\x00" * 64, "video/x-matroska")
        if path == "/Items/m1/Images/Primary":
            return self._out(200, b"\xff\xd8\xff fake jpeg", "image/jpeg")
        self._out(404, {})


def serve(handler):
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


class LauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jf = serve(FakeJellyfin)
        jf_url = f"http://127.0.0.1:{cls.jf.server_address[1]}"
        cls.tmp = tempfile.mkdtemp(prefix="jellyby-test-")
        etc = os.path.join(cls.tmp, "etc")  # stands in for /etc/jellyby (media-owned)
        os.mkdir(etc)
        cls.apps = os.path.join(etc, "apps.json")
        cls.players = os.path.join(etc, "players.json")
        with open(cls.apps, "w") as f:
            json.dump({"apps": [
                {"name": "Jellyfin", "type": "mpv", "server": "jellyfin", "url": jf_url},
                {"name": "Plex", "type": "browser", "server": "plex", "url": "http://plex.local:32400/web"},
                {"name": "Broken", "type": "mpv", "server": "jellyfin", "url": "http://127.0.0.1:9"},
            ]}, f)
        with open(cls.players, "w") as f:
            json.dump({"players": {"Jellyfin": {"username": "alice", "password": "secret"},
                                   "Broken": {"username": "x", "password": "y"}}}, f)
        os.chmod(cls.players, 0o600)
        cls.record = os.path.join(cls.tmp, "play-record.json")
        cls.play_sh = os.path.join(cls.tmp, "play.sh")
        with open(cls.play_sh, "w") as f:
            f.write("#!/usr/bin/env python3\nimport json, sys\n"
                    "args = sys.argv[1:]\n"
                    "url = open(args[args.index('--url-file') + 1]).read().strip()\n"
                    f"json.dump({{'args': args, 'url': url}}, open({cls.record!r}, 'w'))\n")
        os.chmod(cls.play_sh, 0o755)

        os.environ.update(JELLYBY_CONFIG=cls.apps, JELLYBY_PLAYERS=cls.players,
                          JELLYBY_PLAY_SH=cls.play_sh,
                          JELLYBY_WWW_DIR=os.path.join(REPO, "files/opt/jellyby/www"))
        sys.path.insert(0, os.path.join(REPO, "files/opt/jellyby"))
        import server  # noqa: E402  (reads the env above at import)
        cls.server_mod = server
        cls.httpd = serve(server.Handler)
        cls.base = f"http://127.0.0.1:{cls.httpd.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.jf.shutdown()

    def call(self, path, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(self.base + path, data=data,
                                     headers={"Content-Type": "application/json"} if data else {})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read()
                return r.status, (json.loads(body) if r.headers.get_content_type() == "application/json" else body)
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def q(self, **kw):
        return urllib.parse.urlencode(kw)

    # --- static + config ---------------------------------------------------

    def test_ui_served(self):
        for path in ("/", "/static/app.js", "/static/style.css"):
            code, body = self.call(path)
            self.assertEqual(code, 200, path)
            self.assertTrue(body)

    def test_static_path_traversal_blocked(self):
        code, _ = self.call("/static/..%2f..%2fserver.py")
        self.assertIn(code, (403, 404))

    def test_config_roundtrip_and_validation(self):
        code, cfg = self.call("/api/config")
        self.assertEqual(code, 200)
        names = [a["name"] for a in cfg["apps"]]
        self.assertEqual(names[:2], ["Jellyfin", "Plex"])
        new = cfg["apps"] + [{"name": "Docs", "type": "browser", "server": "url", "url": "https://example.org"}]
        code, res = self.call("/api/config", {"apps": new})
        self.assertEqual(code, 200, res)
        with open(self.apps) as f:
            self.assertIn("Docs", [a["name"] for a in json.load(f)["apps"]])
        code, res = self.call("/api/config", {"apps": cfg["apps"]})  # restore
        self.assertEqual(code, 200, res)
        for bad in ({"apps": [{"name": "", "url": "http://x"}]},
                    {"apps": [{"name": "X", "url": "ftp://x"}]},
                    {"apps": [{"name": "X", "url": "http://x", "type": "mpv", "server": "plex"}]}):
            code, _ = self.call("/api/config", bad)
            self.assertEqual(code, 400, bad)

    def test_browser_launch(self):
        code, res = self.call("/api/launch", {"name": "Plex"})
        self.assertEqual((code, res["mode"]), (200, "browser"))

    # --- media browse + play ------------------------------------------------

    def test_browse_and_play(self):
        app = "Jellyfin"
        code, libs = self.call("/api/media/libraries?" + self.q(app=app))
        self.assertEqual(code, 200, libs)
        self.assertEqual(libs["items"][0]["name"], "Movies")
        code, items = self.call("/api/media/items?" + self.q(app=app, parent="lib1"))
        self.assertEqual((code, items["items"][0]["id"]), (200, "m1"))
        code, res = self.call("/api/media/resume?" + self.q(app=app))
        self.assertEqual(res["items"][0]["resume"], 600_000_000)
        code, img = self.call("/api/media/poster?" + self.q(app=app, item="m1"))
        self.assertEqual(code, 200)
        self.assertTrue(img.startswith(b"\xff\xd8"))

        code, res = self.call("/api/media/play", {"app": app, "item": "m1", "start": 600_000_000})
        self.assertEqual((code, res.get("mode")), (200, "mpv"), res)
        with open(self.record) as f:
            rec = json.load(f)
        self.assertEqual(rec["args"][0], app)
        self.assertIn("--start", rec["args"])
        self.assertEqual(rec["args"][rec["args"].index("--start") + 1], "60")
        self.assertIn("/Videos/m1/stream?static=true&api_key=" + TOKEN, rec["url"])
        self.assertNotIn(TOKEN, " ".join(rec["args"]), "api_key must not be in argv")

        # token persisted (so the password isn't needed per request), still 0600
        with open(self.players) as f:
            cred = json.load(f)["players"][app]
        self.assertEqual((cred["token"], cred["user_id"]), (TOKEN, UID))
        self.assertEqual(stat.S_IMODE(os.stat(self.players).st_mode), 0o600)
        before = FakeJellyfin.auth_calls
        self.call("/api/media/libraries?" + self.q(app=app))
        self.assertEqual(FakeJellyfin.auth_calls, before, "cached token should be reused")

    def test_unreachable_server_reports_error(self):
        code, res = self.call("/api/media/libraries?" + self.q(app="Broken"))
        self.assertEqual(code, 502)
        self.assertIn("error", res)

    def test_media_input_validation(self):
        self.assertEqual(self.call("/api/media/libraries?" + self.q(app="Nope"))[0], 404)
        self.assertEqual(self.call("/api/media/libraries?" + self.q(app="Plex"))[0], 400)
        self.assertEqual(self.call("/api/media/poster?" + self.q(app="Jellyfin", item="../x"))[0], 400)
        self.assertEqual(self.call("/api/media/play", {"app": "Jellyfin", "item": "a b"})[0], 400)

    # --- network validation (never reaches nmcli here) ----------------------

    def test_network_validation(self):
        v = self.server_mod.validate_network
        iface = sorted(os.listdir("/sys/class/net"))[0]
        self.assertEqual(v({"interface": iface, "mode": "dhcp", "confirm": True}), [iface, "dhcp"])
        ok = v({"interface": iface, "mode": "static", "confirm": True,
                "address": "192.168.1.50/24", "gateway": "192.168.1.1", "dns": ["1.1.1.1"]})
        self.assertEqual(ok, [iface, "static", "192.168.1.50/24", "192.168.1.1", "1.1.1.1"])
        for bad in ({"interface": iface, "mode": "dhcp"},  # no confirm
                    {"interface": "eth0; rm -rf /", "mode": "dhcp", "confirm": True},
                    {"interface": iface, "mode": "static", "confirm": True,
                     "address": "192.168.1.50/24", "gateway": "10.0.0.1", "dns": []},
                    {"interface": iface, "mode": "static", "confirm": True,
                     "address": "192.168.1.0/24", "gateway": "192.168.1.1", "dns": []},
                    {"interface": iface, "mode": "static", "confirm": True,
                     "address": "192.168.1.50", "gateway": "192.168.1.1", "dns": []}):
            with self.assertRaises(ValueError):
                v(bad)


if __name__ == "__main__":
    unittest.main()
