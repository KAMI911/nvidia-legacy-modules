#!/usr/bin/env bash
# reprotest-wrap.sh <series> <target> — build twice with varied environment and
# diffoscope the .debs. Any difference fails the release gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILDDIR="${BUILDDIR:-$ROOT/../build}"
series="${1:?}"; target="${2:?}"
tree="$BUILDDIR/dkms-src/$series-$target"
[ -d "$tree/debian" ] || { echo "render first"; exit 1; }

command -v reprotest >/dev/null || { echo "reprotest not installed"; exit 1; }

cd "$tree"
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
