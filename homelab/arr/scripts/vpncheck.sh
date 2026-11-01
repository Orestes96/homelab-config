#!/usr/bin/env bash
# Verifies qBittorrent's traffic exits via the VPN. Alerts via ntfy on state change.
set -u
TOPIC=$(cat "$HOME/.ntfy-rips-topic")
STATEFILE="$HOME/homelab/arr/scripts/vpncheck.state"
LOG="$HOME/homelab/arr/scripts/vpncheck.log"
PUSHFILE="$HOME/.vpncheck-push-url"

notify() { curl -s -H "Title: VPN check" -H "Priority: $2" -d "$1" "https://ntfy.sh/$TOPIC" >/dev/null; }

HOME_IP=$(curl -s -m 10 https://ifconfig.me)
VPN_IP=$(docker run --rm --network container:gluetun curlimages/curl -s -m 10 https://ifconfig.me 2>/dev/null)

[ -z "$HOME_IP" ] && exit 0   # no internet at all; Uptime Kuma covers that case

if [ -z "$VPN_IP" ]; then
  STATE="down"
  MSG="VPN tunnel down. Kill switch holding, qBittorrent has no network."
  PRIO="default"
elif [ "$VPN_IP" = "$HOME_IP" ]; then
  STATE="LEAK"
  docker stop qbittorrent >/dev/null 2>&1
  MSG="LEAK: qBittorrent traffic leaving via home IP $HOME_IP. qBittorrent stopped."
  PRIO="urgent"
else
  STATE="ok"
  MSG="VPN tunnel ok, exit IP $VPN_IP."
  PRIO="low"
fi

LAST=$(cat "$STATEFILE" 2>/dev/null || echo "none")
if [ "$STATE" != "$LAST" ]; then
  echo "$STATE" > "$STATEFILE"
  echo "$(date -Is) $STATE $MSG" >> "$LOG"
  notify "$MSG" "$PRIO"
fi

if [ "$STATE" = "ok" ] && [ -f "$PUSHFILE" ]; then
  curl -s -m 10 "$(cat "$PUSHFILE")" >/dev/null
fi
