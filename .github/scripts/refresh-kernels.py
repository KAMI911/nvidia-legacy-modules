#!/usr/bin/env python3
"""refresh-kernels.py — append newly released kernels to tests/module-build/kernels.yaml.

Sources:
  * Debian:   Packages index of each suite + backports  (linux-headers-*-<arch>)
  * Ubuntu:   <suite>-updates + <suite>-hwe            (linux-headers-*-generic)
  * kernel-ppa: ppa:canonical-kernel-team/ppa           (Ubuntu, non-blocking)
  * mainline: https://kernel.ubuntu.com/mainline/       (latest stable, non-blocking)

New entries land as `blocking: false` — a human promotes them to blocking once a
run has proven green, so a fresh kernel never turns the release gate red on its own.

Uses ruamel.yaml (round-trip mode) rather than plain PyYAML: the file carries
hand-written explanatory comments (kernel-specific build-compat notes, fetch-kind
documentation) that a bare yaml.safe_dump would silently discard on the first
run that actually finds something to append.

Distro archives keep many old kernel-header builds resolvable in the Packages
index (an old point-release rarely gets pruned), so a naive "add every match
not already known" would, on the first-ever run against a long-stale file,
bulk-import that whole back-catalogue in one PR -- and module-build/run.sh
spins up one container per kernels.yaml entry, so that would multiply CI time
by however many old kernels the archive still lists. Instead, per target (and
per Debian arch), only the single highest-versioned *new* ABI is added each
run: a weekly cadence then catches up one release at a time, same as if a
human were doing it.
"""
import pathlib, re, sys, urllib.request, gzip
from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap

ROOT = pathlib.Path(__file__).resolve().parents[2]
KFILE = ROOT / "tests" / "module-build" / "kernels.yaml"

yaml = YAML()
yaml.preserve_quotes = True
yaml.width = 4096  # don't wrap the flow-style entry mappings
yaml.indent(mapping=2, sequence=4, offset=2)  # match the file's "  - {...}" style
with KFILE.open() as f:
    doc = yaml.load(f)

DEB = {
    "debian11": ("bullseye", ["amd64", "i386"]),
    "debian12": ("bookworm", ["amd64", "i386"]),
    "debian13": ("trixie",   ["amd64", "i386"]),
}
UBU = {
    "ubuntu2004": "focal", "ubuntu2204": "jammy", "ubuntu2404": "noble",
    "ubuntu2604": "resolute",
}


def fetch_packages(url: str) -> str:
    try:
        raw = urllib.request.urlopen(url, timeout=30).read()
    except Exception as e:
        print(f"  warn: {url}: {e}", file=sys.stderr)
        return ""
    if url.endswith(".gz"):
        return gzip.decompress(raw).decode("utf-8", "replace")
    return raw.decode("utf-8", "replace")


def known_abis(target: str) -> set:
    return {e["abi"] for e in doc.get(target, [])}


def version_key(abi: str):
    return tuple(int(p) if p.isdigit() else p for p in re.split(r"(\d+)", abi))


def pick_latest_new(matches, have):
    """matches: iterable of (pkg, ver). Returns the single (abi, pkg, ver)
    with the highest ABI among those not in `have`, or None."""
    candidates = []
    for pkg, ver in matches:
        abi = pkg.replace("linux-headers-", "")
        if abi not in have:
            candidates.append((abi, pkg, ver))
    if not candidates:
        return None
    candidates.sort(key=lambda c: version_key(c[0]))
    return candidates[-1]


def add(target: str, abi: str, pkg: str, ver: str, fetch: str, arch: str = "amd64"):
    entry = CommentedMap(
        [("abi", abi), ("pkg", pkg), ("ver", ver), ("fetch", fetch), ("blocking", False)]
    )
    if arch != "amd64":
        entry["arch"] = arch
    entry.fa.set_flow_style()
    doc.setdefault(target, []).append(entry)
    print(f"  + {target}: {abi} ({pkg} {ver})")


changed = False
for tgt, (suite, arches) in DEB.items():
    have = known_abis(tgt)
    for arch in arches:
        idx = fetch_packages(
            f"http://deb.debian.org/debian/dists/{suite}/main/binary-{arch}/Packages.gz")
        matches = [
            (m.group(1), m.group(2))
            for m in re.finditer(r"^Package: (linux-headers-[\d.]+-\d+-(?:amd64|686-pae))\n"
                                  r"(?:.*\n)*?Version: (\S+)", idx, re.M)
        ]
        picked = pick_latest_new(matches, have)
        if picked:
            abi, pkg, ver = picked
            add(tgt, abi, pkg, ver, "archive", "i386" if "686" in abi else "amd64")
            changed = True

for tgt, suite in UBU.items():
    have = known_abis(tgt)
    matches = []
    for pocket in (f"{suite}-updates", suite):
        idx = fetch_packages(
            f"http://archive.ubuntu.com/ubuntu/dists/{pocket}/main/binary-amd64/Packages.gz")
        matches.extend(
            (m.group(1), m.group(2))
            for m in re.finditer(r"^Package: (linux-headers-[\d.]+-\d+-generic)\n"
                                  r"(?:.*\n)*?Version: (\S+)", idx, re.M)
        )
    picked = pick_latest_new(matches, have)
    if picked:
        abi, pkg, ver = picked
        add(tgt, abi, pkg, ver, "archive")
        changed = True

if changed:
    with KFILE.open("w") as f:
        yaml.dump(doc, f)
    print("kernels.yaml updated")
else:
    print("no new kernels")
