#!/usr/bin/env python3
"""stallcheck: replace downloads that Radarr or Sonarr report as stalled.

A queue item stalled for longer than GRACE_MINUTES is removed from
qBittorrent, blocklisted so the same release isn't picked again, and a
fresh search is started for that film or episode. Sends an ntfy alert
for each replacement. Run from cron every 10 minutes.
Use --dry-run to report what it would do without changing anything.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

GRACE_MINUTES = 30
HOME = os.path.expanduser("~")
STATE = f"{HOME}/homelab/arr/scripts/stallcheck.state"
LOG = f"{HOME}/homelab/arr/scripts/stallcheck.log"
TOPIC_FILE = f"{HOME}/.ntfy-rips-topic"
APPS = {"radarr": 7878, "sonarr": 8989}
DRY_RUN = "--dry-run" in sys.argv


def api_key(app):
    out = subprocess.run(
        ["docker", "exec", app, "sed", "-n",
         r"s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p", "/config/config.xml"],
        capture_output=True, text=True, check=True)
    return out.stdout.strip()


def call(app, key, method, path, body=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:{APPS[app]}/api/v3/{path}",
        method=method,
        headers={"X-Api-Key": key, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read()
        return json.loads(data) if data else None


def log(msg):
    line = time.strftime("%Y-%m-%dT%H:%M:%S") + " " + msg
    print(line)
    if not DRY_RUN:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def notify(msg):
    if DRY_RUN or not os.path.exists(TOPIC_FILE):
        return
    topic = open(TOPIC_FILE).read().strip()
    req = urllib.request.Request(
        f"https://ntfy.sh/{topic}", data=msg.encode(), method="POST",
        headers={"Title": "Stalled download replaced"})
    urllib.request.urlopen(req, timeout=30)


try:
    state = json.load(open(STATE))
except (OSError, ValueError):
    state = {}

now = time.time()
still_stalled = {}

for app in APPS:
    key = api_key(app)
    for r in call(app, key, "GET", "queue?pageSize=200")["records"]:
        if "stalled" not in (r.get("errorMessage") or "").lower():
            continue
        sid = f"{app}:{r['id']}"
        first = state.get(sid, now)
        waited = (now - first) / 60
        if waited < GRACE_MINUTES:
            still_stalled[sid] = first
            if DRY_RUN:
                log(f"{app}: '{r['title']}' stalled for {waited:.0f} min, within grace period")
            continue
        msg = f"{app}: '{r['title']}' stalled for {waited:.0f} min, removed, blocklisted and searching again"
        if DRY_RUN:
            log("WOULD DO: " + msg)
            still_stalled[sid] = first
            continue
        call(app, key, "DELETE", f"queue/{r['id']}?removeFromClient=true&blocklist=true")
        if app == "radarr":
            cmd = {"name": "MoviesSearch", "movieIds": [r["movieId"]]}
        else:
            cmd = {"name": "EpisodeSearch", "episodeIds": [r["episodeId"]]}
        call(app, key, "POST", "command", cmd)
        log(msg)
        notify(msg)

if not DRY_RUN:
    with open(STATE, "w") as f:
        json.dump(still_stalled, f)
