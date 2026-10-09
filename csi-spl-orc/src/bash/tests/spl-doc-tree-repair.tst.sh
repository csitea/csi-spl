#!/bin/bash
#------------------------------------------------------------------------------
# @description Test suite for do_spl_doc_tree_repair (spec 113 T003).
# @description Plant violations (gap, overlap, unreachable), repair, and verify.
# @example bash spl-doc-tree-repair.tst.sh
#------------------------------------------------------------------------------

set -euo pipefail

# Test DB credentials
export PGUSER=spool
export PGPASSWORD=spool_lde_pw
export PGHOST=127.0.0.1
export PGPORT=55432
export PGDATABASE=spool

# RLS scope for the test tenant
export PGOPTIONS='-c app.current_tenant=11111111-1111-1111-1111-111111111111 -c app.rls_scope=operator'

# Load the repair function
source /opt/csi/csi-spl-orc/src/bash/run/spl-doc-tree-repair.func.sh

# Setup: Create the test schema and data
setup_test_db() {
  psql -X -q -v ON_ERROR_STOP=1 <<SQL
-- Create tables
CREATE TABLE IF NOT EXISTS workspace_doc (
  id bigint PRIMARY KEY,
  tenant_id uuid NOT NULL,
  title text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS workspace_doc_item (
  id bigint PRIMARY KEY,
  tenant_id uuid NOT NULL,
  doc_id bigint NOT NULL REFERENCES workspace_doc(id),
  parent_id bigint REFERENCES workspace_doc_item(id),
  ord bigint NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);

-- Remove UNIQUE INDEX to allow planted overlaps (for testing)
DROP INDEX IF EXISTS workspace_doc_item_doc_parent_ord_idx;
CREATE INDEX IF NOT EXISTS workspace_doc_item_doc_parent_ord_idx ON workspace_doc_item (doc_id, parent_id, ord);

-- Insert test tenant
INSERT INTO workspace_doc (id, tenant_id, title) VALUES
  (1, '11111111-1111-1111-1111-111111111111'::uuid, 'Test Doc')
ON CONFLICT DO NOTHING;
SQL
}

# Teardown: Clean up test data
teardown_test_db() {
  psql -X -q -v ON_ERROR_STOP=1 <<SQL
TRUNCATE TABLE workspace_doc_item CASCADE;
TRUNCATE TABLE workspace_doc CASCADE;
SQL
}

# Plant a doc with a gap in ord
plant_gap() {
  local tenant_id="11111111-1111-1111-1111-111111111111"
  psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title, body) VALUES
  (1, '$tenant_id'::uuid, 1, NULL, 1, 'Root', ''),
  (2, '$tenant_id'::uuid, 1, 1, 1, 'Child 1', ''),
  (3, '$tenant_id'::uuid, 1, 1, 3, 'Child 3', '');
SQL
}

# Plant a doc with an overlap in ord
plant_overlap() {
  local tenant_id="11111111-1111-1111-1111-111111111111"
  psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title, body) VALUES
  (1, '$tenant_id'::uuid, 1, NULL, 1, 'Root', ''),
  (2, '$tenant_id'::uuid, 1, 1, 1, 'Child 1', ''),
  (3, '$tenant_id'::uuid, 1, 1, 1, 'Child 2', '');
SQL
}

# Plant a doc with an unreachable item
plant_unreachable() {
  local tenant_id="11111111-1111-1111-1111-111111111111"
  psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title, body) VALUES
  (1, '$tenant_id'::uuid, 1, NULL, 1, 'Root', ''),
  (2, '$tenant_id'::uuid, 1, 1, 1, 'Child 1', ''),
  (3, '$tenant_id'::uuid, 1, 999, 1, 'Unreachable', '');
SQL
}

# Plant a doc with a cycle (unreachable + cycle)
plant_cycle() {
  local tenant_id="11111111-1111-1111-1111-111111111111"
  psql -X -q -v ON_ERROR_STOP=1 <<SQL
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title, body) VALUES
  (1, '$tenant_id'::uuid, 1, NULL, 1, 'Root', ''),
  (2, '$tenant_id'::uuid, 1, 3, 1, 'Cycle 1', ''),
  (3, '$tenant_id'::uuid, 1, 2, 1, 'Cycle 2', '');
SQL
}

# Test 1: Repair a gap (DRY_RUN=1)
test_repair_gap_dry_run() {
  echo "=== Test 1: Repair gap (DRY_RUN=1)"
  teardown_test_db
  setup_test_db
  plant_gap

  local output
  output="$(DRY_RUN=1 DOC_ID=1 _spl_doc_tree_repair_run 2>&1)"
  echo "Output: $output"

  if [[ "$output" != *"renumbered=1"* ]]; then
    echo "FAIL: Expected renumbered=1 in output"
    return 1
  fi
  if [[ "$output" != *"DRY_RUN: SQL to execute"* ]]; then
    echo "FAIL: Expected DRY_RUN SQL output"
    return 1
  fi
  echo "PASS"
}

# Test 2: Repair a gap (DRY_RUN=0)
test_repair_gap_execute() {
  echo "=== Test 2: Repair gap (DRY_RUN=0)"
  teardown_test_db
  setup_test_db
  plant_gap

  local output
  output="$(DRY_RUN=0 DOC_ID=1 _spl_doc_tree_repair_run 2>&1)"
  echo "Output: $output"

  if [[ "$output" != *"renumbered=1"* ]]; then
    echo "FAIL: Expected renumbered=1 in output"
    return 1
  fi
  if [[ "$output" == *"DRY_RUN: SQL to execute"* ]]; then
    echo "FAIL: Did not expect DRY_RUN SQL output"
    return 1
  fi

  # Verify the gap is fixed
  local check_output
  check_output="$(DOC_ID=11111111-1111-1111-1111-111111111111 _spl_doc_tree_check_run 2>&1)"
  echo "Check output: $check_output"
  if [[ "$check_output" != *"violations=0"* ]]; then
    echo "FAIL: Expected violations=0 after repair"
    return 1
  fi
  echo "PASS"
}

