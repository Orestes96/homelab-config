#!/bin/bash
# reboot-required: publishes whether Ubuntu is waiting for a reboot to finish
# installing updates, for node-exporter's textfile collector.
# Usage: reboot-required.sh   (no arguments; run from cron)
set -euo pipefail

DIR="/var/lib/node_exporter/textfile"
OUT="$DIR/reboot_required.prom"

if [ ! -w "$DIR" ]; then
  printf 'Problem: %s\nHow to fix it: %s\nWhat changed: Nothing.\n' \
    "Can't write to $DIR." "Check the folder exists and is yours with: ls -ld $DIR" >&2
  exit 1
fi

required=0
packages=0
if [ -f /var/run/reboot-required ]; then
  required=1
fi
if [ -f /var/run/reboot-required.pkgs ]; then
  packages=$(sort -u /var/run/reboot-required.pkgs | wc -l)
fi

tmp="$(mktemp "${OUT}.XXXXXX")"
cat > "$tmp" <<METRICS
# HELP node_reboot_required 1 if Ubuntu is waiting for a reboot to finish installing updates.
# TYPE node_reboot_required gauge
node_reboot_required ${required}
# HELP node_reboot_required_packages How many packages asked for the pending reboot.
# TYPE node_reboot_required_packages gauge
node_reboot_required_packages ${packages}
METRICS
chmod 644 "$tmp"
mv "$tmp" "$OUT"
