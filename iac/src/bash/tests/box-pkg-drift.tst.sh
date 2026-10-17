#!/bin/bash
#
# box-pkg-drift.tst.sh: test do_box_pkg_drift with stubs.
#
# Red control: drop the journal join -> lose the agent id in NOT-IN-MANIFEST.
#

set -euo pipefail

# --- Test setup ---
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

# --- Stubs ---
stub_apt_mark() {
    cat <<'EOF' | sort -u
package1
package2
package3
base-pkg1
base-pkg2
EOF
}

stub_journal() {
    cat <<'EOF'
2026-10-17T12:00:00Z	pc	m-348	SPL-2271	install	package1	package1 package2 package3	0		"test install"
EOF
}

stub_bin_dirs() {
    cat <<'EOF'
BIN_DIR/tool1
BIN_DIR/tool2
USER_BIN_DIR/tool3
EOF
}

stub_base_list() {
    cat <<'EOF' | sort -u
base-pkg1
base-pkg2
EOF
}

stub_manifest() {
    cat <<'EOF'
# kind	name	pin	installed_by	needed_by	service	added
apt	package1		play 02_os_binaries	do_require_bin (43 actions)		2026-10-17 SPL-2271
apt	package2		play 02_os_binaries	do_require_bin (43 actions)		2026-10-17 SPL-2271
bin	tool1		play 02_os_binaries	do_require_bin (43 actions)		2026-10-17 SPL-2271
bin	tool2		play 02_os_binaries	do_require_bin (43 actions)		2026-10-17 SPL-2271
EOF
}

# --- Test cases ---
test_green_case() {
    echo "=== Green case: drift report with journal join ==="
    
    # Setup stubs
    export BOX_CLASS="pc"
    export BOX_PKG_DIR="${TEST_DIR}"
    export BASE_LIST="${TEST_DIR}/base-pc.txt"
    export JOURNAL="${TEST_DIR}/journal.tsv"
    export MANIFEST="${TEST_DIR}/pc.tsv"
    export BOX_PKG_STUB_APT_MARK="$(stub_apt_mark)"
    
    stub_base_list > "${BASE_LIST}"
    stub_journal > "${JOURNAL}"
    stub_manifest > "${MANIFEST}"
    
    # Override commands for the test
    find() {
        if [[ "$*" == *"/usr/local/bin"* ]]; then
            echo "/fake/local/bin/tool1"
        elif [[ "$*" == *"~ai-usr/bin"* ]]; then
            echo "/fake/home/ai-usr/bin/tool3"
        fi
    }
    id() { echo "ai-usr"; }
    
    # Override read_bin_dirs for the test: only tool1 and tool3 exist
    read_bin_dirs() {
        echo -e "bin\ttool1\nbin\ttool3"
    }
    
    # Run the drift report
    local output="$( {
        BOX_CLASS="pc" DRIFT_STRICT=0 \
        "$(dirname "${BASH_SOURCE[0]}")/../run/box-pkg-drift.func.sh" 2>&1
    })"
    
    # Check output
    echo "${output}" | grep -q "MISSING-FROM-BOX tool2" || { echo "FAIL: tool2 not reported as MISSING-FROM-BOX"; exit 1; }
    echo "${output}" | grep -q "NOT-IN-MANIFEST package3.*m-348.*test install" || { echo "FAIL: package3 not reported with agent id"; exit 1; }
    echo "${output}" | grep -q "NOT-IN-MANIFEST tool3" || { echo "FAIL: tool3 not reported"; exit 1; }
    
    echo "PASS: Green case"
}

test_red_control() {
    echo "=== Red control: drift report without journal join ==="
    
    # Setup stubs (same as green case, but drop the journal join)
    export BOX_CLASS="pc"
    export BOX_PKG_DIR="${TEST_DIR}"
    export BASE_LIST="${TEST_DIR}/base-pc.txt"
    export JOURNAL="${TEST_DIR}/journal.tsv"
    export MANIFEST="${TEST_DIR}/pc.tsv"
    export BOX_PKG_STUB_APT_MARK="$(stub_apt_mark)"
    
    stub_base_list > "${BASE_LIST}"
    # Break the journal join: drop the agent id and reason
    echo -e "2026-10-17T12:00:00Z	pc			install	package1	package1 package2 package3	0		" > "${JOURNAL}"
    stub_manifest > "${MANIFEST}"
    
    # Override commands for the test
    find() {
        if [[ "$*" == *"/usr/local/bin"* ]]; then
            echo "/fake/local/bin/tool1"
        elif [[ "$*" == *"~ai-usr/bin"* ]]; then
            echo "/fake/home/ai-usr/bin/tool3"
        fi
    }
    id() { echo "ai-usr"; }
    
    # Override read_bin_dirs for the test: only tool1 and tool3 exist
    read_bin_dirs() {
        echo -e "bin\ttool1\nbin\ttool3"
    }
    
    # Run the drift report
    local output="$( {
        BOX_CLASS="pc" DRIFT_STRICT=0 \
        "$(dirname "${BASH_SOURCE[0]}")/../run/box-pkg-drift.func.sh" 2>&1
    })"
    
    # Check output: package3 must NOT have an agent id
    echo "${output}" | grep -q "NOT-IN-MANIFEST package3 (\s*)$" || { echo "FAIL: package3 reported with agent id (red control)"; exit 1; }
    
    echo "PASS: Red control"
}

test_strict_mode() {
    echo "=== Strict mode: exit 2 on NOT-IN-MANIFEST ==="
    
    # Setup stubs
    export BOX_CLASS="pc"
    export BOX_PKG_DIR="${TEST_DIR}"
    export BASE_LIST="${TEST_DIR}/base-pc.txt"
    export JOURNAL="${TEST_DIR}/journal.tsv"
    export MANIFEST="${TEST_DIR}/pc.tsv"
    export BOX_PKG_STUB_APT_MARK="$(stub_apt_mark)"
    
    stub_base_list > "${BASE_LIST}"
    stub_journal > "${JOURNAL}"
    stub_manifest > "${MANIFEST}"
    
    # Override commands for the test
    find() {
        if [[ "$*" == *"/usr/local/bin"* ]]; then
            echo "/fake/local/bin/tool1"
        elif [[ "$*" == *"~ai-usr/bin"* ]]; then
            echo "/fake/home/ai-usr/bin/tool3"
        fi
    }
    id() { echo "ai-usr"; }
    
    # Override read_bin_dirs for the test: only tool1 and tool3 exist
    read_bin_dirs() {
        echo -e "bin\ttool1\nbin\ttool3"
    }
    
    # Run the drift report in strict mode
    if {
        BOX_CLASS="pc" DRIFT_STRICT=1 \
        "$(dirname "${BASH_SOURCE[0]}")/../run/box-pkg-drift.func.sh" 2>&1
    }; then
        echo "FAIL: Strict mode did not exit 2"; exit 1
    else
        local rc=$?
        [[ $rc -eq 2 ]] || { echo "FAIL: Strict mode exited $rc, expected 2"; exit 1; }
    fi
    
    echo "PASS: Strict mode"
}

# --- Run tests ---
test_green_case
test_red_control
test_strict_mode

echo "=== All tests passed ==="