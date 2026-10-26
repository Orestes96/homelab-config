#!/bin/bash
# deploy.sh - one-command deploy for the network-asset containers.
# Usage: deploy.sh staging|production [--dry-run]
#   staging     builds the `staging` branch into network-asset-staging (port 3001)
#   production  builds the `main` branch into network-asset-production (port 3002)
# --dry-run prints what would run without changing anything.
set -euo pipefail

REPO="/home/elliot/homelab/network-asset-poc"
LOG="/home/elliot/homelab/logs/deploy.log"

env_name="${1:-}"
dry=0
[ "${2:-}" = "--dry-run" ] && dry=1

case "$env_name" in
  staging)    branch="staging"; service="network-asset-staging";    port=3001 ;;
  production) branch="main";    service="network-asset-production"; port=3002 ;;
  *) echo "usage: $0 staging|production [--dry-run]"; exit 2 ;;
esac

run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

cd "$REPO"

# never build on top of uncommitted changes to tracked files
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "ABORT: uncommitted changes to tracked files in $REPO:"
  git status --short --untracked-files=no
  exit 1
fi

git fetch --quiet origin
sha=$(git rev-parse --short "origin/$branch")

echo "Deploying $env_name from branch '$branch' at commit:"
git log --oneline -1 "origin/$branch"

if [ "$env_name" = "production" ] && [ "$dry" = 0 ]; then
  echo "Reminder: has CI passed on this commit? Production only ever builds from main."
  read -r -p "Type 'production' to continue: " answer
  [ "$answer" = "production" ] || { echo "cancelled"; exit 1; }
fi

run git checkout "$branch"
run git pull --ff-only origin "$branch"

if [ "$dry" = 0 ]; then
  current=$(git rev-parse --abbrev-ref HEAD)
  if [ "$current" != "$branch" ]; then
    echo "ABORT: checkout is on '$current', expected '$branch'"
    exit 1
  fi
fi

run docker compose up -d --build "$service"

status="dry-run"
if [ "$dry" = 0 ]; then
  status="FAILED-HEALTHCHECK"
  for i in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/" || true)
    if [ "$code" = "200" ]; then status="ok"; break; fi
    sleep 2
  done
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $env_name $sha $status" >> "$LOG"
  if [ "$status" = "ok" ]; then
    echo "OK: $env_name is up on port $port at $sha"
  else
    echo "WARNING: $env_name did not answer 200 on port $port. Check: docker logs $service"
  fi
  # leave the checkout on main so the default state is production-safe
  [ "$env_name" = "staging" ] && git checkout main
  [ "$status" = "ok" ] || exit 1
fi
