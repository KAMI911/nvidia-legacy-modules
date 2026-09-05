#!/usr/bin/env bash
# reprotest-wrap.sh <series> <target> — build twice with varied environment and
# diffoscope the .debs. Any difference fails the release gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILDDIR="${BUILDDIR:-$ROOT/../build}"
series="${1:?}"; target="${2:?}"

command -v reprotest >/dev/null || { echo "reprotest not installed"; exit 1; }

# $BUILDDIR/dkms-src/$series-$target (sbuild-wrap.sh's render scratch dir)
# holds only debian/ -- dpkg-source -b treats the missing payload as deleted
# relative to the .orig, which is fine for building a *.dsc but not for
# running dpkg-buildpackage directly here, which needs the real, complete
# unpacked source (payload + debian/ on top) the way sbuild's chroot gets
# it. Extract that properly from the .dsc sbuild-wrap.sh already built.
dsc="$(ls -t "$BUILDDIR"/nvidia-legacy-"$series"_*.dsc 2>/dev/null | head -1 || true)"
[ -n "$dsc" ] || { echo "no .dsc for $series in $BUILDDIR -- run sbuild-wrap.sh first"; exit 1; }
work="$BUILDDIR/reprotest-src/$series-$target"
rm -rf "$work"
mkdir -p "$(dirname "$work")"
dpkg-source -x "$dsc" "$work" >/dev/null

cd "$work"
# reprotest runs dpkg-buildpackage directly on this runner, not inside
# sbuild's schroot -- unlike the sbuild-wrap.sh build, nothing has installed
# this package's own Build-Depends here yet.
command -v mk-build-deps >/dev/null || { echo "devscripts (mk-build-deps) not installed"; exit 1; }
sudo mk-build-deps --install --remove \
  --tool='apt-get -y --no-install-recommends -o Debug::pkgProblemResolver=yes' \
  debian/control

# Vary everything reprotest safely can; keep build path constant (NVIDIA blob
# Makefiles are not path-agnostic) and user_group constant (fakeroot quirks).
reprotest \
  --vary=-user_group \
  --vary=-build_path \
  --vary=+kernel,+time,+timezone,+locales,+environment,+umask,+aslr \
  --store-dir="$BUILDDIR/reprotest-$series-$target" \
  "dpkg-buildpackage --no-sign -b" \
  "../*.deb"
echo "REPROTEST: identical"
