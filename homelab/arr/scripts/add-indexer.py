#!/usr/bin/env python3
"""add-indexer: add a public indexer to Prowlarr from the command line and
push it to every app that should use it.

Usage:
  add-indexer.py "Indexer name" [LazyLibrarian daily API limit, default 20]
  add-indexer.py --list [search text]

Finds the indexer in Prowlarr's catalogue (custom definitions included),
applies the "Search only" sync profile, runs Prowlarr's connection test,
saves it, then runs sync-indexer.sh to check Sonarr and Radarr and add it
to LazyLibrarian. Public indexers only: ones needing a login or API key
must be added through Prowlarr's web interface.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

PROWLARR = "http://127.0.0.1:9696/api/v1"
PROFILE = "Search only"
HERE = os.path.dirname(os.path.abspath(__file__))


def api_key():
    out = subprocess.run(
        ["docker", "exec", "prowlarr", "sed", "-n",
         r"s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p", "/config/config.xml"],
        capture_output=True, text=True, check=True)
    return out.stdout.strip()


KEY = api_key()


def call(method, path, body=None):
    req = urllib.request.Request(
        f"{PROWLARR}/{path}", method=method,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        sys.exit(f"Prowlarr refused {method} {path} ({e.code}): {detail[:500]}")


args = sys.argv[1:]
if not args:
    sys.exit(__doc__)

schema = call("GET", "indexer/schema")

if args[0] == "--list":
    text = args[1].lower() if len(args) > 1 else ""
    for s in sorted(schema, key=lambda s: s["name"].lower()):
        if text in s["name"].lower():
            print(f"{s['name']}  [{s.get('privacy', '')}]")
    sys.exit(0)

name = args[0]
limit = args[1] if len(args) > 1 else "20"

ix = next((s for s in schema if s["name"].lower() == name.lower()), None)
if ix is None:
    sys.exit(f"No indexer called '{name}' in Prowlarr's catalogue. "
             f"Search for it with: add-indexer.py --list \"{name.split()[0]}\"")
if ix.get("privacy") != "public":
    sys.exit(f"'{ix['name']}' is {ix.get('privacy')}, so it needs credentials. "
             "Add it through Prowlarr's web interface instead.")

if any(i["name"] == ix["name"] for i in call("GET", "indexer")):
    print(f"'{ix['name']}' is already in Prowlarr, moving on to the app sync.")
else:
    profile = next((p for p in call("GET", "appprofile") if p["name"] == PROFILE), None)
    if profile is None:
        sys.exit(f"No sync profile called '{PROFILE}' in Prowlarr.")
    ix["enable"] = True
    ix["appProfileId"] = profile["id"]
    ix["priority"] = 25
    ix.setdefault("tags", [])
    print(f"Testing '{ix['name']}' through Prowlarr...")
    call("POST", "indexer/test", ix)
    call("POST", "indexer", ix)
    print(f"Added '{ix['name']}' to Prowlarr with the '{PROFILE}' profile.")

result = subprocess.run([f"{HERE}/sync-indexer.sh", ix["name"], limit])
sys.exit(result.returncode)
