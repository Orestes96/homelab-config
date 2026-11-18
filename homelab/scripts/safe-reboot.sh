#!/bin/bash
# safe-reboot: reboots homelab-01 to finish installing updates, but only when
# /var/run/reboot-required exists and nothing on the box is busy.
#
# Busy means any of: a MakeMKV rip running, a disc drive in use, a rip folder
# waiting for ripwatch (.done), a SMART self-test running, a backup running
# (restic, backup-*.sh, labbackup), qBittorrent actively downloading, or
# someone actively playing from Jellyfin or Plex (paused doesn't count). A check that can't be done counts
# as busy. A busy night is skipped and retried the next night; after 7 skipped
# nights in a row (and every 7 after that) it sends an ntfy alert.
#
# Before rebooting it saves the list of running containers, silences the
# restart-related Prometheus alerts for 25 minutes, and sends a heads-up. After
# boot (--after-boot, from @reboot) it checks those containers came back and
# sends one ntfy message with the result.
#
# Usage (as root):
#   safe-reboot              nightly run (from /etc/cron.d/safe-reboot, 02:00 UTC)
#   safe-reboot --dry-run    run every check, report what would happen, change nothing
#   safe-reboot --after-boot post-boot container check (from @reboot)
#
# Installed copy: /usr/local/sbin/safe-reboot (root-owned). Source of truth,
# tracked by labsync: /home/elliot/homelab/scripts/safe-reboot.sh
set -uo pipefail

SOURCE=/home/elliot/homelab/scripts/safe-reboot.sh
CRON_SOURCE=/home/elliot/homelab/scripts/cron/safe-reboot
LOGROTATE_SOURCE=/home/elliot/homelab/scripts/logrotate/safe-reboot
STATE=/var/lib/safe-reboot
ENV_FILE=/etc/safe-reboot.env
TOPIC_FILE=/home/elliot/.ntfy-topic
QBT_PASS_FILE=/home/elliot/.qbt-pass
PLEX_PREFS="/home/elliot/homelab/plex/config/Library/Application Support/Plex Media Server/Preferences.xml"
RIPS=/srv/media/rips
MARK=/usr/local/bin/mark-success  # root-owned copy of ~/bin/mark-success
ALERTMANAGER=http://127.0.0.1:9093
SILENCE_MINUTES=25
SKIP_ALERT_EVERY=7
HOST=$(hostname)

MODE=nightly
case "${1:-}" in
  "") ;;
  --dry-run) MODE=dry ;;
  --after-boot) MODE=after ;;
  *) echo "Usage: $0 [--dry-run | --after-boot]" >&2; exit 2 ;;
esac

say() { echo "$(date -u +%FT%TZ) $*"; logger -t safe-reboot -- "$*" 2>/dev/null || true; }

notify() {  # notify <title> <message>
  if [ "$MODE" = dry ]; then
    printf 'WOULD SEND ntfy [%s]:\n%s\n' "$1" "$2"
    return 0
  fi
  local topic
  topic=$(cat "$TOPIC_FILE" 2>/dev/null) || { say "Problem: can't read $TOPIC_FILE, so this ntfy message wasn't sent: $2"; return 1; }
  curl -s -m 15 -H "Title: $1" -d "$2" "https://ntfy.sh/$topic" >/dev/null \
    || say "Problem: ntfy didn't accept the message (network?). Message was: $2"
}

