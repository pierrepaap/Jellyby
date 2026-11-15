# Jellyby

A small appliance image for the **Raspberry Pi 4** that boots straight into a
fullscreen launcher for your **Jellyfin**, **Emby** and **Plex** (or any other
web) servers — no Kodi, no sync, no plugins, just like a smart-TV app — driven
entirely by your **TV/projector remote over HDMI-CEC**.

- Jellyfin/Emby libraries are browsed in the launcher and played in **native
  mpv** with Pi 4 hardware HEVC decoding (direct play, no transcode).
- Anything else (Plex, other web UIs) opens in a **Chromium kiosk** tab.
- The same Pi can run **readsb** with an RTL-SDR dongle; the tar1090 map runs
  in a container on another machine.
- Everything is a systemd service, manageable over **SSH**.

## Contents

- [Architecture](#architecture)
- [Install](#install)
- [Using the launcher](#using-the-launcher)
- [Playback: mpv vs browser](#playback-mpv-vs-browser)
- [Network settings](#network-settings)
- [CEC remote mapping](#cec-remote-mapping)
- [readsb (ADS-B)](#readsb-ads-b)
- [Configuration files](#configuration-files)
- [Development and testing](#development-and-testing)
- [Release pipeline](#release-pipeline)
- [Security notes](#security-notes)
- [Repo layout](#repo-layout)

## Architecture

```
 remote --HDMI-CEC--> Pi 4
                        │
 ┌──────────────────────┼────────────────────────────────────────────┐
 │ cec-kbd (libcec → /dev/uinput) → Xorg → Chromium --kiosk           │
 │                                            │                       │
 │                       launcher: http://127.0.0.1:8901              │
 │                       server.py + www/ (tiles, browse, OSK)        │
 │                          │                         │               │
 │          type "mpv": play.sh → mpv (rpivid)   type "browser": tab  │
 │                          │                         │               │
 │                  Jellyfin / Emby API         Plex / any web UI     │
 └───────────────────────────────────────────────────────────────────┘

 readsb (RTL-SDR) --beast:30005--> LAN --> remote host: tar1090 (docker)
```

| Piece | Service | Notes |
|---|---|---|
| Launcher UI + API | `jellyby-web` | `python3 /opt/jellyby/server.py`, bound to 127.0.0.1:8901 |
| Display | `jellyby-x` | Xorg on `:0` |
| Kiosk browser | `jellyby-kiosk` | Chromium `--kiosk`; shows the launcher and `browser`-type tiles |
| Native player | on demand | system `mpv` fullscreen on `:0`, started by `/opt/jellyby/play.sh` |
| CEC remote → keyboard | `cec-kbd` | libcec daemon injecting keys via uinput |
| ADS-B receiver | `readsb` | options in `/etc/default/readsb` |
| SSH | `ssh` | enabled |

## Install

### Option A — Raspberry Pi Imager (ready-to-flash image)

1. In **Raspberry Pi Imager**, open Settings (gear) → **add a custom repository**:
   `https://github.com/pierrepaap/Jellyby/releases/latest/download/jellyby-imager.json`
   (older Imager without that setting: use "Use custom" with
   [`imager/jellyby.json`](imager/jellyby.json)).
2. Choose **OS → Jellyby (Raspberry Pi 4) → Jellyby Pi 4 (64-bit)**, pick the SD
   card, and set hostname / Wi-Fi / your own user in the customisation dialog
   (recommended).
3. Flash, then boot the Pi with HDMI to the display and Ethernet (or the Wi-Fi
   set in step 2).

> The image ships with SSH enabled and a default login **pi / jellyby** unless
> you set your own user in Imager. Change it immediately (`passwd` or SSH keys).

### Option B — build on a stock Raspberry Pi OS Lite

1. Flash **Raspberry Pi OS Lite (64-bit, Bookworm)** with SSH enabled.
2. Then:

   ```bash
   ssh pi@<pi-ip>
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/pierrepaap/Jellyby.git
   cd Jellyby
   sudo ./setup.sh
   sudo reboot
   ```

`setup.sh` installs packages, compiles `cec-kbd` and readsb on the Pi (a few
minutes) and writes the required `config.txt` lines. It is idempotent and does
not overwrite an edited `/etc/jellyby/apps.json` or keymap on re-runs.

Optional: `JELLYBY_THEATER=1 sudo ./setup.sh` also installs Jellyfin Media
Player (flatpak) / Emby Theater (.deb). System mpv stays the decode path either
way.

### Option C — PINN multiboot entry

Each release also ships [PINN](https://github.com/procount/pinn) assets, so
Jellyby can sit alongside other OSes on one SD card:

1. On PINN's boot partition, append to `recovery.cmdline`:

   ```
   alt_image_source=https://github.com/pierrepaap/Jellyby/releases/latest/download/os_list_v3.json
   ```

2. Reboot PINN — **Jellyby** appears in the OS list (group "Media"). Tick it
   with any other OSes and press Install.
3. PINN writes the partitions and runs `partition_setup.sh`, which rewrites
   `cmdline.txt`/`fstab` to the new PARTUUIDs. The rootfs expands on first boot.

## Using the launcher

- **Home**: one tile per configured app.
  - `mpv` tiles (Jellyfin/Emby) open the **browse view**: a continue-watching
    row, then libraries → shows → seasons → episodes. OK on a title plays it in
    mpv; the remote's **exit** key quits mpv and returns to the launcher.
  - `browser` tiles open the URL in a Chromium tab; **exit** (`Ctrl+W`) closes
    the tab.
- **Settings** (menu key / gear tile, `F10`):
  - add, edit or delete apps with the **on-screen keyboard** (saved to
    `/etc/jellyby/apps.json`);
  - network configuration (see [Network settings](#network-settings));
  - service states and **Reboot** / **Power off** (press twice to confirm).

## Playback: mpv vs browser

No browser on a Pi 4 can hardware-decode HEVC/H.265 — only mpv/ffmpeg through
the kernel's rpivid V4L2 stateless decoder. That requires
`dtoverlay=vc4-kms-v3d` and `gpu_mem=256` in `config.txt` (`setup.sh` adds
them). So each app in `/etc/jellyby/apps.json` is **typed**:

```json
{ "apps": [
  { "name": "Jellyfin", "type": "mpv",     "server": "jellyfin", "url": "http://jellyfin.local:8096", "item": "" },
  { "name": "Emby",     "type": "mpv",     "server": "emby",     "url": "http://emby.local:8096",     "item": "" },
  { "name": "Plex",     "type": "browser", "server": "plex",     "url": "http://plex.local:32400/web" }
] }
```

**`type: "mpv"`** (Jellyfin / Emby)

- The launcher talks to the server API via `mediaclient.py` (stdlib only;
  Emby's `/emby` base path is auto-detected):
  `GET /api/media/libraries`, `/api/media/items`, `/api/media/resume`.
- Posters are proxied through `/api/media/poster`, so the auth token never
  reaches the UI.
- Playing (`POST /api/media/play`) resolves a **direct-play** URL
  (`/Videos/{id}/stream?static=true`, original file) and starts mpv with
  `/opt/jellyby/mpv/mpv.conf` (`hwdec=auto-safe`, `vo=gpu`, fullscreen). The
  URL is passed via a 0600 playlist file, never on the command line.
- Credentials live in `/etc/jellyby/players.json`, keyed by app name (edit over
  SSH). After the first login the AccessToken + UserId are stored there and
  reused until they go stale.
- If a stream can't be resolved (server down, bad credentials), the API answers
  `mode: "browser"` and the launcher opens the web UI instead.
- Limitation: playback progress is **not** reported back to the server yet;
  "resume" uses the server-side position.

**`type: "browser"`** opens the URL in a Chromium tab. Legacy `{name, url}`
entries are still accepted and treated as `browser`.

## Network settings

Settings → Network shows the live NetworkManager state and lets you switch an
interface between **DHCP** and **static** (address/CIDR, gateway, up to 3 DNS
servers) with the remote. Input is strictly validated, then applied by
`sudo /opt/jellyby/netapply.sh`, which may only run specific `nmcli`
subcommands (see `/etc/sudoers.d/jellyby`).

**Locked out by a bad static config?** From a local console:
`sudo /opt/jellyby/netapply.sh eth0 dhcp`.

## CEC remote mapping

[`/etc/jellyby/cec-keymap.conf`](files/etc/jellyby/cec-keymap.conf) maps CEC
buttons to keyboard keys:

```
select    = enter
backward  = backspace
exit      = ctrl+w
root_menu = f10
play      = space
volume_up = volumeup
```

After editing: `sudo systemctl restart cec-kbd`. Debug with
`journalctl -u cec-kbd -f`, or test CEC itself with `cec-client`.

## readsb (ADS-B)

The Pi runs **only readsb** and serves Beast output on TCP **30005**. The map
runs in a tar1090 container elsewhere — see
[`docs/remote-tar1090/docker-compose.yml`](docs/remote-tar1090/docker-compose.yml):
set `BEASTHOST` to the Pi's IP and open `http://<remote-host>:8080`.

```bash
sudo nano /etc/default/readsb    # READSB_OPTIONS; optional READSB_REMOTE_HOST/PORT to push beast_out
sudo systemctl restart readsb
sudo systemctl status readsb     # check the dongle is detected
```

Plug the RTL-SDR dongle in before (re)starting the service.

## Configuration files

| File | Purpose | Edit via |
|---|---|---|
| `/etc/jellyby/apps.json` | launcher tiles (name / type / server / url / item) | launcher Settings or SSH |
| `/etc/jellyby/players.json` | media-server credentials + cached tokens (`media:media`, 0600) | SSH |
| `/etc/jellyby/cec-keymap.conf` | CEC button → key mapping | SSH |
| `/etc/default/readsb` | readsb options + optional push target | SSH |

## Development and testing

### Launcher on any PC

The launcher is a web page and the CEC daemon only sends keyboard events, so a
desktop browser with arrows / Enter / Backspace / F10 behaves like the remote:

```bash
./scripts/serve-local.sh    # then open http://127.0.0.1:8901
```

It uses a temp copy of `files/etc/jellyby/apps.json`, so the repo is untouched.

### Image checks without booting

```bash
sudo bash scripts/check-image.sh jellyby-pi4.img
```

Mounts the image and verifies boot config, installed binaries, enabled
services, permissions and JSON configs. This is what gates releases in CI.

### Booting the image in QEMU (manual, not in CI)

`scripts/test-image-qemu.sh` boots a resized copy of the image, waits for SSH
and runs smoke checks; the serial console is saved to `qemu-console.log`.

```bash
sudo apt install qemu-system-arm qemu-utils sshpass device-tree-compiler
xz -d jellyby-pi4.img.xz
sudo bash scripts/test-image-qemu.sh jellyby-pi4.img 2222   # logs in as pi/jellyby
ssh -p 2222 pi@127.0.0.1
```

Emulation caveats (handled by the script):

- QEMU's raspi machines don't run the VideoCore firmware, so `config.txt` is
  ignored and the kernel/DTB are loaded with `-kernel`/`-dtb` from the image.
- It uses `-M raspi3b`: `raspi4b` has no usable network (the Pi 4 USB
  controller sits on PCIe, which QEMU doesn't emulate).
- On the stock Pi 3 DTB the PL011 UART belongs to Bluetooth; the image's
  `disable-bt` overlay is applied with `fdtoverlay` so `console=ttyAMA0` works.
- No GPU and no HDMI-CEC: the kiosk UI, remote and video playback can't be
  tested there.

### What can only be verified on a real Pi 4

HEVC (incl. 10-bit) hardware decode in mpv, HDMI-CEC remote pairing, actual
playback of your library, readsb with a dongle. Useful checks over SSH:
`mpv --hwdec=auto-safe --msg-level=all=v <file>` and
`v4l2-ctl -d /dev/video10 --list-formats`.

## Release pipeline

- **[`lint.yml`](.github/workflows/lint.yml)** runs on every push/PR:
  shellcheck, `cec_kbd.c` syntax check against libcec headers, Python / JS /
  JSON syntax checks.
- **[`release-image.yml`](.github/workflows/release-image.yml)** runs when a
  GitHub release is **published** (Releases → New release → tag e.g. `v0.5.0`
  → Publish). It:
  1. downloads the latest Pi OS Lite (64-bit) and grows it;
  2. enables SSH and the default user on the boot partition;
  3. runs `setup.sh` in a chroot under `qemu-user-static` (`JELLYBY_OFFLINE=1`);
  4. shrinks it with PiShrink (auto-expands on first boot) and compresses it;
  5. gates on `scripts/check-image.sh`;
  6. packs the PINN assets and the Imager JSON (with size + sha256);
  7. attaches `jellyby-pi4.img.xz`, `jellyby-imager.json` and the PINN files to
     the release.

## Security notes

- The prebuilt image's default login is **pi / jellyby** — change it on first
  boot, use SSH keys, or set your own user in Imager.
- Kiosk Chromium runs **with its sandbox** (no `--no-sandbox`), relying on
  unprivileged user namespaces (default on Pi OS Bookworm), since it loads
  remote web UIs.
- The launcher API listens on **127.0.0.1 only**.
- The kiosk user (`media`) may only run, via sudo: `systemctl reboot`,
  `systemctl poweroff`, `systemctl restart readsb`, and specific
  `nmcli connection/device` subcommands used by `netapply.sh`
  (see [`/etc/sudoers.d/jellyby`](files/etc/sudoers.d/jellyby)).
- Media-server credentials and tokens are kept in `players.json` (0600) and
  stream URLs reach mpv via a 0600 playlist file, not the command line.

## Repo layout

```
setup.sh                       provisioning (on the Pi as root, or in the CI chroot)
files/                         installed into / by setup.sh
  etc/systemd/system/          service units (jellyby-web/-x/-kiosk, cec-kbd, readsb)
  etc/jellyby/                 apps.json, players.json, cec-keymap.conf
  etc/sudoers.d/jellyby        the kiosk user's allowed privileged commands
  etc/X11/xorg.conf.d/         Xorg config
  etc/default/readsb           readsb options
  opt/jellyby/                 server.py, mediaclient.py, resolve_stream.py, play.sh,
                               netapply.sh, kiosk.sh, cec_kbd.c, mpv/, www/ (launcher UI)
  usr/local/bin/               readsb-wrapper.sh
scripts/
  serve-local.sh               run the launcher on any PC
  check-image.sh               no-boot image checks (release gate)
  test-image-qemu.sh           boot an image in QEMU and smoke-test over SSH
  gen-pinn.py                  generate PINN metafiles
  ci-apt.sh                    resilient apt install for CI runners
pinn/                          PINN templates: partition_setup.sh, icon, marketing.tar
imager/jellyby.json            Raspberry Pi Imager repo list (reference copy)
docs/remote-tar1090/           docker-compose for the remote map host
.github/workflows/             lint.yml, release-image.yml
```
