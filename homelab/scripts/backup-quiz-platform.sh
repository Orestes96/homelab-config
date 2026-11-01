#!/bin/bash
# backup-quiz-platform: takes a consistent snapshot of the quiz-platform
# production database and sends it to the restic repository in Backblaze B2.
set -euo pipefail

CONTAINER="quiz-platform-production"
STAGE="/home/elliot/homelab/quiz-restic"
DEST="$STAGE/production.db"

source /home/elliot/.config/restic/quiz.env

mkdir -p "$STAGE"

# Consistent snapshot via SQLite's backup API inside the container
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

restic backup "$DEST" --tag quiz-platform --host homelab-01 --quiet

# Retention runs once a day, on the midnight run
if [ "$(date -u +%H)" = "00" ]; then
  restic forget --tag quiz-platform --group-by host,tags \
    --keep-last 4 --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
    --prune --quiet
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - backup sent to restic"
