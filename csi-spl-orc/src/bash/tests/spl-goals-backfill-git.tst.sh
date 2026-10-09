#!/usr/bin/env bash
#
# spl-goals-backfill-git.tst.sh: Test do_spl_goals_backfill_git (spec 112, ORC-2).
#
# Runs:
#   do_spl_goals_backfill_git
#
# Expects:
#   - A fixture repo with tags v1.2.0, v1.2.1, v1.3.0
#   - Exactly 2 release events (v1.2.0 and v1.3.0; v1.2.1 is a patch and must be ignored)
#   - 503 roadmap_not_configured treated as a warning
#   - 200 OK on success

set -euo pipefail

setup_fixture_repo() {
    local fixture_dir
    fixture_dir="$(mktemp -d)"
    cd "${fixture_dir}" || exit 1
    git init . >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    git commit --allow-empty -m "Initial commit" >/dev/null 2>&1
    git tag -a v1.2.0 -m "Release v1.2.0" >/dev/null 2>&1
    git tag -a v1.2.1 -m "Release v1.2.1" >/dev/null 2>&1
    git tag -a v1.3.0 -m "Release v1.3.0" >/dev/null 2>&1
    
    # Mock required directories and files
    mkdir -p "${fixture_dir}/csi-spl-cnf/csi-spl"
    mkdir -p "${fixture_dir}/csi-spl-doc/goals"
    
    cat > "${fixture_dir}/csi-spl-cnf/csi-spl/all.env.yaml" << 'EOC'
env:
  roadmap:
    tenant_id: "mock-tenant"
  hub:
    base_url: "http://localhost:8080"
EOC
    
    # Empty milestones.yaml to avoid counting it
    touch "${fixture_dir}/csi-spl-doc/goals/milestones.yaml"
    
    echo "${fixture_dir}"
}

test_backfill_git() {
    local repo_root
    local cnf_file
    local fixture_dir
    local deploy_token
    local response
    local response_code

    repo_root="$(git rev-parse --show-toplevel)"
    cnf_file="${repo_root}/csi-spl-cnf/csi-spl/all.env.yaml"

    # Setup fixture repo
    fixture_dir="$(setup_fixture_repo)"
    cd "${fixture_dir}" || exit 1

    # Debug: List tags
    echo "Tags in fixture:"
    git tag -l

    # Mock DEPLOY_ID_TOKEN
    export DEPLOY_ID_TOKEN="mock-token"

    # Mock yq and curl
    yq() {
        if [[ "$*" == "eval .env.roadmap.tenant_id // \"\" ${cnf_file}" ]]; then
            echo "mock-tenant"
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

    # Source the function
    source "${repo_root}/csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh"

    # Test backfill
    response="$(do_spl_goals_backfill_git 2>&1)"
    response_code="$?"

    # Cleanup
    rm -rf "${fixture_dir}"

    if [[ "${response_code}" -ne 0 ]]; then
        echo "FAIL: do_spl_goals_backfill_git failed with exit code ${response_code}"
        echo "Output: ${response}"
        exit 1
    fi

    if [[ "${response}" != *"Backfilled 2 events to calendar"* ]]; then
        echo "FAIL: Expected 2 events backfilled, got: ${response}"
        exit 1
    fi

    echo "PASS: do_spl_goals_backfill_git"
}

test_backfill_git_503() {
    local repo_root
    local cnf_file
    local deploy_token
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
        elif [[ "$*" == "eval .env.hub.base_url // \"\" ${cnf_file}" ]]; then
            echo "http://localhost:8080"
        else
            command yq "$@"
        fi
    }
    export -f yq

    curl() {
        echo "roadmap_not_configured"
        echo 503
        return 0
    }
    export -f curl

    # Source the function
    source "${repo_root}/csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh"

    # Test 503 handling
    response="$(do_spl_goals_backfill_git 2>&1)"
    response_code="$?"

    if [[ "${response_code}" -ne 0 ]]; then
        echo "FAIL: do_spl_goals_backfill_git should treat 503 as a warning"
        echo "Output: ${response}"
        exit 1
    fi

    if [[ "${response}" != *"WARNING: Roadmap not configured (503 roadmap_not_configured)"* ]]; then
        echo "FAIL: Expected 503 warning, got: ${response}"
        exit 1
    fi

    echo "PASS: do_spl_goals_backfill_git 503 handling"
}

test_backfill_git
