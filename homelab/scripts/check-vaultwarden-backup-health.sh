#!/bin/bash
# check-vaultwarden-backup-health: exits 1 if the vaultwarden restic repository
# in B2 can't be reached or fails an integrity check. Freshness is covered by
# the vaultwarden-backup job's own mark-success alert.
ENV_FILE="/home/elliot/.config/restic/vaultwarden.env"

fail() {
  logger -t vaultwarden-backup-health "WARNING: $1"
  printf 'Problem: %s\nHow to fix it: %s\nWhat changed: Nothing. This check only reads.\n' "$1" "$2" >&2
  exit 1
}

if [ ! -r "$ENV_FILE" ]; then
  fail "The restic settings file $ENV_FILE is missing or unreadable." "Check it exists and belongs to you: ls -l $ENV_FILE"
fi
source "$ENV_FILE"

restic check --read-data-subset=10% --quiet \
  || fail "restic check failed for the vaultwarden repository." "See the full report with: bash -c 'source $ENV_FILE && restic check'"

exit 0
