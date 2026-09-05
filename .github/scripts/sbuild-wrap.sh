#!/usr/bin/env bash
# sbuild-wrap.sh <series> <target> — build the source package in a clean chroot
# for every arch that series/target needs. Captures .buildinfo. blhc on the log.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMON="$ROOT/common"
BUILDDIR="${BUILDDIR:-$ROOT/../build}"
series="${1:?}"; target="${2:?}"

# common/drivers.yaml is the single source of truth for target codenames
# (also used by build-reprotest.yml's own chroot-creation step) — a
# hardcoded duplicate list here once went stale and broke ubuntu2604.
cn="$(python3 -c "import yaml;print(yaml.safe_load(open('$COMMON/drivers.yaml'))['targets']['$target']['codename'])")"

# arches for this (series,target) from series.yaml
mapfile -t arches < <("$(dirname "$0")/target-arches.sh" "$series" "$target")
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
dsc="$(ls -t "$BUILDDIR"/nvidia-legacy-"$series"_*.dsc 2>/dev/null | head -1 || true)"
[ -n "$dsc" ] || { echo "no .dsc for $series in $BUILDDIR"; exit 1; }

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
