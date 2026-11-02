#!/bin/bash
# readsb wrapper: reads /etc/default/readsb and appends an optional
# --net-connector push target (READSB_REMOTE_HOST / READSB_REMOTE_PORT).
set -euo pipefail

# shellcheck source=/dev/null
source /etc/default/readsb

OPTS="${READSB_OPTIONS:-}"

if [[ -n "${READSB_REMOTE_HOST:-}" ]]; then
  OPTS="$OPTS --net-connector ${READSB_REMOTE_HOST},${READSB_REMOTE_PORT:-30005},beast_out"
fi

# shellcheck disable=SC2086
exec /usr/local/bin/readsb $OPTS
