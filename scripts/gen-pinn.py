#!/usr/bin/env python3
"""Generate the PINN (procount/pinn) repository metafiles for a built Jellyby image.

Emits into --out: os_list_v3.json, os.json, partitions.json.
The partition tarballs, partition_setup.sh, Jellyby.png and marketing.tar are
copied in by the caller. All asset URLs point at the GitHub release "latest"
download folder so they stay stable across releases.
"""
import argparse
import hashlib
import json
import os

SUPPORTED_MODELS = ["Pi 4", "Pi 400", "Pi Compute Module 4"]
DESCRIPTION = ("Kiosk launcher for Emby / Jellyfin / Plex over HDMI-CEC remote, "
               "plus readsb ADS-B. SSH enabled, default login pi / jellyby.")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--boot-tar", required=True)
    ap.add_argument("--rootfs-tar", required=True)
    ap.add_argument("--boot-mib", type=int, required=True, help="used size of boot partition, MiB")
    ap.add_argument("--root-mib", type=int, required=True, help="used size of root partition, MiB")
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--date", required=True, help="YYYY-MM-DD")
    ap.add_argument("--version", required=True)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    boot_name = os.path.basename(args.boot_tar)
    root_name = os.path.basename(args.rootfs_tar)

    boot_bytes = os.path.getsize(args.boot_tar)
    root_bytes = os.path.getsize(args.rootfs_tar)
    download_size = boot_bytes + root_bytes

    boot_part_mib = max(512, args.boot_mib + 64)
    root_part_mib = args.root_mib + 400
    nominal_size = boot_part_mib + root_part_mib

    base = args.base_url.rstrip("/")
    partitions = {
        "partitions": [
            {
                "label": "boot",
                "filesystem_type": "fat",
                "partition_size_nominal": boot_part_mib,
                "want_maximised": False,
                "partition_type": "0xC",
                "uncompressed_tarball_size": args.boot_mib,
                "sha256sum": sha256_of(args.boot_tar),
            },
            {
                "label": "root",
                "filesystem_type": "ext4",
                "partition_size_nominal": root_part_mib,
                "want_maximised": True,
                "uncompressed_tarball_size": args.root_mib,
                "sha256sum": sha256_of(args.rootfs_tar),
            },
        ]
    }

    os_json = {
        "name": "Jellyby",
        "description": DESCRIPTION,
        "release_date": args.date,
        "supported_models": SUPPORTED_MODELS,
        "nominal_size": nominal_size,
        "supports_backup": True,
        "version": args.version,
        "url": "https://github.com/pierrepaap/Jellyby",
        "username": "pi",
        "password": "jellyby",
        "group": "Media",
        "download_size": download_size,
    }

    os_list = {
        "os_list": [
            {
                "os_name": "Jellyby",
                "description": DESCRIPTION,
                "group": "Media",
                "icon": f"{base}/Jellyby.png",
                "marketing_info": f"{base}/marketing.tar",
                "nominal_size": nominal_size,
                "download_size": download_size,
                "os_info": f"{base}/os.json",
                "partitions_info": f"{base}/partitions.json",
                "partition_setup": f"{base}/partition_setup.sh",
                "tarballs": [f"{base}/{boot_name}", f"{base}/{root_name}"],
                "release_date": args.date,
                "supported_models": SUPPORTED_MODELS,
                "supports_backup": True,
                "version": args.version,
            }
        ]
    }

    for name, doc in (("os.json", os_json), ("partitions.json", partitions),
                      ("os_list_v3.json", os_list)):
        with open(os.path.join(args.out, name), "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=2)
            f.write("\n")
    print(f"PINN metafiles written to {args.out}: nominal_size={nominal_size} MiB, "
          f"download_size={download_size} bytes")


if __name__ == "__main__":
    main()
