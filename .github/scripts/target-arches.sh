#!/usr/bin/env bash
# target-arches.sh <series> <target> — print the space-separated arches
# series.yaml says <series> builds for <target>'s distro family (debian/ubuntu),
# e.g. "amd64 i386". Shared by sbuild-wrap.sh and build-reprotest.yml's
# chroot-creation step so both agree on exactly what needs a schroot.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
series="${1:?}"; target="${2:?}"

python3 - "$ROOT/series.yaml" "$series" "$target" <<'PY'
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
