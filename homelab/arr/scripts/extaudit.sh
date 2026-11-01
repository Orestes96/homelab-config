#!/usr/bin/env bash
# Nightly: report any file under /srv/media/digital with an extension not on the allow list.
# Book files (epub, pdf) are allowed only inside downloads/books.
set -u
TOPIC=$(cat "$HOME/.ntfy-rips-topic")
LOG="$HOME/homelab/arr/scripts/extaudit.log"
ROOT="/srv/media/digital"

BAD=$(find "$ROOT" -type f ! -path "$ROOT/downloads/quarantine/*" \
  ! \( -path "$ROOT/downloads/books/*" \( -iname '*.epub' -o -iname '*.pdf' \) \) \
  ! -iname '*.mkv' ! -iname '*.mp4' ! -iname '*.m4v' ! -iname '*.avi' ! -iname '*.mov' ! -iname '*.webm' ! -iname '*.ts' \
  ! -iname '*.srt' ! -iname '*.ass' ! -iname '*.sub' ! -iname '*.idx' ! -iname '*.nfo' ! -iname '*.jpg' ! -iname '*.png' \
  ! -iname '*.torrent' ! -iname '*.!qB' ! -iname '.*' \
  ! -iname '*_meta.xml' ! -iname '*_meta.sqlite' ! -iname '*_files.xml' 2>/dev/null)

if [ -n "$BAD" ]; then
  N=$(echo "$BAD" | wc -l)
  echo "$(date -Is) $N unexpected file(s):" >> "$LOG"
  echo "$BAD" >> "$LOG"
  curl -s -H "Title: Extension audit" -H "Priority: high" -d "$N unexpected file(s) under digital/. First: $(echo "$BAD" | head -n 1)" "https://ntfy.sh/$TOPIC" >/dev/null
fi
