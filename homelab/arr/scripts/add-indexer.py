#!/usr/bin/env python3
"""add-indexer: add a public indexer to Prowlarr and push it to every app
that should use it. Applies the "Search only" sync profile, tests the
indexer through Prowlarr before saving, then runs sync-indexer.sh to check
Sonarr and Radarr and add it to LazyLibrarian if it carries books.
"""
import difflib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

SELF = "~/homelab/arr/scripts/add-indexer.py"
PROWLARR = "http://127.0.0.1:9696/api/v1"
PROFILE = "Search only"
COMPOSE = "~/homelab/arr/compose.yaml"
HERE = os.path.dirname(os.path.abspath(__file__))

# Indexers that look right but must not be used: reason, then what to use instead
BLOCKED = {
    "internet archive": (
        "the Internet Archive deliberately stalls requests that identify as "
        "Prowlarr, so every search times out",
        'use your own copy, which is already set up: "Internet Archive (homelab)"'),
}

USAGE = f"""How to use it:
  {SELF} "Indexer name"        add an indexer
  {SELF} "Indexer name" 30     add it, allowing LazyLibrarian 30 searches a day (default 20)
  {SELF} --list word           find indexer names containing a word
  {SELF} --help                show this help

Always put the indexer name in quotes, as most names contain spaces or brackets."""


def fail(problem, fix, code=1):
    print(f"\nProblem: {problem}\nHow to fix it: {fix}\n", file=sys.stderr)
    sys.exit(code)


def api_key():
    try:
        out = subprocess.run(
            ["docker", "exec", "prowlarr", "sed", "-n",
             r"s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p", "/config/config.xml"],
            capture_output=True, text=True)
    except FileNotFoundError:
        fail("Docker isn't available here.",
             "Run this on homelab-01, where the arr stack runs.", 2)
    if out.returncode != 0 or not out.stdout.strip():
        fail("Couldn't read Prowlarr's API key, so the Prowlarr container is probably not running.",
             "Check it with:\n  docker ps --filter name=prowlarr\n"
             f"If it isn't shown as Up, start it with:\n  docker compose -f {COMPOSE} up -d prowlarr", 2)
    return out.stdout.strip()


