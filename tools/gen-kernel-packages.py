#!/usr/bin/env python3
"""gen-kernel-packages.py — expand tools/kernels.yaml into one buildable source
package per (series, target, ABI).

For each ABI it:
  * renders the `modules`-flavour debian/ from common/ (render-debian.py)
  * rewrites the source/binary package names to embed the ABI
      nvidia-legacy-<series>-kernel-<abi>
  * pins the exact linux-headers-<abi> (= <pkg_ver>) as a Build-Depends
  * writes packaging/<series>/<target>/<abi>/debian/

The prebuilt .ko is compiled by debian/helpers/build-prebuilt-module.sh inside
the build chroot, which installs exactly that one linux-headers package.

Usage:
  gen-kernel-packages.py --series 390xx [--target debian13] [--abi 6.12.0-1-amd64]
  gen-kernel-packages.py --all
"""
from __future__ import annotations
import argparse, pathlib, re, subprocess, sys, yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
COMMON = ROOT / "common"
RENDER = COMMON / "scripts" / "render-debian.py"


def series_targets() -> dict:
    return yaml.safe_load((ROOT / "series.yaml").read_text())["build"]


def abi_arch(abi: str) -> str:
    if abi.endswith(("-amd64", "-generic")):
        return "amd64"
    if "686" in abi or abi.endswith("-i386"):
        return "i386"
    return "amd64"


def render_one(series: str, target: str, abi: str, pkg_ver: str, blocking: bool) -> pathlib.Path:
    out = ROOT / "packaging" / series / target / abi
    subprocess.run([sys.executable, str(RENDER), "--series", series,
                    "--target", target, "--flavour", "modules",
                    "--out", str(out)], check=True)
    debian = out / "debian"
    ctl = (debian / "control").read_text()

    kpkg = f"linux-headers-{abi}"
    bdep = kpkg if pkg_ver == "*" else f"{kpkg} (= {pkg_ver})"
    src_old, src_new = f"nvidia-legacy-{series}", f"nvidia-legacy-{series}-kernel-{abi}"
    ctl = ctl.replace(f"Source: {src_old}\n", f"Source: {src_new}\n")
    ctl = re.sub(r"^(Build-Depends:\n)", r"\1 %s,\n" % bdep, ctl, count=1, flags=re.M)

    # changelog source name must match control Source
    cl = debian / "changelog"
    cl.write_text(cl.read_text().replace(f"{src_old} (", f"{src_new} (", 1))

    # the per-ABI .ko package
    arch = abi_arch(abi)
    ko_pkg = (
        f"\nPackage: nvidia-legacy-{series}-kernel-{abi}\n"
        f"Architecture: {arch}\n"
        f"Section: non-free/kernel\n"
        f"Depends: ${{misc:Depends}}, linux-image-{abi}\n"
        f"Provides: nvidia-legacy-{series}-kernel-{abi},\n"
        f" nvidia-legacy-{series}-kernel-modules\n"
        f"Description: NVIDIA legacy {series} prebuilt module for Linux {abi}\n"
        f" The nvidia/-modeset/-drm/-uvm modules from the {series} series,\n"
        f" compiled for the {abi} kernel ABI. No toolchain needed on the target.\n"
    )
    ctl = ctl.rstrip() + "\n" + ko_pkg
    (debian / "control").write_text(ctl)

    (debian / f"nvidia-legacy-{series}-kernel-{abi}.install").write_text(
        f"lib/modules/{abi}/updates/dkms/*.ko\n")

    # metapackage (idempotent: one file lists the newest ABI; see gen summary)
    (out / ".abi").write_text(f"{abi}\n{pkg_ver}\n{int(blocking)}\n")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--series"); ap.add_argument("--target"); ap.add_argument("--abi")
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()

    kdoc = yaml.safe_load((ROOT / "tools" / "kernels.yaml").read_text())
    build = series_targets()
    made = []
    for series, cfg in build.items():
        if a.series and series != a.series:
            continue
        for target in cfg["targets"]:
            if a.target and target != a.target:
                continue
            for arch, entries in kdoc.get(target, {}).items():
                fam = "debian" if target.startswith("debian") else "ubuntu"
                if arch not in cfg["archs"].get(fam, []):
                    continue
                for e in entries:
                    if a.abi and e["abi"] != a.abi:
                        continue
                    if not (COMMON / "debian-template" / series / "debian").is_dir():
                        print(f"skip {series}/{target}/{e['abi']} (no template yet)")
                        continue
                    made.append(render_one(series, target, e["abi"],
                                           e.get("pkg_ver", "*"),
                                           e.get("blocking", True)))
    print(f"generated {len(made)} per-ABI source trees")
    for p in made:
        print(" ", p.relative_to(ROOT))


if __name__ == "__main__":
    main()
