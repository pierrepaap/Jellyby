#!/bin/sh
#supports_backup in PINN
#
# Run by PINN after it has created and filled Jellyby's partitions.
# PINN passes the new partitions as $part1 (boot, FAT) and $part2 (root, ext4).
#
# - Point cmdline.txt and fstab at the new partitions, by PARTUUID when the
#   device has one (works from SD or USB boot), else by device path.
# - Drop Pi OS's first-boot resize hook from cmdline.txt: PINN has already
#   sized the root partition, Jellyby's root is usually not the last
#   partition on a multi-boot card (so the resize would fail), and the hook
#   may also change the card's disk ID, which would break the other OSes.

set -ex

if [ -z "$part1" ] || [ -z "$part2" ]; then
  printf "Error: missing environment variable part1 or part2\n" 1>&2
  exit 1
fi

# Prefer PARTUUID=...; fall back to the device path.
ref() {
  pu=$(blkid -o value -s PARTUUID "$1" 2>/dev/null || true)
  if [ -n "$pu" ]; then
    echo "PARTUUID=$pu"
  else
    echo "$1"
  fi
}
boot_ref=$(ref "$part1")
root_ref=$(ref "$part2")

mkdir -p /tmp/1 /tmp/2

mount "$part1" /tmp/1
mount "$part2" /tmp/2

sed /tmp/1/cmdline.txt -i \
  -e "s|root=[^ ]*|root=${root_ref}|" \
  -e "s| init=/usr/lib/raspberrypi-sys-mods/firstboot||" \
  -e "s| init=/usr/lib/raspi-config/init_resize\.sh||"
sed /tmp/2/etc/fstab -i -e "s|^[^#][^ \t]*\([ \t][ \t]*/[ \t]\)|${root_ref}\1|"
sed /tmp/2/etc/fstab -i -e "s|^[^#][^ \t]*\([ \t][ \t]*/boot/firmware[ \t]\)|${boot_ref}\1|"
sed /tmp/2/etc/fstab -i -e "s|^[^#][^ \t]*\([ \t][ \t]*/boot[ \t]\)|${boot_ref}\1|"

if [ -z "$restore" ]; then
  if [ -f /mnt/ssh ]; then
    cp /mnt/ssh /tmp/1/
  fi
  if [ -f /mnt/ssh.txt ]; then
    cp /mnt/ssh.txt /tmp/1/
  fi
  if [ -f /mnt/userconf.txt ]; then
    cp /mnt/userconf.txt /tmp/1/
  fi
  if [ -f /settings/wpa_supplicant.conf ]; then
    cp /settings/wpa_supplicant.conf /tmp/1/
  fi
fi

umount /tmp/1
umount /tmp/2
