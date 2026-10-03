#!/usr/bin/env bash
# test-graft-wrap.sh -- one wrapper shape, written by the feature and the run action alike.
#
# Regression: the feature's install wrote a stub naming GRAFT_SAFE_BIN; the run
# action's _graft_apply_safe_wrapper copied graft-safe.sh verbatim. Once the
# action ran, the feature's verify reported "wrapper names no target" for the
# owner. Fixture launchers only; no real graft is touched.
#
#   wrap        a raw launcher moves to graft.real once; PATH graft is the stub
#   idempotent  a second wrap changes nothing
#   keep        an existing graft.real is never overwritten or deleted
#   convert     the verbatim-copy shape becomes the stub
#   refuse      a REAL that is itself a wrapper; no raw launcher at all
#   action      _graft_apply_safe_wrapper leaves exactly the stub graft-wrap.sh writes
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== graft-wrap.sh"
W="$SCRIPTS/graft-wrap.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
mkdir -p "$T/a/bin" "$T/b/bin" "$T/c/bin" "$T/d/bin" "$T/lib/dist"
printf '#!/usr/bin/env bash\necho raw-launcher "$@"\n' > "$T/lib/dist/cli.js"; chmod 755 "$T/lib/dist/cli.js"
raw() { printf '#!/usr/bin/env bash\nexec node "%s/lib/dist/cli.js" "$@"\n' "$T" > "$1"; chmod 755 "$1"; }

raw "$T/a/bin/graft"
bash "$W" "$T/a/bin/graft" >/dev/null; rc=$?
is "$rc" 0 "wrap a raw launcher: rc 0"
has "$(cat "$T/a/bin/graft.real")" 'exec node' "the raw launcher is now graft.real"
bash "$W" --check "$T/a/bin/graft"; is "$?" 0 "--check: PATH graft is the stub naming a raw launcher"
is "$(bash "$W" --target "$T/a/bin/graft")" "$T/a/bin/graft.real" "--target names graft.real"
before="$(cat "$T/a/bin/graft")"
out="$(bash "$W" "$T/a/bin/graft")"
is "$out|$(cat "$T/a/bin/graft")" "|$before" "a second wrap: silent, nothing changed"

ln -s "$T/lib/dist/cli.js" "$T/b/bin/graft.real"
cp "$SCRIPTS/graft-safe.sh" "$T/b/bin/graft"
bash "$W" --check "$T/b/bin/graft"; is "$?" 1 "--check: a verbatim copy of graft-safe.sh is not the wrapper"
bash "$W" "$T/b/bin/graft" >/dev/null
bash "$W" --check "$T/b/bin/graft"; is "$?" 0 "convert: the verbatim copy becomes the stub"
is "$(readlink "$T/b/bin/graft.real")" "$T/lib/dist/cli.js" "keep: the existing graft.real symlink is untouched"

raw "$T/c/bin/graft"; printf 'precious\n' > "$T/c/bin/graft.real"; chmod 755 "$T/c/bin/graft.real"
bash "$W" "$T/c/bin/graft" >/dev/null 2>&1
is "$(cat "$T/c/bin/graft.real")" "precious" "keep: graft.real is never overwritten by a raw graft"

bash "$W" "$T/d/bin/graft" "$T/a/bin/graft" >/dev/null 2>&1; rc=$?
is "$rc" 1 "refuse: a REAL that is itself a wrapper"
[ -e "$T/d/bin/graft" ] && bad "refuse: nothing written" || ok "refuse: nothing written"
bash "$W" "$T/d/bin/graft" >/dev/null 2>&1; rc=$?
is "$rc" 1 "refuse: no raw launcher anywhere"

bash "$W" "$T/d/bin/graft" "$T/lib/dist/cli.js" >/dev/null
bash "$W" --check "$T/d/bin/graft"; is "$?" 0 "a second account points at another's launcher by path"
out="$(cd "$T" && GRAFT_SAFE_ALLOW_PROXY=1 "$T/d/bin/graft" build . 2>&1)"
has "$out" "raw-launcher build ." "the stub runs graft-safe, which runs the raw launcher"

echo "== the run action writes the same shape"
common="$SCRIPTS/graft-common.inc.sh"
mkdir -p "$T/e/bin"; raw "$T/e/bin/graft"
bash -c '
  do_log() { :; }
  . "$1"
  G="$2"; _graft_candidates() { printf "%s\n" "$G"; }
  _graft_apply_safe_wrapper' _ "$common" "$T/e/bin/graft"
bash "$W" --check "$T/e/bin/graft"; is "$?" 0 "action: PATH graft is the stub"
mkdir -p "$T/f/bin"; raw "$T/f/bin/graft"; bash "$W" "$T/f/bin/graft" >/dev/null
is "$(sed "s#$T/e/#X/#g" "$T/e/bin/graft")" "$(sed "s#$T/f/#X/#g" "$T/f/bin/graft")" "action and graft-wrap.sh write byte-identical stubs"

finish