fail() {  # fail <problem> <fix> [what changed]
  local changed="${3:-Nothing. The box was not rebooted.}"
  local msg
  msg=$(printf 'Problem: %s\nHow to fix it: %s\nWhat changed: %s' "$1" "$2" "$changed")
  say "$msg"
  notify "safe-reboot problem" "$msg"
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  echo "Problem: safe-reboot must run as root (it reads SMART data and reboots the box)." >&2
  echo "How to fix it: run it with sudo, e.g.  sudo /usr/local/sbin/safe-reboot --dry-run" >&2
  echo "What changed: Nothing." >&2
  exit 1
fi

[ -r "$ENV_FILE" ] && source "$ENV_FILE"

# ---------------------------------------------------------------- checks ---
# Each check prints one line and returns 0 = free, 1 = busy, 2 = couldn't check.

check_rip() {
  # makemkvcon "guiserver" is MakeMKV's idle background process in the
  # makemkv-convert container, so it doesn't count; a rip it runs shows up as
  # the drive being in use and as a rip folder being written.
  local p rc recent
  p=$(pgrep -a -f 'makemkvcon|/home/elliot/bin/rescuerip' 2>/dev/null); rc=$?
  [ $rc -gt 1 ] && { echo "couldn't list processes (pgrep exit $rc)"; return 2; }
  p=$(grep -v -E 'makemkvcon( .*)? guiserver' <<<"$p")
  [ -n "$p" ] && { echo "a rip is running: $(echo "$p" | head -1 | cut -c1-80)"; return 1; }
  [ -d "$RIPS" ] && [ -r "$RIPS" ] || { echo "can't read $RIPS"; return 2; }
  # A rip folder with no .done/.pending/.failed marker that was written in the last 3 minutes.
  recent=$(find "$RIPS" -mindepth 2 -maxdepth 2 -name '*.mkv' -mmin -3 -printf '%h\n' 2>/dev/null | sort -u |
    while read -r d; do [ -e "$d/.done" ] || [ -e "$d/.pending" ] || [ -e "$d/.failed" ] || basename "$d"; done)
  [ -n "$recent" ] && { echo "a rip folder is being written: $(echo $recent)"; return 1; }
  echo "no rip running"; return 0
}

check_drive() {
  # Not fuser: a container's /dev/sg3 is its own device file (different inode)
  # for the same device, so fuser on the host node never sees container
  # processes. Instead, match open files by device number (major:minor).
  # MakeMKV opens the drive in bursts, so sample for 10 seconds. MakeMKV's
  # "guiserver" keeps the drives open even when idle, so it only counts when
  # it's using CPU; any other makemkvcon (rescuerip's rips) always counts.
  local s blk nums=() found=0
  for s in /sys/class/scsi_generic/sg*; do
    [ "$(cat "$s/device/type" 2>/dev/null)" = 5 ] || continue
    found=1
    nums+=("$(stat -c '%t:%T' "/dev/$(basename "$s")" 2>/dev/null)")
    for blk in "$s"/device/block/*; do
      [ -e "$blk" ] && nums+=("$(stat -c '%t:%T' "/dev/$(basename "$blk")" 2>/dev/null)")
    done
  done
  [ $found -eq 0 ] && { echo "no disc drive attached"; return 0; }
  [ -r /proc/1/fd ] || { echo "can't read other processes' open files (not root?)"; return 2; }

  local gui gui_start=0 gui_end=0 users=() i f pid rdev cmd mk
  gui=$(pgrep -f 'makemkvcon( .*)? guiserver' 2>/dev/null | head -1)
  [ -n "$gui" ] && gui_start=$(awk '{print $14+$15}' "/proc/$gui/stat" 2>/dev/null || echo 0)
  for i in $(seq 1 20); do
    while IFS= read -r f; do
      rdev=$(stat -L -c '%t:%T' "$f" 2>/dev/null) || continue
      [[ " ${nums[*]} " == *" $rdev "* ]] || continue
      pid=${f#/proc/}; pid=${pid%%/*}
      [ "$pid" = "$gui" ] && continue
      cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | cut -c1-60)
      [[ " ${users[*]} " == *"pid $pid "* ]] || users+=("pid $pid ($cmd)")
    done < <(find /proc/[0-9]*/fd -maxdepth 1 -type l \( -lname '/dev/sr*' -o -lname '/dev/sg*' \
               -o -lname '/dev/cdrom*' -o -lname '/dev/dvd*' \) 2>/dev/null)
    mk=$(pgrep -a -f '/makemkvcon ' 2>/dev/null | grep -v -E 'makemkvcon( .*)? guiserver|docker exec' | head -1)
    if [ -n "$mk" ]; then echo "MakeMKV is reading a disc: $(cut -c1-70 <<<"$mk")"; return 1; fi
    [ ${#users[@]} -gt 0 ] && { echo "disc drive open by ${users[*]}"; return 1; }
    sleep 0.5
  done
  if [ -n "$gui" ]; then
    gui_end=$(awk '{print $14+$15}' "/proc/$gui/stat" 2>/dev/null || echo 0)
    # Idle it uses ~1 tick per 5 s; 20+ ticks in 10 s (2% CPU) means it's working.
    if [ $((gui_end - gui_start)) -ge 20 ]; then
      echo "MakeMKV's GUI server is working ($((gui_end - gui_start)) CPU ticks in 10 s)"; return 1
    fi
  fi
  echo "disc drives idle"; return 0
}

check_ripwatch() {
  [ -d "$RIPS" ] && [ -r "$RIPS" ] || { echo "can't read $RIPS"; return 2; }
  local waiting=()
  for m in "$RIPS"/*/.done; do [ -e "$m" ] && waiting+=("$(basename "$(dirname "$m")")"); done
  [ ${#waiting[@]} -gt 0 ] && { echo "rip waiting for ripwatch: ${waiting[*]}"; return 1; }
  echo "no rips waiting to be sorted"; return 0
}

check_smart() {
  command -v smartctl >/dev/null || { echo "smartctl isn't installed"; return 2; }
  local scan line dev args out rc testing=()
  scan=$(smartctl --scan 2>&1) || { echo "smartctl --scan failed: $scan"; return 2; }
  [ -n "$scan" ] || { echo "smartctl found no drives"; return 2; }
  while IFS= read -r line; do
    line=${line%%#*}; read -r dev args <<<"$line"
    [ -n "$dev" ] || continue
    # shellcheck disable=SC2086
    out=$(smartctl -c -l selftest $args "$dev" 2>&1); rc=$?
    if (( rc & 3 )); then echo "couldn't read SMART from $dev (smartctl exit $rc)"; return 2; fi
    grep -qi "in progress" <<<"$out" && testing+=("$dev")
  done <<<"$scan"
  [ ${#testing[@]} -gt 0 ] && { echo "SMART self-test running on ${testing[*]}"; return 1; }
  echo "no SMART self-tests running"; return 0
}

check_backup() {
  local p
  p=$(pgrep -a -f '(^|/)restic( |$)|/backup-[^ /]*\.sh|/home/elliot/bin/labbackup' 2>/dev/null); local rc=$?
  [ $rc -gt 1 ] && { echo "couldn't list processes (pgrep exit $rc)"; return 2; }
  [ -n "$p" ] && { echo "a backup is running: $(echo "$p" | head -1 | cut -c1-80)"; return 1; }
  echo "no backup running"; return 0
}

check_qbittorrent() {
  local jar body n code
  [ -r "$QBT_PASS_FILE" ] || { echo "can't read $QBT_PASS_FILE"; return 2; }
  jar=$(mktemp) || { echo "couldn't make a temp file"; return 2; }
  # qBittorrent 5 answers a good login with HTTP 204 and no body; older versions
  # with 200 "Ok.". Either way a good login sets the SID cookie.
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -c "$jar" -H "Host: qbt.home.arpa" --data-urlencode "username=admin" \
    --data-urlencode "password=$(cat "$QBT_PASS_FILE")" http://127.0.0.1:8081/api/v2/auth/login)
  if [[ "$code" != 2* ]] || ! grep -q 'SID' "$jar"; then rm -f "$jar"; echo "qBittorrent login failed (HTTP ${code:-none})"; return 2; fi
  body=$(curl -s -m 10 -b "$jar" -H "Host: qbt.home.arpa" http://127.0.0.1:8081/api/v2/torrents/info); rm -f "$jar"
  n=$(jq -r '[.[] | select(.state | test("^(downloading|forcedDL|metaDL|forcedMetaDL|checkingDL|moving)$"))] | length' <<<"$body" 2>/dev/null) \
    || { echo "qBittorrent's torrent list wasn't readable"; return 2; }
  [ "$n" -gt 0 ] && { echo "qBittorrent has $n active download(s)"; return 1; }
  echo "qBittorrent idle"; return 0
}

check_jellyfin() {
  [ -n "${JELLYFIN_API_KEY:-}" ] || { echo "JELLYFIN_API_KEY isn't set in $ENV_FILE"; return 2; }
  local body n
  body=$(curl -sf -m 10 -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" http://127.0.0.1:8096/Sessions) \
    || { echo "Jellyfin didn't answer (or rejected the key)"; return 2; }
  # Only sessions actively playing count; a paused one left overnight doesn't.
  n=$(jq -r '[.[] | select(.NowPlayingItem != null and (.PlayState.IsPaused | not))] | length' <<<"$body" 2>/dev/null) \
    || { echo "Jellyfin's session list wasn't readable"; return 2; }
  [ "$n" -gt 0 ] && { echo "$n Jellyfin stream(s) playing"; return 1; }
  echo "no Jellyfin streams playing"; return 0
}

check_plex() {
  local token body n
  token=$(grep -o 'PlexOnlineToken="[^"]*"' "$PLEX_PREFS" 2>/dev/null | cut -d'"' -f2)
  [ -n "$token" ] || { echo "couldn't read Plex's token from Preferences.xml"; return 2; }
  body=$(curl -sf -m 10 -H "Accept: application/json" -H "X-Plex-Token: $token" http://127.0.0.1:32400/status/sessions) \
    || { echo "Plex didn't answer"; return 2; }
  # Only playing or buffering sessions count; paused ones don't.
  n=$(jq -r '[.MediaContainer.Metadata[]? | select(.Player.state == "playing" or .Player.state == "buffering")] | length' <<<"$body" 2>/dev/null) \
    || { echo "Plex's session list wasn't readable"; return 2; }
  [ "$n" -gt 0 ] && { echo "$n Plex stream(s) playing"; return 1; }
  echo "no Plex streams playing"; return 0
}

CHECKS=(rip drive ripwatch smart backup qbittorrent jellyfin plex)

run_checks() {  # sets BUSY array
  BUSY=()
  local c line rc
  for c in "${CHECKS[@]}"; do
    line=$("check_$c"); rc=$?
    case $rc in
      0) say "  ok    $c: $line" ;;
      1) say "  BUSY  $c: $line"; BUSY+=("$line") ;;
      *) say "  BUSY  $c: couldn't check, so counting it as busy: $line"; BUSY+=("couldn't check $c: $line") ;;
    esac
  done
}

running_containers() { docker ps --format '{{.Names}}' | sort; }

drift_warning() {  # log + ntfy when an installed root-owned copy differs from its tracked source
  local pair self src dst fix problems=""
  self=$(readlink -f "$0")
  for pair in "$self|$SOURCE|755|/usr/local/sbin/safe-reboot" \
              "/etc/cron.d/safe-reboot|$CRON_SOURCE|644|/etc/cron.d/safe-reboot" \
              "/etc/logrotate.d/safe-reboot|$LOGROTATE_SOURCE|644|/etc/logrotate.d/safe-reboot" \
              "$MARK|/home/elliot/bin/mark-success|755|$MARK"; do
    IFS='|' read -r dst src mode target <<<"$pair"
    [ "$dst" = "$src" ] && continue
    if [ -e "$dst" ] && ! cmp -s "$dst" "$src"; then
      problems+="${problems:+$'\n'}$dst differs from $src. Reinstall with: sudo install -m $mode -o root -g root $src $target"
    fi
  done
  [ -x "$MARK" ] || problems+="${problems:+$'\n'}$MARK is missing. Install it with: sudo install -m 755 -o root -g root /home/elliot/bin/mark-success $MARK"
  [ -z "$problems" ] && return 0
  local msg="Problem: installed copies used by root differ from their tracked sources:
$problems
How to fix it: if the tracked copies are the ones you want, run the reinstall command(s) above.
What changed: Nothing. safe-reboot carried on with the installed copies."
  say "$msg"
  notify "safe-reboot copies out of date" "$msg"
}

# ------------------------------------------------------------ after boot ---

after_boot() {
  local pending="$STATE/postcheck-pending" expected="$STATE/expected-containers"
  if [ "$MODE" = after ] && [ ! -f "$pending" ]; then
    exit 0  # this boot wasn't one of ours
  fi
  if [ ! -s "$expected" ]; then
    [ "$MODE" = dry ] && { say "After-boot check: no saved container list yet (one is saved just before a reboot)."; return; }
    rm -f "$pending"
    fail "No saved container list was found after the reboot, so containers weren't checked." \
         "Check them by hand with: docker ps -a" "The box rebooted. Nothing else changed."
  fi
  local deadline=$(( $(date +%s) + 600 )) missing unhealthy starting
  if [ "$MODE" = after ]; then
    until docker info >/dev/null 2>&1 || [ "$(date +%s)" -ge $deadline ]; do sleep 10; done
  fi
  while :; do
    missing=$(comm -23 "$expected" <(running_containers 2>/dev/null))
    starting=$(docker ps --filter health=starting --format '{{.Names}}' 2>/dev/null)
    if [ "$MODE" = dry ] || { [ -z "$missing" ] && [ -z "$starting" ]; } || [ "$(date +%s)" -ge $deadline ]; then break; fi
    sleep 15
  done
  unhealthy=$(docker ps --filter health=unhealthy --format '{{.Names}}' 2>/dev/null)
  local still=""; [ -f /var/run/reboot-required ] && still=$'\nNote: the system still says a reboot is required.'
  local total; total=$(wc -l <"$expected")
  if [ -z "$missing" ] && [ -z "$unhealthy" ]; then
    notify "homelab rebooted" "$HOST rebooted to finish updates and all $total containers are back and healthy.$still"
  else
    local list=""
    [ -n "$missing" ] && list+=$'\nNot running: '"$(echo $missing)"
    [ -n "$unhealthy" ] && list+=$'\nUnhealthy: '"$(echo $unhealthy)"
    [ -n "$starting" ] && list+=$'\nStill starting after 10 minutes: '"$(echo $starting)"
    notify "homelab rebooted with problems" "Problem: $HOST rebooted to finish updates, but some containers didn't come back.$list
How to fix it: look at each with: docker logs <name>   then start it with: docker start <name>   (or docker compose up -d in its folder).
What changed: The box rebooted. Nothing was restarted automatically.$still"
  fi
  [ "$MODE" = dry ] || rm -f "$pending"
}

# --------------------------------------------------------------- nightly ---

nightly() {
  [ "$MODE" = dry ] && say "DRY RUN: nothing will be changed, sent or rebooted."
  drift_warning
  if [ ! -f /var/run/reboot-required ]; then
    say "No reboot needed."
    if [ "$MODE" != dry ]; then echo 0 >"$STATE/skips"; "$MARK" safe-reboot 93600; fi
    if [ "$MODE" != dry ]; then return 0; fi
    say "(Running the checks anyway so you can see them.)"
  else
    say "Reboot needed for: $(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
  fi

  run_checks
  local skips; skips=$(cat "$STATE/skips" 2>/dev/null || echo 0)

  if [ ${#BUSY[@]} -gt 0 ]; then
    skips=$((skips + 1))
    say "Skipping tonight ($skips night(s) in a row). Will try again tomorrow at 02:00 UTC."
    if [ "$MODE" = dry ]; then
      say "WOULD record skip number $skips."
    else
      echo "$skips" >"$STATE/skips"
    fi
    if [ $((skips % SKIP_ALERT_EVERY)) -eq 0 ]; then
      local reasons; reasons=$(printf -- '- %s\n' "${BUSY[@]}")
      notify "Reboot needed by hand" "Problem: $HOST has skipped its update reboot for $skips nights in a row because it was busy. Tonight:
$reasons
How to fix it: reboot by hand when it's quiet: sudo reboot   (or wait; it keeps trying nightly at 02:00 UTC).
What changed: Nothing. The box was not rebooted."
    fi
    [ "$MODE" = dry ] || "$MARK" safe-reboot 93600
    return 0
  fi

  # Nothing busy: prepare and reboot.
  local end
  end=$(date -u -d "+${SILENCE_MINUTES} minutes" +%FT%TZ)
  local silence
  silence=$(jq -n --arg s "$(date -u +%FT%TZ)" --arg e "$end" '{
    matchers: [{name: "alertname", value: "HostRebooted|EndpointDown|DnsDown|TargetDown|ContainerDown|ContainerUnhealthy|ContainerRestartLoop|DockerStateStale", isRegex: true, isEqual: true}],
    startsAt: $s, endsAt: $e, createdBy: "safe-reboot", comment: "Planned reboot to finish updates"}')
  local pkgs; pkgs=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')
  local headsup="$HOST is rebooting now to finish installing updates (${pkgs:-packages}). It should be back in about 5 minutes.
Expect: Uptime Kuma down/up alerts, and one down/up alert from Home Assistant on the Pi. Prometheus restart alerts are silenced for $SILENCE_MINUTES minutes."

  if [ "$MODE" = dry ]; then
    say "WOULD save $(running_containers | wc -l) running containers to $STATE/expected-containers:"
    running_containers | tr '\n' ' '; echo
    say "WOULD create an Alertmanager silence until $end for: HostRebooted EndpointDown DnsDown TargetDown ContainerDown ContainerUnhealthy ContainerRestartLoop DockerStateStale"
    curl -sf -m 5 "$ALERTMANAGER/-/healthy" >/dev/null && say "  (Alertmanager is reachable.)" || say "  (Alertmanager is NOT reachable; a real run would reboot without the silence and say so.)"
    notify "homelab rebooting" "$headsup"
    say "WOULD reset the skip counter, mark success, and run: systemctl reboot"
    say "After boot, the --after-boot check would send (judged against the containers running now):"
    after_boot_dry
    return 0
  fi

  running_containers >"$STATE/expected-containers" || fail "Couldn't list running containers before rebooting." "Check Docker is working with: docker ps"
  date -u +%FT%TZ >"$STATE/postcheck-pending"
  if ! curl -sf -m 10 -H "Content-Type: application/json" -d "$silence" "$ALERTMANAGER/api/v2/silences" >/dev/null; then
    headsup+=$'\nNote: Alertmanager could not be reached, so expect Prometheus restart alerts too.'
    say "Alertmanager silence failed; rebooting anyway."
  fi
  notify "homelab rebooting" "$headsup"
  echo 0 >"$STATE/skips"
  "$MARK" safe-reboot 93600
  say "Rebooting now."
  sync
  systemctl reboot || fail "systemctl reboot failed." "Reboot by hand with: sudo reboot" "Alerts were silenced and a heads-up was sent, but the box did not reboot."
}

after_boot_dry() {  # preview the post-boot message from a temp copy of the container list
  local real=$STATE
  STATE=$(mktemp -d) || return 1
  running_containers >"$STATE/expected-containers"
  after_boot
  rm -rf "$STATE"; STATE=$real
}

if [ "$MODE" != dry ]; then
  mkdir -p "$STATE" || { echo "Problem: can't create $STATE" >&2; exit 1; }
fi

case $MODE in
  after) after_boot ;;
  *) nightly ;;
esac
