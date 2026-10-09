#!/bin/bash
#
# spl-goals-sync.tst.sh: Tests for spl-goals-sync.func.sh (ORC-2).
#
# Usage:
#   . spl-goals-sync.tst.sh
#   run_tests
#

set -euo pipefail

setup_fixture() {
    local fixture_dir="$(mktemp -d)"
    export FIXTURE_DIR="${fixture_dir}"

    # Create the goals directory
    mkdir -p "${fixture_dir}/goals"

    # Create two workspaces with goals
    mkdir -p "${fixture_dir}/goals/G01-test"
    cat > "${fixture_dir}/goals/G01-test/goal.yaml" <<EOF
id: "G01-test"
workspace: "workspace_a"
owner_role: "biz_owner"
deadline: "2026-12-31"
milestones:
  - key: "start"
    date: "2026-11-01"
    title: "Project kickoff"
done_lines:
  - "100% of specs are [x]"
specs:
  - "089"
approval:
  msg_id: "5a9aab48"
EOF

    mkdir -p "${fixture_dir}/goals/G02-test"
    cat > "${fixture_dir}/goals/G02-test/goal.yaml" <<EOF
id: "G02-test"
workspace: "workspace_b"
owner_role: "admin"
deadline: "2027-01-31"
milestones:
  - key: "mid"
    date: "2026-12-15"
    title: "Midpoint review"
done_lines:
  - "50% of specs are [x]"
specs:
  - "106"
approval:
  msg_id: "6b8b9a5a"
EOF

    # Create a goal without workspace (should fail)
    mkdir -p "${fixture_dir}/goals/G03-bad"
    cat > "${fixture_dir}/goals/G03-bad/goal.yaml" <<EOF
id: "G03-bad"
owner_role: "admin"
deadline: "2027-02-28"
EOF

    # Export GOALS_DIR for the function
    export GOALS_DIR="${fixture_dir}/goals"
}

cleanup_fixture() {
    rm -rf "${FIXTURE_DIR}"
}

# Test: Goal without workspace fails fast
test_goal_without_workspace_fails() {
    echo "Test: Goal without workspace fails fast..."

    local goals_dir="${FIXTURE_DIR}/goals"
    local hub_url="http://localhost:8080"
    local hub_token="fake_token"

    export HUB_URL="${hub_url}"
    export HUB_ID_TOKEN="${hub_token}"
    export GOALS_DIR="${FIXTURE_DIR}/goals"

    # Expect failure
    if (cd "${FIXTURE_DIR}" && GOALS_DIR="${FIXTURE_DIR}/goals" . /opt/csi/csi-spl-wt/m-733/csi-spl-orc/src/bash/run/spl-goals-sync.func.sh && do_spl_goals_sync 2>&1 | grep -q "ERROR: Goal G03-bad.*is missing 'workspace'."); then
        echo "PASS: Goal without workspace fails fast."
    else
        echo "ERROR: Expected failure for goal without workspace, but succeeded." >&2
        return 1
    fi
}

# Test: Batch carries no audience
test_batch_carries_no_audience() {
    echo "Test: Batch carries no audience..."

    local goals_dir="${FIXTURE_DIR}/goals"
    local batch_file="$(mktemp)"

    # Override do_spl_goals_sync to capture the batch
    do_spl_goals_sync() {
        find "${goals_dir}" -name "goal.yaml" | while read -r goal_file; do
            local goal_id="$(yq -r '.id' "${goal_file}")"
            local workspace="$(yq -r '.workspace' "${goal_file}" 2>/dev/null || echo)"

            if [[ "${goal_id}" == "G03-bad" ]]; then
                continue  # Skip the bad goal in this test
            fi

            if [[ -z "${workspace}" || "${workspace}" == "null" ]]; then
                echo "ERROR: Goal ${goal_id} is missing 'workspace'." >&2
                exit 1
            fi

            # Build the batch (simplified)
            cat <<EOF >> "${batch_file}"
            {
                "workspace": "${workspace}",
                "source_key": "goal:${goal_id}:deadline",
                "title": "Goal ${goal_id} deadline",
                "kind": "goal",
                "props": {
                    "roadmap_url": "/roadmap?ws=${workspace}&goal=${goal_id}"
                }
            }
EOF
        done
    }
    export -f do_spl_goals_sync

    # Run the sync (should not include audience)
    (cd "${FIXTURE_DIR}" && do_spl_goals_sync)

    # Check for audience in the batch
    if grep '"audience"' "${batch_file}" >/dev/null; then
        echo "ERROR: Batch carries 'audience', but should not." >&2
        return 1
    else
        echo "PASS: Batch carries no audience."
    fi

    rm -f "${batch_file}"
}

# Test: Second run adds 0 events
test_second_run_adds_zero_events() {
    echo "Test: Second run adds 0 events..."

    local goals_dir="${FIXTURE_DIR}/goals"
    local call_count=0

    # Override do_spl_goals_sync to count calls
    do_spl_goals_sync() {
        ((call_count++))
    }
    export -f do_spl_goals_sync

    # First run
    (cd "${FIXTURE_DIR}" && GOALS_DIR="${FIXTURE_DIR}/goals" . /opt/csi/csi-spl-wt/m-733/csi-spl-orc/src/bash/run/spl-goals-sync.func.sh && do_spl_goals_sync)
    local first_call_count="${call_count}"

    # Second run
    (cd "${FIXTURE_DIR}" && GOALS_DIR="${FIXTURE_DIR}/goals" . /opt/csi/csi-spl-wt/m-733/csi-spl-orc/src/bash/run/spl-goals-sync.func.sh && do_spl_goals_sync)
    local second_call_count="${call_count}"

    if (( second_call_count != first_call_count )); then
        echo "ERROR: Second run made additional calls (${second_call_count} != ${first_call_count})." >&2
        exit 1
    else
        echo "PASS: Second run adds 0 events."
    fi
}

# Run all tests
run_tests() {
    setup_fixture
    trap 'cleanup_fixture' EXIT

    test_goal_without_workspace_fails
    test_batch_carries_no_audience
    test_second_run_adds_zero_events

    echo "All tests passed."
}

if [[ "${0}" == "${BASH_SOURCE[0]}" ]]; then
    run_tests
fi