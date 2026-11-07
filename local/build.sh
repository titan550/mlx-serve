#!/usr/bin/env bash
# The fork's build: the app and server exactly as `bash app/build.sh` makes them, named after the tree
# (<last release>.<commits since it>, e.g. 26.11.2.8 — numeric, so UpdateChecker still offers the next release
# and never nags about this one), plus this build's plugin kit staged at ~/.mlx-serve/kit under the same name,
# which is what Models > Plugins matches before it would download a release's kit (local/CHANGE-POLICY.md, F1).
# Usage: local/build.sh [ko]      (ko relaunches the app, as app/build.sh does)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

desc="$(git describe --tags --match 'v*' --long)"   # v26.11.2-8-g6ae3b42d
base="${desc#v}"; base="${base%-g*}"                 # 26.11.2-8
VERSION="${base%-*}.${base##*-}"                     # 26.11.2.8
if [ -n "$(git status --porcelain -- src app build.zig build lib)" ]; then
  echo "[fork-build] note: uncommitted changes under src/ app/ build/ lib/; $VERSION names HEAD, not this tree" >&2
fi
echo "[fork-build] version $VERSION ($desc)"

MLX_SERVE_DEV_VERSION="$VERSION" bash app/build.sh "$@"

ZIG="$ROOT/.zig-toolchain/zig"; [ -x "$ZIG" ] || ZIG=zig
"$ZIG" build kit -Dversion="$VERSION"
KIT="$HOME/.mlx-serve/kit"
rm -rf "$KIT"
cp -R "zig-out/kit/mlx-serve-plugin-kit-$VERSION" "$KIT"
echo "[fork-build] kit $VERSION staged at $KIT (Models > Plugins installs against it)"
