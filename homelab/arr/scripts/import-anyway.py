#!/usr/bin/env python3
"""import-anyway: import a film that Radarr has blocked only because it has
no audio track, as happens with silent films.

Only the no-audio rule is overridden. Files Radarr rejects for any other
reason (wrong film, a sample, unreadable) are refused, as forcing those in
would be a mistake.
"""
import difflib
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

SELF = "~/homelab/arr/scripts/import-anyway.py"
RADARR = "http://127.0.0.1:7878/api/v3"
COMPOSE = "~/homelab/arr/compose.yaml"
OVERRIDABLE = {"No audio tracks detected"}

USAGE = f"""How to use it:
  {SELF} "Film title"          list the blocked files for that film, numbered
  {SELF} "Film title" 2        import file number 2 from that list
  {SELF} --help                show this help

Always put the title in quotes. If two films share a title, add the year in
brackets, for example: "The Great Train Robbery (1903)"."""


def fail(problem, fix, code=1):
    print(f"\nProblem: {problem}\nHow to fix it: {fix}\n", file=sys.stderr)
    sys.exit(code)


def api_key():
    try:
        out = subprocess.run(
            ["docker", "exec", "radarr", "sed", "-n",
             r"s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p", "/config/config.xml"],
            capture_output=True, text=True)
    except FileNotFoundError:
        fail("Docker isn't available here.",
             "Run this on homelab-01, where the arr stack runs.", 2)
    if out.returncode != 0 or not out.stdout.strip():
        fail("Couldn't read Radarr's API key, so the Radarr container is probably not running.",
             "Check it with:\n  docker ps --filter name=radarr\n"
             f"If it isn't shown as Up, start it with:\n  docker compose -f {COMPOSE} up -d radarr", 2)
    return out.stdout.strip()


