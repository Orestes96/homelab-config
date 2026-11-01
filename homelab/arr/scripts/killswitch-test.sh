#!/usr/bin/env bash
# Weekly kill-switch test. A: eth0 must have no route out. B: with WireGuard blocked, nothing must exit.
set -u
TOPIC=$(cat /home/elliot/.ntfy-rips-topic)
LOG=/home/elliot/homelab/arr/scripts/killswitch-test.log
notify() { curl -s -H "Title: Kill switch test" -H "Priority: $2" -d "$1" "https://ntfy.sh/$TOPIC" >/dev/null; }
probe() { docker run --rm --network container:gluetun curlimages/curl -s -m 15 "$@" https://ifconfig.me 2>/dev/null; }
RULE=(DOCKER-USER -p udp --dport 51820 -j DROP)
cleanup() { iptables -D "${RULE[@]}" 2>/dev/null; }
trap cleanup EXIT

FAIL=""
A=$(probe --interface eth0)
[ -n "$A" ] && FAIL="$FAIL A:eth0-leak($A)"

iptables -I "${RULE[@]}"
sleep 30
B=$(probe)
[ -n "$B" ] && FAIL="$FAIL B:tunnel-down-leak($B)"
cleanup
trap - EXIT

if [ -n "$FAIL" ]; then
  docker stop qbittorrent >/dev/null 2>&1
  echo "$(date -Is) FAIL$FAIL" >> "$LOG"
  notify "Kill switch FAILED:$FAIL. qBittorrent stopped." urgent
else
  echo "$(date -Is) PASS" >> "$LOG"
  notify "Kill switch test passed (eth0 blocked, tunnel-down blocked)." low
fi
