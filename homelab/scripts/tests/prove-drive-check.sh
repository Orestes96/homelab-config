#!/bin/bash
# prove-drive-check: re-runnable proof that safe-reboot's drive check sees a rip
# running inside the makemkv-convert container. Re-run after any change to
# check_drive, while a rip is going:
#   sudo ~/homelab/scripts/tests/prove-drive-check.sh
# It runs the installed drive check twice, read-only:
#   1. as installed
#   2. with the "any makemkvcon running" shortcut switched off, so only the
#      device-number scan of open files can catch the rip
# Both should say busy (returned 1). Nothing is changed.
set -uo pipefail
INSTALLED=/usr/local/sbin/safe-reboot

if [ "$(id -u)" -ne 0 ]; then
  printf 'Problem: %s\nHow to fix it: %s\nWhat changed: Nothing.\n' \
    "This needs root to see the rip's open files." "Run it with: sudo $0" >&2
  exit 1
fi
[ -r "$INSTALLED" ] || { printf 'Problem: %s is missing.\nHow to fix it: %s\nWhat changed: Nothing.\n' \
  "$INSTALLED" "Install it with: sudo install -m 755 -o root -g root /home/elliot/homelab/scripts/safe-reboot.sh $INSTALLED" >&2; exit 1; }

func=$(sed -n '/^check_drive() {/,/^}/p' "$INSTALLED")
[ -n "$func" ] || { echo "Problem: couldn't find check_drive in $INSTALLED. How to fix it: reinstall safe-reboot. What changed: Nothing." >&2; exit 1; }

rip=$(pgrep -af '^/opt/makemkv/bin/makemkvcon -r (mkv|info|backup)' | head -1)
echo "Rip running now: ${rip:-none (both checks below should then say idle)}"
echo

echo "1. Drive check as installed:"
bash -c "$func"$'\n'"check_drive; echo \"   returned \$? (1 = busy)\""
echo

echo "2. Device-number scan only (makemkvcon shortcut off):"
scan_only=$(sed "s#pgrep -a -f '/makemkvcon '#true#" <<<"$func")
if [ "$scan_only" = "$func" ]; then
  echo "   Problem: couldn't switch off the makemkvcon shortcut (the check's code changed). How to fix it: update this script. What changed: Nothing."
  exit 1
fi
bash -c "$scan_only"$'\n'"check_drive; echo \"   returned \$? (1 = busy)\""
