#!/bin/bash
# backup-services: backs up service settings to the "services" restic
# repository in Backblaze B2: the arr apps, Plex (without caches), AdGuard's
# settings, and the ebook library's database and project files (not the books).
#
# SQLite databases are copied with sqlite3's backup command, which gives a
# consistent copy while the apps keep running. The copies go into $STAGE under
# their original paths, and the live database files are left out of the backup.
#
# To restore: restore the snapshot, copy the files back, then copy each database
# from <restore folder>/home/elliot/homelab/services-restic/<original path>
# over the original. AdGuard's settings are in .../services-restic/adguard/.
#
# Usage: backup-services.sh   (no arguments)
set -euo pipefail
umask 077

ENV_FILE="/home/elliot/.config/restic/services.env"
STAGE="/home/elliot/homelab/services-restic"
SELF="/home/elliot/homelab/scripts/backup-services.sh"
SOURCES=(
  /home/elliot/homelab/arr
  /home/elliot/homelab/plex
  /home/elliot/ebooks
)
PLEX="/home/elliot/homelab/plex/config/Library/Application Support/Plex Media Server"
ADGUARD_CONF="/opt/adguardhome/conf/AdGuardHome.yaml"

fail() {
  logger -t services-backup "FAILED: $1"
  printf 'Problem: %s\nHow to fix it: %s\nWhat changed: %s\n' "$1" "$2" "${3:-Nothing was sent to B2.}" >&2
  exit 1
}

cleanup() {
  rm -rf -- "$STAGE"
}
trap cleanup EXIT

if [ "$#" -gt 0 ]; then
  fail "This script takes no arguments, but got: $*" "Run it on its own: $SELF"
fi

if [ ! -r "$ENV_FILE" ]; then
  fail "The restic settings file $ENV_FILE is missing or unreadable." "Check it exists and belongs to you: ls -l $ENV_FILE"
fi
source "$ENV_FILE"

for tool in restic sqlite3; do
  if ! command -v "$tool" >/dev/null; then
    fail "$tool isn't installed." "Install it with: sudo apt install $tool"
  fi
done

for src in "${SOURCES[@]}"; do
  if [ ! -d "$src" ]; then
    fail "The folder $src doesn't exist." "Check the path. If that service has gone, remove the line from SOURCES in $SELF"
  fi
done

state=$(docker inspect -f '{{.State.Status}}' adguard 2>/dev/null || echo "not found")
if [ "$state" != "running" ]; then
  fail "The adguard container isn't running (state: $state)." "Start it with: docker compose -f /home/elliot/homelab/adguard/docker-compose.yml up -d   then rerun: $SELF"
fi

rm -rf -- "$STAGE"
mkdir -p "$STAGE"

# 1. Consistent copies of every SQLite database
count=0
while IFS= read -r -d '' db; do
  dest="$STAGE$db"
  mkdir -p "$(dirname "$dest")"
  if ! sqlite3 -cmd ".timeout 10000" "$db" ".backup '$dest'"; then
    fail "Couldn't take a consistent copy of $db" "Check the database is readable and not damaged with: sqlite3 \"$db\" 'PRAGMA quick_check;'"
  fi
  count=$((count + 1))
done < <(find "${SOURCES[@]}" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -size +0 ! -name 'logs.db' -not -path '/home/elliot/ebooks/library-backup-3/*' -not -path '/home/elliot/ebooks/config-backup/*' -print0)

if [ "$count" -eq 0 ]; then
  fail "No databases were found in: ${SOURCES[*]}" "Check the folders still hold the apps' data with: ls ${SOURCES[*]}"
fi

# 2. AdGuard's settings (root-only on the host, so copied out of the container)
mkdir -p "$STAGE/adguard"
if ! docker cp -q "adguard:$ADGUARD_CONF" "$STAGE/adguard/AdGuardHome.yaml"; then
  fail "Couldn't copy AdGuard's settings out of the container." "Check where the image keeps them with: docker exec adguard ls /opt/adguardhome/conf   and update ADGUARD_CONF in $SELF"
fi

# 3. What to leave out: live databases (their copies are in $STAGE), caches and logs
EXCLUDES=()
for src in "${SOURCES[@]}"; do
  for ext in db db-wal db-shm db-journal sqlite sqlite-wal sqlite-shm sqlite3 sqlite3-wal sqlite3-shm; do
    EXCLUDES+=(--exclude "$src/**/*.$ext")
  done
done
EXCLUDES+=(
  --exclude "$PLEX/Cache" --exclude "$PLEX/Codecs" --exclude "$PLEX/Drivers"
  --exclude "$PLEX/Logs" --exclude "$PLEX/Crash Reports" --exclude "$PLEX/Diagnostics"
  --exclude "$PLEX/Updates" --exclude "$PLEX/plexmediaserver.pid"
  --exclude /home/elliot/ebooks/library-backup-3 --exclude /home/elliot/ebooks/config-backup
  --exclude /home/elliot/ebooks/ingest --exclude /home/elliot/ebooks/library --exclude /home/elliot/homelab/arr/lazylibrarian/log
  --exclude logs --exclude MediaCover
)

# 4. Send to B2
set +e
restic backup "${SOURCES[@]}" "$STAGE" "${EXCLUDES[@]}" --tag services --host homelab-01 --quiet
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
  fail "The backup was sent, but some files couldn't be read (they're listed just above)." "Make them readable, usually with: sudo chown -R elliot:elliot <folder>   then rerun: $SELF" "A snapshot was saved without the unreadable files."
elif [ "$rc" -ne 0 ]; then
  fail "restic couldn't send the backup to B2 (exit code $rc)." "Test the connection and keys with: bash -c 'source $ENV_FILE && restic snapshots'"
fi

# 5. Retention (this job runs once a day)
if ! restic forget --tag services --group-by host,tags \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune --quiet; then
  fail "The backup was sent, but pruning old snapshots failed." "Retry by hand with: bash -c 'source $ENV_FILE && restic forget --tag services --group-by host,tags --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune'" "Today's backup is safe in B2. Old snapshots weren't removed."
fi

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) - backup sent to restic ($count databases)"
