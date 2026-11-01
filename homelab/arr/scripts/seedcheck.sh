#!/usr/bin/env bash
# Enforces no-seeding: settings pinned, seeding torrents stopped, upload speed and session total watched.
set -u
QB="http://127.0.0.1:8081"
HOSTHDR="Host: qbt.home.arpa"
COOKIE="/tmp/seedcheck.cookie"
TOPIC=$(cat "$HOME/.ntfy-rips-topic")
LOG="$HOME/homelab/arr/scripts/seedcheck.log"
LAST="$HOME/homelab/arr/scripts/seedcheck.last"
WANT='{"max_ratio_enabled":true,"max_ratio":0,"max_ratio_act":0,"max_seeding_time_enabled":true,"max_seeding_time":0,"up_limit":1024,"dht":false,"pex":false,"lsd":false}'

notify() { curl -s -H "Title: Seed check" -H "Priority: high" -d "$1" "https://ntfy.sh/$TOPIC" >/dev/null; }
api() { curl -s -b "$COOKIE" -H "$HOSTHDR" "$@"; }

curl -s -c "$COOKIE" -H "$HOSTHDR" --data-urlencode "username=admin" --data-urlencode "password=$(cat "$HOME/.qbt-pass")" "$QB/api/v2/auth/login" >/dev/null

PROBLEMS=""

DRIFT=$(api "$QB/api/v2/app/preferences" | python3 -c '
import sys,json
p=json.load(sys.stdin)
bad=[k for k,v in json.loads(sys.argv[1]).items() if p.get(k)!=v]
print(",".join(bad))' "$WANT")
if [ -n "$DRIFT" ]; then
  api --data-urlencode "json=$WANT" "$QB/api/v2/app/setPreferences"
  PROBLEMS="$PROBLEMS settings-reapplied($DRIFT)"
fi

SEEDING=$(api "$QB/api/v2/torrents/info" | python3 -c '
import sys,json
print("|".join(t["hash"] for t in json.load(sys.stdin) if t["state"] in ("uploading","stalledUP","forcedUP","queuedUP","checkingUP")))')
if [ -n "$SEEDING" ]; then
  api -d "hashes=$SEEDING" "$QB/api/v2/torrents/stop" >/dev/null || api -d "hashes=$SEEDING" "$QB/api/v2/torrents/pause" >/dev/null
  N=$(echo "$SEEDING" | tr '|' '\n' | wc -l)
  PROBLEMS="$PROBLEMS stopped-$N-seeding"
fi

read -r UP DLT UPT < <(api "$QB/api/v2/transfer/info" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["up_info_speed"], d["dl_info_data"], d["up_info_data"])')
[ "$UP" -gt 51200 ] && PROBLEMS="$PROBLEMS upload-${UP}B/s"

PREV=$(cut -d' ' -f2 "$LAST" 2>/dev/null || echo 0)
echo "$DLT $UPT $(date -Is)" > "$LAST"
if [ "$UPT" -gt 5000000 ] && [ "${PREV:-0}" -le 5000000 ]; then
  PROBLEMS="$PROBLEMS session-upload-${UPT}B"
fi

if [ -n "$PROBLEMS" ]; then
  echo "$(date -Is) FIX$PROBLEMS" >> "$LOG"
  notify "Seeding guard acted:$PROBLEMS"
fi
