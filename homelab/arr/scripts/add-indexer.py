#!/usr/bin/env python3
"""add-indexer: add a public indexer to Prowlarr and push it to every app
that should use it. Applies the "Search only" sync profile and any tags you
ask for, tests the indexer through Prowlarr before saving, then runs
sync-indexer.sh to check Sonarr and Radarr and add it to LazyLibrarian if
it carries books.

Tags matter because an app with a tag in Prowlarr only receives indexers
carrying that same tag. Use --tags to see which apps use which tags.
"""
import difflib
import json
import os
import re
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
  {SELF} "Indexer name"                     add an indexer
  {SELF} "Indexer name" 30                  ...allowing LazyLibrarian 30 searches a day (default 20)
  {SELF} "Indexer name" --tag movies        ...with the existing Prowlarr tag "movies" (repeat for more)
  {SELF} "Indexer name" --create-tag books  ...creating the tag "books" first if it doesn't exist
  {SELF} --list word                        find indexer names containing a word
  {SELF} --tags                             show Prowlarr's tags and which apps use them
  {SELF} --help                             show this help

Always put the indexer name in quotes, as most names contain spaces or brackets.
Running it again on an indexer that's already added adds any tags you give
and retries the app sync, without adding the indexer twice."""


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


def parse(args):
    """Split arguments into the name/limit, --tag names and --create-tag names."""
    positional, tags, create = [], [], []
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("--tag", "--create-tag"):
            if i + 1 >= len(args) or args[i + 1].startswith("-"):
                fail(f"'{a}' needs a tag name after it.",
                     f'For example:\n  {SELF} "Indexer name" {a} movies')
            (tags if a == "--tag" else create).append(args[i + 1].strip().lower())
            i += 2
            continue
        if a.startswith("-"):
            fail(f"'{a}' isn't an option this script knows.", "\n" + USAGE)
        positional.append(a)
        i += 1
    return positional, tags, create


def check_tags(tags, create):
    """Return ids of existing tags, and labels still to create. Changes nothing."""
    by_label = {t["label"].lower(): t["id"] for t in api("GET", "tag")}
    ids = []
    for label in tags:
        if label not in by_label:
            close = difflib.get_close_matches(label, list(by_label), n=3, cutoff=0.5)
            if close:
                fix = (f"Did you mean: {', '.join(close)}? Use one of those with --tag.\n"
                       f"Or, if '{label}' is a new tag you want, use --create-tag {label} instead.")
            elif by_label:
                fix = (f"The existing tags are: {', '.join(sorted(by_label))}.\n"
                       f"Or, if '{label}' is a new tag you want, use --create-tag {label} instead.")
            else:
                fix = f"Prowlarr has no tags yet. Create this one with --create-tag {label} instead."
            fail(f"Prowlarr has no tag called '{label}'.", fix)
        ids.append(by_label[label])
    to_create = []
    for label in create:
        if label in by_label:
            ids.append(by_label[label])
        elif not re.fullmatch(r"[a-z0-9-]+", label):
            fail(f"'{label}' can't be used as a tag name.",
                 "Use only lowercase letters, numbers and hyphens, for example: public-domain")
        else:
            to_create.append(label)
    return ids, to_create


def create_tags(labels):
    ids = []
    for label in labels:
        try:
            ids.append(api("POST", "tag", {"label": label})["id"])
        except urllib.error.HTTPError as e:
            fail(f"Prowlarr wouldn't create the tag '{label}'. Prowlarr said: {prowlarr_says(e)}",
                 "See Prowlarr's full error with:\n  docker logs --tail 30 prowlarr")
        print(f"Created the tag '{label}' in Prowlarr.")
    return ids


def show_tags():
    tags = api("GET", "tag")
    apps = api("GET", "applications")
    if not tags:
        print("Prowlarr has no tags, so every app receives every indexer.")
        return 0
    print("Tags in Prowlarr, and the apps that use them:")
    for t in sorted(tags, key=lambda t: t["label"]):
        users = [a["name"] for a in apps if t["id"] in a.get("tags", [])]
        print(f"  {t['label']}: {', '.join(users) or 'no apps'}")
    untagged = [a["name"] for a in apps if not a.get("tags")]
    if untagged:
        print(f"Apps with no tags, which receive every indexer: {', '.join(untagged)}")
    tagged = [a for a in apps if a.get("tags")]
    if tagged:
        print("An app with tags only receives indexers carrying at least one of the same tags.")
    return 0


def explain_missing(name):
    """After a failed sync, point out any app whose tags this indexer doesn't share."""
    ix = next((i for i in api("GET", "indexer") if i["name"] == name), None)
    if ix is None:
        return
    labels = {t["id"]: t["label"] for t in api("GET", "tag")}
    ix_tags = set(ix.get("tags", []))
    for a in api("GET", "applications"):
        app_tags = set(a.get("tags", []))
        if app_tags and not app_tags & ix_tags:
            wanted = ", ".join(labels.get(t, str(t)) for t in sorted(app_tags))
            first = labels.get(sorted(app_tags)[0], "")
            print(f"\nLikely cause for {a['name']}: it only receives indexers tagged '{wanted}', "
                  f"and '{name}' has {'no tags' if not ix_tags else 'none of those'}.\n"
                  f"How to fix it: add the tag by running this again:\n"
                  f'  {SELF} "{name}" --tag {first}', file=sys.stderr)


