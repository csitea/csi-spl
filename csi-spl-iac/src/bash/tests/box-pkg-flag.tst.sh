#!/bin/bash
#
# box-pkg-flag.tst.sh: Test suite for do_box_pkg_flag (Sat case only).
#

set -euo pipefail

echo "DEBUG: Test script started" >&2

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

echo "DEBUG: systemctl stub called with $*" >&2

case "$*" in
    "is-active --quiet systemd-resolved")
        echo "DEBUG: systemctl is-active --quiet systemd-resolved" >&2
        # Active for Sat case
        exit 0
        ;;
    "show systemd-resolved -p UnitFileState --value")
        echo "enabled"
        ;;
    "show systemd-resolved -p UnitFileState --value")
        echo "enabled"
        ;;
    "show systemd-resolved -p FragmentPath --value")
        echo "/lib/systemd/systemd/system/systemd-resolved.service"
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
    "-S /lib/systemd/systemd/system/systemd-resolved.service")
        echo "systemd-resolved: /lib/systemd/systemd/system/systemd-resolved.service"
        ;;
    *)
        echo "ERROR: Unexpected dpkg-query call: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/dpkg-query"

# Source the function
source "/opt/csi/csi-spl-wt/m-266/csi-spl-iac/src/bash/run/box-pkg-flag.func.sh" || {
    echo "ERROR: Failed to source box-pkg-flag.func.sh"
    exit 1
}

# Test case
run_test() {
    local test_name="$1"
    local services_map="$2"
    local expected_flag_count="$3"
    
    echo "=== $test_name ==="
    export BOX_PKG_SERVICES_MAP="$services_map"
    echo "DEBUG: Running do_box_pkg_flag" >&2
    echo "DEBUG: PATH=$PATH" >&2
    echo "DEBUG: which systemctl: $(which systemctl)" >&2
    output_file="$TEST_DIR/output.txt"
    source "/opt/csi/csi-spl-wt/m-266/csi-spl-iac/src/bash/run/box-pkg-flag.func.sh"
    echo "DEBUG: Function defined: $(declare -f do_box_pkg_flag)" >&2
    do_box_pkg_flag > "$output_file" 2>&1 || true
    flag_count="$(grep -c '^FLAG:' "$output_file")"
    
    if [[ "$flag_count" -ne "$expected_flag_count" ]]; then
        echo "FAIL: Expected $expected_flag_count FLAG lines, got $flag_count"
        echo "Output:"
        cat "$output_file"
        exit 1
    fi
    
    echo "PASS"
}

# Sat case (systemd-resolved, owner systemd-resolved) -> 0 FLAG lines
run_test "Test 2: Sat case (systemd-resolved, owner systemd-resolved)" \
    "systemd-resolved:systemd-resolved" \
    0

echo "=== All tests passed ==="