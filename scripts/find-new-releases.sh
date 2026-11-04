#!/usr/bin/env bash
# Print a JSON build matrix of TrueNAS release tags that have no Wi-Fi bundle
# yet in $GITHUB_REPOSITORY. A tag qualifies when it exists in truenas/linux,
# truenas/zfs and truenas/scst (all three are tagged per release).
#   find-new-releases.sh            -> new tags only
#   find-new-releases.sh --latest   -> newest tag of every tracked line, with
#                                      bundle_rev bumped (used after patch/config changes)
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:-new}

tags_of() { git ls-remote --tags --refs "https://github.com/truenas/$1" | sed 's#.*refs/tags/##'; }
linux=$(tags_of linux); zfs=$(tags_of zfs); scst=$(tags_of scst)
min=$(awk '$1 == "MIN_TAG" { print $2 }' config/releases.conf)

# Existing bundles: tag -> highest rev
existing=$(gh release list -R "$GITHUB_REPOSITORY" --limit 1000 --json tagName -q '.[].tagName' 2>/dev/null || true)

python3 - "$mode" "$min" <<PY
import json, re, sys
mode, min_tag = sys.argv[1], sys.argv[2]
rules = []
for line in open("config/releases.conf"):
    line = line.split("#", 1)[0].strip()
    if line and not line.startswith("MIN_TAG"):
        rx, deb = line.split()
        rules.append((re.compile(rx), deb))
linux = set("""$linux""".split()); zfs = set("""$zfs""".split()); scst = set("""$scst""".split())
existing = {}
for t in """$existing""".split():
    m = re.match(r"^wifi-(TS-.+)-r(\d+)$", t)
    if m:
        existing[m.group(1)] = max(existing.get(m.group(1), 0), int(m.group(2)))

def key(tag):
    parts = re.findall(r"\d+|[A-Z]+", tag)
    return [int(p) if p.isdigit() else -1 if p in ("BETA", "RC") else 0 for p in parts]

def ver_line(tag):   # "TS-25.10.8" -> "25.10"
    return ".".join(tag[3:].split(".")[:2])

cands = []
for t in linux & zfs & scst:
    for rx, deb in rules:
        if rx.match(t) and (not min_tag or key(t) >= key(min_tag)):
            cands.append((t, deb))
            break

out = []
if mode == "--latest":
    newest = {}
    for t, deb in cands:
        l = ver_line(t)
        if l not in newest or key(t) > key(newest[l][0]):
            newest[l] = (t, deb)
    for t, deb in newest.values():
        out.append({"tag": t, "debian": deb, "rev": existing.get(t, 0) + 1})
else:
    for t, deb in sorted(cands, key=lambda c: key(c[0])):
        if t not in existing:
            out.append({"tag": t, "debian": deb, "rev": 1})
print(json.dumps({"include": out}))
PY
