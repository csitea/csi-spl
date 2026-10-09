#!/usr/bin/env bash
#
# spl-goals-sync.tst.sh: Test do_spl_goals_sync (spec 112, ORC-2).
#
# Runs:
#   do_spl_goals_sync
#
# Expects:
#   - A fixture goal with deadline and milestones
#   - 503 roadmap_not_configured treated as a warning
#   - 200 OK on success

set -euo pipefail

test_sync_goals() {
    local repo_root
    local goals_dir
    local cnf_file
    local response
    local response_code

    repo_root="$(git rev-parse --show-toplevel)"
    goals_dir="${repo_root}/csi-spl-doc/goals"
    cnf_file="${repo_root}/csi-spl-cnf/csi-spl/all.env.yaml"

    # Mock DEPLOY_ID_TOKEN
    export DEPLOY_ID_TOKEN="mock-token"

    # Mock yq and curl
    yq() {
        if [[ "$*" == "eval .env.roadmap.tenant_id // \"\" ${cnf_file}" ]]; then
            echo "mock-tenant"
        elif [[ "$*" == "eval .env.roadmap.approver_role // \"\" ${cnf_file}" ]]; then
            echo "admin"
        elif [[ "$*" == "eval .env.hub.base_url // \"\" ${cnf_file}" ]]; then
            echo "http://localhost:8080"
        else
            command yq "$@"
        fi
    }
    export -f yq

    curl() {
        echo 
        echo 200
        return 0
    }
    export -f curl

    # Create a fixture goal
    mkdir -p "${goals_dir}/G01-test-goal"
    cat > "${goals_dir}/G01-test-goal/goal.yaml" << EOG
id: "G01-test-goal"
owner_role: "admin"
deadline: "2026-12-31"
milestones:
  - key: "start"
    date: "2026-10-01"
    title: "Project kickoff"
approval:
  msg_id: "mock-msg-id"
EOG

    # Source the function
    source "${repo_root}/csi-spl-orc/src/bash/run/spl-goals-sync.func.sh"

    # Test sync
    response="$(do_spl_goals_sync 2>&1)"
    response_code="$?"

    # Cleanup
    rm -rf "${goals_dir}/G01-test-goal"

    if [[ "${response_code}" -ne 0 ]]; then
        echo "FAIL: do_spl_goals_sync failed with exit code ${response_code}"
        echo "Output: ${response}"
        exit 1
    fi

    if [[ "${response}" != *"Synced 2 events to calendar"* ]]; then
        echo "FAIL: Expected 2 events synced, got: ${response}"
        exit 1
    fi

    echo "PASS: do_spl_goals_sync"
}

test_sync_goals_503() {
    local repo_root
    local cnf_file
    local response
    local response_code

    repo_root="$(git rev-parse --show-toplevel)"
    cnf_file="${repo_root}/csi-spl-cnf/csi-spl/all.env.yaml"

    # Mock DEPLOY_ID_TOKEN
    export DEPLOY_ID_TOKEN="mock-token"

    # Mock yq and curl for 503
    yq() {
        if [[ "$*" == "eval .env.roadmap.tenant_id // \"\" ${cnf_file}" ]]; then
            echo ""
        elif [[ "$*" == "eval .env.roadmap.approver_role // \"\" ${cnf_file}" ]]; then
            echo ""
        elif [[ "$*" == "eval .env.hub.base_url // \"\" ${cnf_file}" ]]; then
            echo "http://localhost:8080"
        else
            command yq "$@"
        fi
    }
    export -f yq

    curl() {
        echo roadmap_not_configured
        echo 503
        return 0
    }
    export -f curl

    # Source the function
    source "${repo_root}/csi-spl-orc/src/bash/run/spl-goals-sync.func.sh"

    # Test 503 handling
    response="$(do_spl_goals_sync 2>&1)"
    response_code="$?"

    if [[ "${response_code}" -ne 0 ]]; then
        echo "FAIL: do_spl_goals_sync should treat 503 as a warning"
        echo "Output: ${response}"
        exit 1
    fi

    if [[ "${response}" != *"WARNING: Roadmap not configured (503 roadmap_not_configured)"* ]]; then
        echo "FAIL: Expected 503 warning, got: ${response}"
        exit 1
    fi

    echo "PASS: do_spl_goals_sync 503 handling"
}

test_sync_goals
test_sync_goals_503
