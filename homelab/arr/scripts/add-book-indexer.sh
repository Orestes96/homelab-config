#!/usr/bin/env bash
# add-book-indexer: add a Prowlarr indexer to LazyLibrarian as an
# ebook-only Torznab provider.
# Usage: add-book-indexer.sh "Indexer Name" [daily API limit, default 20]
set -euo pipefail

NAME="${1:?Usage: $0 \"Indexer Name\" [daily API limit]}"
LIMIT="${2:-20}"
CONF="$HOME/homelab/arr/lazylibrarian/config.ini"
COMPOSE="$HOME/homelab/arr/compose.yaml"

KEY=$(docker exec prowlarr sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml)

ID=$(curl -s -H "X-Api-Key: $KEY" http://127.0.0.1:9696/api/v1/indexer \
  | python3 -c "import json,sys; n=sys.argv[1]; print(next((str(i['id']) for i in json.load(sys.stdin) if i['name']==n), ''))" "$NAME")

if [ -z "$ID" ]; then
  echo "No Prowlarr indexer named '$NAME'. Check the exact name on Prowlarr's Indexers page." >&2
  exit 1
fi

if grep -q "^host = http://prowlarr:9696/$ID/api$" "$CONF"; then
  echo "LazyLibrarian already has a provider for '$NAME' (Prowlarr ID $ID). Nothing changed."
  exit 0
fi

MAX=$(grep -o '^\[Torznab_[0-9]*\]' "$CONF" | tr -dc '0-9\n' | sort -n | tail -n 1)
N=$(( ${MAX:--1} + 1 ))

docker compose -f "$COMPOSE" stop lazylibrarian
cp "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"

cat >> "$CONF" <<BLOCK

[Torznab_$N]
dispname = $NAME
enabled = True
host = http://prowlarr:9696/$ID/api
api = $KEY
generalsearch = search
bookcat = 7000
magcat = 7000
audiocat = 3000
comiccat = 7000
updated = $(date +%Y-%m-%d)
apilimit = $LIMIT
dltypes = E
BLOCK

docker compose -f "$COMPOSE" start lazylibrarian
echo "Added '$NAME' (Prowlarr ID $ID) as Torznab_$N with a daily limit of $LIMIT."
