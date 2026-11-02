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
| SSH | `ssh` | enabled |

## Install — option A: ready-to-flash image via Raspberry Pi Imager

Once a release has been built (see [Image build pipeline](#image-build-pipeline)),
Jellyby appears in Raspberry Pi Imager's OS list:

1. Open **Raspberry Pi Imager** → gear icon (Settings) → **add a custom repository**
   with this URL:
   `https://github.com/pierrepaap/Jellyby/releases/latest/download/jellyby-imager.json`
   (fallback if your Imager version has no custom-repo setting: `imager/jellyby.json`
   in this repo, via "Use custom").
2. Choose **OS → Jellyby (Raspberry Pi 4) → Jellyby Pi 4 (64-bit)**, pick your SD
   card, and use the gear to set hostname / WiFi / your own user (recommended).
3. Flash. Boot the Pi with HDMI to the projector and an Ethernet cable (or WiFi
   configured in step 2).

> The image ships with SSH enabled and default login **pi / jellyby** — change it
> immediately (`passwd`, or use SSH keys).

## Install — option B: build it yourself on a stock Pi OS Lite

1. Flash **Raspberry Pi OS Lite (64-bit, Bookworm)** (enable SSH in Imager or via
   an empty `ssh` file on the boot partition).
2. Boot, then:

   ```bash
   ssh pi@<pi-ip>
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/pierrepaap/Jellyby.git
   cd Jellyby
   sudo ./setup.sh
   sudo reboot
   ```

`setup.sh` installs everything and compiles `cec-kbd` and readsb **on the Pi**
(a few minutes). It is idempotent and will not overwrite your edited
`/etc/jellyby/apps.json` or keymap on re-runs.

## Test locally without a Pi

The launcher is just a web page, and the CEC daemon injects plain keyboard
events — so a desktop browser with arrow keys/Enter/Backspace/F10 behaves
exactly like the remote:

```bash
./scripts/serve-local.sh        # then open http://127.0.0.1:8901
```

## Test in a QEMU Raspberry Pi 4 emulator

QEMU boots Pi OS Lite (`-M raspi4b`) — good for validating provisioning,
services, the readsb build and the HTTP API — but it has **no GPU (V3D) and no
HDMI-CEC**, so the kiosk UI and remote cannot be tested there:

```bash
qemu-system-aarch64 -M raspi4b -cpu cortex-a72 -smp 4 -m 4096 \
  -kernel kernel8.img -dtb bcm2711-rpi-4-b.dtb \
  -append "rw root=/dev/mmcblk0p2 rootfstype=ext4 console=ttyAMA0" \
  -drive file=pi-os-lite.img,format=raw,if=sd \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device usb-net,netdev=n0 -nographic
# kernel8.img / bcm2711-rpi-4-b.dtb: copy them from the boot partition of the image
# ssh -p 2222 pi@127.0.0.1  →  sudo ./setup.sh, systemctl status, curl 127.0.0.1:8901/api/config
```

## Using the kiosk

- Home screen: one tile per configured server. Selecting a tile opens that web
  UI in a new tab; **exit** on the remote (mapped to `Ctrl+W`) closes the tab
  and returns to the launcher.
- **Settings** (menu key / gear tile): add, edit or delete apps with the
  **on-screen keyboard** driven by the remote. Saved to `/etc/jellyby/apps.json`
  (also editable over SSH).
- Settings also shows service states and offers **Reboot** / **Power off**
  (press twice to confirm).

> Playback note: Chromium on Pi may not hardware-decode every codec (e.g.
> HEVC). If direct play stalls, enable transcoding on your Emby/Jellyfin server.

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
Check with `sudo systemctl status cec-kbd` / `journalctl -u cec-kbd -f`, or test
CEC itself with `cec-client`.

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

## Image build pipeline

`.github/workflows/release-image.yml` builds the flashable image in CI: it
downloads the latest Pi OS Lite (64-bit), mounts the image, enables SSH +
default user on the boot partition, runs `setup.sh` in a chroot under
`qemu-user-static` (`JELLYBY_OFFLINE=1` mode), shrinks the image with PiShrink
(auto-expands on first boot), and publishes `jellyby-pi4.img.xz` plus a
ready-made `jellyby-imager.json` to a GitHub Release marked "latest".

Trigger it manually (Actions → release-image → Run workflow) or with a tag:

```bash
git tag image-1 && git push origin image-1
```

## Security notes

- The prebuilt image ships with **pi / jellyby** — change it right after first
  boot, or use SSH keys (`ssh-copy-id`). In Imager you can also set your own
  user/password at flash time.
- The launcher API binds to **127.0.0.1 only**; the only privileged actions
  allowed for the kiosk user are `systemctl reboot/poweroff/restart readsb`
  (see `/etc/sudoers.d/jellyby`).

## Repo layout

```
setup.sh                        provisioning script (run once as root on the Pi, or in CI chroot)
scripts/serve-local.sh          run the launcher UI on any PC for testing
imager/jellyby.json             Raspberry Pi Imager custom-repo list (reference copy)
files/etc/systemd/system/       service units
files/etc/jellyby/              apps.json (default tiles) + cec-keymap.conf
files/etc/default/readsb        readsb options
files/opt/jellyby/              server.py, cec_kbd.c, kiosk.sh, www/ (launcher UI)
files/usr/local/bin/            readsb-wrapper.sh
docs/remote-tar1090/            docker-compose for the remote map machine
.github/workflows/lint.yml      CI: shellcheck, gcc syntax check, py/node/json checks
.github/workflows/release-image.yml  CI: build + publish flashable image to Releases
```
