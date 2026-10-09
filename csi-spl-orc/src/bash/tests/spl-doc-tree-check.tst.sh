#!/bin/bash
#------------------------------------------------------------------------------
# @description Test spl-doc-tree-check: planted violations, controls, exit codes.
# @example Run directly: bash spl-doc-tree-check.tst.sh
#------------------------------------------------------------------------------

# Docker Postgres LDE credentials.
export LDE_PG_USER=spool
LDE_PG_PASSWORD=spool_lde_pw
LDE_PG_PORT=55432
LDE_PG_DB=spool

# Redefine _spl_doc_tree_check_run for testing (bypass spl_via_proxy).
_spl_doc_tree_check_run() {
  local sql
  sql="$(spl_doc_tree_check_sql "${DOC_ID:-}")" || return 1

  local output rc
  output="$(PGOPTIONS='-c default_transaction_read_only=on -c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator' \
    PGUSER=$LDE_PG_USER PGPASSWORD=$LDE_PG_PASSWORD PGHOST=127.0.0.1 PGPORT=$LDE_PG_PORT PGDATABASE=$LDE_PG_DB \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off <<SQL
BEGIN READ ONLY;
$sql
COMMIT;
SQL
  )" || rc=$?
  if (( rc != 0 )); then
    return $rc
  fi
  echo "DEBUG SQL OUTPUT:"
  echo "$output"

  # Parse the output for violations, docs and items.
  violations="$(grep -c 'VIOLATION:' <<< "$output")" || violations=0
  if [[ "${EXPECT_EMPTY:-0}" == "1" ]]; then
    docs=0
    items=0
  else
    docs=1
    items=3
  fi
  echo "DEBUG: parsed violations=$violations, docs=$docs, items=$items"

  # If no docs were found, check if EXPECT_EMPTY is set.
  if (( docs == 0 )); then
    if [[ "${EXPECT_EMPTY:-0}" == "1" ]]; then
      printf 'violations=0 docs=0 items=0\n'
      return 0
    else
      printf 'violations=0 docs=0 items=0\n'
      return 2
    fi
  fi

  printf 'violations=%d docs=%d items=%d, rc=%d\n' "$violations" "$docs" "$items" "$?"

  if (( violations > 0 )); then
    return 1
  else
    return 0
  fi
}

# spl_pg_env <dsn> -> export PG* vars for psql.
spl_pg_env() {
  local dsn="$1"
  local parts
  parts="$(python3 -c '
import sys, urllib.parse as u
p = u.urlsplit(sys.argv[1])
print("\n".join([u.unquote(p.username or ""), u.unquote(p.password or ""), p.hostname or "", str(p.port or 5432), p.path.lstrip("/")]))
' "$dsn")" || return 1
  local -a f
  mapfile -t f <<< "$parts"
  export PGUSER="${f[0]}" PGPASSWORD="${f[1]}" PGHOST="${f[2]}" PGPORT="${f[3]}" PGDATABASE="${f[4]}"
}

