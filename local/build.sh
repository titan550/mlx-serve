#!/usr/bin/env bash
# The fork's build: the app and server exactly as `bash app/build.sh` makes them, named after the tree
# (<last release>+fork.<commits since it>, e.g. 26.11.2+fork.8: a plugin's build.zig.zon names the kit as a
# dependency, so the version must be semver, and `+` metadata is what the app's UpdateChecker ignores, so it
# neither nags about this build nor offers one; a `-` suffix would sort below the release and nag), then this
# build's plugin kit staged at ~/.mlx-serve/kit under the same name (what Models > Plugins matches before it
# would download a release's kit), then every plugin local/plugins.conf pins built against that kit and
# installed, plugins switched on, and only then the app relaunched, so it comes up with them loaded
# (local/CHANGE-POLICY.md, F1).
#   local/build.sh [ko]      the whole thing; ko relaunches the app at the end
#   local/build.sh plugins   only the kit and the plugins, against the app already built (no relaunch)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/app/MLX-Serve.app"
BIN="$APP/Contents/MacOS/mlx-serve"
KIT="$HOME/.mlx-serve/kit"
SRC="$HOME/.mlx-serve/plugin-src"       # the app's own checkout of CommunityServe/plugins
ZIG="$ROOT/.zig-toolchain/zig"; [ -x "$ZIG" ] || ZIG=zig

desc="$(git describe --tags --match 'v*' --long)"   # v26.11.2-8-g6ae3b42d
base="${desc#v}"; base="${base%-g*}"                 # 26.11.2-8
VERSION="${base%-*}+fork.${base##*-}"                # 26.11.2+fork.8

mode="${1:-}"
case "$mode" in
  "" | ko | plugins) ;;
  *) echo "usage: local/build.sh [ko|plugins]" >&2; exit 2 ;;
esac

if [ "$mode" != plugins ]; then
  if [ -n "$(git status --porcelain -- src app build.zig build lib)" ]; then
    echo "[fork-build] note: uncommitted changes under src/ app/ build/ lib/; $VERSION names HEAD, not this tree" >&2
  fi
  echo "[fork-build] version $VERSION ($desc)"
  MLX_SERVE_DEV_VERSION="$VERSION" bash app/build.sh
else
  # The kit must carry the version the built app reports, which is what Models > Plugins matches.
  built="$("$BIN" --version 2>/dev/null | sed -n 's/^mlx-serve \([^ ]*\).*/\1/p')"
  [ -n "$built" ] || { echo "[fork-build] no app at $BIN: run local/build.sh first" >&2; exit 1; }
  [ "$built" = "$VERSION" ] || echo "[fork-build] note: the app is $built, the tree is $VERSION; using the app's" >&2
  VERSION="$built"
fi

"$ZIG" build kit -Dversion="$VERSION"
rm -rf "$KIT"
cp -R "zig-out/kit/mlx-serve-plugin-kit-$VERSION" "$KIT"
echo "[fork-build] kit $VERSION staged at $KIT"

# Each pinned plugin: the app's checkout moved to the pin (as a local `main`, so the app's own `pull --ff-only`
# still works), the repo's staged kit dropped (its fetch-kit keeps its KIT_VERSION over MLX_SERVE_KIT), its Zig
# pointed at ours (fetch-zig downloads otherwise), then the repo's build (the plugin's tests, ReleaseFast) and
# this app's `plugin install` (hash + signature receipt), which is what Models > Plugins runs.
if [ -f local/plugins.conf ]; then
  [ -d "$SRC/.git" ] || git clone -q https://github.com/CommunityServe/plugins.git "$SRC"
  while read -r name sha _; do
    case "$name" in ""|\#*) continue ;; esac
    echo "── plugin $name @ $sha"
    git -C "$SRC" fetch -q origin main
    git -C "$SRC" cat-file -e "$sha^{commit}" 2>/dev/null || git -C "$SRC" fetch -q origin "$sha"
    git -C "$SRC" checkout -q -B main "$sha"
    rm -rf "$SRC/.kit"
    if [ -d "$ROOT/.zig-toolchain" ] && [ ! -e "$SRC/.zig-toolchain/.version" ]; then
      rm -rf "$SRC/.zig-toolchain"; ln -s "$ROOT/.zig-toolchain" "$SRC/.zig-toolchain"
    fi
    (cd "$SRC" && PATH="$(dirname "$BIN"):$PATH" MLX_SERVE_KIT="$KIT" bash scripts/build.sh "$name")
    "$BIN" plugin install "$SRC/plugins/$name/zig-out/lib/lib$name.dylib" --yes
  done < local/plugins.conf
  /usr/bin/python3 -I - <<'PY'
import json, os
p = os.path.expanduser("~/.mlx-serve/plugins.json")
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["enabled"] = True
d.setdefault("disabled", [])
json.dump(d, open(p, "w"), indent=2)
print("[fork-build] plugins on:", p)
PY
fi

if [ "$mode" = ko ]; then
  echo "→ Relaunching MLX-Serve..."
  osascript -e 'tell application id "com.dalcu.mlx-core" to quit' 2>/dev/null || true
  for _ in $(seq 1 50); do pgrep -f "MLX-Serve.app/Contents/MacOS/" >/dev/null || break; sleep 0.2; done
  pkill -9 -f "MLX-Serve.app/Contents/MacOS/" || true
  open "$APP"
fi
