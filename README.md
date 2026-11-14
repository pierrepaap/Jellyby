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
| Kiosk browser | `jellyby-kiosk` | Chromium `--kiosk` on `jellyby-x` (Xorg); launcher UI + `browser`-type tiles |
| Native player | on-demand | system `mpv` fullscreen on :0 with Pi 4 rpivid HEVC hwdec (`/opt/jellyby/play.sh`) |
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

## Test in a QEMU Raspberry Pi emulator (manual; not run in CI)

QEMU's raspi machines are bare SoC emulators: the image's VideoCore firmware
never runs, `config.txt` is ignored, and the kernel must be loaded explicitly
with `-kernel`/`-dtb` taken from the image's boot partition. Emulation caveats:

- use `-M raspi3b` — QEMU's `raspi4b` has **no usable network** (the Pi 4 USB
  controller sits on PCIe, which QEMU does not emulate)
- on the stock Pi 3 DTB the PL011 UART belongs to Bluetooth; apply the image's
  own `disable-bt` overlay to the DTB (`fdtoverlay`) or `console=ttyAMA0`
  prints nothing
- no GPU (V3D) and no HDMI-CEC: the kiosk UI and remote cannot be tested there

`scripts/test-image-qemu.sh` does all of this for you (boots a resized copy,
extracts kernel + DTB, applies the overlay, waits for SSH, runs the checks,
saves the serial console to `qemu-console.log`):

```bash
sudo apt install qemu-system-arm qemu-utils sshpass device-tree-compiler
xz -d jellyby-pi4.img.xz
sudo bash scripts/test-image-qemu.sh jellyby-pi4.img 2222   # logs in as pi/jellyby
# then: ssh -p 2222 pi@127.0.0.1, systemctl status, curl 127.0.0.1:8901/api/config
```

The release pipeline does **not** boot the image in CI (emulated Pi boots are
slow and flaky); it gates on `scripts/check-image.sh` instead — hard no-boot
checks on the mounted image (boot config, installed binaries, enabled
services, permissions, JSON configs). The first real boot happens on your Pi.

Cannot be emulated: real HDMI-CEC remote interaction and GPU video playback —
those still need one boot on the Pi.

## Install — option C: as a multiboot entry in PINN

Every release also ships **PINN** assets (`os_list_v3.json`, `os.json`,
`partitions.json`, `partition_setup.sh`, `boot.tar.xz`, `rootfs.tar.xz`, icon
and `marketing.tar`), so Jellyby can be installed alongside other OSes on one
SD card via [PINN](https://github.com/procount/pinn):

1. Boot PINN on the SD card, edit `recovery.cmdline` on PINN's boot partition
   and append:

   ```
   alt_image_source=https://github.com/pierrepaap/Jellyby/releases/latest/download/os_list_v3.json
   ```

2. Reboot PINN — **Jellyby** appears in the OS list (group "Media"). Tick it
   together with any other OSes and press Install.
3. PINN writes the partitions, untars them and runs `partition_setup.sh`, which
   rewrites `cmdline.txt`/`fstab` to the new PARTUUIDs. On first boot the
   image's own resize step expands the rootfs to the (maximised) partition.

The PINN assets live flat in each release, e.g.
`https://github.com/pierrepaap/Jellyby/releases/latest/download/os_list_v3.json`.

## Playback: native MPV (primary) vs browser (fallback)

No browser on a Pi 4 can hardware-decode HEVC/H.265 — only MPV/ffmpeg via the
kernel rpivid V4L2 stateless decoder (needs `dtoverlay=vc4-kms-v3d` in
`config.txt`, which `setup.sh` ensures idempotently, plus `gpu_mem=256`).
So each app is a **typed** entry in `/etc/jellyby/apps.json`:

```json
{ "apps": [
  { "name": "Jellyfin", "type": "mpv",     "server": "jellyfin", "url": "http://jellyfin.local:8096", "item": "" },
  { "name": "Emby",     "type": "mpv",     "server": "emby",     "url": "http://emby.local:8096",  "item": "" },
  { "name": "Plex",     "type": "browser", "server": "plex",     "url": "http://plex.local:32400/web" }
] }
```

- `type: "mpv"` (default for Jellyfin/Emby): selecting the tile opens the
  **media browse view** — the launcher lists the server's libraries
  (`GET /api/media/libraries`), you drill into shows/seasons/episodes with
  the remote (`GET /api/media/items`), and OK on a title resolves a
  **direct-play stream URL** (`POST /api/media/play` →
  `/Videos/{id}/stream?static=true`, original file, no transcode) and launches
  **system mpv** fullscreen on `DISPLAY :0` with `/opt/jellyby/mpv/mpv.conf`
  (`hwdec=auto-safe` → rpivid v4l2-request, `vo=gpu`, fullscreen). A
  continue-watching row (`GET /api/media/resume`) sits on top; posters are
  proxied via `/api/media/poster` so the auth token never reaches the UI.
  The remote's exit key (Ctrl+W) is mapped to `quit` in `mpv/input.conf`, so
  exiting mpv returns to the launcher — same UX as closing a browser tab.
  The whole Jellyfin/Emby client is `mediaclient.py` (stdlib only,
  `resolve_stream.py` wraps it for the CLI); Emby's `/emby` base path is
  detected at runtime. The stream URL (with its api_key) is handed to mpv
  via a 0600 playlist file, never via the command line.
  Media-server credentials live in `/etc/jellyby/players.json` (media:media
  0600, keyed by app name; edit over SSH). After the first login the launcher
  persists the server's AccessToken + UserId there and only re-authenticates
  when the token goes stale — the password is not used per request.
  Playback progress is **not** reported back to the server in v1 (TODO:
  `/Sessions/Playing{,/Progress,/Stopped}`); resume plays from the
  server-side position.
- `type: "browser"`: opens the URL in a Chromium tab as before (launcher UI
  itself always runs in Chromium). If MPV can't resolve a stream (server down,
  bad credentials), `/api/media/play` returns `mode: "browser"` and the UI
  opens the browser tab — playback degrades gracefully instead of failing.
