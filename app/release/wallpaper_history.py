#!/usr/bin/env python3
"""Writes wallpaper-history.json: for every file of every built-in wallpaper, the fingerprints (SHA-256 of the
content with CRLF normalised to LF) of every version of it in git history plus the current one.

The app uses it when updating the copies in Pictures/Backgrounds: a copy whose files all match a version we
ever shipped is "unedited" and gets replaced by the new version; anything else was edited and is left alone.
Keys are "<Name>/<file>" with the "Wallpaper - " prefix removed (the folder name used in the app).

Usage: wallpaper_history.py REPO_ROOT OUT.json     (without git history: current files only)
"""
import hashlib, json, os, subprocess, sys

root, out = sys.argv[1], sys.argv[2]

def fp(data: bytes) -> str:
    return hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest()

def git(*args):
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True).stdout

history = {}
def add(key, h):
    history.setdefault(key, [])
    if h not in history[key]: history[key].append(h)

dirs = sorted(d for d in os.listdir(root) if d.startswith("Wallpaper - ") and os.path.isfile(os.path.join(root, d, "index.html")))
for d in dirs:
    name = d[len("Wallpaper - "):]
    for dp, _, files in os.walk(os.path.join(root, d)):
        for f in files:
            if f.endswith(".zip") or f == ".DS_Store": continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, os.path.join(root, d)).replace(os.sep, "/")
            with open(p, "rb") as fh: add(f"{name}/{rel}", fp(fh.read()))

try:
    seen_blobs = set()
    for d in dirs:
        name = d[len("Wallpaper - "):]
        commits = git("rev-list", "HEAD", "--", d).decode().split()
        for c in commits:
            for line in git("ls-tree", "-r", c, "--", d + "/").decode().splitlines():
                meta, path = line.split("\t", 1)
                blob = meta.split()[2]
                rel = path[len(d) + 1:]
                if rel.endswith(".zip") or rel.endswith(".DS_Store") or (blob, rel) in seen_blobs: continue
                seen_blobs.add((blob, rel))
                add(f"{name}/{rel}", fp(git("cat-file", "blob", blob)))
except Exception as e:  # no git / shallow clone: current files only
    print("wallpaper_history: git history unavailable (%s); using current files only" % e, file=sys.stderr)

with open(out, "w") as fh: json.dump(history, fh, indent=0, sort_keys=True)
print("wallpaper_history: %d files, %d fingerprints" % (len(history), sum(len(v) for v in history.values())))
