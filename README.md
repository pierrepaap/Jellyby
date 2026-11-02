# Jellyby

A small appliance image for the **Raspberry Pi 4** that boots straight into a
fullscreen web kiosk (no Kodi, no sync, no plugins — like a smart-TV app) where
you can open your **Emby**, **Jellyfin**, **Plex** (or any other web) servers,
navigated entirely with your **projector remote over HDMI-CEC**. The same Pi
can run **readsb** with an RTL-SDR antenna; the web map (tar1090) runs in a
container on a *remote* machine.

## Architecture

```
 projector remote --HDMI-CEC--> Pi 4
                                   │
   ┌───────────────────────────────┼───────────────────────────────┐
   │  cec-kbd (libcec -> /dev/uinput)  → Xorg → Chromium --kiosk   │
   │                                              │                │
   │                              http://127.0.0.1:8901 (launcher)│
   │                              server.py + www/ (tiles + OSK)  │
   │                                              │ opens tabs     │
   │                              Emby / Jellyfin / Plex web UIs   │
   └──────────────────────────────┼───────────────────────────────┘
                                  │
   readsb (RTL-SDR) --beast:30005--┴--> LAN --> remote host: tar1090 (docker)
```

Everything runs as systemd services and is manageable over **SSH**.

## What you get

| Piece | Service | Notes |
|---|---|---|
| Launcher UI | `jellyby-web` | `python3 /opt/jellyby/server.py`, localhost only (127.0.0.1:8901) |
| Kiosk browser | `jellyby-kiosk` | Chromium `--kiosk` on `jellyby-x` (Xorg) |
| CEC remote → keyboard | `cec-kbd` | libcec daemon injecting keys via uinput; keymap in `/etc/jellyby/cec-keymap.conf` |
| ADS-B receiver | `readsb` | config in `/etc/default/readsb` |
| SSH | `ssh` | enabled by setup |

## Install

1. Flash **Raspberry Pi OS Lite (64-bit, Bookworm)** to an SD card (use Raspberry
   Pi Imager and enable SSH there, or create an empty `ssh` file on the boot
   partition).
2. Boot the Pi, find its IP, then:

   ```bash
   ssh pi@<pi-ip>
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/pierrepaap/Jellyby.git
   cd Jellyby
   sudo ./setup.sh
   sudo reboot
   ```

3. After reboot the launcher appears on the HDMI output. Use your projector
   remote: **arrows + OK** to navigate, **back** to go back, **menu** key
   (mapped to F10) or the **⚙ Settings** tile to open settings.

## Using the kiosk

- The home screen shows one tile per configured server. Selecting a tile opens
  that web UI in a new tab; **exit** on the remote (mapped to `Ctrl+W`) closes
  the tab and returns to the launcher (if it was the last tab, the kiosk
  restarts into the launcher).
- **Settings** (menu key / gear tile): add, edit or delete apps
  (Emby/Jellyfin/Plex/anything with a web UI) using the **on-screen keyboard**
  driven by the remote. Apps are saved to `/etc/jellyby/apps.json`
  (also editable over SSH).
- Settings also shows the state of the services and offers **Reboot** /
  **Power off** (press twice to confirm).

> Playback note: the Chromium build on Pi may not hardware-decode every codec
> (e.g. HEVC). If direct play stalls, enable transcoding on your Emby/Jellyfin
> server.

## CEC remote mapping

`/etc/jellyby/cec-keymap.conf` maps CEC buttons to keyboard keys, e.g.:

```
select = enter
backward = backspace
exit   = ctrl+w
root_menu = f10
volume_up = volumeup
```

Edit over SSH, then `sudo systemctl restart cec-kbd`.
Check the daemon with `sudo systemctl status cec-kbd` / `journalctl -u cec-kbd -f`,
or test CEC itself with `cec-client`.

## readsb (ADS-B) — split setup

The Pi runs **only readsb** (no map on the Pi). It serves Beast output on TCP
**30005**. The map runs in a **tar1090 container on a remote machine** — see
[`docs/remote-tar1090/docker-compose.yml`](docs/remote-tar1090/docker-compose.yml):
set `BEASTHOST` to the Pi's IP and open `http://<remote-host>:8080`.

Configurable over SSH:

```bash
sudo nano /etc/default/readsb        # READSB_OPTIONS, optional READSB_REMOTE_HOST/PORT to push beast_out
sudo systemctl restart readsb
sudo systemctl status readsb         # check the dongle is detected
```

Plug the RTL-SDR dongle into the Pi before (re)starting the service.

## Configuration files

| File | Purpose | Edit |
|---|---|---|
| `/etc/jellyby/apps.json` | launcher tiles (name + URL) | in the kiosk (on-screen keyboard) or SSH |
| `/etc/jellyby/cec-keymap.conf` | CEC button → key mapping | SSH |
| `/etc/default/readsb` | readsb options + optional remote push target | SSH |

## Security notes

- Change the default `pi` password or use SSH keys (`ssh-copy-id`).
- The launcher API binds to **127.0.0.1 only**; the only privileged actions
  allowed for the kiosk user are `systemctl reboot/poweroff/restart readsb`
  (see `/etc/sudoers.d/jellyby`).

## Repo layout

```
setup.sh                        provisioning script (run once as root on the Pi)
files/etc/systemd/system/       service units
files/etc/jellyby/              apps.json (default tiles) + cec-keymap.conf
files/etc/default/readsb        readsb options
files/opt/jellyby/              server.py, cec_kbd.c, kiosk.sh, www/ (launcher UI)
files/usr/local/bin/            readsb-wrapper.sh
docs/remote-tar1090/            docker-compose for the remote map machine
.github/workflows/lint.yml      CI: shellcheck, gcc syntax check, py/node checks
```