def api(method, path, body=None):
    req = urllib.request.Request(
        f"{RADARR}/{path}", method=method,
        headers={"X-Api-Key": KEY, "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        fail(f"Radarr refused the request ({e.code} on {path}).",
             "See Radarr's full error with:\n  docker logs --tail 30 radarr", 2)
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        fail(f"Couldn't reach Radarr's API ({e}).",
             "Check Radarr is running with:\n  docker ps --filter name=radarr\n"
             "If it was only just started, wait 30 seconds and try again.", 2)


def label(movie):
    return f"{movie['title']} ({movie['year']})"


def find_movie(text):
    m = re.match(r"^(.*?)\s*\((\d{4})\)\s*$", text)
    title, year = (m.group(1), int(m.group(2))) if m else (text, None)
    movies = api("GET", "movie")
    hits = [x for x in movies
            if x["title"].lower() == title.lower() and (year is None or x["year"] == year)]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        fail(f"Radarr has {len(hits)} films called '{title}'.",
             "Add the year in brackets to pick one:\n" +
             "\n".join(f'  {SELF} "{label(x)}"' for x in hits))
    names = [label(x) for x in movies]
    lower = {n.lower(): n for n in names}
    partial = [n for n in names if title.lower() in n.lower()][:5]
    close = [lower[c] for c in difflib.get_close_matches(text.lower(), list(lower), n=5, cutoff=0.5)]
    options = partial or close
    if options:
        fix = "Did you mean one of these? Copy the line for the one you want:\n" + \
              "\n".join(f'  {SELF} "{n}"' for n in options)
    else:
        fix = ("Check the title as Radarr shows it. The film has to be in Radarr "
               "already, added through Requests or Radarr itself.")
    fail(f"Radarr has no film called '{text}'.", fix)


def candidates(movie):
    if movie.get("hasFile"):
        fail(f"'{label(movie)}' is already imported, so there's nothing to do.",
             "Nothing needed. It should already be in Plex.")
    queue = api("GET", "queue?pageSize=200")["records"]
    items = [q for q in queue if q.get("movieId") == movie["id"] and q.get("downloadId")]
    if not items:
        fail(f"Nothing for '{label(movie)}' is waiting in Radarr's queue.",
             "It has to finish downloading before it can be imported. If it was never "
             "grabbed, request it again, then rerun this once it has downloaded.")
    files = []
    for q in items:
        found = api("GET", f"manualimport?downloadId={q['downloadId']}"
                           f"&movieId={movie['id']}&filterExistingFiles=false") or []
        for f in found:
            f["_downloadId"] = q["downloadId"]
            files.append(f)
    if not files:
        fail(f"Radarr found no video files in the download for '{label(movie)}'.",
             "It may still be downloading or waiting on the hold check. "
             "Run this again in a few minutes.")
    return files


def reasons(f):
    return [r["reason"] for r in f.get("rejections", [])]


def main():
    args = sys.argv[1:]
    if not args:
        fail("No film title given.", "\n" + USAGE)
    if args[0] in ("-h", "--help", "help"):
        print(__doc__ + "\n" + USAGE)
        return 0
    if args[0].startswith("-"):
        fail(f"'{args[0]}' isn't an option this script knows.", "\n" + USAGE)
    if len(args) > 2 or (len(args) == 2 and not args[1].isdigit()):
        words = args[:-1] if args[-1].isdigit() else args
        fail(f"Got {len(args)} separate words, so the title probably wasn't in quotes.",
             f'Put the whole title in quotes, like this:\n  {SELF} "{" ".join(words)}"')

    global KEY
    KEY = api_key()
    movie = find_movie(args[0].strip())
    files = candidates(movie)

    if len(args) == 1:
        best, best_size = None, -1
        print(f"Files in the blocked download for {label(movie)}:")
        for i, f in enumerate(files):
            r = reasons(f)
            bad = [x for x in r if x not in OVERRIDABLE]
            if bad:
                status = "can't import: " + "; ".join(bad)
            else:
                status = "can import" + (" (no audio, fine for a silent film)" if r else "")
                if f["size"] > best_size:
                    best, best_size = i, f["size"]
            print(f"  {i}  {f['size']/1048576:7.1f} MB  {f['relativePath']}  [{status}]")
        if best is None:
            fail("None of these files can be imported with this script.",
                 "Each one is rejected for a reason other than missing audio, "
                 "so the download is probably wrong. Remove it and search again.")
        print(f"\nThe largest importable file is usually the best quality. To import it:\n"
              f'  {SELF} "{label(movie)}" {best}')
        return 0

    n = int(args[1])
    if not 0 <= n < len(files):
        fail(f"There's no file number {n}. The list runs from 0 to {len(files) - 1}.",
             f'See the list again with:\n  {SELF} "{label(movie)}"')
    f = files[n]
    bad = [x for x in reasons(f) if x not in OVERRIDABLE]
    if bad:
        fail(f"File {n} is rejected for: {'; '.join(bad)}.",
             "This script only overrides the no-audio rule, so it won't force this file in. "
             f'Pick a file marked "can import" from:\n  {SELF} "{label(movie)}"')

    api("POST", "command", {
        "name": "ManualImport", "importMode": "auto",
        "files": [{"path": f["path"], "movieId": movie["id"], "quality": f["quality"],
                   "languages": f.get("languages", []),
                   "releaseGroup": f.get("releaseGroup", ""),
                   "downloadId": f["_downloadId"]}]})
    print(f"Importing {f['relativePath']} into {label(movie)}...")

    for _ in range(12):
        time.sleep(5)
        if api("GET", f"movie/{movie['id']}").get("hasFile"):
            print(f"Done. {label(movie)} is imported, and Plex should show it within a minute.")
            return 0
    fail("Radarr accepted the import but hadn't finished it after a minute.",
         f'Check again shortly with:\n  {SELF} "{label(movie)}"\n'
         "If it says the film is already imported, it worked. Otherwise see:\n"
         "  docker logs --tail 30 radarr")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped. If it had already printed 'Importing', Radarr will finish the "
              "import on its own. Otherwise nothing was changed.", file=sys.stderr)
        sys.exit(130)