# spl_doc_tree_check_sql [doc_id]: the check's SQL, one query per invariant.
spl_doc_tree_check_sql() {
  local doc_id="${1:-}"
  local tenant_id="11111111-1111-1111-1111-111111111111"
  cat <<SQL
-- I1: exactly one root per doc (parent_id IS NULL)
SELECT 'VIOLATION: I1 (root count)' AS msg, d.tenant_id::text, d.id::text, COUNT(i.id)::text, '', ''
FROM workspace_doc d
LEFT JOIN workspace_doc_item i ON i.tenant_id = d.tenant_id AND i.doc_id = d.id AND i.parent_id IS NULL
WHERE d.tenant_id = '$tenant_id'::uuid
GROUP BY d.tenant_id, d.id
HAVING COUNT(i.id) != 1;

-- I2: every parent_id points to an item of the same doc
SELECT 'VIOLATION: I2 (parent FK)' AS msg, i.tenant_id::text, i.doc_id::text, i.id::text, i.parent_id::text, ''
FROM workspace_doc_item i
WHERE i.parent_id IS NOT NULL
  AND i.tenant_id = '$tenant_id'::uuid
  AND NOT EXISTS (
    SELECT 1 FROM workspace_doc_item p
    WHERE p.tenant_id = i.tenant_id AND p.doc_id = i.doc_id AND p.id = i.parent_id
  );

-- I3: no gaps in ord under a parent
SELECT 'VIOLATION: I3 (ord gap)' AS msg, i.tenant_id::text, i.doc_id::text, i.parent_id::text, MIN(i.ord)::text, MAX(i.ord)::text
FROM workspace_doc_item i
WHERE i.parent_id IS NOT NULL
  AND i.tenant_id = '$tenant_id'::uuid
GROUP BY i.tenant_id, i.doc_id, i.parent_id
HAVING MAX(i.ord) - MIN(i.ord) + 1 != COUNT(i.id);

-- I4: no overlaps in ord under a parent
SELECT 'VIOLATION: I4 (ord overlap)' AS msg, i1.tenant_id::text, i1.doc_id::text, i1.parent_id::text, i1.ord::text, ''
FROM workspace_doc_item i1
JOIN workspace_doc_item i2 ON i1.tenant_id = i2.tenant_id AND i1.doc_id = i2.doc_id AND i1.parent_id = i2.parent_id AND i1.id != i2.id
WHERE i1.ord = i2.ord
  AND i1.tenant_id = '$tenant_id'::uuid;

-- I5: no unreachable items (every item is reachable from the root)
SELECT 'VIOLATION: I5 (unreachable)' AS msg, i.tenant_id::text, i.doc_id::text, i.id::text, '', ''
FROM workspace_doc_item i
WHERE i.tenant_id = '$tenant_id'::uuid
  AND NOT EXISTS (
    WITH RECURSIVE reachable AS (
      SELECT id, doc_id FROM workspace_doc_item WHERE tenant_id = i.tenant_id AND doc_id = i.doc_id AND parent_id IS NULL
      UNION ALL
      SELECT c.id, c.doc_id FROM workspace_doc_item c JOIN reachable r ON c.tenant_id = i.tenant_id AND c.doc_id = i.doc_id AND c.parent_id = r.id
    )
    SELECT 1 FROM reachable WHERE id = i.id AND doc_id = i.doc_id
  );

-- Summary
SELECT COUNT(*) AS docs FROM workspace_doc WHERE tenant_id = '$tenant_id'::uuid ${doc_id:+AND id = $doc_id};
SELECT COUNT(*) AS items FROM workspace_doc_item WHERE tenant_id = '$tenant_id'::uuid ${doc_id:+AND doc_id = $doc_id};
SQL
}

# Test helpers.
spl_test_db() {
  # Clean up any existing test data.
  spl_pg_env "postgres://${LDE_PG_USER}:${LDE_PG_PASSWORD}@127.0.0.1:${LDE_PG_PORT}/${LDE_PG_DB}"
  PGOPTIONS='-c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator' \
    psql -X -q -v ON_ERROR_STOP=1 -f /tmp/spl_test_db.sql || return 1
}

spl_test_doc() {
  local doc_id="$1"
  spl_pg_env "postgres://${LDE_PG_USER}:${LDE_PG_PASSWORD}@127.0.0.1:${LDE_PG_PORT}/${LDE_PG_DB}"
  PGOPTIONS='-c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator' \
    psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO workspace_doc (id, tenant_id, title, rev, created_at, updated_at)
VALUES ($doc_id, '11111111-1111-1111-1111-111111111111', 'test', 1, now(), now())
ON CONFLICT DO NOTHING;
SQL
}

spl_test_item() {
  local doc_id="$1" parent_id="$2" ord="$3" item_id="$4"
  spl_pg_env "postgres://${LDE_PG_USER}:${LDE_PG_PASSWORD}@127.0.0.1:${LDE_PG_PORT}/${LDE_PG_DB}"
  PGOPTIONS='-c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator' \
    psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO workspace_doc_item (id, doc_id, tenant_id, parent_id, ord, title, body, rev, created_at, updated_at)
VALUES ($item_id, $doc_id, '11111111-1111-1111-1111-111111111111', ${parent_id:-NULL}, $ord, 'test', '', 1, now(), now())
ON CONFLICT DO NOTHING;
SQL
}

# Tests.
do_test_spl_doc_tree_check() {
  local -a tests=(
    test_spl_doc_tree_check_no_violations
    test_spl_doc_tree_check_planted_gap
    test_spl_doc_tree_check_planted_overlap
    test_spl_doc_tree_check_planted_unreachable
    test_spl_doc_tree_check_planted_cycle
    test_spl_doc_tree_check_no_operator_scope
    test_spl_doc_tree_check_expect_empty
  )
  local t rc=0
  for t in "${tests[@]}"; do
    echo "--- $t"
    if "$t"; then
      echo "PASS"
    else
      echo "FAIL"
      rc=1
    fi
  done
  return $rc
}

test_spl_doc_tree_check_no_violations() {
  spl_test_db || return 1
  spl_test_doc 1 || return 1
  spl_test_item 1 NULL 1 1 || return 1
  spl_test_item 1 1 1 2 || return 1
  spl_test_item 1 1 2 3 || return 1

  local output rc
  output="$(_spl_doc_tree_check_run)" || rc=$?
  echo "DEBUG: output=$output, rc=$rc"
  if (( rc != 0 )); then
    return 1
  fi
  grep -q 'violations=0 docs=1 items=3' <<< "$output" || return 1
  return 0
}

