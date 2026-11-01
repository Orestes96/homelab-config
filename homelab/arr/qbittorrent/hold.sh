#!/bin/sh
# Run by qBittorrent on torrent finished: park radarr/sonarr torrents for checking.
HASH="$1"; CAT="$2"
case "$CAT" in
  radarr|sonarr) curl -s -d "hashes=$HASH&category=${CAT}-hold" http://127.0.0.1:8080/api/v2/torrents/setCategory ;;
esac
