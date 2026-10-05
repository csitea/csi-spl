#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_public_export_grants_gen (spec 091 T004, fence 1).
#   1. the committed spool-hub-roles/public-export-grants.sql is exactly what
#      the generator makes from the current allow-list (CHECK=1 exit 0)
#   2. a public column added to a copy of the allow-list: CHECK=1 against the
#      old file FAILs, and the regenerated file grants that column
#   3. it grants no withheld column: none of messages.msg / env / env_sig /
#      files, humans.email, tenants.root_pubkey appears in a GRANT line
#   4. refusals, nothing written: a file whose `version` disagrees with its
#      name, a column name that is not [a-z0-9_] (an injection attempt)
# No cloud, no database: the generator is a pure render (yq).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }

REAL="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/public-export-grants.sql"
LIST="$(ls "$PROJ_ROOT"/cnf/public-dataset/allow-list.v*.yaml | sort -V | tail -1)"

# gen [VAR=value ...] -> runs the action with PROJ_PATH / APP_PATH from
# G_PROJ / G_APP (default: this checkout)
gen() {
  env GEN_SRC="$PROJ_ROOT/src/bash/run/spl-public-export-grants-gen.func.sh" PROJ_PATH="${G_PROJ:-$PROJ_ROOT}" APP_PATH="${G_APP:-$APP_ROOT}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { local b; for b; do command -v "$b" >/dev/null || return 1; done; }
    source "$GEN_SRC"
    do_spl_public_export_grants_gen' 2>&1
}

# --- 1. committed file == generator output ------------------------------------
out=$(gen CHECK=1); rc=$?
[[ $rc -eq 0 ]] && grep -q '^OK public-export-grants.sql equals' <<<"$out" &&
  pass "1. the committed grants file equals what $(basename "$LIST") generates" || fail "1. stale grants file: rc=$rc $out"
gen OUT="$T/g.sql" >/dev/null
cmp -s "$T/g.sql" "$REAL" && pass "1. OUT= renders byte-identical to the committed file" || fail "1. OUT= render differs: $(diff "$T/g.sql" "$REAL" | sed -n 1,5p)"

# --- 2. a new public column is caught, then granted ---------------------------
mkdir -p "$T/app/csi-spl-orc/cnf/public-dataset" "$T/app/csi-spl-rdb/src/sql/postgres/spool-hub-roles"
cp "$LIST" "$T/app/csi-spl-orc/cnf/public-dataset/"
cp "$REAL" "$T/app/csi-spl-rdb/src/sql/postgres/spool-hub-roles/"
FAKE_LIST="$T/app/csi-spl-orc/cnf/public-dataset/$(basename "$LIST")"
yq -i '.tables.channels.public += ["planted_col"]' "$FAKE_LIST"
out=$(G_PROJ="$T/app/csi-spl-orc" G_APP="$T/app" gen CHECK=1); rc=$?
[[ $rc -ne 0 ]] && grep -q '^FAIL .*is not what' <<<"$out" &&
  pass "2. CHECK=1 fails when the allow-list gained a public column" || fail "2. stale file not caught: rc=$rc $out"
G_PROJ="$T/app/csi-spl-orc" G_APP="$T/app" gen >/dev/null
grep -q '^GRANT SELECT (channel_id, name, description, created_by, created_at, planted_col) ON channels TO spool_public_export;$' \
  "$T/app/csi-spl-rdb/src/sql/postgres/spool-hub-roles/public-export-grants.sql" &&
  pass "2. the regenerated file grants the new column" || fail "2. new column not granted"
out=$(G_PROJ="$T/app/csi-spl-orc" G_APP="$T/app" gen CHECK=1); rc=$?
[[ $rc -eq 0 ]] && pass "2. CHECK=1 passes after regenerating" || fail "2. regenerated still stale: $out"

# --- 3. no withheld column is granted -----------------------------------------
bad=0
while read -r t c; do
  grep -E "^GRANT SELECT \(.*\b$c\b.*\) ON $t " "$REAL" >/dev/null && { fail "3. $t.$c is granted"; bad=1; }
done <<'EOF'
messages msg
messages env
messages env_sig
messages files
messages tenant_id
humans email
humans display_name
tenants root_pubkey
EOF
(( bad == 0 )) && pass "3. no withheld column (msg, env, env_sig, files, email, root_pubkey, ...) is granted"
[[ "$(grep -c '^GRANT SELECT (' "$REAL")" == "$(yq -r '.tables | length' "$LIST")" ]] &&
  pass "3. one column GRANT per allow-list table" || fail "3. GRANT count differs from the allow-list's tables"
[[ "$(grep -E '^GRANT [A-Z, ]+ ON ' "$REAL" | grep -vc ' ON SCHEMA public ')" == 1 ]] && grep -q '^GRANT SELECT ON public_export_workspace TO spool_public_export;$' "$REAL" &&
  pass "3. the only table-level grant is SELECT on public_export_workspace" || fail "3. table-level grants: $(grep -E '^GRANT [A-Z, ]+ ON ' "$REAL")"

# --- 4. refusals ----------------------------------------------------------------
cp "$LIST" "$FAKE_LIST"; yq -i '.version = 99' "$FAKE_LIST"
before=$(sha256sum <"$T/app/csi-spl-rdb/src/sql/postgres/spool-hub-roles/public-export-grants.sql")
out=$(G_PROJ="$T/app/csi-spl-orc" G_APP="$T/app" gen); rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL .*says version' <<<"$out" &&
  [[ "$(sha256sum <"$T/app/csi-spl-rdb/src/sql/postgres/spool-hub-roles/public-export-grants.sql")" == "$before" ]] &&
  pass "4. a version that disagrees with the file name is refused, nothing written" || fail "4. version mismatch: rc=$rc $out"
cp "$LIST" "$FAKE_LIST"; yq -i '.tables.tenants.public += ["x); GRANT ALL ON humans TO spool_public_export; --"]' "$FAKE_LIST"
out=$(G_PROJ="$T/app/csi-spl-orc" G_APP="$T/app" gen); rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL .*not \[a-z0-9_\]' <<<"$out" &&
  ! grep -q 'GRANT ALL ON humans' "$T/app/csi-spl-rdb/src/sql/postgres/spool-hub-roles/public-export-grants.sql" &&
  pass "4. a column name that is not [a-z0-9_] is refused, nothing written" || fail "4. injection: rc=$rc $out"

[[ $fails -eq 0 ]] && { echo "PASS: all public-export-grants-gen.tst.sh assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in public-export-grants-gen.tst.sh"; exit 1
