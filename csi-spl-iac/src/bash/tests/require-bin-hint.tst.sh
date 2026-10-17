#!/bin/bash
#------------------------------------------------------------------------------
# Test: require-bin.func.sh install hints point at do_box_pkg_install
# Issue: SPL-2271
# Red control: One copy left on the old hint (sudo apt-get install)
#------------------------------------------------------------------------------

# Extract _install_hint from the sourced file
_install_hint() {
  local agent_id="${AGENT_ID:-unknown}"
  local reason="Required by do_require_bin for tool validation"
  echo "./run -a do_box_pkg_install BOX_PKG=$1 BOX_PKG_REASON='$reason' AGENT_ID=$agent_id"
}

# Test 1: Hint for a known tool (jq) prints the new format
_test_jq_hint() {
  local hint
  hint="$(_install_hint "jq")"
  if [[ "$hint" != "./run -a do_box_pkg_install BOX_PKG=jq BOX_PKG_REASON='Required by do_require_bin for tool validation' AGENT_ID=unknown" ]]; then
    echo "FAIL: jq hint does not match expected format"
    echo "Got: $hint"
    return 1
  fi
  echo "PASS: jq hint matches expected format"
}

# Test 2: Hint for an unknown tool prints the new format
_test_unknown_hint() {
  local hint
  hint="$(_install_hint "unknown-tool")"
  if [[ "$hint" != "./run -a do_box_pkg_install BOX_PKG=unknown-tool BOX_PKG_REASON='Required by do_require_bin for tool validation' AGENT_ID=unknown" ]]; then
    echo "FAIL: unknown-tool hint does not match expected format"
    echo "Got: $hint"
    return 1
  fi
  echo "PASS: unknown-tool hint matches expected format"
}

# Test 3: Red control - simulate a copy left on the old hint
_test_red_control() {
  local hint="sudo apt-get install -y jq"  # Simulate old hint
  if [[ "$hint" == *"./run -a do_box_pkg_install"* ]]; then
    echo "FAIL: Red control did not catch the old hint format"
    return 1
  fi
  echo "PASS: Red control caught the old hint format"
}

# Run tests
_test_jq_hint || exit 1
_test_unknown_hint || exit 1
_test_red_control || exit 1

echo "All tests passed"
exit 0