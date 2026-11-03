#!/bin/bash
# backup-vaultwarden: takes a consistent copy of the Vaultwarden database with
# Vaultwarden's own backup command, then sends it, the token-signing key and any
# attachments or sends to the vaultwarden restic repository in Backblaze B2.
# Usage: backup-vaultwarden.sh   (no arguments)
set -euo pipefail
umask 077

CONTAINER="vaultwarden"
DATA="/home/elliot/vaultwarden-data"
STAGE="/home/elliot/homelab/vaultwarden-restic"
ENV_FILE="/home/elliot/.config/restic/vaultwarden.env"
SELF="/home/elliot/homelab/scripts/backup-vaultwarden.sh"
COMPOSE="/home/elliot/homelab/vaultwarden/docker-compose.yml"
SNAP=""

fail() {
  logger -t vaultwarden-backup "FAILED: $1"
  printf 'Problem: %s\nHow to fix it: %s\nWhat changed: %s\n' "$1" "$2" "${3:-Nothing was sent to B2.}" >&2
  exit 1
}

cleanup() {
  if [ -n "$SNAP" ]; then
    docker exec "$CONTAINER" rm -f "/data/$SNAP" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$STAGE"
}
trap cleanup EXIT

if [ "$#" -gt 0 ]; then
  fail "This script takes no arguments, but got: $*" "Run it on its own: $SELF"
fi

if [ ! -r "$ENV_FILE" ]; then
  fail "The restic settings file $ENV_FILE is missing or unreadable." "Check it exists and belongs to you: ls -l $ENV_FILE"
fi
source "$ENV_FILE"

if ! command -v restic >/dev/null; then
  fail "restic isn't installed." "Install it with: sudo apt install restic"
fi

state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "not found")
if [ "$state" != "running" ]; then
  fail "The $CONTAINER container isn't running (state: $state)." "Start it with: docker start $CONTAINER   or, if it no longer exists: docker compose -f $COMPOSE up -d   then rerun: $SELF"
fi

if ! out=$(docker exec "$CONTAINER" /vaultwarden backup 2>&1); then
  fail "Vaultwarden's backup command failed: $out" "Look at the container log with: docker logs --tail 50 $CONTAINER"
fi
SNAP=$(printf '%s\n' "$out" | sed -nE "s#.*'data/(db_[0-9_]+\.sqlite3)'.*#\1#p")
if [ -z "$SNAP" ]; then
  fail "Couldn't find the backup file name in Vaultwarden's reply: $out" "Vaultwarden may have changed its message. Run: docker exec $CONTAINER /vaultwarden backup   and compare the reply with the sed pattern in $SELF" "A db_*.sqlite3 copy may be left in $DATA. List it with: sudo ls -l $DATA"
fi

mkdir -p "$STAGE"
cp "$DATA/$SNAP" "$STAGE/db.sqlite3" || fail "Couldn't copy $DATA/$SNAP." "Check its permissions with: sudo ls -l $DATA"
cp "$DATA/rsa_key.pem" "$STAGE/" || fail "Couldn't copy $DATA/rsa_key.pem." "Check it exists with: sudo ls -l $DATA"
for d in attachments sends; do
  if [ -d "$DATA/$d" ]; then
    cp -r "$DATA/$d" "$STAGE/" || fail "Couldn't copy the $d folder." "Check its permissions with: sudo ls -la $DATA/$d"
  fi
done

if ! restic backup "$STAGE" --tag vaultwarden --host homelab-01 --quiet; then
  fail "restic couldn't send the backup to B2." "Test the connection and keys with: bash -c 'source $ENV_FILE && restic snapshots'"
fi

# Retention runs once a day, on the first run after midnight local time
if [ "$(date +%H)" = "00" ]; then
  if ! restic forget --tag vaultwarden --group-by host,tags \
      --keep-last 4 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
      --prune --quiet; then
    fail "The backup was sent, but pruning old snapshots failed." "Retry by hand with: bash -c 'source $ENV_FILE && restic forget --tag vaultwarden --group-by host,tags --keep-last 4 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune'" "Today's backup is safe in B2. Old snapshots weren't removed."
  fi
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - backup sent to restic"
