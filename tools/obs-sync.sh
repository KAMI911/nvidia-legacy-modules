#!/usr/bin/env bash
# obs-sync.sh <series> [--target T] [--abi A] [--dry-run]
#
# Push every per-ABI packaging tree under packaging/<series>/<target>/<abi>/ to
# OBS as its own package  nvidia-legacy-<series>-kernel-<abi>  (build on, but
# only for that ABI's distro repository; publish off).
#
# Needs, in $BUILDDIR (default ../build):
#   nvidia-legacy-<series>_<ver>.orig.tar.xz   (from assemble-source.sh)
# Run `make gen` first (or gen-kernel-packages.py) so packaging/ exists.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILDDIR="${BUILDDIR:-$ROOT/../build}"
PROJECT="${OBS_PROJECT:-home:KAMI911:nvidia-legacy:modules}"
DRY=0; only_target=""; only_abi=""
series="${1:?usage: obs-sync.sh <series> [--target T] [--abi A] [--dry-run]}"; shift || true
while [ $# -gt 0 ]; do case "$1" in
  --target) only_target="$2"; shift ;; --abi) only_abi="$2"; shift ;;
  --dry-run) DRY=1 ;; *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; shift; done
command -v osc >/dev/null || { echo "osc not installed"; exit 1; }

uv="$(python3 -c "import yaml;print(yaml.safe_load(open('$ROOT/common/drivers.yaml'))['series']['$series']['version'])")"
orig="$BUILDDIR/nvidia-legacy-${series}_${uv}.orig.tar.xz"
[ -f "$orig" ] || { echo "missing $orig — run assemble-source.sh first"; exit 1; }

declare -A REPO=(
  [debian11]=Debian_11 [debian12]=Debian_12 [debian13]=Debian_13
  [ubuntu2004]=xUbuntu_20.04 [ubuntu2204]=xUbuntu_22.04
  [ubuntu2404]=xUbuntu_24.04 [ubuntu2604]=xUbuntu_26.04)

n=0
for tree in "$ROOT"/packaging/"$series"/*/*/; do
  [ -f "$tree/debian/control" ] || continue
  abi="$(basename "$tree")"; target="$(basename "$(dirname "$tree")")"
  [ -z "$only_target" ] || [ "$only_target" = "$target" ] || continue
  [ -z "$only_abi" ] || [ "$only_abi" = "$abi" ] || continue
  repo="${REPO[$target]:?no OBS repo for $target}"
  pkg="$(sed -n 's/^Source: //p' "$tree/debian/control" | head -1)"
  [ -n "$pkg" ] || { echo "no Source: in $tree"; exit 1; }
  echo ":: $pkg  ($target -> $repo)"

  cp -f "$orig" "$BUILDDIR/${pkg}_${uv}.orig.tar.xz"
  ( cd "$BUILDDIR" && dpkg-source --no-check -b "$tree" >/dev/null )
  dsc="$(ls "$BUILDDIR/${pkg}_${uv}"*.dsc | head -1)"

  # ensure the OBS package exists, build only in $repo, publish off
  meta="<package name=\"$pkg\" project=\"$PROJECT\">
  <title>NVIDIA legacy $series prebuilt module — $abi</title>
  <person userid=\"$(cut -d: -f2 <<<"$PROJECT")\" role=\"maintainer\"/>
  <build><disable/><enable repository=\"$repo\"/></build>
  <publish><disable/></publish>
</package>"
  if [ "$DRY" = 1 ]; then
    echo "   would PUT _meta + commit $(basename "$dsc")"; n=$((n+1)); continue
  fi
  osc api -X PUT "/source/$PROJECT/$pkg/_meta" --data "$meta" >/dev/null

  wd="$(mktemp -d)"
  ( cd "$wd" && osc co "$PROJECT" "$pkg" ) >/dev/null
  pdir="$wd/$PROJECT/$pkg"
  cp "$dsc" "${dsc%.dsc}.debian.tar."* "$BUILDDIR/${pkg}_${uv}.orig.tar.xz" "$pdir/"
  ( cd "$pdir" && osc addremove >/dev/null &&
    osc ci -m "CI: $pkg $uv $(date -u +%FT%TZ) from ${GITHUB_SHA:-$(git -C "$ROOT" rev-parse --short HEAD)}" )
  rm -rf "$wd"
  n=$((n+1))
done
echo "obs-sync: $n per-ABI package(s) for $series -> $PROJECT$([ "$DRY" = 1 ] && echo '  (dry-run)')"
