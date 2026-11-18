#!/bin/bash
# Alerts (phone push via ntfy) when any restic repository in B2 (network-asset,
# quiz, vaultwarden, services) has lost its config file, or when the
# network-asset repository can't be reached or fails an integrity check. Freshness is covered by the
# network-asset-backup job's own mark-success alert.
# Run with --test to send a test notification to your phone.

TOPIC_FILE="$HOME/.ntfy-topic"

notify() {
  local msg="$1"
  logger -t backup-health "$msg"
  if [ -f "$TOPIC_FILE" ]; then
    curl -s -H "Title: B2 backups" -H "Priority: high" \
      -d "$msg" "https://ntfy.sh/$(cat "$TOPIC_FILE")" > /dev/null
  fi
}

if [ "$1" = "--test" ]; then
  notify "TEST: backup health alerts are working"
  echo "test notification sent"
  exit 0
fi

# Every restic repository in B2 must still have its config file. A repository
# deleted from B2 otherwise goes unnoticed until the next backup fails.
missing=()
for repo in network-asset quiz vaultwarden services; do
  env_file="/home/elliot/.config/restic/$repo.env"
  if ! ( source "$env_file" && restic cat config --no-lock >/dev/null 2>&1 ); then
    missing+=("$repo")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  notify "Problem: these restic repositories are missing or unreadable in B2: ${missing[*]}.
How to fix it: check each with: bash -c 'source ~/.config/restic/<name>.env && restic cat config'. If it's gone, find out why before recreating it with restic init.
What changed: Nothing. This check only reads."
  exit 1
fi

source /home/elliot/.config/restic/network-asset.env

if ! restic check --read-data-subset=10% --quiet; then
  notify "network-asset backup problem: restic check failed for the B2 repository"
  exit 1
fi

exit 0
