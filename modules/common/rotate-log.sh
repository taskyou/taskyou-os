#!/usr/bin/env bash
# Rotate a poller log once it outgrows a size cap, keeping one generation.
#
# Poller logs are append-only and nothing else prunes them: one box was found
# with 487MB across four unrotated poll logs (one of them 178MB, from a poller
# that was rate-limited on every cycle). Cron calls this before each run.
#
# Usage: rotate-log.sh <logfile> [max-bytes]   (default cap: 10MB)

set -u
log="${1:?usage: rotate-log.sh <logfile> [max-bytes]}"
max="${2:-10485760}"

[ -f "$log" ] || exit 0

size=$(wc -c < "$log" | tr -d '[:space:]')
[ "$size" -gt "$max" ] || exit 0

mv -f "$log" "$log.1"
: > "$log"
