#!/bin/bash
# Alerts (phone push via ntfy) when the network-asset backup is broken.
# Checks the failure modes that actually matter, not just "did the job run":
#   1. backup commits made locally but never pushed to GitHub
#   2. no successful backup run recently (job stopped, or failing)
#   3. GitHub unreachable, so the check itself can't be trusted
# Run with --test to send a test notification to your phone.

REPO="/home/elliot/homelab/network-asset-backups"
LOG="/home/elliot/homelab/logs/backup.log"
TOPIC_FILE="$HOME/.ntfy-topic"
MAX_RUN_AGE_HOURS=8

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

problems=()

# 1. unpushed commits (compare local main against GitHub's main)
if git -C "$REPO" fetch --quiet origin 2>/dev/null; then
  ahead=$(git -C "$REPO" rev-list --count origin/main..HEAD)
  if [ "$ahead" -gt 0 ]; then
    problems+=("$ahead backup commit(s) not pushed to GitHub")
  fi
else
  problems+=("cannot reach GitHub to check the backup repo")
fi

# 2. last successful run (a failed push leaves no success line at all)
if [ ! -f "$LOG" ]; then
  problems+=("backup log is missing")
else
  last_time=$(grep -E "no changes, skipping commit|backup committed and pushed" "$LOG" \
    | grep -oE '^[0-9T:-]+Z' | tail -1)
  if [ -z "$last_time" ]; then
    problems+=("backup has never succeeded")
  else
    age_hours=$(( ($(date +%s) - $(date -d "$last_time" +%s)) / 3600 ))
    if [ "$age_hours" -gt "$MAX_RUN_AGE_HOURS" ]; then
      problems+=("no successful backup run for $age_hours hours")
    fi
  fi
fi

if [ ${#problems[@]} -gt 0 ]; then
  notify "network-asset backup problem: $(printf '%s; ' "${problems[@]}")"
  exit 1
fi