# Test 3: Repair an overlap (DRY_RUN=1)
test_repair_overlap_dry_run() {
  echo "=== Test 3: Repair overlap (DRY_RUN=1)"
  teardown_test_db
  setup_test_db
  plant_overlap

  local output
  output="$(DRY_RUN=1 DOC_ID=1 _spl_doc_tree_repair_run 2>&1)"
  echo "Output: $output"

  if [[ "$output" != *"renumbered=1"* ]]; then
    echo "FAIL: Expected renumbered=1 in output"
    return 1
  fi
  if [[ "$output" != *"DRY_RUN: SQL to execute"* ]]; then
    echo "FAIL: Expected DRY_RUN SQL output"
    return 1
  fi
  echo "PASS"
}

# Test 4: Repair an overlap (DRY_RUN=0)
test_repair_overlap_execute() {
  echo "=== Test 4: Repair overlap (DRY_RUN=0)"
  teardown_test_db
  setup_test_db
  plant_overlap

  local output
  output="$(DRY_RUN=0 DOC_ID=1 _spl_doc_tree_repair_run 2>&1)"
  echo "Output: $output"

  if [[ "$output" != *"renumbered=1"* ]]; then
    echo "FAIL: Expected renumbered=1 in output"
    return 1
  fi
  if [[ "$output" == *"DRY_RUN: SQL to execute"* ]]; then
    echo "FAIL: Did not expect DRY_RUN SQL output"
    return 1
  fi

  # Verify the overlap is fixed
  local check_output
  check_output="$(DOC_ID=11111111-1111-1111-1111-111111111111 _spl_doc_tree_check_run 2>&1)"
  echo "Check output: $check_output"
  if [[ "$check_output" != *"violations=0"* ]]; then
    echo "FAIL: Expected violations=0 after repair"
    return 1
  fi
  echo "PASS"
}

# Test 5: Repair an unreachable item (DRY_RUN=1)
test_repair_unreachable_dry_run() {
  echo "=== Test 5: Repair unreachable (DRY_RUN=1)"
  teardown_test_db
  setup_test_db
  plant_unreachable

  local output
  output="$(DRY_RUN=1 DOC_ID=1 _spl_doc_tree_repair_run 2>&1)"
  echo "Output: $output"

  if [[ "$output" != *"reattached=1"* ]]; then
    echo "FAIL: Expected reattached=1 in output"
    return 1
  fi
  if [[ "$output" != *"DRY_RUN: SQL to execute"* ]]; then
    echo "FAIL: Expected DRY_RUN SQL output"
    return 1
  fi
  echo "PASS"
}

# Test 6: Repair an unreachable item (DRY_RUN=0)
test_repair_unreachable_execute() {
  echo "=== Test 6: Repair unreachable (DRY_RUN=0)"
  teardown_test_db
  setup_test_db
  plant_unreachable

  local output
  output="$(DRY_RUN=0 DOC_ID=1 _spl_doc_tree_repair_run 2>&1)"
  echo "Output: $output"

  if [[ "$output" != *"reattached=1"* ]]; then
    echo "FAIL: Expected reattached=1 in output"
    return 1
  fi
  if [[ "$output" == *"DRY_RUN: SQL to execute"* ]]; then
    echo "FAIL: Did not expect DRY_RUN SQL output"
    return 1
  fi

  # Verify the unreachable item is fixed
  local check_output
  check_output="$(DOC_ID=11111111-1111-1111-1111-111111111111 _spl_doc_tree_check_run 2>&1)"
  echo "Check output: $check_output"
  if [[ "$check_output" != *"violations=0"* ]]; then
    echo "FAIL: Expected violations=0 after repair"
    return 1
  fi
  echo "PASS"
}

# Test 7: Repair a cycle (DRY_RUN=0)
test_repair_cycle_execute() {
  echo "=== Test 7: Repair cycle (DRY_RUN=0)"
  teardown_test_db
  setup_test_db
  plant_cycle

  local output
  output="$(DRY_RUN=0 DOC_ID=1 _spl_doc_tree_repair_run 2>&1)"
  echo "Output: $output"

  if [[ "$output" != *"reattached=2"* ]]; then
    echo "FAIL: Expected reattached=2 in output"
    return 1
  fi
  if [[ "$output" == *"DRY_RUN: SQL to execute"* ]]; then
    echo "FAIL: Did not expect DRY_RUN SQL output"
    return 1
  fi

  # Verify the cycle is fixed
  local check_output
  check_output="$(DOC_ID=11111111-1111-1111-1111-111111111111 _spl_doc_tree_check_run 2>&1)"
  echo "Check output: $check_output"
  if [[ "$check_output" != *"violations=0"* ]]; then
    echo "FAIL: Expected violations=0 after repair"
    return 1
  fi
  echo "PASS"
}

# Run all tests
main() {
  echo "Starting spl-doc-tree-repair tests..."
  set -x
  test_repair_gap_dry_run || exit 1
  test_repair_gap_execute || exit 1
  test_repair_overlap_dry_run || exit 1
  test_repair_overlap_execute || exit 1
  test_repair_unreachable_dry_run || exit 1
  test_repair_unreachable_execute || exit 1
  test_repair_cycle_execute || exit 1
  echo "All tests passed!"
}

main