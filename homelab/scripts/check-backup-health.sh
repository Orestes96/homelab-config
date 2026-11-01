#!/bin/bash
# Alerts (phone push via ntfy) when the network-asset backup repository in B2
# can't be reached or fails an integrity check. Freshness is covered by the
# network-asset-backup job's own mark-success alert.
# Run with --test to send a test notification to your phone.

TOPIC_FILE="$HOME/.ntfy-topic"

notify() {
  local msg="$1"
  logger -t backup-health "$msg"
  if [ -f "$TOPIC_FILE" ]; then
    curl -s -H "Title: network-asset backup" -H "Priority: high" \
      -d "$msg" "https://ntfy.sh/$(cat "$TOPIC_FILE")" > /dev/null
  fi
}

if [ "$1" = "--test" ]; then
  notify "TEST: backup health alerts are working"
  echo "test notification sent"
  exit 0
fi

source /home/elliot/.config/restic/network-asset.env

if ! restic check --read-data-subset=10% --quiet; then
  notify "network-asset backup problem: restic check failed for the B2 repository"
  exit 1
fi

exit 0
