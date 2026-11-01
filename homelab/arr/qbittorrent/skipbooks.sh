#!/bin/sh
# Run by qBittorrent on torrent added. For torrents saving to the books
# folder, download only the .epub files. If there are none, download the
# .pdf files instead. Torrents with neither are stopped and tagged no-ebook.
HASH="$1"; SAVEPATH="$2"
API="http://127.0.0.1:8080/api/v2"

case "$SAVEPATH" in
  /data/digital/downloads/books|/data/digital/downloads/books/) ;;
  *) exit 0 ;;
esac

FILES=$(curl -s "$API/torrents/files?hash=$HASH" | tr '}' '\n')
[ -n "$FILES" ] || exit 1

pick() {
  echo "$FILES" | grep -iE "\"name\":\"[^\"]*\.$1\"" | grep -o '"index":[0-9]*' | cut -d: -f2 | paste -sd'|' -
}

ALL=$(echo "$FILES" | grep -o '"index":[0-9]*' | cut -d: -f2 | paste -sd'|' -)
KEEP=$(pick epub)
[ -n "$KEEP" ] || KEEP=$(pick pdf)

curl -s -d "hash=$HASH&id=$ALL&priority=0" "$API/torrents/filePrio"

if [ -n "$KEEP" ]; then
  curl -s -d "hash=$HASH&id=$KEEP&priority=1" "$API/torrents/filePrio"
else
  curl -s -d "hashes=$HASH" "$API/torrents/stop"
  curl -s -d "hashes=$HASH&tags=no-ebook" "$API/torrents/addTags"
fi
