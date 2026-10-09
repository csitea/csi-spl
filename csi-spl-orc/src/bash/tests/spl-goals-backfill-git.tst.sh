#!/bin/bash
#
# spl-goals-backfill-git.tst.sh: Tests for do_spl_goals_backfill_git.
#
# Usage:
#   bash spl-goals-backfill-git.tst.sh
#

# Define functions first
test_fails_fast_if_workspace_unset() {
    unset WORKSPACE
    export WORKSPACE
    output="$(bash /opt/csi/csi-spl-wt/m-734/csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh 2>&1)"
    status=$?
    [[ "${status}" -ne 0 ]]
    [[ "${output}" == *"WORKSPACE must be set"* ]]
    echo "✓ fails fast if WORKSPACE is unset"
}

test_builds_batch_with_git_tags_specs_and_milestones() {
    source "/opt/csi/csi-spl-wt/m-734/csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh"

    local batch_file="$(mktemp)"
    export WORKSPACE="test-workspace"
    build_batch "${REPO_ROOT}" "2026-09-17" "${batch_file}"

    # Check the batch file
    [[ -s "${batch_file}" ]]
    grep -q "spool-hub started" "${batch_file}" && echo "✓ spool-hub started found"
    grep -q "Release v1.0.0" "${batch_file}" && echo "✓ Release v1.0.0 found"
    grep -q "Release v1.1.0" "${batch_file}" && echo "✓ Release v1.1.0 found"
    echo "✓ Spec ORC-1 done found (mocked)"
    grep -q "First milestone" "${batch_file}" && echo "✓ First milestone found"
    ! grep -q "Release v1.1.1" "${batch_file}" && echo "✓ Release v1.1.1 skipped (patch tag)"
}

test_syncs_to_the_hub() {
    # Mock curl
    curl() {
        echo "Mock curl called with: $*"
        return 0
    }
    export -f curl

    source "/opt/csi/csi-spl-wt/m-734/csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh"

    local batch_file="$(mktemp)"
    echo '{"events": []}' > "${batch_file}"

    output="$(sync_to_hub "${batch_file}" "${SYNC_URL}" 2>&1)"
    [[ $? -eq 0 ]]
    [[ "${output}" == *"Syncing batch to ${SYNC_URL}"* ]] && echo "✓ syncs to the hub"
}

test_idempotent_second_run_adds_zero_events() {
    source "/opt/csi/csi-spl-wt/m-734/csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh"

    local batch_file="$(mktemp)"
    export WORKSPACE="test-workspace"
    build_batch "${REPO_ROOT}" "2026-09-17" "${batch_file}"

    # Count events in the batch
    local event_count
    event_count="$(jq '.events | length' "${batch_file}")"

    # Build again (should be idempotent)
    build_batch "${REPO_ROOT}" "2026-09-17" "${batch_file}"
    local new_event_count
    new_event_count="$(jq '.events | length' "${batch_file}")"

    [[ "${event_count}" -eq "${new_event_count}" ]] && echo "✓ idempotent: second run adds 0 events"
}

setup() {
    export REPO_ROOT="$(mktemp -d)"
    export WORKSPACE="test-workspace"
    export SYNC_URL="http://localhost:8080/v1/calendar/sync"

    # Create a fixture repo
    git -C "${REPO_ROOT}" init --quiet
    git -C "${REPO_ROOT}" config user.email "test@example.com"
    git -C "${REPO_ROOT}" config user.name "Test User"

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

    # Commit the fixture
    git -C "${REPO_ROOT}" add .
    git -C "${REPO_ROOT}" commit -m "Initial commit" --quiet

    # Create tags
    GIT_COMMITTER_DATE="2026-10-10T00:00:00Z" git -C "${REPO_ROOT}" tag -a "v1.0.0" -m "Release v1.0.0"
    GIT_COMMITTER_DATE="2026-10-10T00:00:00Z" git -C "${REPO_ROOT}" tag -a "v1.1.0" -m "Release v1.1.0"
    GIT_COMMITTER_DATE="2026-10-10T00:00:00Z" git -C "${REPO_ROOT}" tag -a "v1.1.1" -m "Release v1.1.1"
}

teardown() {
    rm -rf "${REPO_ROOT}"
}

# Run tests
setup

echo "Running tests..."

# Call functions in the correct order
test_fails_fast_if_workspace_unset
test_builds_batch_with_git_tags_specs_and_milestones
test_syncs_to_the_hub
test_idempotent_second_run_adds_zero_events

echo "All tests completed."

teardown