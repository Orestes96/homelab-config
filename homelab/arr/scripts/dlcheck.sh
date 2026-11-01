#!/usr/bin/env bash
# Checks torrents parked in *-hold categories with ffprobe; releases good ones, quarantines bad ones.
set -u
QB="http://127.0.0.1:8081"
HOSTHDR="Host: qbt.home.arpa"
COOKIE="/tmp/dlcheck.cookie"
TOPIC=$(cat "$HOME/.ntfy-rips-topic")
LOG="$HOME/homelab/arr/scripts/dlcheck.log"
QUAR="/srv/media/digital/downloads/quarantine"
MIN_SECS=300

notify() { curl -s -H "Title: Download check" -d "$1" "https://ntfy.sh/$TOPIC" >/dev/null; }
api() { curl -s -b "$COOKIE" -H "$HOSTHDR" "$@"; }

curl -s -c "$COOKIE" -H "$HOSTHDR" --data-urlencode "username=admin" --data-urlencode "password=$(cat "$HOME/.qbt-pass")" "$QB/api/v2/auth/login" >/dev/null

for CAT in radarr sonarr; do
  api "$QB/api/v2/torrents/info?category=${CAT}-hold" | python3 -c 'import sys,json; [print(t["hash"], t["content_path"]) for t in json.load(sys.stdin) if t["progress"] >= 1]' |
  while read -r HASH CPATH; do
    HOSTPATH="/srv/media/digital${CPATH#/data/digital}"
    GOOD=0
    while IFS= read -r F; do
      D=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$F" 2>/dev/null | cut -d. -f1)
      [ -n "$D" ] && [ "$D" -ge "$MIN_SECS" ] && GOOD=1 && break
    done < <(find "$HOSTPATH" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.avi' -o -iname '*.mov' -o -iname '*.webm' -o -iname '*.ts' \) 2>/dev/null)
    NAME=$(basename "$HOSTPATH")
    if [ "$GOOD" = 1 ]; then
      api -d "hashes=$HASH&category=$CAT" "$QB/api/v2/torrents/setCategory"
      echo "$(date -Is) PASS $CAT $NAME" >> "$LOG"
    else
      mkdir -p "$QUAR"
      mv "$HOSTPATH" "$QUAR/" 2>/dev/null
      api -d "hashes=$HASH&deleteFiles=false" "$QB/api/v2/torrents/delete"
      echo "$(date -Is) QUARANTINE $CAT $NAME" >> "$LOG"
      notify "Quarantined (no playable video over 5 min): $NAME"
    fi
  done
done
