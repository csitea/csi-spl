#!/usr/bin/env bash
# t_spool_bin (lib.inc.sh) on a tree the runner cannot write (b24-02,
# SPL-6002): the test still gets a spool binary, built outside the tree into
# the runner's cache, and the tree is unchanged. A tree's own executable
# bin/spool is still the one used.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox

# A copy of what t_spool_bin reads: the test lib, the api sources (no bin/)
# and .version, laid out as in the repo, then made read-only.
C="$T_TMP/tree"
MOD="$C/csi-spl-api/src/go/spool-hub-api"
mkdir -p "$C/csi-spl-orc/src/bash/features/spawn-agents/tests"
cp "$T_HERE/lib.inc.sh" "$C/csi-spl-orc/src/bash/features/spawn-agents/tests/"
tar -C "$T_REPO" --exclude=csi-spl-api/src/go/spool-hub-api/bin -cf - csi-spl-api/src .version | tar -C "$C" -xf -
trap 'chmod -R u+w "$C" 2>/dev/null; t_cleanup' EXIT
chmod -R a-w "$C"
snap() { find "$C" -printf '%P %s %m\n' | LC_ALL=C sort | sha256sum; }
before="$(snap)"

# Go's build cache stays the runner's own: only the spool cache moves.
GOC="${GOCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/go-build}"
CACHE="$T_TMP/cache"
spool_bin_in_copy() {
  (cd / && env XDG_CACHE_HOME="$CACHE" GOCACHE="$GOC" bash -c \
    '. "$1/csi-spl-orc/src/bash/features/spawn-agents/tests/lib.inc.sh"; t_spool_bin && echo "SPOOL_BIN=$SPOOL_BIN"' _ "$C" 2>&1)
}

# ---- no bin/spool in a read-only tree: built in the cache -----------------
out="$(spool_bin_in_copy)"; rc=$?
eq "t_spool_bin on a read-only tree returns 0" 0 "$rc"
bin="$(sed -n 's/^SPOOL_BIN=//p' <<<"$out")"
case "$bin" in
  "$CACHE/csi-spl/spool-"*/spool) ok "the binary is in the runner's cache, outside the tree" ;;
  *) nok "the binary is in the runner's cache, outside the tree (got '$bin': $(tail -3 <<<"$out"))" ;;
esac
check "the built binary runs (spool version)" sh -c '"$1" version >/dev/null 2>&1' _ "$bin"
check "the tree has no bin/" test ! -e "$MOD/bin"
eq "the tree is unchanged" "$before" "$(snap)"

# ---- a second run takes the cached build, no rebuild ----------------------
m1="$(stat -c %Y "$bin" 2>/dev/null)"
out2="$(spool_bin_in_copy)"
eq "a second run gets the same cached binary" "SPOOL_BIN=$bin" "$(grep '^SPOOL_BIN=' <<<"$out2")"
eq "the cached binary was not rebuilt" "$m1" "$(stat -c %Y "$bin" 2>/dev/null)"

# ---- control: a tree's own executable bin/spool is still used --------------
chmod u+w "$MOD"
mkdir "$MOD/bin" && printf '#!/bin/sh\necho tree-spool\n' >"$MOD/bin/spool" && chmod 555 "$MOD/bin/spool"
chmod -R a-w "$MOD"
out3="$(spool_bin_in_copy)"
eq "a tree's own bin/spool wins" "SPOOL_BIN=$MOD/bin/spool" "$(grep '^SPOOL_BIN=' <<<"$out3")"

t_done
