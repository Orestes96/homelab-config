#!/bin/bash
set -euo pipefail

CONTAINER="quiz-platform-production"
REPO="/home/elliot/homelab/quiz-platform-backups"
DEST="$REPO/production.db"

docker exec "$CONTAINER" python -c "
import sqlite3
s = sqlite3.connect('quiz_platform.db')
d = sqlite3.connect('/tmp/backup.db')
s.backup(d)
s.close()
d.close()
"
docker cp "$CONTAINER:/tmp/backup.db" "$DEST"
docker exec "$CONTAINER" rm /tmp/backup.db

cd "$REPO"
git add production.db

if git diff --cached --quiet; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - no changes, skipping commit"
else
  git commit -m "Backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git push origin main
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - backup committed and pushed"
fi
