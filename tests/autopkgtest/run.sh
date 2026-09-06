#!/usr/bin/env bash
# autopkgtest/run.sh <series> <target>
# Runs the archive autopkgtests against the freshly built .debs in a container.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../lib.sh"
series="${1:?}"; target="${2:?}"

declare -A img=(
  [debian11]=debian:11 [debian12]=debian:12 [debian13]=debian:trixie
  [ubuntu2004]=ubuntu:20.04 [ubuntu2204]=ubuntu:22.04 [ubuntu2404]=ubuntu:24.04
  [ubuntu2604]=ubuntu:26.04)
base="${img[$target]:?}"
command -v podman >/dev/null && OCI=podman || OCI=docker

cid="apt-$series-$target"
$OCI rm -f "$cid" >/dev/null 2>&1 || true
set +e
$OCI run --name "$cid" -v "$BUILDDIR":/build:ro -v "$here":/t:ro \
  -e SERIES="$series" "$base" bash -c '
    set -e; export DEBIAN_FRONTEND=noninteractive
    . /t/apt-lib.sh
    # debian11/12/13 also ship an i386 driver-libs .deb (32-bit compat libs)
    # -- irrelevant to what these tests check (the amd64 driver installs and
    # works) and pulling in i386 multiarch has repeatedly cascaded into
    # unrelated i386/amd64 base-image packages 404ing against a stuck
    # bullseye-security CDN cache. Skip the i386 .deb here entirely.
    apt_disable_security_pocket
    apt-get update -qq
    apt_install_reconciled /build/*_amd64.deb /build/*_all.deb >/dev/null || {
      dpkg -i /build/*_amd64.deb /build/*_all.deb || true
      apt-get -f install -y -qq --no-upgrade --no-install-recommends
    }
    fail=0
    # install-purge last: it ends by purging every nvidia-legacy-* package,
    # and since these came from a local .deb (not a real apt source), once
    # purged apt no longer knows them as installable -- the other two tests
    # each call apt-get install nvidia-legacy-... themselves and would then
    # fail with "Unable to locate package".
    for t in file-conflicts xorg-dummy install-purge; do
      echo "===== $t ====="
      bash /t/$t.sh "$SERIES" || fail=1
    done
    exit $fail
  '
rc=$?
set -e
$OCI rm -f "$cid" >/dev/null 2>&1 || true
[ $rc -eq 0 ] && ok "autopkgtest $target" || no "autopkgtest $target"
summary