def api(method, path, body=None):
    req = urllib.request.Request(
        f"{PROWLARR}/{path}", method=method,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError:
        raise
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        fail(f"Couldn't reach Prowlarr's API ({e}).",
             "Check Prowlarr is running with:\n  docker ps --filter name=prowlarr\n"
             "If it was only just started, wait 30 seconds and try again.", 2)


def prowlarr_says(err):
    try:
        body = json.loads(err.read().decode(errors="replace"))
        if isinstance(body, list):
            return "; ".join(x.get("errorMessage", str(x)) for x in body)
        return body.get("message") or str(body)
    except Exception:
        return f"HTTP error {err.code}"


def main():
    args = sys.argv[1:]

    if not args:
        fail("No indexer name given.", "\n" + USAGE)
    if args[0] in ("-h", "--help", "help"):
        print(__doc__ + "\n" + USAGE)
        return 0
    if args[0].startswith("-") and args[0] != "--list":
        fail(f"'{args[0]}' isn't an option this script knows.", "\n" + USAGE)

    global KEY
    KEY = api_key()
    schema = api("GET", "indexer/schema")

    if args[0] == "--list":
        word = " ".join(args[1:]).lower()
        hits = sorted((s for s in schema if word in s["name"].lower()),
                      key=lambda s: s["name"].lower())
        if not hits:
            fail(f"Nothing in Prowlarr's catalogue contains '{word}'.",
                 "Try a shorter or different word, such as just the first word of the name.")
        for s in hits:
            note = "  (don't use, see --help)" if s["name"].lower() in BLOCKED else ""
            print(f"{s['name']}  [{s.get('privacy', 'unknown')}]{note}")
        return 0

    # Spot a name that wasn't quoted, which arrives as several separate words
    if len(args) > 2:
        words = args[:-1] if args[-1].isdigit() else args
        fail(f"Got {len(args)} separate words, so the name probably wasn't in quotes.",
             f'Put the whole name in quotes, like this:\n  {SELF} "{" ".join(words)}"')

    name = args[0].strip()
    limit = "20"
    if len(args) == 2:
        if not args[1].isdigit():
            fail(f"'{args[1]}' isn't a number, so it can't be the daily search limit. "
                 "The name probably wasn't in quotes.",
                 f'Put the whole name in quotes, like this:\n  {SELF} "{args[0]} {args[1]}"')
        limit = args[1]
        if not 1 <= int(limit) <= 500:
            fail(f"A daily limit of {limit} won't work.",
                 "Use a number from 1 to 500. 20 suits most free archives.")
    if not name:
        fail("The indexer name is empty.", "\n" + USAGE)

    if name.lower() in BLOCKED:
        reason, instead = BLOCKED[name.lower()]
        fail(f"'{name}' shouldn't be used: {reason}.", f"Don't add this one. Instead, {instead}.")

    ix = next((s for s in schema if s["name"].lower() == name.lower()), None)
    if ix is None:
        names = [s["name"] for s in schema]
        lower = {n.lower(): n for n in names}
        partial = [n for n in names if name.lower() in n.lower()]
        close = [lower[m] for m in difflib.get_close_matches(name.lower(), list(lower), n=5, cutoff=0.6)]
        options = partial[:5] or close
        if options:
            fix = "Did you mean one of these? Copy the line for the one you want:\n" + \
                  "\n".join(f'  {SELF} "{n}"' for n in options)
        else:
            fix = f"Search the catalogue with one word from the name:\n  {SELF} --list {name.split()[0]}"
        fail(f"There's no indexer called '{name}' in Prowlarr's catalogue.", fix)

    real_name = ix["name"]

    if any(i["name"] == real_name for i in api("GET", "indexer")):
        print(f"'{real_name}' is already in Prowlarr, moving on to the app sync.")
    else:
        privacy = ix.get("privacy", "unknown")
        if privacy != "public":
            fail(f"'{real_name}' is a {privacy} indexer, so it needs a login, invite or API key.",
                 "This script only fills in public indexers. Add it in Prowlarr's web interface "
                 "with the Search only profile, then run this script again with the same name "
                 "to push it to the other apps.")
        profile = next((p for p in api("GET", "appprofile") if p["name"] == PROFILE), None)
        if profile is None:
            fail(f"Prowlarr has no sync profile called '{PROFILE}'.",
                 f"Create it in Prowlarr under Settings, Apps, Sync Profiles, named exactly "
                 f"'{PROFILE}', with Enable RSS unticked. Then run this again.")
        ix["enable"] = True
        ix["appProfileId"] = profile["id"]
        ix["priority"] = 25
        ix.setdefault("tags", [])

        print(f"Testing '{real_name}' through Prowlarr (can take up to 2 minutes)...")
        try:
            api("POST", "indexer/test", ix)
        except urllib.error.HTTPError as e:
            fail(f"Prowlarr's connection test failed, so nothing was saved. Prowlarr said: {prowlarr_says(e)}",
                 "Common causes: the site is down or slow, so try again later; or it blocks or "
                 "stalls Prowlarr the way the Internet Archive does, in which case it needs a "
                 "custom definition. Opening the site in a browser shows whether it's up.")
        try:
            api("POST", "indexer", ix)
        except urllib.error.HTTPError as e:
            fail(f"The test passed but Prowlarr refused to save it. Prowlarr said: {prowlarr_says(e)}",
                 "See Prowlarr's full error with:\n  docker logs --tail 30 prowlarr")
        print(f"Added '{real_name}' to Prowlarr with the '{PROFILE}' profile.")

    sync = os.path.join(HERE, "sync-indexer.sh")
    if not os.access(sync, os.X_OK):
        fail(f"'{real_name}' is in Prowlarr, but the follow-on script {sync} is missing or not executable.",
             f"Make it executable with:\n  chmod +x {sync}\n"
             "Then run this again with the same name to finish the job.", 2)

    result = subprocess.run([sync, real_name, limit])
    if result.returncode != 0:
        print(f"\n'{real_name}' is saved in Prowlarr, but not every app received it. "
              "The lines above say which. Running this again with the same name retries "
              "the sync without adding it twice.", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped. If it had already printed 'Added', run it again with the same "
              "name to finish the app sync. Otherwise nothing was changed.", file=sys.stderr)
        sys.exit(130)
