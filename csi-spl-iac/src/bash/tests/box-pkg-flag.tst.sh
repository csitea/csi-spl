#!/bin/bash
#
# box-pkg-flag.tst.sh: Test suite for do_box_pkg_flag.
#
# Fixtures:
#   - PC case: Inst systemd-resolved, Inst libnss-resolve (owner: NetworkManager) -> 1 FLAG line
#   - Sat case: Probes for systemd-resolved (owner: systemd-resolved) -> 0 FLAG lines
#   - Remv network-manager -> 1 FLAG line
#   - Red control: Drop libnss-resolve from the map -> 1 FLAG line
#

set -uo pipefail

# Test setup
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Stub executables
mkdir -p "$TEST_DIR/bin"
export PATH="$TEST_DIR/bin:$PATH"

# Stub systemctl for PC case
cat > "$TEST_DIR/bin/systemctl" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "DEBUG: systemctl stub called with $*" >&2

case "$*" in
    "is-active --quiet systemd-resolved")
        # Active for PC and sat cases
        exit 0
        ;;
    "is-active --quiet NetworkManager")
        # Active for Remv case
        exit 0
        ;;
    "show systemd-resolved -p UnitFileState --value")
        # PC case: NetworkManager is the expected owner, but the service is enabled (owned by systemd-resolved)
        echo "enabled"
        ;;
    "show NetworkManager -p UnitFileState --value")
        # Remv case: not enabled
        echo "disabled"
        ;;
    "show systemd-resolved -p FragmentPath --value")
        echo "/lib/systemd/system/systemd-resolved.service"
        ;;
    "show NetworkManager -p FragmentPath --value")
        echo "/lib/systemd/system/NetworkManager.service"
        ;;
    *)
        echo "ERROR: Unexpected systemctl call: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/systemctl"

# Stub dpkg-query
cat > "$TEST_DIR/bin/dpkg-query" << 'EOF'
#!/bin/bash
set -euo pipefail

echo "DEBUG: dpkg-query stub called with $*" >&2

case "$*" in
    "-S /lib/systemd/system/systemd-resolved.service")
        # PC case: systemd-resolved
        echo "systemd-resolved: /lib/systemd/system/systemd-resolved.service"
        ;;
    "-S /lib/systemd/system/NetworkManager.service")
        # Remv case: network-manager
        echo "network-manager: /lib/systemd/system/NetworkManager.service"
        ;;
    *)
        echo "ERROR: Unexpected dpkg-query call: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/dpkg-query"

# Source the function
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run/box-pkg-flag.func.sh" || {
    echo "ERROR: Failed to source box-pkg-flag.func.sh"
    exit 1
}

# Test cases
run_test() {
    local test_name="$1"
    local services_map="$2"
    local expected_flag_count="$3"
    local expected_flag_text="$4"
    
    echo "=== $test_name ==="
    export BOX_PKG_SERVICES_MAP="$services_map"
    echo "DEBUG: Calling do_box_pkg_flag" >&2
    output="$(do_box_pkg_flag 2>&1 || true)"
    echo "DEBUG: do_box_pkg_flag completed" >&2
    flag_count="$(echo "$output" | grep -c '^FLAG:')"
    
    if [[ "$flag_count" -ne "$expected_flag_count" ]]; then
        echo "FAIL: Expected $expected_flag_count FLAG lines, got $flag_count"
        echo "Output:"
        echo "$output"
        exit 1
    fi
    
    if [[ -n "${expected_flag_text:-}" ]]; then
        if [[ "$flag_count" -gt 0 ]]; then
            if ! grep -q "$expected_flag_text" <<< "$output"; then
                echo "FAIL: Expected FLAG line not found"
                echo "Output:"
                echo "$output"
                exit 1
            fi
        else
            echo "FAIL: Expected FLAG line but got 0 FLAG lines"
            exit 1
        fi
    fi
    
    echo "PASS"
}

# Test 1: PC case (systemd-resolved, owner NetworkManager) -> 1 FLAG line
run_test "Test 1: PC case (systemd-resolved, libnss-resolve, owner NetworkManager)" \
    "systemd-resolved:NetworkManager" \
    1 \
    "FLAG: systemd-resolved takes systemd-resolved from NetworkManager"

# Test 2: Sat case (systemd-resolved, owner systemd-resolved) -> 0 FLAG lines
run_test "Test 2: Sat case (systemd-resolved, owner systemd-resolved)" \
    "systemd-resolved:systemd-resolved" \
    0 \
    ""

# Test 3: Remv network-manager -> 1 FLAG line
run_test "Test 3: Remv network-manager" \
    "NetworkManager:NetworkManager" \
    1 \
    "FLAG: network-manager takes NetworkManager from NetworkManager"

# Test 4: Red control (drop libnss-resolve from map) -> 1 FLAG line
run_test "Test 4: Red control (drop libnss-resolve from map)" \
    "systemd-resolved:systemd" \
    1 \
    "FLAG: systemd-resolved takes systemd-resolved from systemd"

echo "=== All tests passed ==="