def main():
    args = sys.argv[1:]

    if not args:
        fail("No indexer name given.", "\n" + USAGE)
    if args[0] in ("-h", "--help", "help"):
        print(__doc__ + "\n" + USAGE)
        return 0

    global KEY
    KEY = api_key()

    if args[0] == "--tags":
        return show_tags()

    if args[0] == "--list":
        schema = api("GET", "indexer/schema")
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

    positional, tags, create = parse(args)

    if not positional:
        fail("No indexer name given, only tag options.", "\n" + USAGE)
    if len(positional) > 2 or (len(positional) == 2 and not positional[1].isdigit()):
        words = positional[:-1] if positional[-1].isdigit() else positional
        fail(f"Got {len(positional)} separate words for the name, so it probably wasn't in quotes.",
             f'Put the whole name in quotes, like this:\n  {SELF} "{" ".join(words)}"')

    name = positional[0].strip()
    limit = positional[1] if len(positional) == 2 else "20"
    if not 1 <= int(limit) <= 500:
        fail(f"A daily limit of {limit} won't work.",
             "Use a number from 1 to 500. 20 suits most free archives.")
    if not name:
        fail("The indexer name is empty.", "\n" + USAGE)

    if name.lower() in BLOCKED:
        reason, instead = BLOCKED[name.lower()]
        fail(f"'{name}' shouldn't be used: {reason}.", f"Don't add this one. Instead, {instead}.")

    schema = api("GET", "indexer/schema")
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

    # Check every tag name before changing anything
    tag_ids, to_create = check_tags(tags, create)

    existing = next((i for i in api("GET", "indexer") if i["name"] == real_name), None)
    if existing:
        print(f"'{real_name}' is already in Prowlarr.")
        if tag_ids or to_create:
            tag_ids += create_tags(to_create)
            merged = sorted(set(existing.get("tags", [])) | set(tag_ids))
            if merged != sorted(existing.get("tags", [])):
                existing["tags"] = merged
                try:
                    api("PUT", f"indexer/{existing['id']}", existing)
                except urllib.error.HTTPError as e:
                    fail(f"Prowlarr wouldn't save the new tags. Prowlarr said: {prowlarr_says(e)}",
                         "Nothing else was changed. See Prowlarr's full error with:\n"
                         "  docker logs --tail 30 prowlarr")
                print("Added the tags to it.")
            else:
                print("It already has those tags.")
        print("Moving on to the app sync.")
    else:
        privacy = ix.get("privacy", "unknown")
        if privacy != "public":
            fail(f"'{real_name}' is a {privacy} indexer, so it needs a login, invite or API key.",
                 "This script only fills in public indexers. Add it in Prowlarr's web interface "
                 "with the Search only profile, then run this script again with the same name "
                 "(and any --tag options) to push it to the other apps.")
        profile = next((p for p in api("GET", "appprofile") if p["name"] == PROFILE), None)
        if profile is None:
            fail(f"Prowlarr has no sync profile called '{PROFILE}'.",
                 f"Create it in Prowlarr under Settings, Apps, Sync Profiles, named exactly "
                 f"'{PROFILE}', with Enable RSS unticked. Then run this again.")
        ix["enable"] = True
        ix["appProfileId"] = profile["id"]
        ix["priority"] = 25

        print(f"Testing '{real_name}' through Prowlarr (can take up to 2 minutes)...")
        try:
            api("POST", "indexer/test", ix)
        except urllib.error.HTTPError as e:
            fail(f"Prowlarr's connection test failed, so nothing was saved. Prowlarr said: {prowlarr_says(e)}",
                 "Common causes: the site is down or slow, so try again later; or it blocks or "
                 "stalls Prowlarr the way the Internet Archive does, in which case it needs a "
                 "custom definition. Opening the site in a browser shows whether it's up.")

        tag_ids += create_tags(to_create)
        ix["tags"] = sorted(set(tag_ids))
        try:
            api("POST", "indexer", ix)
        except urllib.error.HTTPError as e:
            fail(f"The test passed but Prowlarr refused to save it. Prowlarr said: {prowlarr_says(e)}",
                 "See Prowlarr's full error with:\n  docker logs --tail 30 prowlarr")
        tagnote = f" and {len(ix['tags'])} tag(s)" if ix["tags"] else ""
        print(f"Added '{real_name}' to Prowlarr with the '{PROFILE}' profile{tagnote}.")

    sync = os.path.join(HERE, "sync-indexer.sh")
    if not os.access(sync, os.X_OK):
        fail(f"'{real_name}' is in Prowlarr, but the follow-on script {sync} is missing or not executable.",
             f"Make it executable with:\n  chmod +x {sync}\n"
             "Then run this again with the same name to finish the job.", 2)

    result = subprocess.run([sync, real_name, limit])
    if result.returncode != 0:
        print(f"\n'{real_name}' is saved in Prowlarr, but not every app received it. "
              "The lines above say which.", file=sys.stderr)
        explain_missing(real_name)
        print("\nRunning this again with the same name retries the sync without adding it twice.",
              file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped. If it had already printed 'Added', run it again with the same "
              "name to finish the app sync. Otherwise nothing was changed.", file=sys.stderr)
        sys.exit(130)
