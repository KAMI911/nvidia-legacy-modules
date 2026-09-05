#!/usr/bin/env bash
# sbuild-wrap.sh <series> <target> — build the source package in a clean chroot
# for every arch that series/target needs. Captures .buildinfo. blhc on the log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$ROOT/common"
BUILDDIR="${BUILDDIR:-$ROOT/../build}"
series="${1:?}"; target="${2:?}"

declare -A codename=(
  [debian11]=bullseye [debian12]=bookworm [debian13]=trixie
  [ubuntu2004]=focal [ubuntu2204]=jammy [ubuntu2404]=noble)
cn="${codename[$target]:?unknown target}"

# arches for this (series,target) from series.yaml
mapfile -t arches < <(python3 - "$ROOT/series.yaml" "$series" "$target" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1])); s, t = sys.argv[2], sys.argv[3]
cfg = doc["build"][s]
fam = "debian" if t.startswith("debian") else "ubuntu"
for a in cfg["archs"].get(fam, []):
    # i386 kernel module only where the distro ships an i386 kernel
    if a == "i386" and fam == "ubuntu":
        continue
    print(a)
PY
)
[ "${#arches[@]}" -gt 0 ] && echo "arches: ${arches[*]}" || { echo "nothing to build"; exit 0; }

mkdir -p "$BUILDDIR"
"$COMMON/scripts/verify-run.sh" "$series"
"$COMMON/scripts/assemble-source.sh" "$series" "$BUILDDIR"

# Render into a scratch dir, *not* packaging/$series/$target: that path is
# where gen-kernel-packages.py commits per-ABI trees (packaging/$series/$target/<abi>/),
# and dpkg-source would see those sibling directories as unexpected upstream
# changes and abort.
tree="$BUILDDIR/dkms-src/$series-$target"
mkdir -p "$tree"
python3 "$COMMON/scripts/render-debian.py" --series "$series" --target "$target" --flavour dkms --out "$tree"
( cd "$BUILDDIR" && dpkg-source --no-check -b "$tree" )
dsc="$(ls -t "$BUILDDIR"/nvidia-legacy-"$series"_*.dsc | head -1)"

first=1
for arch in "${arches[@]}"; do
  echo "==== sbuild $series/$cn/$arch ===="
  # build Architecture:all binaries (e.g. the -kernel-dkms package) once, on
  # the first arch only, or every subsequent --no-arch-all build would skip
  # them and no arch:all .deb would ever be produced.
  archall_flag="--no-arch-all"; [ "$first" = 1 ] && archall_flag="--arch-all"
  first=0
  # no --extra-repository: nothing here depends on another locally-built
  # .deb, and pointing apt at $BUILDDIR without a Packages index there just
  # makes `apt-get update` fail inside the chroot.
  # -v: without it sbuild writes the real build transcript only to its own
  # per-package .build file, not to stdout — a failure here would otherwise
  # show nothing but the exit code.
  # --no-run-lintian: this step verifies the dkms flavour still compiles and
  # packages, not full Debian policy compliance — that's static.yml's job
  # against the real product (the modules flavour). sbuild's own lintian pass
  # here fails the whole build on things that are either inherent to shipping
  # prebuilt proprietary NVIDIA binaries (embedded zlib, no PIE/RELRO,
  # sonames that don't match the upstream .so names) or false positives
  # (e.g. "missing-build-dependency-for-dh_-command dh_dkms" even though the
  # build just used it successfully) — none of which sbuild's blanket
  # error-on-any-lintian-E policy can distinguish from a real regression.
  # NB: a previous version of this script tried to second-guess sbuild's exit
  # code by checking for a produced .changes file — but that check's own
  # `ls ... | head -1` died silently under `set -e -o pipefail` whenever the
  # glob didn't match (ls's own non-zero exit propagates through the pipe),
  # aborting the script with zero diagnostic output. That bug, not sbuild
  # itself, was the real cause of several mysterious no-output CI failures.
  # Trust sbuild's own exit code directly.
  SOURCE_DATE_EPOCH="$(dpkg-parsechangelog -l"$tree/debian/changelog" -STimestamp)" \
  sbuild -v --no-run-lintian --dist="$cn" --arch="$arch" "$archall_flag" \
    --build-dir="$BUILDDIR" --stats-dir="$BUILDDIR/stats" \
    --dpkg-source-opts="--no-check" \
    "$dsc" 2>&1 | tee "$BUILDDIR/build-$series-$cn-$arch.log"

  # hardening check on the actual build log. The dkms flavour compiles
  # nothing at package-build time (dkms itself builds the module later, on
  # the target) — blhc's "No compiler commands!" there is expected, not a
  # real hardening gap.
  if command -v blhc >/dev/null; then
    # `if out=$(cmd)` (not `out=$(cmd); rc=$?`) — under `set -e`, a failing
    # command substitution used in a plain assignment aborts the script
    # immediately, before the next line ever runs; using the assignment
    # itself as an `if` condition is the one context bash exempts from -e.
    if out="$(blhc --all "$BUILDDIR/build-$series-$cn-$arch.log" 2>&1)"; then
      echo "blhc: clean"
    elif [ "$out" = "No compiler commands!" ]; then
      echo "blhc: no compiler commands (expected, dkms flavour compiles nothing at build time)"
    else
      echo "$out"; echo "blhc: hardening issues"; exit 1
    fi
  fi
done
ls -l "$BUILDDIR"/*.buildinfo 2>/dev/null || echo "WARN: no .buildinfo produced"
