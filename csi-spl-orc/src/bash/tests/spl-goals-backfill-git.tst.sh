#!/bin/bash
#
# spl-goals-backfill-git.tst.sh: Tests for do_spl_goals_backfill_git.
#
# Usage:
#   bash spl-goals-backfill-git.tst.sh
#

set -euo pipefail

# The func, resolved from this test's own dir
FUNCTION_FILE="$(cd "$(dirname "$0")" && pwd)/../run/spl-goals-backfill-git.func.sh"

# Define functions first
test_fails_fast_if_workspace_unset() {
    unset WORKSPACE
    export WORKSPACE
    if output="$(bash "${FUNCTION_FILE}" 2>&1)"; then
        echo "✗ Expected failure when WORKSPACE is unset"
        exit 1
    fi
    [[ "${output}" == *"WORKSPACE must be set"* ]]
    echo "✓ fails fast if WORKSPACE is unset"
}

test_builds_batch_with_tags_specs_and_milestones() {
    # shellcheck source=../run/spl-goals-backfill-git.func.sh
    source "${FUNCTION_FILE}"

    local batch_file="$(mktemp)"
    export WORKSPACE="test-workspace"
    build_batch "${REPO_ROOT}" "2026-09-17" "${batch_file}"

    # Check the batch file
    if [[ ! -s "${batch_file}" ]]; then
        echo "✗ Batch file is empty"
        exit 1
    fi
    
    if ! grep -q "spool-hub started" "${batch_file}"; then
        echo "✗ spool-hub started not found"
        exit 1
    fi
    
    if grep -q '"audience"' "${batch_file}"; then
        echo "✗ Batch contains audience key (HUB-2 sets it)"
        exit 1
    fi
    
    echo "✓ Batch contains required events and no audience key"
}

test_syncs_to_the_hub() {
    # Mock curl
    curl() {
        echo "Mock curl called with: $*"
        return 0
    }
    export -f curl

    # shellcheck source=../run/spl-goals-backfill-git.func.sh
    source "${FUNCTION_FILE}"

    local batch_file="$(mktemp)"
    echo '{"events": []}' > "${batch_file}"

    if ! output="$(sync_to_hub "${batch_file}" "${SYNC_URL}" 2>&1)"; then
        echo "✗ Failed to sync to the hub"
        exit 1
    fi
    
    if [[ "${output}" != *"Syncing batch to ${SYNC_URL}"* ]]; then
        echo "✗ Unexpected output from sync_to_hub"
        exit 1
    fi
    
    echo "✓ syncs to the hub"
}

setup() {
    export REPO_ROOT="$(mktemp -d)"
    export WORKSPACE="test-workspace"
    export SYNC_URL="http://localhost:8080/v1/calendar/sync"

    # Create the goals directory
    mkdir -p "${REPO_ROOT}/csi-spl-doc/goals"
    cat > "${REPO_ROOT}/csi-spl-doc/goals/milestones.yaml" <<EOF
milestones:
  - title: "spool-hub started"
    date: "2026-09-17"
    source_key: "milestone:spool-hub-started"
  - title: "First milestone"
    date: "2026-09-18"
EOF

    # Create the specs directory
    mkdir -p "${REPO_ROOT}/csi-spl-doc/specs/112-goals-strategy-roadmap"
    cat > "${REPO_ROOT}/csi-spl-doc/specs/112-goals-strategy-roadmap/tasks.md" <<EOF
# 112 Goals, strategy and roadmap: tasks

- [x] **ORC-1**: Test spec done
EOF

    # Create the spec file
    cat > "${REPO_ROOT}/csi-spl-doc/specs/112-goals-strategy-roadmap/spec.md" <<EOF
# Spec 112: Goals, strategy and roadmap
EOF
}

teardown() {
    rm -rf "${REPO_ROOT}"
}

# Run tests
setup

echo "Running tests..."

test_fails_fast_if_workspace_unset
test_builds_batch_with_tags_specs_and_milestones
test_syncs_to_the_hub

echo "All tests completed."

teardown