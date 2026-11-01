#!/bin/bash
# backup-network-asset: copies the network-asset production data, checks it
# is valid JSON, and sends it to the restic repository in Backblaze B2.
set -euo pipefail

SOURCE="/home/elliot/homelab/network-asset-poc/data/production.json"
STAGE="/home/elliot/homelab/network-asset-restic"
DEST="$STAGE/production.json"

source /home/elliot/.config/restic/network-asset.env

mkdir -p "$STAGE"

# Take a copy that parses as JSON, so a half-written file is never backed up
for attempt in 1 2 3; do
  cp "$SOURCE" "$DEST.tmp"
  if python3 -m json.tool "$DEST.tmp" > /dev/null 2>&1; then
    mv "$DEST.tmp" "$DEST"
    break
  fi
  rm -f "$DEST.tmp"
  if [ "$attempt" = "3" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - copy was not valid JSON after 3 attempts, backup skipped" >&2
    exit 1
  fi
  sleep 5
done

restic backup "$DEST" --tag network-asset --host homelab-01 --quiet

# Retention runs once a day, on the midnight run
if [ "$(date -u +%H)" = "00" ]; then
  restic forget --tag network-asset --group-by host,tags \
    --keep-last 4 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
    --prune --quiet
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - backup sent to restic"
