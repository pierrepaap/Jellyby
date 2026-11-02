#!/usr/bin/env python3
"""Jellyby launcher server.

Serves the kiosk UI from /opt/jellyby/www and a small API on 127.0.0.1:8901:
  GET  /                 -> launcher page
  GET  /static/<file>    -> static assets
  GET  /api/config       -> current app list (/etc/jellyby/apps.json)
  POST /api/config       -> replace app list (JSON body {"apps": [{name, url}]})
  GET  /api/status       -> systemd state of the Jellyby services
  POST /api/system/reboot
  POST /api/system/poweroff

The API binds to localhost only; the kiosk browser is the only client.
"""
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = 8901
WWW_DIR = "/opt/jellyby/www"
CONFIG_PATH = "/etc/jellyby/apps.json"
MAX_APPS = 24
MAX_BODY = 65536
URL_RE = re.compile(r"^https?://[^\s]+$", re.IGNORECASE)
SERVICES = ("readsb", "cec-kbd", "jellyby-web", "jellyby-x", "jellyby-kiosk")
STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
}


def load_apps():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("apps"), list):
            return data
    except (OSError, ValueError):
        pass
    return {"apps": []}


def validate_apps(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("apps"), list):
        raise ValueError("payload must be {\"apps\": [...]}")
    apps = payload["apps"]
    if len(apps) > MAX_APPS:
        raise ValueError(f"too many apps (max {MAX_APPS})")
    out = []
    for app in apps:
        if not isinstance(app, dict):
            raise ValueError("each app must be an object with name and url")
        name = str(app.get("name", "")).strip()
        url = str(app.get("url", "")).strip()
        if not name or len(name) > 40:
            raise ValueError("app name must be 1-40 characters")
        if not url or len(url) > 2048 or not URL_RE.match(url):
            raise ValueError(f"invalid url for {name!r} (must start with http:// or https://)")
        out.append({"name": name, "url": url})
    return {"apps": out}


def save_apps(apps):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(apps, f, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)


def service_status():
    status = {}
    for svc in SERVICES:
        try:
            r = subprocess.run(
                ["systemctl", "is-active", svc],
                capture_output=True, text=True, timeout=5,
            )
            status[svc] = (r.stdout or "unknown").strip()
        except Exception:
            status[svc] = "unknown"
    return status


class Handler(BaseHTTPRequestHandler):
    server_version = "Jellyby/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj).encode("utf-8"))

    def _serve_file(self, name):
        if "/" in name or ".." in name:
            return self._json({"error": "forbidden"}, 403)
        full = os.path.join(WWW_DIR, name)
        if not os.path.isfile(full):
            return self._json({"error": "not found"}, 404)
        ctype = STATIC_TYPES.get(os.path.splitext(name)[1].lower(), "application/octet-stream")
        with open(full, "rb") as f:
            self._send(200, f.read(), ctype)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            return self._serve_file("index.html")
        if path.startswith("/static/"):
            return self._serve_file(path[len("/static/"):])
        if path == "/api/config":
            return self._json(load_apps())
        if path == "/api/status":
            return self._json({"services": service_status()})
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return self._json({"error": "invalid or too large body"}, 400)
        raw = self.rfile.read(length)
        if path == "/api/config":
            try:
                payload = json.loads(raw.decode("utf-8"))
                apps = validate_apps(payload)
            except (ValueError, UnicodeDecodeError) as e:
                return self._json({"error": str(e)}, 400)
            try:
                save_apps(apps)
            except OSError as e:
                return self._json({"error": f"cannot save config: {e}"}, 500)
            return self._json({"ok": True, "apps": apps["apps"]})
        if path in ("/api/system/reboot", "/api/system/poweroff"):
            action = "reboot" if path.endswith("reboot") else "poweroff"
            subprocess.Popen(["/usr/bin/sudo", "/usr/bin/systemctl", action])
            return self._json({"ok": True, "action": action})
        return self._json({"error": "not found"}, 404)


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    sys.stderr.write(f"Jellyby launcher listening on http://{HOST}:{PORT}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
