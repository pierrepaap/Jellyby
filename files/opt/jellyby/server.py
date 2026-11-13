#!/usr/bin/env python3
"""Jellyby launcher server.

Serves the kiosk UI from /opt/jellyby/www and a small API on 127.0.0.1:8901:
  GET  /                 -> launcher page
  GET  /static/<file>    -> static assets
  GET  /api/config       -> current app list (/etc/jellyby/apps.json)
  POST /api/config       -> replace app list (typed entries, see validate_apps)
  GET  /api/status       -> systemd state of the Jellyby services
  POST /api/launch       -> {"name": ...} launch an app (mpv tile -> native MPV on
                            DISPLAY :0 via play.sh; browser tile or mpv fallback
                            -> caller opens the browser tab)
  GET  /api/network      -> current NetworkManager state
  POST /api/network      -> apply dhcp|static config via netapply.sh (sudo nmcli)
  POST /api/system/reboot
  POST /api/system/poweroff

The API binds to localhost only; the kiosk browser is the only client.
Python 3 standard library only.
"""
import ipaddress
import json
import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("JELLYBY_HOST", "127.0.0.1")
PORT = int(os.environ.get("JELLYBY_PORT", "8901"))
WWW_DIR = os.environ.get("JELLYBY_WWW_DIR", "/opt/jellyby/www")
CONFIG_PATH = os.environ.get("JELLYBY_CONFIG", "/etc/jellyby/apps.json")
PLAYERS_PATH = os.environ.get("JELLYBY_PLAYERS", "/etc/jellyby/players.json")
PLAY_SH = os.environ.get("JELLYBY_PLAY_SH", "/opt/jellyby/play.sh")
NETAPPLY_SH = "/opt/jellyby/netapply.sh"
MAX_APPS = 24
MAX_BODY = 65536
URL_RE = re.compile(r"^https?://[^\s]+$", re.IGNORECASE)
IFACE_RE = re.compile(r"^[A-Za-z0-9._-]{1,15}$")
APP_TYPES = ("mpv", "browser")
APP_SERVERS = ("jellyfin", "emby", "plex", "url")
MPV_SERVERS = ("jellyfin", "emby")  # only these have a stdlib-resolvable stream API
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
    """Load apps.json, normalising legacy {name,url} entries to typed ones."""
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("apps"), list):
            return {"apps": [normalize_app(a) for a in data["apps"]]}
    except (OSError, ValueError):
        pass
    return {"apps": []}


def normalize_app(app):
    if not isinstance(app, dict):
        return {"name": "", "type": "browser", "server": "url", "url": "", "item": ""}
    return {
        "name": str(app.get("name", "")),
        "type": app.get("type", "browser") if app.get("type", "browser") in APP_TYPES else "browser",
        "server": app.get("server", "url") if app.get("server", "url") in APP_SERVERS else "url",
        "url": str(app.get("url", "")),
        "item": str(app.get("item", ""))[:64],
    }


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
        atype = app.get("type", "browser")
        server = app.get("server", "url")
        item = str(app.get("item", "")).strip()[:64]
        if not name or len(name) > 40:
            raise ValueError("app name must be 1-40 characters")
        if not url or len(url) > 2048 or not URL_RE.match(url):
            raise ValueError(f"invalid url for {name!r} (must start with http:// or https://)")
        if atype not in APP_TYPES:
            raise ValueError(f"invalid type for {name!r} (mpv or browser)")
        if server not in APP_SERVERS:
            raise ValueError(f"invalid server for {name!r} (jellyfin, emby, plex or url)")
        if atype == "mpv" and server not in MPV_SERVERS:
            raise ValueError(f"mpv playback for {name!r} only supports jellyfin/emby servers")
        entry = {"name": name, "type": atype, "server": server, "url": url}
        if item:
            entry["item"] = item
        out.append(entry)
    return {"apps": out}


def save_apps(apps):
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(apps, f, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)


def load_players():
    try:
        with open(PLAYERS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("players"), dict):
            return data["players"]
    except (OSError, ValueError):
        pass
    return {}


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


def network_state():
    """Read-only NetworkManager state (nmcli needs no root for this)."""
    out = {"interfaces": []}
    try:
        r = subprocess.run(
            ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"],
            capture_output=True, text=True, timeout=10,
        )
        for line in r.stdout.splitlines():
            parts = line.split(":")
            if len(parts) < 4 or parts[0] in ("", "lo"):
                continue
            dev, dtype, dstate, con = parts[0], parts[1], parts[2], parts[3] or ""
            iface = {"name": dev, "type": dtype, "state": dstate, "connection": con,
                     "method": "", "address": "", "gateway": "", "dns": []}
            try:
                d = subprocess.run(
                    ["nmcli", "-t", "-f", "IP4.ADDRESS,IP4.GATEWAY,IP4.DNS", "device", "show", dev],
                    capture_output=True, text=True, timeout=10,
                )
                for l in d.stdout.splitlines():
                    k, _, v = l.partition(":")
                    if k == "IP4.ADDRESS" and v:
                        iface["address"] = v.split(",")[0]
                    elif k == "IP4.GATEWAY" and v:
                        iface["gateway"] = v
                    elif k == "IP4.DNS" and v:
                        iface["dns"] = [x for x in v.split(",") if x]
            except Exception:
                pass
            if con:
                try:
                    m = subprocess.run(
                        ["nmcli", "-t", "-f", "ipv4.method", "connection", "show", con],
                        capture_output=True, text=True, timeout=10,
                    )
                    iface["method"] = m.stdout.strip().split(":", 1)[-1]
                except Exception:
                    pass
            out["interfaces"].append(iface)
    except Exception as e:
        out["error"] = str(e)
    return out


