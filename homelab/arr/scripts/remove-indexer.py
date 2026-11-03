#!/usr/bin/env python3
"""remove-indexer: remove an indexer from Prowlarr and from every app that
received it: Sonarr, Radarr and LazyLibrarian. Shows what it will remove
and asks you to confirm before changing anything.
"""
import configparser
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

SELF = "~/homelab/arr/scripts/remove-indexer.py"
COMPOSE = os.path.expanduser("~/homelab/arr/compose.yaml")
LL_CONF = os.path.expanduser("~/homelab/arr/lazylibrarian/config.ini")
APPS = {"prowlarr": ("http://127.0.0.1:9696/api/v1"),
        "sonarr": ("http://127.0.0.1:8989/api/v3"),
        "radarr": ("http://127.0.0.1:7878/api/v3")}
PRECIOUS = {"internet archive (homelab)":
            "it's your only legal indexer at the moment, so films, TV and books "
            "would have nowhere to search until you add another"}

USAGE = f"""How to use it:
  {SELF} "Indexer name"        remove an indexer, after showing what will go and asking to confirm
  {SELF} "Indexer name" --yes  remove it without asking
  {SELF} --list                show the indexers currently in Prowlarr
  {SELF} --help                show this help

Always put the indexer name in quotes, as most names contain spaces or brackets."""

KEYS = {}


def fail(problem, fix, code=1):
    print(f"\nProblem: {problem}\nHow to fix it: {fix}\n", file=sys.stderr)
    sys.exit(code)


def key(app):
    if app in KEYS:
        return KEYS[app]
    try:
        out = subprocess.run(
            ["docker", "exec", app, "sed", "-n",
             r"s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p", "/config/config.xml"],
            capture_output=True, text=True)
    except FileNotFoundError:
        fail("Docker isn't available here.",
             "Run this on homelab-01, where the arr stack runs.", 2)
    if out.returncode != 0 or not out.stdout.strip():
        fail(f"Couldn't read {app}'s API key, so the {app} container is probably not running.",
             f"Check it with:\n  docker ps --filter name={app}\n"
             f"If it isn't shown as Up, start it with:\n  docker compose -f {COMPOSE} up -d {app}", 2)
    KEYS[app] = out.stdout.strip()
    return KEYS[app]


