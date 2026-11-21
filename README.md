# Jellyby

A small appliance image for the **Raspberry Pi 4** (and, experimentally, the
**Radxa ZERO 3E/3W**) that boots straight into a
fullscreen launcher for your **Jellyfin**, **Emby** and **Plex** (or any other
web) servers — no Kodi, no sync, no plugins, just like a smart-TV app — driven
entirely by your **TV/projector remote over HDMI-CEC**.

- Jellyfin/Emby libraries are browsed in the launcher and played in **native
  mpv** with hardware HEVC decoding (direct play, no transcode).
- Anything else (Plex, other web UIs) opens in a **Chromium kiosk** tab.
- The same Pi can run **readsb** with an RTL-SDR dongle; the tar1090 map runs
  in a container on another machine.
- Everything is a systemd service, manageable over **SSH**.

## Contents

- [Supported boards](#supported-boards)
- [Architecture](#architecture)
- [Install](#install)
- [Using the launcher](#using-the-launcher)
- [Playback: mpv vs browser](#playback-mpv-vs-browser)
- [Network settings](#network-settings)
- [CEC remote mapping](#cec-remote-mapping)
- [readsb (ADS-B)](#readsb-ads-b)
- [Settings reference](#settings-reference)
- [Configuration files](#configuration-files)
- [Development and testing](#development-and-testing)
- [Release pipeline](#release-pipeline)
- [Security notes](#security-notes)
- [Repo layout](#repo-layout)

## Supported boards

| | Raspberry Pi 4 | Radxa ZERO 3E / 3W (experimental) |
|---|---|---|
| Status | supported, tested | **untested on hardware** — code paths in place |
| Base OS | Raspberry Pi OS Lite 64-bit | Armbian, **vendor (6.1) kernel** |
| HEVC hardware decode | rpivid via v4l2-request (Pi OS's mpv) | Rockchip MPP — needs an **MPP-enabled mpv** (see below) |
| HDMI-CEC | `/dev/cec0` (vc4-kms) | `/dev/cec0` (dw-hdmi) — likely enabled by the vendor device tree, unconfirmed |
| Boot config | `config.txt` (written by `setup.sh`) | `/boot/armbianEnv.txt` (left as shipped) |
| Image | `jellyby-pi4.img.xz`, Imager, PINN | `jellyby-zero3.img.xz` (flash with Etcher / `dd`) |
| RAM | 2 GB+ | 1 GB works but is tight (Chromium + 4K mpv) — 2 GB+ preferred |

`setup.sh` detects the board by itself and installs the matching mpv
hardware-decode profile. ZERO 3 install steps:
[Option D](#option-d--radxa-zero-3e3w-experimental-untested-on-hardware).

## Architecture

```
 remote --HDMI-CEC--> Pi 4
                        │
 ┌──────────────────────┼────────────────────────────────────────────┐
 │ cec-kbd (/dev/cec* → /dev/uinput) → Xorg+openbox → Chromium kiosk  │
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
| CEC remote → keyboard | `cec-kbd` | small C daemon on the kernel CEC API (`/dev/cec*`), injects keys via uinput |
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
3. Flash, then boot the Pi with the display on **HDMI0** (the micro-HDMI port
   next to the USB-C power socket — audio goes there by default) and Ethernet
   (or the Wi-Fi set in step 2).

> The image ships with SSH enabled and a default login **pi / jellyby** unless
> you set your own user in Imager. Change it immediately (`passwd` or SSH keys).

### Option B — build on a stock Raspberry Pi OS Lite

1. Flash **Raspberry Pi OS Lite (64-bit, Trixie or Bookworm)** with SSH enabled.
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

Optional: `sudo JELLYBY_THEATER=1 ./setup.sh` also installs Jellyfin Media
Player (flatpak) / Emby Theater (.deb). System mpv stays the decode path either
way.

### Option C — PINN multiboot entry

Each release also ships [PINN](https://github.com/procount/pinn) assets, so
Jellyby can sit alongside other OSes on one SD card:

1. Add the Jellyby list to PINN's options, on the **same single line** as
   the existing ones (space-separated):

   ```
   alt_image_source=http://github.com/pierrepaap/Jellyby/releases/latest/download/os_list_v3.json
   ```

   - Use **`http://`**, not `https://`: PINN silently drops
     `alt_image_source` URLs that don't start with `http://`. GitHub
     redirects to https and PINN follows the redirect.
   - Only the **last** `alt_image_source` on the line is used.
   - Either edit `recovery.cmdline` on PINN's partition from another
     computer, or from a running PINN: Maintenance menu → select the
     **PINN** entry → **Edit Config** → `cmdline.txt` tab (or **Edit
     Options** → `alt_image_source`), save, then reboot PINN.
2. Reboot PINN with the network connected — **Jellyby** appears in the OS
   list (tab "Media"). It is only listed on a Pi 4, Pi 400 or CM4.
3. **Empty card / reinstall everything:** tick it with any other OSes and
   press Install. ⚠️ Install erases every OS already on the card.
4. **Add it to a card that already has OSes** — replace a Project Space or
   an OS you no longer want:
   1. On the Main Menu, tick **Jellyby** (do *not* press Install).
   2. Switch to the Maintenance toolbar (`more` button, or `M`), select the
      Project Space / OS to replace, and press **Replace**.
   3. In the dialog, choose **Jellyby** in the drop-down next to it, then OK.

   The target must have two partitions (FAT boot + ext4 root) and be big
   enough: about 70 MB of boot data and ~3.2 GB of root data. A default
   Project Space (100 MB FAT + 500 MB ext4) only fits if its ext4 grew into
   the free space on the card. Other OSes are left untouched.
5. PINN writes the partitions and runs `partition_setup.sh`, which rewrites
   `cmdline.txt`/`fstab` to the new partitions. The rootfs expands on first
   boot.

**Offline install (no network in PINN):** download `os.json`,
`partitions.json`, `partition_setup.sh`, `boot.tar.xz`, `root.tar.xz`,
`Jellyby.png` and `marketing.tar` from the release into `os/Jellyby/` at the
root of either **PINN's own FAT partition** or the **first partition of a USB
stick**. PINN looks for one tarball per partition named after its label, so
the root tarball must be called `root.tar.xz` (releases up to v0.6.2 ship it
as `rootfs.tar.xz` — rename it).

### Option D — Radxa ZERO 3E/3W (experimental, untested on hardware)

You need: the board, a microSD card (16 GB+), a **micro-HDMI** cable to the
display, Ethernet (the 3E has no Wi-Fi), and a USB-C power supply.

There are two ways in. **D1** is simplest but only works once a release has
been published with a `jellyby-zero3.img.xz` asset; **D2** works today.

#### D1 — prebuilt image

1. Download `jellyby-zero3.img.xz` from the
   [latest release](https://github.com/pierrepaap/Jellyby/releases/latest).
2. Flash it with [balenaEtcher](https://etcher.balena.io/) (or Raspberry Pi
   Imager → *Use custom*), or from Linux:
   `xz -dc jellyby-zero3.img.xz | sudo dd of=/dev/sdX bs=4M status=progress`.
3. Boot the board with HDMI + Ethernet. Find its IP on your router and log in:
   `ssh pi@<ip>` — password **jellyby** (root is locked). Change it: `passwd`.
4. Continue with [First checks](#first-checks-on-the-zero-3) below.

#### D2 — install on top of Armbian

1. **Flash Armbian.** From the
   [Armbian Radxa ZERO 3 page](https://www.armbian.com/radxa-zero-3/), download
   a **minimal / server** image with the **vendor** kernel (Debian Trixie or
   Bookworm) and flash it to the microSD as above.
2. **First boot.** Boot with HDMI + Ethernet, then `ssh root@<ip>`
   (password `1234`). Armbian's first-login wizard asks for a new root password
   and lets you create your own user — do that, then log in as that user.
3. **Install Jellyby:**

   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/pierrepaap/Jellyby.git
   cd Jellyby
   sudo ./setup.sh
   sudo reboot
   ```

   `setup.sh` detects the board by itself. It installs everything, puts the
   decoder/CEC device nodes in the `video` group (udev rule) and holds the
   kernel packages so an upgrade can't drop the vendor kernel.
4. After the reboot the launcher appears on HDMI. Continue with the checks.

> **Video decoding.** Without extra steps, Jellyby uses Debian's mpv, which
> **cannot** use the RK3566 hardware decoder: playback works but decodes in
> software (fine for 1080p H.264, too slow for 4K/HEVC). Once you have .deb
> packages of an mpv built against
> [ffmpeg-rockchip](https://github.com/nyanmisaka/ffmpeg-rockchip), re-run the
> installer with them — it is safe to re-run:
>
> ```bash
> cd ~/Jellyby
> sudo JELLYBY_MPV_DEBS="/home/me/debs/mpv_*.deb /home/me/debs/libmpv2_*.deb" ./setup.sh
> ```
>
> See [Settings reference](#settings-reference) for what this variable takes.

#### First checks on the ZERO 3

Over SSH:

```bash
ls /dev/cec0 /dev/mpp_service /dev/rga /dev/dma_heap   # CEC + decoder device nodes exist?
cec-ctl -d /dev/cec0 --show-topology                   # TV and other HDMI devices visible?
journalctl -u cec-kbd -b                               # adapter opened, address claimed, keys
aplay -l                                               # HDMI audio card name
mpv --hwdec=rkmpp --msg-level=vd=v <video-file>        # look for "Using hardware decoding (rkmpp)"
```

- `/dev/cec0` missing → the board's device tree needs a CEC overlay
  (`overlays=...` in `/boot/armbianEnv.txt`); the remote won't work until then.
  A keyboard plugged into the board works meanwhile.
- Keys don't arrive → see [CEC remote mapping](#cec-remote-mapping).
- No "Using hardware decoding" line → mpv is not MPP-enabled (see the
  video decoding note above).

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

No browser on these boards can hardware-decode HEVC/H.265 — only mpv/ffmpeg
can. On the Pi 4 that goes through the kernel's rpivid V4L2 stateless decoder,
which requires `dtoverlay=vc4-kms-v3d` and `gpu_mem=256` in `config.txt`
(`setup.sh` adds them); on the Radxa ZERO 3 through Rockchip MPP (see
[Supported boards](#supported-boards)). So each app in
`/etc/jellyby/apps.json` is **typed**:

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
  `/opt/jellyby/mpv/mpv.conf` (`vo=gpu`, fullscreen) plus the board's hwdec
  profile `board.conf` (`drm` on Pi 4, `rkmpp` on ZERO 3). The
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

After editing: `sudo systemctl restart cec-kbd`.

`cec-kbd` talks to the kernel's CEC devices (`/dev/cec0`, plus `/dev/cec1`
for the Pi 4's second HDMI port) directly. It registers as a playback device
named **Jellyby** and answers the TV's routing queries, so the TV sends the
remote's keys to it.

**Debugging:**

- `journalctl -u cec-kbd -f` shows the adapter it opened, its HDMI address,
  and every key received (`CEC key 0x01 -> up`, or `unmapped CEC key 0x..`
  for buttons you can then add to the keymap).
- No keys at all → on the TV, enable HDMI-CEC (brand names: Anynet+, SimpLink,
  Bravia Sync, …) and select the Jellyby input once.
- Low-level view of the bus: `cec-ctl -d /dev/cec0 --monitor` (from
  `v4l-utils`; stop `cec-kbd` first).

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

## Settings reference

All Jellyby options are environment variables. They are **optional** — the
defaults are right for a normal install. There are three places they go:

**1. On the command line of `setup.sh`** (on the board, at install time — put
them *after* `sudo` so sudo keeps them), e.g.
`sudo JELLYBY_THEATER=1 ./setup.sh`. Re-running `setup.sh` with different
values is safe.

| Variable | Default | Effect |
|---|---|---|
| `JELLYBY_BOARD` | auto-detected | `pi4` or `zero3`. Only needed if detection fails (you'll be asked) |
| `JELLYBY_MPV_DEBS` | empty | ZERO 3 only: space-separated paths or URLs of MPP-enabled mpv/ffmpeg `.deb`s to install instead of Debian's mpv |
| `JELLYBY_HOLD_KERNEL` | `1` | ZERO 3 only: `0` = don't `apt-mark hold` the kernel packages |
| `JELLYBY_THEATER` | `0` | `1` = also install Jellyfin Media Player (flatpak) / Emby Theater |
| `JELLYBY_OFFLINE` | `0` | CI only (image build in a chroot) — don't set by hand |

**2. In the `cec-kbd` service** (on the board, any time):

| Variable | Default | Effect |
|---|---|---|
| `CEC_KBD_ACTIVATE` | `0` | `1` = at start, turn the TV on and switch it to the Jellyby input |
| `CEC_KBD_PORT` | all `/dev/cec0`–`3` | only use these CEC devices, e.g. `/dev/cec0` |

```bash
sudo systemctl edit cec-kbd
#   add these lines, save:
#   [Service]
#   Environment=CEC_KBD_ACTIVATE=1
sudo systemctl restart cec-kbd
```

**3. As GitHub repository variables** (only if you build release images: on
GitHub → repo **Settings → Secrets and variables → Actions → Variables** tab →
*New repository variable*). They're read by the image build when a release
is published:

| Variable | Default | Effect |
|---|---|---|
| `ZERO3_BASE_IMAGE_URL` | `https://dl.armbian.com/radxa-zero3/Trixie_vendor_minimal` | Armbian image the ZERO 3 build starts from — set it if the default link stops working |
| `ZERO3_MPV_DEBS` | empty | URLs of MPP-enabled mpv/ffmpeg `.deb`s baked into the ZERO 3 image (same as `JELLYBY_MPV_DEBS`) |

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
sudo bash scripts/check-image.sh jellyby-pi4.img            # pi4 (default)
sudo bash scripts/check-image.sh jellyby-zero3.img zero3
```

Mounts the image and verifies boot config, installed binaries, enabled
services, permissions and JSON configs. This is what gates releases in CI.

### Booting the image in QEMU (manual, not in CI)

Pi image only. `scripts/test-image-qemu.sh` boots a resized copy of the image, waits for SSH
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

### What can only be verified on real hardware

HEVC (incl. 10-bit) hardware decode in mpv, HDMI-CEC remote pairing, actual
playback of your library, readsb with a dongle. Useful checks over SSH on a
Pi 4: `mpv --msg-level=vd=v <file>` (look for "Using hardware decoding
(drm)"; HEVC only — H.264 decodes in software), `v4l2-ctl --list-devices`
(should list `rpivid`), `speaker-test -c2 -t wav` (sound on the TV), and
`journalctl -u cec-kbd -f` while pressing remote buttons. For the ZERO 3, see
[First checks on the ZERO 3](#first-checks-on-the-zero-3).

## Release pipeline

- **[`lint.yml`](.github/workflows/lint.yml)** runs on every push/PR:
  shellcheck, Python / JS / JSON syntax checks, and two hardware-free tests:
  - `tests/cec_kbd_sim.c`: `cec-kbd` against a simulated kernel CEC adapter
    (address claim, replies to the TV, key → keyboard translation);
  - `tests/test_server.py`: the launcher API against a fake Jellyfin server
    (config save, browse, poster proxy, play → `play.sh` arguments, token
    caching, network input validation).

  Run them locally: `python3 -m unittest discover -s tests -v` and
  `gcc -o /tmp/sim tests/cec_kbd_sim.c && /tmp/sim files/etc/jellyby/cec-keymap.conf`.
- **[`release-image.yml`](.github/workflows/release-image.yml)** runs when a
  GitHub release is **published** (Releases → New release → tag e.g. `v0.5.0`
  → Publish). One job per board (`pi4`, `zero3`), each of which:
  1. downloads the base image (latest Pi OS Lite 64-bit / Armbian vendor) and
     grows it;
  2. sets up SSH and the default user `pi / jellyby` (on the ZERO 3 it also
     skips Armbian's first-login wizard and locks root);
  3. runs `setup.sh` in a chroot under `qemu-user-static`
     (`JELLYBY_OFFLINE=1 JELLYBY_BOARD=<board>`);
  4. shrinks it with PiShrink (auto-expands on first boot) and compresses it;
  5. gates on `scripts/check-image.sh <image> <board>`;
  6. Pi only: packs the PINN assets and the Imager JSON (with size + sha256);
  7. attaches the image(s) to the release.

  The `zero3` job is **experimental**: if it fails, the Pi image still
  publishes. It can be tuned with GitHub repository variables, see
  [Settings reference](#settings-reference).

  **Test build without a release:** Actions tab → *release-image* → *Run
  workflow* → pick a branch. Same build and checks, but nothing is published:
  the images are attached to the run as downloadable artifacts
  (`jellyby-pi4-image`, `jellyby-zero3-image`, kept 14 days).

## Security notes

- The prebuilt images' default login is **pi / jellyby** — change it on first
  boot, use SSH keys, or set your own user in Imager (Pi). On the ZERO 3 image,
  Armbian's default root password is locked.
- Kiosk Chromium runs **with its sandbox** (no `--no-sandbox`), relying on
  unprivileged user namespaces (default on Pi OS Bookworm and later), since it loads
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
  etc/udev/rules.d/            Rockchip decoder/CEC device permissions (ZERO 3 only)
  etc/X11/xorg.conf.d/         Xorg config
  etc/default/readsb           readsb options
  opt/jellyby/                 server.py, mediaclient.py, resolve_stream.py, play.sh,
                               netapply.sh, kiosk.sh, cec_kbd.c, www/ (launcher UI),
                               mpv/ (mpv.conf + board-pi4.conf / board-zero3.conf hwdec profiles)
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
