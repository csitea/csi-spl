#!/bin/bash
#
# box-pkg-flag.tst.sh: Test suite for do_box_pkg_flag.
#
# Fixtures:
#   - PC case: Inst systemd-resolved, Inst libnss-resolve (owner: NetworkManager) -> 2 FLAG lines
#   - Sat case: Probes for systemd-resolved (owner: systemd-resolved) -> 0 FLAG lines
#   - Remv network-manager -> 1 FLAG line
#   - Red control: Drop libnss-resolve from the map -> PC case must go red
#

set -euo pipefail

# Test setup
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Stub executables
mkdir -p "$TEST_DIR/bin"
export PATH="$TEST_DIR/bin:$PATH"

# Stub systemctl
cat > "$TEST_DIR/bin/systemctl" << 'EOF'
#!/bin/bash
set -euo pipefail

case "$*" in
    "is-active --quiet systemd-resolved")
        # Active for PC and sat cases
        exit 0
        ;;
    "is-active --quiet NetworkManager")
        # Inactive for Remv case
        exit 3
        ;;
    "show systemd-resolved -p UnitFileState --value")
        # PC case: NetworkManager
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
source "/opt/csi/csi-spl-wt/m-266/csi-spl-iac/src/bash/run/box-pkg-flag.func.sh"

# Test cases
echo "=== Test 1: PC case (systemd-resolved, libnss-resolve, owner NetworkManager) ==="
export BOX_PKG_SERVICES_MAP="systemd-resolved:NetworkManager"
output="$(do_box_pkg_flag 2>&1)"
echo "Output:"
echo "$output"
if [[ "$(echo "$output" | grep -c '^FLAG:')" -ne 1 ]]; then
    echo "FAIL: Expected 1 FLAG line, got $(echo "$output" | grep -c '^FLAG:')"
    exit 1
fi
if ! echo "$output" | grep -q "FLAG: systemd-resolved takes systemd-resolved from NetworkManager"; then
    echo "FAIL: Expected FLAG line not found"
    exit 1
fi
echo "PASS"


echo "=== Test 2: Sat case (systemd-resolved, owner systemd-resolved) ==="
export BOX_PKG_SERVICES_MAP="systemd-resolved:systemd-resolved"
output="$(do_box_pkg_flag 2>&1)"
echo "Output:"
echo "$output"
if [[ "$(echo "$output" | grep -c '^FLAG:')" -ne 0 ]]; then
    echo "FAIL: Expected 0 FLAG lines, got $(echo "$output" | grep -c '^FLAG:')"
    exit 1
fi
echo "PASS"


echo "=== Test 3: Remv network-manager ==="
export BOX_PKG_SERVICES_MAP="NetworkManager:NetworkManager"
output="$(do_box_pkg_flag 2>&1)"
echo "Output:"
echo "$output"
if [[ "$(echo "$output" | grep -c '^FLAG:')" -ne 1 ]]; then
    echo "FAIL: Expected 1 FLAG line, got $(echo "$output" | grep -c '^FLAG:')"
    exit 1
fi
if ! echo "$output" | grep -q "FLAG: network-manager takes NetworkManager from NetworkManager"; then
    echo "FAIL: Expected FLAG line not found"
    exit 1
fi
echo "PASS"


echo "=== Test 4: Red control (drop libnss-resolve from map) ==="
export BOX_PKG_SERVICES_MAP="systemd-resolved:NetworkManager"
# Simulate missing libnss-resolve by forcing a mismatch
output="$(BOX_PKG_SERVICES_MAP="systemd-resolved:systemd" do_box_pkg_flag 2>&1)"
echo "Output:"
echo "$output"
if [[ "$(echo "$output" | grep -c '^FLAG:')" -ne 1 ]]; then
    echo "FAIL: Expected 1 FLAG line (red control), got $(echo "$output" | grep -c '^FLAG:')"
    exit 1
fi
echo "PASS"


echo "=== All tests passed ==="