def validate_network(payload):
    if not isinstance(payload, dict):
        raise ValueError("payload must be an object")
    iface = str(payload.get("interface", "")).strip()
    mode = str(payload.get("mode", "")).strip()
    if not IFACE_RE.match(iface):
        raise ValueError("invalid interface name")
    if not os.path.isdir(f"/sys/class/net/{iface}"):
        raise ValueError(f"interface {iface!r} does not exist")
    if mode not in ("dhcp", "static"):
        raise ValueError("mode must be dhcp or static")
    if payload.get("confirm") is not True:
        raise ValueError("set confirm=true to apply (a wrong static config can drop SSH)")
    args = [iface, mode]
    if mode == "static":
        addr = str(payload.get("address", "")).strip()
        gw = str(payload.get("gateway", "")).strip()
        dns = payload.get("dns", [])
        try:
            net = ipaddress.ip_network(addr, strict=False)
        except ValueError:
            raise ValueError("address must be valid IPv4/CIDR, e.g. 192.168.1.50/24")
        if net.version != 4 or net.prefixlen < 8 or net.prefixlen > 32:
            raise ValueError("address must be IPv4 with prefix /8../32")
        try:
            g = ipaddress.ip_address(gw)
        except ValueError:
            raise ValueError("gateway must be a valid IPv4 address")
        if g.version != 4 or g not in net:
            raise ValueError("gateway must be inside the address subnet")
        if not isinstance(dns, list) or len(dns) > 3:
            raise ValueError("dns must be a list of up to 3 IPv4 addresses")
        dnsout = []
        for d in dns:
            try:
                di = ipaddress.ip_address(str(d).strip())
            except ValueError:
                raise ValueError(f"invalid dns server {d!r}")
            if di.version != 4:
                raise ValueError("dns servers must be IPv4")
            dnsout.append(str(di))
        args += [f"{net.with_prefixlen}", str(g), ",".join(dnsout)]
    return args


class Handler(BaseHTTPRequestHandler):
    server_version = "Jellyby/1.1"
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

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return None
        return self.rfile.read(length)

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
        if path == "/api/network":
            return self._json(network_state())
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        raw = self._read_body()
        if raw is None:
            return self._json({"error": "invalid or too large body"}, 400)
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
        if path == "/api/launch":
            try:
                payload = json.loads(raw.decode("utf-8"))
                name = str(payload.get("name", "")).strip()
            except (ValueError, UnicodeDecodeError):
                return self._json({"error": "invalid JSON body"}, 400)
            app = next((a for a in load_apps()["apps"] if a["name"] == name), None)
            if app is None:
                return self._json({"error": f"no app named {name!r}"}, 404)
            if app["type"] != "mpv":
                return self._json({"ok": True, "mode": "browser", "url": app["url"]})
            # mpv tile: launch native player; browser is the graceful fallback
            try:
                r = subprocess.run(
                    [PLAY_SH, name], capture_output=True, text=True, timeout=25,
                )
            except subprocess.TimeoutExpired:
                return self._json({"ok": True, "mode": "browser", "url": app["url"],
                                   "fallback": True, "reason": "timeout"})
            except OSError as e:
                return self._json({"error": f"cannot launch player: {e}"}, 500)
            if r.returncode == 0:
                return self._json({"ok": True, "mode": "mpv"})
            return self._json({"ok": True, "mode": "browser", "url": app["url"],
                               "fallback": True,
                               "reason": (r.stderr or "").strip().splitlines()[-1] if r.stderr else "resolve failed"})
        if path == "/api/network":
            try:
                payload = json.loads(raw.decode("utf-8"))
                args = validate_network(payload)
            except (ValueError, UnicodeDecodeError) as e:
                return self._json({"error": str(e)}, 400)
            try:
                r = subprocess.run(
                    ["/usr/bin/sudo", NETAPPLY_SH] + args,
                    capture_output=True, text=True, timeout=60,
                )
            except Exception as e:
                return self._json({"error": f"apply failed: {e}"}, 500)
            if r.returncode != 0:
                return self._json({"error": (r.stderr or r.stdout or "apply failed").strip()}, 500)
            return self._json({"ok": True, "output": r.stdout.strip()})
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
