#!/bin/bash
set -euo pipefail

SOURCE="/home/elliot/homelab/network-asset-poc/data/production.json"
REPO="/home/elliot/homelab/network-asset-backups"
DEST="$REPO/data.json"

cp "$SOURCE" "$DEST"

cd "$REPO"
git add data.json

if git diff --cached --quiet; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - no changes, skipping commit"
else
  git commit -m "Backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git push origin main
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - backup committed and pushed"
fi
