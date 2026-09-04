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
  # sbuild's own exit code has proven unreliable here (e.g. a "Not cleaning
  # session: cloned chroot in use" cleanup warning can flip it non-zero on an
  # otherwise "Status: successful" build) — verify real success by checking
  # for the .changes it should have produced, instead of trusting the code.
  set +e
  SOURCE_DATE_EPOCH="$(dpkg-parsechangelog -l"$tree/debian/changelog" -STimestamp)" \
  sbuild -v --no-run-lintian --dist="$cn" --arch="$arch" "$archall_flag" \
    --build-dir="$BUILDDIR" --stats-dir="$BUILDDIR/stats" \
    --dpkg-source-opts="--no-check" \
    "$dsc" 2>&1 | tee "$BUILDDIR/build-$series-$cn-$arch.log"
  sb_rc="${PIPESTATUS[0]}"
  set -e
  changes="$(ls -t "$BUILDDIR"/nvidia-legacy-"$series"_*_"$arch".changes 2>/dev/null | head -1)"
  if [ -z "$changes" ]; then
    echo "sbuild: no .changes for $arch (exit $sb_rc) — real failure"
    exit 1
  elif [ "$sb_rc" != 0 ]; then
    echo "sbuild: exited $sb_rc but $(basename "$changes") was produced — treating as success"
  fi

  # hardening check on the actual build log. The dkms flavour compiles
  # nothing at package-build time (dkms itself builds the module later, on
  # the target) — blhc's "No compiler commands!" there is expected, not a
  # real hardening gap.
  if command -v blhc >/dev/null; then
    out="$(blhc --all "$BUILDDIR/build-$series-$cn-$arch.log" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then
      echo "blhc: clean"
    elif [ "$out" = "No compiler commands!" ]; then
      echo "blhc: no compiler commands (expected, dkms flavour compiles nothing at build time)"
    else
      echo "$out"; echo "blhc: hardening issues"; exit 1
    fi
  fi
done
ls -l "$BUILDDIR"/*.buildinfo 2>/dev/null || echo "WARN: no .buildinfo produced"
