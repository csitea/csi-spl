#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: true release notes + the release-level forward-only gate (spec 072
#          A55, research 16 R2 + R3), against a throwaway repo + bare remote:
#   1. a migration added then renamed inside the range is listed ONCE, by its
#      new name (the tree diff; `git log --diff-filter=A` listed both)
#   2. a migration the previous stable holds RENAMED = FATAL, nothing cut
#      (CONTROL: the same tree with the name put back cuts)
#   3. EDITED = FATAL; 4. DELETED = FATAL
#   5. two migrations sharing a number = FATAL; the grandfathered pair passes
#   6. the version wraps 9.9.9 -> 1.0.1 of cycle 2 (tag v1.0.1-c2): that
#      build is released as v1.0.1, and the gate (migrations only, never
#      version numbers) calls it forward
#   7. THIS tree against the newest stable-* tag on the remote: forward-only.
#      A branch that renames, edits or deletes a released migration turns
#      this suite red.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
M=csi-spl-rdb/src/sql/postgres/spool-hub

git init -q --bare "$T/remote.git"
git init -q "$T/w" && git -C "$T/w" remote add origin "$T/remote.git"
commit() {  # <subject> -> sha; stages what the caller changed
  git -C "$T/w" add -A && git -C "$T/w" commit -q --allow-empty -m "$1" && git -C "$T/w" rev-parse HEAD
}
mig() { mkdir -p "$T/w/$M"; echo "${2:-select 1;}" >"$T/w/$M/$1"; }
vtag() { git -C "$T/w" tag "v$1" "$2" && git -C "$T/w" push -q origin "refs/tags/v$1"; }
act() {  # env... -> stdout + the gate's stderr lines; rc kept
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/w" STABLE_GH_RELEASE=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_stable' 2>&1
}
rtag() { git --git-dir="$T/remote.git" rev-parse -q --verify "refs/tags/$1^{commit}"; }

# --- base: the first stable holds 0001 + the grandfathered 0021 pair ---------------
mig 0001_core.sql; mig 0021_rls_fail_closed.sql; mig 0021_tenant_rbac.sql
c=$(commit "feat(rdb): core"); vtag 1.0.0 "$c"
out=$(act STABLE_DATE=2026-10-05 DRY_RUN=0); rc=$?
[[ $rc == 0 && "$(rtag stable-2026-10-05)" == "$c" ]] && pass "base stable cut (the grandfathered 0021 pair passes the gate)" \
  || fail "base cut (rc $rc): $out"

# --- 1. added then renamed inside the range ----------------------------------------
mig 0040_x.sql; commit "feat(rdb): 0040_x" >/dev/null
git -C "$T/w" mv "$M/0040_x.sql" "$M/0041_x.sql"; c=$(commit "fix(rdb): renumber 0040_x to 0041_x"); vtag 1.0.1 "$c"
out=$(act STABLE_DATE=2026-10-12); rc=$?
if ((rc == 0)) && grep -q '^## Database migrations (1)$' <<<"$out" && grep -qx -- '- `0041_x.sql`' <<<"$out"; then
  pass "added then renamed in the range: listed once, as 0041_x.sql"
else
  fail "R2 notes (rc $rc): $out"
fi
grep -q '^- `0040_x' <<<"$out" && fail "CONTROL: the notes name 0040_x.sql, which the release does not hold" \
  || pass "CONTROL: 0040_x.sql (not in the release) is not named"
act STABLE_DATE=2026-10-12 DRY_RUN=0 >/dev/null || fail "cut stable-2026-10-12"

# --- 2. a stable migration renamed --------------------------------------------------
git -C "$T/w" mv "$M/0041_x.sql" "$M/0042_x.sql"; c=$(commit "fix(rdb): renumber a released one"); vtag 1.0.2 "$c"
out=$(act STABLE_DATE=2026-10-19 DRY_RUN=0); rc=$?
((rc == 1)) && [[ -z "$(rtag stable-2026-10-19)" ]] && grep -q 'FATAL forward-only: 0041_x.sql is in stable-2026-10-12 and was RENAMED' <<<"$out" \
  && pass "a released migration renamed: FATAL, nothing cut" || fail "rename gate (rc $rc): $out"
git -C "$T/w" mv "$M/0042_x.sql" "$M/0041_x.sql"; mig 0043_y.sql; c=$(commit "fix(rdb): put it back, add 0043_y"); vtag 1.0.3 "$c"
out=$(act STABLE_DATE=2026-10-19 DRY_RUN=0); rc=$?
((rc == 0)) && [[ "$(rtag stable-2026-10-19)" == "$c" ]] && grep -qx -- '- `0043_y.sql`' <<<"$out" \
  && pass "CONTROL: the name put back and a new one added: cut" || fail "control cut (rc $rc): $out"

