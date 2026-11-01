#!/usr/bin/env bash
# sync-indexer: get a Prowlarr indexer into every app that should use it.
# Sonarr and Radarr receive it through Prowlarr's own sync, which this
# triggers and then verifies. LazyLibrarian receives it through
# add-book-indexer.sh, as Prowlarr's sync to it doesn't work.
# Usage: sync-indexer.sh "Indexer Name" [LazyLibrarian daily API limit, default 20]
set -euo pipefail

NAME="${1:?Usage: $0 \"Indexer Name\" [LazyLibrarian daily API limit]}"
LIMIT="${2:-20}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

key() { docker exec "$1" sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml; }

PKEY=$(key prowlarr)

# Find the indexer and the category ranges it supports
CATS=$(curl -s -H "X-Api-Key: $PKEY" http://127.0.0.1:9696/api/v1/indexer | python3 -c '
import json, sys
name = sys.argv[1]
for i in json.load(sys.stdin):
    if i["name"] == name:
        ids = {c["id"] for c in i.get("capabilities", {}).get("categories", [])}
        found = set()
        for c in ids:
            if 2000 <= c < 3000: found.add("movies")
            if 5000 <= c < 6000: found.add("tv")
            if 7000 <= c < 8000: found.add("books")
        print("found " + " ".join(sorted(found)))
        break
' "$NAME")

if [ -z "$CATS" ]; then
  echo "No Prowlarr indexer named '$NAME'. Check the exact name on Prowlarr's Indexers page." >&2
  exit 1
fi

# Ask Prowlarr to push its indexers to the apps it syncs with
curl -s -o /dev/null -X POST -H "X-Api-Key: $PKEY" -H "Content-Type: application/json" \
  -d '{"name":"ApplicationIndexerSync"}' http://127.0.0.1:9696/api/v1/command

has_indexer() {
  curl -s -H "X-Api-Key: $2" "http://127.0.0.1:$1/api/v3/indexer" | python3 -c '
import json, sys
n = sys.argv[1]
sys.exit(0 if any(i["name"].startswith(n) for i in json.load(sys.stdin)) else 1)
' "$NAME"
}

check_app() {
  local app="$1" port="$2" cat="$3"
  if [[ " $CATS " != *" $cat "* ]]; then
    echo "$app: not applicable (no $cat categories)"
    return
  fi
  local akey; akey=$(key "$app")
  for attempt in 1 2 3 4 5 6; do
    if has_indexer "$port" "$akey"; then
      echo "$app: present"
      return
    fi
    sleep 10
  done
  echo "$app: MISSING after 60 seconds. Check Prowlarr's Settings, Apps, and System, Logs." >&2
  FAIL=1
}

check_app sonarr 8989 tv
check_app radarr 7878 movies

if [[ " $CATS " == *" books "* ]]; then
  echo "lazylibrarian: handing over to add-book-indexer.sh"
  "$DIR/add-book-indexer.sh" "$NAME" "$LIMIT" || FAIL=1
else
  echo "lazylibrarian: not applicable (no books categories)"
fi

exit "$FAIL"
