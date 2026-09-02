#!/usr/bin/env bash
# regen.sh — expand tools/kernels.yaml into packaging/<series>/<target>/<abi>/.
# Thin wrapper around tools/gen-kernel-packages.py (see it for details).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$ROOT/common/scripts/render-debian.py" ] || { echo "init common/ submodule first"; exit 1; }
exec python3 "$ROOT/tools/gen-kernel-packages.py" --all "$@"
