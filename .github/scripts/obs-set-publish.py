#!/usr/bin/env python3
"""obs-set-publish.py <series> <target> enable|disable
   obs-set-publish.py --disable-missing <passed.txt>

Edits the OBS package meta so <repository-for-target> has <publish><enable/> or
<disable/>. Uses `osc meta pkg -e` semantics via a fetch/modify/put cycle.

The modules flavour ships one prebuilt .ko per kernel ABI, so OBS carries one
package per (series, target, ABI) -- nvidia-legacy-<series>-kernel-<abi>, see
tools/gen-kernel-packages.py -- not one package per series. abi_packages()
below mirrors that generator's own (series, target) -> ABI selection so the
two never drift apart.
"""
import os, pathlib, subprocess, sys, xml.etree.ElementTree as ET

import yaml

PROJECT = os.environ.get("OBS_PROJECT", "home:KAMI911:nvidia-legacy:modules")
REPO = {
    "debian11": "Debian_11", "debian12": "Debian_12", "debian13": "Debian_13",
    "ubuntu2004": "xUbuntu_20.04", "ubuntu2204": "xUbuntu_22.04", "ubuntu2404": "xUbuntu_24.04",
}
ROOT = pathlib.Path(__file__).resolve().parents[2]


def abi_packages(series: str, target: str) -> list[str]:
    """Every OBS package gen-kernel-packages.py creates for (series, target)."""
    build = yaml.safe_load((ROOT / "series.yaml").read_text())["build"]
    kdoc = yaml.safe_load((ROOT / "tools" / "kernels.yaml").read_text())
    cfg = build[series]
    fam = "debian" if target.startswith("debian") else "ubuntu"
    allowed_archs = cfg["archs"].get(fam, [])
    pkgs = []
    for arch, entries in kdoc.get(target, {}).items():
        if arch not in allowed_archs:
            continue
        for e in entries:
            pkgs.append(f"nvidia-legacy-{series}-kernel-{e['abi']}")
    return pkgs


def osc(*a, inp=None):
    return subprocess.run(["osc", *a], input=inp, text=True,
                          capture_output=True, check=True).stdout


def set_pkg_flag(pkg: str, repo: str, enable: bool):
    meta = osc("meta", "pkg", PROJECT, pkg)
    root = ET.fromstring(meta)
    pub = root.find("publish")
    if pub is None:
        pub = ET.SubElement(root, "publish")
    for e in list(pub):
        if e.get("repository") == repo:
            pub.remove(e)
    ET.SubElement(pub, "enable" if enable else "disable", {"repository": repo})
    out = ET.tostring(root, encoding="unicode")
    osc("meta", "pkg", PROJECT, pkg, "-F", "-", inp=out)
    print(f"{pkg}: {repo} -> {'enable' if enable else 'disable'}")


def set_flag(series: str, target: str, enable: bool):
    repo = REPO[target]
    for pkg in abi_packages(series, target):
        try:
            set_pkg_flag(pkg, repo, enable)
        except subprocess.CalledProcessError as e:
            print(f"warn: {series}/{target} ({pkg}): {e.stderr}", file=sys.stderr)


if sys.argv[1] == "--disable-missing":
    passed = {tuple(l.split()) for l in pathlib.Path(sys.argv[2]).read_text().split("\n") if l and not l.startswith("#")}
    # every known combo not in passed -> disable
    doc = yaml.safe_load(open(ROOT / "series.yaml"))
    for s, cfg in doc["build"].items():
        for t in cfg["targets"]:
            if (s, t) not in passed:
                set_flag(s, t, False)
else:
    set_flag(sys.argv[1], sys.argv[2], sys.argv[3] == "enable")