# --- 3. edited, 4. deleted ----------------------------------------------------------
mig 0001_core.sql "select 2;"; c=$(commit "fix(rdb): edit a released one"); vtag 1.0.4 "$c"
out=$(act STABLE_DATE=2026-10-26); rc=$?
((rc == 1)) && grep -q 'FATAL forward-only: 0001_core.sql is in stable-2026-10-19 and was EDITED' <<<"$out" \
  && pass "a released migration edited: FATAL" || fail "edit gate (rc $rc): $out"
mig 0001_core.sql; git -C "$T/w" rm -q "$M/0043_y.sql"; c=$(commit "fix(rdb): drop a released one"); vtag 1.0.5 "$c"
out=$(act STABLE_DATE=2026-10-26); rc=$?
((rc == 1)) && grep -q 'FATAL forward-only: 0043_y.sql is in stable-2026-10-19 and was RENAMED or DELETED' <<<"$out" \
  && ! grep -q '0001_core.sql.*EDITED' <<<"$out" \
  && pass "a released migration deleted: FATAL (and the edit undone is clean)" || fail "delete gate (rc $rc): $out"
mig 0043_y.sql; commit "fix(rdb): restore 0043_y" >/dev/null

# --- 5. a shared number --------------------------------------------------------------
mig 0050_a.sql; mig 0050_b.sql; c=$(commit "feat(rdb): two 0050s"); vtag 1.0.6 "$c"
out=$(act STABLE_DATE=2026-10-26); rc=$?
((rc == 1)) && grep -q 'FATAL forward-only: migrations share a number: 0050_a.sql 0050_b.sql' <<<"$out" \
  && ! grep -q 'share a number:.*0021' <<<"$out" \
  && pass "two new migrations share a number: FATAL; the grandfathered 0021 pair does not" || fail "dup gate (rc $rc): $out"
mig 0021_third.sql; c=$(commit "feat(rdb): a third 0021"); vtag 1.0.7 "$c"
out=$(act STABLE_DATE=2026-10-26); rc=$?
((rc == 1)) && grep -q 'share a number: 0021_rls_fail_closed.sql 0021_tenant_rbac.sql 0021_third.sql' <<<"$out" \
  && pass "grandfathered by NAME: a third 0021 is FATAL" || fail "grandfather by name (rc $rc): $out"
git -C "$T/w" rm -q "$M/0050_b.sql" "$M/0021_third.sql"; c=$(commit "fix(rdb): one 0050"); vtag 1.0.8 "$c"
out=$(act STABLE_DATE=2026-10-26 DRY_RUN=0); rc=$?
((rc == 0)) && [[ "$(rtag stable-2026-10-26)" == "$c" ]] && pass "CONTROL: numbers unique again: cut" || fail "dup control (rc $rc): $out"

# --- 6. the version wraps 9.9.9 -> 1.0.1 ---------------------------------------------
c=$(commit "feat(hub): the last build of a cycle"); vtag 9.9.9 "$c"
mig 0060_z.sql; cw=$(commit "feat(rdb): the first build after the wrap")
vtag 1.0.1-c2 "$cw"
out=$(act STABLE_DATE=2026-11-02); rc=$?
((rc == 0)) && grep -q "^# stable-2026-11-02 (v1.0.1)" <<<"$out" && grep -q "Commit \`${cw:0:12}\`" <<<"$out" \
  && grep -q 'OK forward-only' <<<"$out" && grep -qx -- '- `0060_z.sql`' <<<"$out" \
  && pass "9.9.9 -> v1.0.1-c2: the cycle-2 build is released as v1.0.1, forward-only" || fail "wrap (rc $rc): $out"

# --- 7. this tree against the newest released stable ---------------------------------
R=$(git -C "$PROJ_ROOT" rev-parse --show-toplevel)
st=$(git -C "$R" ls-remote --tags origin 'refs/tags/stable-*' 2>/dev/null | sed 's#.*refs/tags/##; /\^{}$/d' | sort | tail -1)
[[ -n "$st" ]] || st=$(git -C "$R" tag -l 'stable-*' | sort | tail -1)
if [[ -z "$st" ]]; then
  echo "SKIP: no stable-* tag on origin or here: the gate on this tree did not run"
else
  if ! git -C "$R" rev-parse -q --verify "refs/tags/$st^{commit}" >/dev/null; then
    for i in 1 2 3; do git -C "$R" fetch -q --depth=1 origin "refs/tags/$st:refs/tags/$st" && break; sleep $((i * 5)); done
  fi
  if ! git -C "$R" rev-parse -q --verify "refs/tags/$st^{commit}" >/dev/null; then
    echo "SKIP: cannot fetch $st: the gate on this tree did not run"
  else
    out=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" ST="$st" bash -c '
      do_log() { echo "$*"; }
      for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
      spl_stable_forward_only "refs/tags/$ST" HEAD' 2>&1); rc=$?
    ((rc == 0)) && pass "this tree only adds migrations to $st" || fail "this tree vs $st: $out"
  fi
fi

echo "fails=$fails"
exit $((fails > 0))
