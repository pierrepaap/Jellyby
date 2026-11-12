#!/bin/sh
# netapply.sh <interface> <dhcp|static> [address/cidr gateway dns,csv]
# Applies a network config through NetworkManager. Runs as root via the
# narrow sudoers entries in /etc/sudoers.d/jellyby (specific nmcli commands).
# Called by server.py (/api/network); also usable over SSH for recovery:
#   sudo /opt/jellyby/netapply.sh eth0 dhcp        # revert to DHCP
set -eu

iface="$1"
mode="$2"
shift 2

con=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$iface" '$2 == d {print $1; exit}')
if [ -z "$con" ]; then
  # no active profile for this device: create one for ethernet; wifi needs an
  # existing profile (SSID/password) — set it up once with nmtui over SSH.
  if [ "$(cat "/sys/class/net/$iface/type" 2>/dev/null)" = "1" ]; then
    nmcli connection add type ethernet ifname "$iface" con-name "jellyby-$iface" autoconnect yes
    con="jellyby-$iface"
  else
    echo "no active connection on $iface and it is not ethernet; create a wifi profile first (nmtui)" >&2
    exit 2
  fi
fi

if [ "$mode" = "dhcp" ]; then
  nmcli connection modify "$con" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
else
  addr="$1"
  gw="$2"
  dns="${3:-}"
  nmcli connection modify "$con" ipv4.method manual ipv4.addresses "$addr" ipv4.gateway "$gw" ipv4.dns "$dns"
fi

nmcli connection up "$con"
nmcli device reapply "$iface" 2>/dev/null || true
echo "applied $mode on $iface (connection $con)"
