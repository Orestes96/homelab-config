#!/bin/bash
# check-services-backup-health: exits 1 if the services restic repository
# in B2 can't be reached or fails an integrity check. Freshness is covered by
# the services-backup job's own mark-success alert.
ENV_FILE="/home/elliot/.config/restic/services.env"

fail() {
  logger -t services-backup-health "WARNING: $1"
  printf 'Problem: %s\nHow to fix it: %s\nWhat changed: Nothing. This check only reads.\n' "$1" "$2" >&2
  exit 1
}

if [ ! -r "$ENV_FILE" ]; then
  fail "The restic settings file $ENV_FILE is missing or unreadable." "Check it exists and belongs to you: ls -l $ENV_FILE"
fi
source "$ENV_FILE"

restic check --read-data-subset=5% --quiet \
  || fail "restic check failed for the services repository." "See the full report with: bash -c 'source $ENV_FILE && restic check'"

exit 0