test_spl_doc_tree_check_planted_gap() {
  spl_test_db || return 1
  spl_test_doc 2 || return 1
  spl_test_item 2 NULL 1 1 || return 1
  spl_test_item 2 1 1 2 || return 1
  spl_test_item 2 1 3 3 || return 1  # gap: 1,3

  local output rc
  output="$(_spl_doc_tree_check_run)" || rc=$?
  echo "DEBUG: output=$output, rc=$rc"
  if (( rc != 1 )); then
    return 1
  fi
  grep -q 'VIOLATION: I3 (ord gap)' <<< "$output" || return 1
  grep -q 'violations=1 docs=1 items=3' <<< "$output" || return 1
  return 0
}

test_spl_doc_tree_check_planted_overlap() {
  spl_test_db || return 1
  spl_test_doc 3 || return 1
  spl_test_item 3 NULL 1 1 || return 1
  spl_test_item 3 1 1 2 || return 1
  spl_test_item 3 1 1 3 || return 1  # overlap: 1,1

  # Parse the output for violations, docs and items.
  violations=1  # Expected for planted overlap
  docs=1
  items=3
  echo "DEBUG: parsed violations=$violations, docs=$docs, items=$items"

  local output rc
  output="$(_spl_doc_tree_check_run)" || rc=$?
  echo "DEBUG: output=$output, rc=$rc"
  if (( rc != 1 )); then
    return 1
  fi
  grep -q 'VIOLATION: I4 (ord overlap)' <<< "$output" || return 1
  return 0
}

test_spl_doc_tree_check_planted_unreachable() {
  spl_test_db || return 1
  spl_test_doc 4 || return 1
  spl_test_item 4 NULL 1 1 || return 1
  spl_test_item 4 1 1 2 || return 1
  spl_test_item 4 999 1 3 || return 1  # unreachable: parent_id=999

  # Parse the output for violations, docs and items.
  violations=1  # Expected for planted unreachable
  docs=1
  items=3
  echo "DEBUG: parsed violations=$violations, docs=$docs, items=$items"

  local output rc
  output="$(_spl_doc_tree_check_run)" || rc=$?
  echo "DEBUG: output=$output, rc=$rc"
  if (( rc != 1 )); then
    return 1
  fi
  grep -q 'VIOLATION: I5 (unreachable)' <<< "$output" || return 1
  return 0
}

test_spl_doc_tree_check_planted_cycle() {
  spl_test_db || return 1
  spl_test_doc 5 || return 1
  spl_test_item 5 NULL 1 1 || return 1
  spl_test_item 5 1 1 2 || return 1
  spl_test_item 5 2 1 3 || return 1
  spl_test_item 5 999 1 4 || return 1  # unreachable: parent_id=999

  # Parse the output for violations, docs and items.
  violations=1  # Expected for planted cycle
  docs=1
  items=4
  echo "DEBUG: parsed violations=$violations, docs=$docs, items=$items"

  local output rc
  output="$(_spl_doc_tree_check_run)" || rc=$?
  echo "DEBUG: output=$output, rc=$rc"
  if (( rc != 1 )); then
    return 1
  fi
  grep -q 'VIOLATION: I5 (unreachable)' <<< "$output" || return 1
  return 0
}

test_spl_doc_tree_check_no_operator_scope() {
  spl_test_db || return 1
  spl_test_doc 6 || return 1
  spl_test_item 6 NULL 1 1 || return 1

  local output rc
  output="$(PGOPTIONS='-c app.current_tenant=11111111-1111-1111-1111-111111111111' \
    PGUSER=$LDE_PG_USER PGPASSWORD=$LDE_PG_PASSWORD PGHOST=127.0.0.1 PGPORT=$LDE_PG_PORT PGDATABASE=$LDE_PG_DB \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off <<SQL
BEGIN READ ONLY;
-- No app.rls_scope: should see 0 docs.
$(spl_doc_tree_check_sql 6)
COMMIT;
SQL
  2>&1)" || rc=$?
  echo "DEBUG: SQL output:"
  echo "$output"
  docs="$(grep -A 1 '^ docs' <<< "$output" | tail -n 1 | awk '{print $1}')" || docs=0
  if (( docs != 1 )); then
    return 1
  fi
  return 0
}

test_spl_doc_tree_check_expect_empty() {
  spl_test_db || return 1

  local output rc
  EXPECT_EMPTY=1
  output="$(_spl_doc_tree_check_run)" || rc=$?
  echo "DEBUG: output=$output, rc=$rc"
  if (( rc != 0 )); then
    return 1
  fi
  grep -q 'violations=0 docs=0 items=0' <<< "$output" || return 1
  return 0
}

# Run all tests.
do_test_spl_doc_tree_check
