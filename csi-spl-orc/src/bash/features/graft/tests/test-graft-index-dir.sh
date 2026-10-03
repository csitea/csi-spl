#!/usr/bin/env bash
# test-graft-index-dir.sh -- a repo's graft index lives outside the repo.
#
# A stub graft records its argv and writes into whatever --dir it is given
# (or <repo>/graft without one, as the real tool does). No real graft runs.
#
#   dir       graft-index-dir.sh: $GRAFT_INDEX_ROOT or $GRAFT_VAR_ROOT/index,
#             plus a slug of the repo's physical path; outside a repo, rc 1
#   wrapper   graft-safe.sh adds --dir <index> inside a git repo, leaves an
#             explicit --dir alone, adds nothing outside a repo or with
#             GRAFT_SAFE_IN_TREE=1
#   action    _graft_build_repo builds with --dir, writes no <repo>/graft, and
#             names (never deletes) an in-tree graft/ left by an older build
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== graft-index-dir.sh"
D="$SCRIPTS/graft-index-dir.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)"
mkdir -p "$T/src/my-repo" "$T/plain"
git -C "$T/src/my-repo" init -q
SLUG="${T#/}/src/my-repo"; SLUG="${SLUG//\//__}"

is "$(cd "$T/src/my-repo" && GRAFT_INDEX_ROOT="$T/idx" bash "$D")" "$T/idx/$SLUG" "GRAFT_INDEX_ROOT + the slug of the git top level"
is "$(env -u GRAFT_INDEX_ROOT GRAFT_VAR_ROOT="$T/var" bash "$D" "$T/src/my-repo")" "$T/var/index/$SLUG" "GRAFT_VAR_ROOT/index + the slug, for an explicit repo"
is "$(env -u GRAFT_INDEX_ROOT -u GRAFT_VAR_ROOT bash "$D" "$T/src/my-repo")" "/var/csi/csi-spl/graft/index/$SLUG" "default: the box-wide csi-spl state dir, not a home"
( cd "$T/plain" && GRAFT_INDEX_ROOT="$T/idx" bash "$D" >/dev/null 2>&1 ); is "$?" 1 "outside a git repo: rc 1"
case "$SLUG" in */*) bad "the slug holds no /" ;; *) ok "the slug holds no /" ;; esac

echo "== graft-safe.sh adds the out-of-tree --dir"
cat > "$T/stub" <<'STUB'
#!/usr/bin/env bash
echo "ARGV:$*"
[ -n "${STUB_ARGV:-}" ] && echo "ARGV:$*" >> "$STUB_ARGV"
dir="graft"; [ "${1:-}" = --dir ] && dir="$2"
mkdir -p "$dir" && touch "$dir/INDEX.md"
STUB
chmod 755 "$T/stub"
out="$(cd "$T/src/my-repo" && GRAFT_INDEX_ROOT="$T/idx" GRAFT_SAFE_BIN="$T/stub" bash "$SCRIPTS/graft-safe.sh" ask foo 2>&1)"
has "$out" "ARGV:--dir $T/idx/$SLUG ask foo" "inside a repo: --dir <index> is added"
out="$(cd "$T/src/my-repo" && GRAFT_INDEX_ROOT="$T/idx" GRAFT_SAFE_BIN="$T/stub" bash "$SCRIPTS/graft-safe.sh" --dir "$T/mine" ask foo 2>&1)"
has "$out" "ARGV:--dir $T/mine ask foo" "an explicit --dir is left alone"
out="$(cd "$T/plain" && GRAFT_INDEX_ROOT="$T/idx" GRAFT_SAFE_BIN="$T/stub" bash "$SCRIPTS/graft-safe.sh" version 2>&1)"
has "$out" "ARGV:version" "outside a repo: nothing added"
out="$(cd "$T/src/my-repo" && GRAFT_SAFE_IN_TREE=1 GRAFT_INDEX_ROOT="$T/idx" GRAFT_SAFE_BIN="$T/stub" bash "$SCRIPTS/graft-safe.sh" ask foo 2>&1)"
has "$out" "ARGV:ask foo" "GRAFT_SAFE_IN_TREE=1: nothing added"
rm -rf "$T/src/my-repo/graft"

echo "== the index action builds out of tree"
common="$SCRIPTS/graft-common.inc.sh"
act() {
  GRAFT_INDEX_ROOT="$T/idx" STUB_ARGV="$T/argv" bash -c 'do_log() { printf "%s\n" "$*"; }; . "$1"; _graft_build_repo "$2" "$3"' _ "$common" "$T/stub" "$1" 2>&1
}
out="$(act "$T/src/my-repo")"
has "$(cat "$T/argv" 2>/dev/null)" "ARGV:--dir $T/idx/$SLUG build ." "the build passes --dir <index>"
[ -e "$T/idx/$SLUG/INDEX.md" ] && ok "the index is written out of tree" || bad "no index at $T/idx/$SLUG"
[ -e "$T/src/my-repo/graft" ] && bad "a graft/ was written into the repo" || ok "nothing is written into the repo"
mkdir -p "$T/src/my-repo/graft"; touch "$T/src/my-repo/graft/old.md"
out="$(act "$T/src/my-repo")"
has "$out" "WARN  $T/src/my-repo/graft is an in-tree index" "an old in-tree graft/ is named"
[ -e "$T/src/my-repo/graft/old.md" ] && ok "... and never deleted" || bad "the old in-tree graft/ was deleted"

finish
