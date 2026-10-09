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

    
    # Override the function to use the fixture repo
    
    # Override the function to use the fixture repo

    # Debug: List tags
    echo "Tags in fixture:"
    git tag -l

    # Mock DEPLOY_ID_TOKEN
    export DEPLOY_ID_TOKEN="mock-token"




    source "${repo_root}/csi-spl-orc/src/bash/run/spl-goals-backfill-git.func.sh"

    # Test backfill
    export DEPLOY_ID_TOKEN="mock-token"
    response="$(do_spl_goals_backfill_git 2>&1)"
    response_code="$?"
    
    # Override git tag -l to return fixture tags
    
    # Override git tag -l to return fixture tags
    git() {
        if [[ "$*" == "tag -l" ]]; then
            echo -e "v1.2.0\nv1.2.1\nv1.3.0"
            return 0
        fi
        command git "$@"
    }
    export -f git
    
    # Count the number of events in the response
    event_count="$(do_spl_goals_backfill_git 2>&1 | grep -c "^{")"
    
    if [[ "${event_count}" -ne 2 ]]; then
        echo "FAIL: Expected 2 events in batch, got ${event_count}" >&2
        exit 1
    fi

    # Cleanup
    rm -rf "${fixture_dir}"

    if [[ "${response_code}" -ne 0 ]]; then
        echo "FAIL: do_spl_goals_backfill_git failed with exit code ${response_code}"
        echo "Output: ${response}"
        exit 1
    fi

    if [[ "${response}" != *"Backfilled 2 events to calendar"* ]]; then
        echo "FAIL: Expected 2 events backfilled (v1.2.0 and v1.3.0), got: ${response}"
        exit 1
    fi

    echo "PASS: do_spl_goals_backfill_git"
}

test_backfill_git_503() {
    local repo_root
    local cnf_file
    local response
    local response_code

    repo_root="$(git rev-parse --show-toplevel)"
    cnf_file="${repo_root}/csi-spl-cnf/csi-spl/all.env.yaml"

    # Mock DEPLOY_ID_TOKEN
    export DEPLOY_ID_TOKEN="mock-token"



    # Mock yq and curl
    yq() {
        if [[ "$*" == *".env.roadmap.tenant_id // \"\""* ]]; then
            echo "mock-tenant"
        elif [[ "$*" == *".env.hub.base_url // \"\""* ]]; then
            echo "http://localhost:8080"
        else
            echo "ERROR: Unexpected yq call: $*" >&2
            exit 1
        fi
    }
    export -f yq

    curl() {
        # Read the batch file and count the number of events
        local batch_size
        batch_size="$(grep -c '^{' "$1")"
        
        if [[ "${batch_size}" -ne 2 ]]; then
            echo "FAIL: Expected 2 events in batch, got ${batch_size}" >&2
            echo 400
            return 1
        fi
        
        echo 
        echo 200
        return 0
    }
    export -f curl

    # Call the function
    response="$(do_spl_goals_backfill_git 2>&1)"
    response_code="$?"


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
