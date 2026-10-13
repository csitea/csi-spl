#!/bin/sh
# The local hub's one-shot WUI build (docker-compose-local-hub.yaml,
# service wui-generate): `nuxt generate` of the mounted csi-spl-wui, then the
# bundle replaces the named volume wui-dist that wui-static serves.
#
# Runs as container root on purpose: on the stack's rootless dockerd that IS
# the stack's own unprivileged host user, the one uid that may write the
# mounted tree (any other container uid maps to a subuid).
#
#   WUI_DIR   the mounted csi-spl-wui (default /app)
#   WUI_DIST  the served volume (default /dist)
#
# No node_modules in the tree: one `pnpm install --frozen-lockfile` at the
# pinned packageManager version, the only step that needs the registry.
# A failed generate, or one that wrote no index.html, leaves the served
# bundle as it was. Pure POSIX sh (the node image has no bash guarantee).
set -eu

wui="${WUI_DIR:-/app}"
dist="${WUI_DIST:-/dist}"
cd "$wui"

if [ ! -d node_modules ]; then
  ver=$(sed -n 's/.*"packageManager": *"pnpm@\([^"]*\)".*/\1/p' package.json)
  [ -n "$ver" ] || { echo "wui-generate: no pnpm packageManager in $wui/package.json" >&2; exit 1; }
  echo "wui-generate: no node_modules: pnpm@$ver install --frozen-lockfile"
  npx --yes "pnpm@$ver" install --frozen-lockfile --store-dir /tmp/pnpm-store
fi

npm run generate
[ -f .output/public/index.html ] || { echo "wui-generate: no .output/public/index.html: the served bundle is unchanged" >&2; exit 1; }

find "$dist" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R .output/public/. "$dist"/
chmod -R a+rX "$dist"
echo "wui-generate: $(find "$dist" -type f | wc -l) files in $dist"