def api(app, method, path, body=None):
    req = urllib.request.Request(
        f"{APPS[app]}/{path}", method=method,
        headers={"X-Api-Key": key(app), "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = resp.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        fail(f"{app} refused a request ({e.code} on {path}).",
             f"See {app}'s full error with:\n  docker logs --tail 30 {app}", 2)
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        fail(f"Couldn't reach {app}'s API ({e}).",
             f"Check it's running with:\n  docker ps --filter name={app}\n"
             "If it was only just started, wait 30 seconds and try again.", 2)


def app_copy(app, name):
    """The copy of this indexer in Sonarr or Radarr, if any (Prowlarr adds ' (Prowlarr)')."""
    return next((i for i in api(app, "GET", "indexer") if i["name"].startswith(name)), None)


def ll_sections(conf, prowlarr_id):
    host = f"http://prowlarr:9696/{prowlarr_id}/api"
    return [s for s in conf.sections()
            if s.startswith("Torznab_") and conf.get(s, "host", fallback="") == host]


def read_ll():
    conf = configparser.ConfigParser(interpolation=None)
    conf.optionxform = str
    if not os.path.exists(LL_CONF):
        return None
    conf.read(LL_CONF)
    return conf


def remove_from_ll(prowlarr_id):
    """Take the provider out of LazyLibrarian's config and renumber the rest."""
    with open(LL_CONF) as f:
        lines = f.read().splitlines()
    host = f"host = http://prowlarr:9696/{prowlarr_id}/api"

    # Split into sections, keeping everything outside Torznab blocks untouched
    blocks, current = [], None
    for line in lines:
        if line.startswith("["):
            current = [line]
            blocks.append(current)
        elif current is None:
            blocks.append([line])
            current = blocks[-1]
        else:
            current.append(line)
    kept, n = [], 0
    for block in blocks:
        head = block[0]
        if re.fullmatch(r"\[Torznab_\d+\]", head):
            if any(l.strip() == host for l in block):
                continue
            block = [f"[Torznab_{n}]"] + block[1:]
            n += 1
        kept.append(block)

    subprocess.run(["docker", "compose", "-f", COMPOSE, "stop", "lazylibrarian"],
                   check=True, capture_output=True)
    backup = f"{LL_CONF}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(LL_CONF, backup)
    with open(LL_CONF, "w") as f:
        f.write("\n".join(l for block in kept for l in block) + "\n")
    subprocess.run(["docker", "compose", "-f", COMPOSE, "start", "lazylibrarian"],
                   check=True, capture_output=True)
    return backup


def main():
    args = sys.argv[1:]
    if not args:
        fail("No indexer name given.", "\n" + USAGE)
    if args[0] in ("-h", "--help", "help"):
        print(__doc__ + "\n" + USAGE)
        return 0

    indexers = api("prowlarr", "GET", "indexer")
    tags = {t["id"]: t["label"] for t in api("prowlarr", "GET", "tag")}

    if args[0] == "--list":
        if not indexers:
            print("Prowlarr has no indexers.")
            return 0
        print("Indexers in Prowlarr:")
        for i in sorted(indexers, key=lambda i: i["name"].lower()):
            t = ", ".join(tags.get(x, str(x)) for x in i.get("tags", [])) or "no tags"
            print(f'  "{i["name"]}"  (ID {i["id"]}, {t})')
        return 0

    yes = "--yes" in args
    rest = [a for a in args if a != "--yes"]
    unknown = [a for a in rest if a.startswith("-")]
    if unknown:
        fail(f"'{unknown[0]}' isn't an option this script knows.", "\n" + USAGE)
    if len(rest) != 1:
        fail(f"Got {len(rest)} separate words, so the name probably wasn't in quotes.",
             f'Put the whole name in quotes, like this:\n  {SELF} "{" ".join(rest)}"')
    name = rest[0].strip()

    ix = next((i for i in indexers if i["name"].lower() == name.lower()), None)
    if ix is None:
        names = [i["name"] for i in indexers]
        lower = {n.lower(): n for n in names}
        options = [n for n in names if name.lower() in n.lower()][:5] or \
                  [lower[m] for m in difflib.get_close_matches(name.lower(), list(lower), n=5, cutoff=0.5)]
        if options:
            fix = "Did you mean one of these? Copy the line for the one you want:\n" + \
                  "\n".join(f'  {SELF} "{n}"' for n in options)
        else:
            fix = f"See the indexers Prowlarr actually has with:\n  {SELF} --list"
        fail(f"Prowlarr has no indexer called '{name}'.", fix)

    real, pid = ix["name"], ix["id"]
    have = {app: app_copy(app, real) for app in ("sonarr", "radarr")}
    conf = read_ll()
    ll = ll_sections(conf, pid) if conf else []

    print(f"This will remove '{real}' (Prowlarr ID {pid}) from:")
    print("  prowlarr")
    for app, copy in have.items():
        print(f"  {app}" if copy else f"  {app}: doesn't have it, nothing to do")
    print("  lazylibrarian" if ll else "  lazylibrarian: doesn't have it, nothing to do")
    if real.lower() in PRECIOUS:
        print(f"\nWarning: {PRECIOUS[real.lower()]}.")

    if not yes:
        if not sys.stdin.isatty():
            fail("Nothing was changed, as there's no one here to confirm.",
                 f'Add --yes to remove it without asking:\n  {SELF} "{real}" --yes')
        if input("\nType yes to go ahead: ").strip().lower() != "yes":
            print("Cancelled. Nothing was changed.")
            return 0

    api("prowlarr", "DELETE", f"indexer/{pid}")
    print(f"Removed from prowlarr.")
    api("prowlarr", "POST", "command", {"name": "ApplicationIndexerSync"})

    for app, copy in have.items():
        if not copy:
            continue
        for _ in range(6):
            time.sleep(5)
            if not app_copy(app, real):
                break
        else:
            api(app, "DELETE", f"indexer/{copy['id']}")
        print(f"Removed from {app}.")

    if ll:
        try:
            backup = remove_from_ll(pid)
        except subprocess.CalledProcessError:
            fail(f"'{real}' is gone from Prowlarr, Sonarr and Radarr, but LazyLibrarian "
                 "couldn't be stopped or started to edit its config.",
                 f"Check it with:\n  docker ps --filter name=lazylibrarian\n"
                 f"Then run this again with the same name to finish:\n  {SELF} \"{real}\"", 2)
        print(f"Removed from lazylibrarian (its old config is saved as {backup}).")

    print(f"\nDone. '{real}' has been removed everywhere.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped. If it had already printed 'Removed from prowlarr', run it again "
              "with the same name to finish the other apps. Otherwise nothing was changed.",
              file=sys.stderr)
        sys.exit(130)