- Legacy `{name, url}` entries still load (normalized to `type: "browser"`).
- Optional polished front-ends (Jellyfin Media Player flatpak, Emby Theater
  .deb) install only with `JELLYBY_THEATER=1 sudo ./setup.sh`; system mpv
  remains the decode path regardless.

## Network settings (in the launcher)

Settings → Network shows live NetworkManager state (`GET /api/network`) and
lets you switch an interface between **DHCP** and **static** (address/CIDR,
gateway, DNS list) with the remote + on-screen keyboard. `POST /api/network`
validates strictly (IPv4/CIDR, gateway-in-subnet, ≤3 IPv4 DNS, existing
interface, `confirm: true`) and applies via `sudo /opt/jellyby/netapply.sh`,
which is restricted to specific `nmcli` subcommands in `/etc/sudoers.d/jellyby`.
**Escape hatch if a bad static config locks you out of SSH:**
`sudo /opt/jellyby/netapply.sh eth0 dhcp`.

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
| `/etc/jellyby/apps.json` | launcher tiles (typed: name/type/server/url/item) | in the kiosk (on-screen keyboard) or SSH |
| `/etc/jellyby/players.json` | media-server credentials + auth tokens for MPV (media:media 0600) | SSH only (launcher persists tokens) |
| `/etc/jellyby/cec-keymap.conf` | CEC button → key mapping | SSH |
| `/etc/default/readsb` | readsb options + optional remote push target | SSH |

## Image build pipeline

`.github/workflows/release-image.yml` builds the flashable image in CI: it
downloads the latest Pi OS Lite (64-bit), grows and mounts the image, enables
SSH + default user on the boot partition, runs `setup.sh` in a chroot under
`qemu-user-static` (`JELLYBY_OFFLINE=1` mode), shrinks the image with PiShrink
(auto-expands on first boot), **smoke-tests the result by booting it in QEMU**
(`scripts/test-image-qemu.sh` — no assets are published if this fails), packs
the PINN assets, and attaches `jellyby-pi4.img.xz`, `jellyby-imager.json`
(with sha256/size) and the `pinn-out/*` files to the release.

**Single trigger: publish a GitHub release** (Releases → New release → choose
a tag like `v0.2.0` → mark as latest → Publish). The workflow then builds the
image and uploads the assets to that release. Lint still gates every PR/merge
via `lint.yml`; image builds stay release-driven so each image maps to a
versioned release.

## What is verified where

- **QEMU CI smoke test (hard checks)**: image boots, SSH up, launcher served,
  `/api/config` valid, `mpv`/`cec-kbd`/`readsb`/`play.sh`/`netapply.sh`
  installed, `config.txt` has `vc4-kms-v3d` + `gpu_mem=256`, `media` in the
  `video` group.
- **Soft warnings only (need real hardware)**: headless-Chromium render, readsb
  with an RTL-SDR dongle.
- **Real Pi 4 only**: HEVC 10-bit hwdec via rpivid in mpv, HDMI-CEC remote
  pairing, actual playback of your library. Verify with
  `mpv --hwdec=auto-safe --msg-level=all=v` over SSH, or
  `v4l2-ctl -d /dev/video10 --list-formats`.

## Security notes

- The prebuilt image ships with **pi / jellyby** — change it right after first
  boot, or use SSH keys (`ssh-copy-id`). In Imager you can also set your own
  user/password at flash time.
- The kiosk Chromium runs with its **sandbox enabled** (no `--no-sandbox`); it needs
  unprivileged user namespaces (`kernel.unprivileged_userns_clone=1`, default on Pi OS
  Bookworm+) because the launcher loads remote web UIs.
- The launcher API binds to **127.0.0.1 only**; the only privileged actions
  allowed for the kiosk user are `systemctl reboot/poweroff/restart readsb`
  (see `/etc/sudoers.d/jellyby`).

## Repo layout

```
setup.sh                        provisioning script (run once as root on the Pi, or in CI chroot)
scripts/serve-local.sh          run the launcher UI on any PC for testing
scripts/test-image-qemu.sh      boot a built image in QEMU and smoke-test it over SSH
scripts/gen-pinn.py             generate PINN metafiles (os_list_v3.json, os.json, partitions.json)
pinn/                           PINN repo templates: partition_setup.sh, Jellyby.png, marketing.tar
imager/jellyby.json             Raspberry Pi Imager custom-repo list (reference copy)
files/etc/systemd/system/       service units
files/etc/jellyby/              apps.json (default tiles) + cec-keymap.conf
files/etc/default/readsb        readsb options
files/opt/jellyby/              server.py, resolve_stream.py, play.sh, netapply.sh, cec_kbd.c, kiosk.sh, mpv/ (hwdec config), www/ (launcher UI)
files/usr/local/bin/            readsb-wrapper.sh
docs/remote-tar1090/            docker-compose for the remote map machine
.github/workflows/lint.yml      CI: shellcheck, gcc syntax check, py/node/json checks
.github/workflows/release-image.yml  CI: build + publish flashable image to Releases
```
