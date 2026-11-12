#!/bin/bash
# Hardened apt update+install for GitHub runners.
# - avoid azure.archive.ubuntu.com (its DNS is flaky on GH runners right now)
# - bounded timeouts + retries so a network blip fails fast and is retried
# Usage: sudo bash scripts/ci-apt.sh <package> [package...]
set -euo pipefail

sudo sed -i 's|azure\.archive\.ubuntu\.com|archive.ubuntu.com|g' \
  /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true

APTOPTS=(-o Acquire::Retries=5 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 -o Acquire::DNS::Timeout=10)

updated=0
for i in 1 2 3 4 5; do
  if sudo apt-get "${APTOPTS[@]}" update; then updated=1; break; fi
  echo "apt-get update attempt $i failed; retrying in 15s" >&2
  sleep 15
done
if [ "$updated" -ne 1 ]; then
  echo "apt-get update failed after 5 attempts (proceeding with cached lists)" >&2
fi

for i in 1 2 3 4 5; do
  # no --fix-missing on purpose: a partially fetched package set must count as
  # failure so the retry loop re-runs (v0.4.3: --fix-missing returned 0 while
  # qemu-user-static was skipped -> qemu-aarch64-static missing later)
  if sudo apt-get install -y "${APTOPTS[@]}" "$@"; then exit 0; fi
  echo "apt-get install attempt $i failed; retrying in 15s" >&2
  sleep 15
done

echo "apt-get install failed after 5 attempts" >&2
exit 1
