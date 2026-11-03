#!/usr/bin/env python3
"""update-stack: weekly automatic updates for the low-risk containers.

Pulls new images for the containers on the AUTO list, recreates only the
ones whose image changed, checks each comes back healthy, and sends one ntfy
summary. Plex is restarted every run, which makes it install the newest
version. Old images are kept for 8 days so any update can be rolled back.

Everything else (Caddy, AdGuard, Vaultwarden, the VPN, qBittorrent, the arr
apps, Prometheus, Alertmanager) is notify-only: Diun tells you when an update
exists, and you update those by hand when you can watch them.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

SELF = "~/homelab/scripts/update-stack.py"
TOPIC_FILE = os.path.expanduser("~/.ntfy-topic")
LOG = os.path.expanduser("~/homelab/logs/update-stack.log")
AUTO = ["homepage", "uptime-kuma", "blackbox-exporter", "node-exporter",
        "smartctl-exporter", "jellyfin", "ersatztv", "makemkv", "ollama",
        "calibre-web-automated", "lazylibrarian", "diun", "maps", "plex"]
ALWAYS_RESTART = {"plex"}       # updates itself on every start
HEALTH_WAIT = 180               # seconds to wait for a healthy container
KEEP_OLD_IMAGES_HOURS = 192     # 8 days, so rollbacks stay possible

USAGE = f"""How to use it:
  {SELF}              update the auto tier now (cron runs this weekly)
  {SELF} --dry-run    download new images and report what would update, without restarting anything
  {SELF} --list       show which containers are updated automatically and which are notify-only
  {SELF} --help       show this help"""


def fail(problem, fix, code=1):
    print(f"\nProblem: {problem}\nHow to fix it: {fix}\n", file=sys.stderr)
    sys.exit(code)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def inspect(name):
    r = run(["docker", "inspect", name])
    return json.loads(r.stdout)[0] if r.returncode == 0 else None


def compose_cmd(c):
    """docker compose arguments for this container's project, from Docker's labels."""
    labels = c["Config"].get("Labels") or {}
    files = labels.get("com.docker.compose.project.config_files")
    project = labels.get("com.docker.compose.project")
    service = labels.get("com.docker.compose.service")
    if not (files and project and service):
        return None, None
    cmd = ["docker", "compose", "-p", project]
    for f in files.split(","):
        cmd += ["-f", f]
    return cmd, service


def image_id(image):
    r = run(["docker", "image", "inspect", image, "--format", "{{.Id}}"])
    return r.stdout.strip() if r.returncode == 0 else None


def wait_ready(name):
    deadline = time.time() + HEALTH_WAIT
    time.sleep(15)
    while time.time() < deadline:
        c = inspect(name)
        if c:
            state = c["State"]
            health = (state.get("Health") or {}).get("Status")
            if health == "healthy":
                return True, "healthy"
            if health == "unhealthy":
                return False, "reported unhealthy"
            if health is None and state.get("Running") and not state.get("Restarting"):
                time.sleep(15)
                again = inspect(name)
                if again and again["State"].get("Running") and not again["State"].get("Restarting"):
                    return True, "running"
        time.sleep(10)
    return False, f"not ready after {HEALTH_WAIT} seconds"


def notify(title, msg, failed):
    if not os.path.exists(TOPIC_FILE):
        return
    topic = open(TOPIC_FILE).read().strip()
    req = urllib.request.Request(
        f"https://ntfy.sh/{topic}", data=msg.encode(), method="POST",
        headers={"Title": title, "Priority": "high" if failed else "default"})
    try:
        urllib.request.urlopen(req, timeout=30)
    except Exception:
        print("Couldn't send the ntfy summary, so check the log instead.", file=sys.stderr)


def main():
    args = sys.argv[1:]
    known = {"--dry-run", "--list", "--help", "-h", "help"}
    unknown = [a for a in args if a not in known]
    if unknown:
        fail(f"'{unknown[0]}' isn't an option this script knows.", "\n" + USAGE)
    if any(a in ("--help", "-h", "help") for a in args):
        print(__doc__ + "\n" + USAGE)
        return 0
    if run(["docker", "info"]).returncode != 0:
        fail("Docker isn't available or isn't running.",
             "Run this on homelab-01. If you are, check Docker with:\n  systemctl status docker --no-pager", 2)

    if "--list" in args:
        running = run(["docker", "ps", "--format", "{{.Names}}"]).stdout.split()
        print("Updated automatically every week:")
        for name in AUTO:
            print(f"  {name}" + ("" if name in running else "  (not running, will be skipped)"))
        print("\nNotify only (Diun alerts you, update these by hand):")
        for name in sorted(n for n in running if n not in AUTO):
            print(f"  {name}")
        return 0

    dry = "--dry-run" in args
    results, failed = [], False

    for name in AUTO:
        c = inspect(name)
        if c is None:
            results.append(f"{name}: not found, skipped. Remove it from AUTO in {SELF} if it's gone for good.")
            continue
        cmd, service = compose_cmd(c)
        if cmd is None:
            results.append(f"{name}: not started by docker compose, so skipped. Update it by hand.")
            continue
        image, old = c["Config"]["Image"], c["Image"]

        pull = run(cmd + ["pull", service])
        if pull.returncode != 0:
            results.append(f"{name}: FAILED to download its new image, left as it was. "
                           f"Try by hand with: {' '.join(cmd)} pull {service}")
            failed = True
            continue
        new = image_id(image)
        changed = new and new != old

        if not changed and name not in ALWAYS_RESTART:
            results.append(f"{name}: already up to date")
            continue
        verb = "update" if changed else "restart (to self-update)"
        if dry:
            results.append(f"{name}: would {verb}")
            continue

        if changed:
            up = run(cmd + ["up", "-d", service])
        else:
            up = run(["docker", "restart", name])
        ok, how = (wait_ready(name) if up.returncode == 0 else (False, "failed to start"))
        if ok:
            results.append(f"{name}: {verb}d, {how}")
        else:
            failed = True
            rollback = (f"docker tag {old} {image} && {' '.join(cmd)} up -d {service}"
                        if changed else f"docker logs --tail 30 {name}")
            results.append(f"{name}: FAILED after {verb} ({how}). To fix it: {rollback}")

    if not dry:
        run(["docker", "image", "prune", "-f", "--filter", f"until={KEEP_OLD_IMAGES_HOURS}h"])

    apt = run(["bash", "-c", "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l"]).stdout.strip()
    results.append(f"Ubuntu: {apt} non-security package updates waiting (security ones install automatically)")

    title = ("Weekly updates (dry run)" if dry else "Weekly updates") + (": something FAILED" if failed else "")
    summary = "\n".join(results)
    print(title + "\n" + summary)
    if not dry:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {title}\n{summary}\n\n")
        notify(title, summary, failed)
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped part way. Any container already updated stays updated, and the "
              "rest are unchanged. Run it again to finish.", file=sys.stderr)
        sys.exit(130)
