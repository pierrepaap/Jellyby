#!/bin/sh
# netapply.sh <interface> <dhcp|static> [address/cidr gateway dns,csv]
# Applies a network config through NetworkManager.
# Called by server.py (/api/network) as the unprivileged kiosk user: the
# changing nmcli calls then go through "sudo -n", which /etc/sudoers.d/jellyby
# allows for these specific nmcli subcommands only (no blanket root).
# Also usable over SSH for recovery (already root, no sudo needed):
#   sudo /opt/jellyby/netapply.sh eth0 dhcp        # revert to DHCP
set -eu

NMCLI=/usr/bin/nmcli
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo -n"
fi

iface="$1"
mode="$2"
shift 2

con=$($NMCLI -t -f NAME,DEVICE connection show --active | awk -F: -v d="$iface" '$2 == d {print $1; exit}')
if [ -z "$con" ]; then
  # no active profile for this device: create one for ethernet; wifi needs an
  # existing profile (SSID/password) — set it up once with nmtui over SSH.
  if [ "$(cat "/sys/class/net/$iface/type" 2>/dev/null)" = "1" ]; then
    $SUDO $NMCLI connection add type ethernet ifname "$iface" con-name "jellyby-$iface" autoconnect yes
    con="jellyby-$iface"
  else
    echo "no active connection on $iface and it is not ethernet; create a wifi profile first (nmtui)" >&2
    exit 2
  fi
fi

if [ "$mode" = "dhcp" ]; then
  $SUDO $NMCLI connection modify "$con" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
else
  addr="$1"
  gw="$2"
  dns="${3:-}"
  $SUDO $NMCLI connection modify "$con" ipv4.method manual ipv4.addresses "$addr" ipv4.gateway "$gw" ipv4.dns "$dns"
fi

$SUDO $NMCLI connection up "$con"
$SUDO $NMCLI device reapply "$iface" 2>/dev/null || true
echo "applied $mode on $iface (connection $con)"
