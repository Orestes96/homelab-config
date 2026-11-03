#!/bin/bash
# autoheal: restarts containers that Docker marks unhealthy, then any container
# that shares the healed container's network (such as qbittorrent behind gluetun).
# Gives up on a container after MAX_RESTARTS restarts within WINDOW seconds, and
# reports restarts and give-ups through node-exporter so Alertmanager can tell you.
# Usage: autoheal.sh [--dry-run]
set -euo pipefail

MAX_RESTARTS=3
WINDOW=21600          # 6 hours
STOP_TIMEOUT=30       # seconds a container gets to stop cleanly
SKIP=()               # names never to restart, for example: SKIP=(quiz-platform-ci-runner)
STATE="/home/elliot/.local/state/autoheal"
TEXTFILE="/var/lib/node_exporter/textfile/autoheal.prom"
SELF="/home/elliot/homelab/monitoring/scripts/autoheal.sh"

fail() {
  logger -t autoheal "FAILED: $1"
  printf 'Problem: %s\nHow to fix it: %s\nWhat changed: %s\n' "$1" "$2" "${3:-Nothing.}" >&2
  exit 1
}

say() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1"
  logger -t autoheal "$1"
}

is_skipped() {
  local n
  for n in "${SKIP[@]}"; do
    if [ "$n" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

if [ "$#" -gt 1 ]; then
  fail "Too many options: $*" "Use at most one option: $SELF --dry-run"
fi

dry=0
case "${1:-}" in
  "") ;;
  --dry-run) dry=1 ;;
  -n|--dryrun|--dry|dry-run|-dry-run) fail "Unknown option: $1" "Did you mean --dry-run? Run: $SELF --dry-run" ;;
  *) fail "Unknown option: $1" "Run it with no options, or preview without restarting anything: $SELF --dry-run" ;;
esac

if ! docker info >/dev/null 2>&1; then
  fail "Can't talk to Docker." "Check Docker is running with: systemctl status docker"
fi
mkdir -p "$STATE" || fail "Can't create the state folder $STATE." "Check your home folder has space and is yours: df -h ~ ; ls -ld ~/.local"
if [ ! -w "$(dirname "$TEXTFILE")" ]; then
  fail "Can't write to $(dirname "$TEXTFILE")." "Check the folder exists and is yours with: ls -ld $(dirname "$TEXTFILE")"
fi

now=$(date +%s)

# Forget restarts older than the window
if [ "$dry" -eq 0 ]; then
  for f in "$STATE"/*; do
    if [ ! -f "$f" ]; then
      continue
    fi
    awk -v cutoff=$((now - WINDOW)) '$1 >= cutoff' "$f" > "$f.tmp"
    mv "$f.tmp" "$f"
    if [ ! -s "$f" ]; then
      rm -f "$f"
    fi
  done
fi

gave_up=()
mapfile -t unhealthy < <(docker ps --filter health=unhealthy --format '{{.Names}}')

if [ "${#unhealthy[@]}" -eq 0 ] && [ "$dry" -eq 1 ]; then
  say "DRY RUN: no unhealthy containers, nothing to do"
fi

for name in "${unhealthy[@]}"; do
  if is_skipped "$name"; then
    say "$name is unhealthy but is in SKIP, leaving it alone"
    continue
  fi

  count=0
  if [ -f "$STATE/$name" ]; then
    count=$(wc -l < "$STATE/$name")
  fi
  if [ "$count" -ge "$MAX_RESTARTS" ]; then
    gave_up+=("$name")
    say "$name is still unhealthy after $count restarts in the last $((WINDOW / 3600)) hours, not restarting it again"
    continue
  fi

  id=$(docker inspect -f '{{.Id}}' "$name")
  mapfile -t deps < <(docker inspect --format '{{.Name}} {{.HostConfig.NetworkMode}}' $(docker ps -q) \
    | awk -v a="container:$id" -v b="container:$name" '$2 == a || $2 == b { sub(/^\//, "", $1); print $1 }')

  if [ "$dry" -eq 1 ]; then
    if [ "${#deps[@]}" -gt 0 ]; then
      say "DRY RUN: would restart $name, then ${deps[*]}"
    else
      say "DRY RUN: would restart $name"
    fi
    continue
  fi

  say "Restarting $name (unhealthy)"
  echo "$now" >> "$STATE/$name"
  if ! docker restart -t "$STOP_TIMEOUT" "$name" >/dev/null; then
    say "Restart of $name failed"
    continue
  fi
  for d in "${deps[@]}"; do
    say "Restarting $d (shares $name's network)"
    docker restart -t "$STOP_TIMEOUT" "$d" >/dev/null || say "Restart of $d failed"
  done
done

if [ "$dry" -eq 1 ]; then
  exit 0
fi

# Publish metrics for Alertmanager
tmp="$(mktemp "${TEXTFILE}.XXXXXX")"
{
  echo "# HELP autoheal_last_restart_timestamp_seconds When autoheal last restarted the container."
  echo "# TYPE autoheal_last_restart_timestamp_seconds gauge"
  for f in "$STATE"/*; do
    if [ -f "$f" ]; then
      echo "autoheal_last_restart_timestamp_seconds{container=\"$(basename "$f")\"} $(tail -n 1 "$f")"
    fi
  done
  echo "# HELP autoheal_gave_up 1 if the container is still unhealthy and autoheal has stopped restarting it."
  echo "# TYPE autoheal_gave_up gauge"
  for n in "${gave_up[@]}"; do
    echo "autoheal_gave_up{container=\"$n\"} 1"
  done
} > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$TEXTFILE"
