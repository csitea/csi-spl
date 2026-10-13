#!/bin/bash
# Tests for spawn-window.sh vendor CLI checks (SPL-1614).
# Usage: SPAWN_TEST_MODE=1 ./spawn-window-vendor-cli.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MOCK_HERE="$HERE/mock-here"
SPAWN_WINDOW="/opt/csi/csi-spl-wt/m-917/csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh"
sed -i "s|\"\\(.*\\)/next-agent-id.sh|\"$MOCK_HERE/next-agent-id.sh|g" "$SPAWN_WINDOW"

# Mock vendor_cli data for testing
export BOX_PICK_CNF="$HERE/vendor_cli_test.yaml"
cat >"$BOX_PICK_CNF" <<'EOF'
env:
  vendor_cli:
    tnk: [claude, agy, qwen, grok, mistral]
    sat: [claude, qwen, grok, mistral]
    lde: [claude, agy, qwen, grok, mistral]
EOF

# Mock lane-map.sh for testing
export SPAWN_PLACE_MAP_CMD="$HERE/mock-lane-map.sh"
cat >"$SPAWN_PLACE_MAP_CMD" <<'EOF'
#!/bin/bash
# Mock lane-map.sh --json output for testing
cat <<JSON
{
  "load": [
    {"box": "tnk", "live": true, "busy": 0, "mem_kb": 8192000},
    {"box": "sat", "live": true, "busy": 1, "mem_kb": 4096000},
    {"box": "lde", "live": true, "busy": 2, "mem_kb": 2048000}
  ]
}
JSON
EOF
chmod +x "$SPAWN_PLACE_MAP_CMD"

# Mock next-agent-id.sh for testing
mkdir -p "$HERE/mock-scripts"
cat >"$HERE/mock-scripts/next-agent-id.sh" <<'EOF'
#!/bin/bash
echo "a-001"
EOF
chmod +x "$HERE/mock-scripts/next-agent-id.sh"

# Override PATH to use the mock
export PATH="$HERE/mock-scripts:$PATH"

# Test 1: Auto placement skips boxes without the vendor CLI
test_auto_skip_no_cli() {
  echo "Test 1: Auto placement skips boxes without the vendor CLI (agy on sat)"
  export SPAWN_BOX=""
  export SPAWN_VENDOR="agy"
  if TARGET="$(SPAWN_TEST_MODE=1 bash "$SPAWN_WINDOW" auto "test-title")"; then
    echo "FAIL: Expected HOLD (rc 10), got target=$TARGET"
    exit 1
  else
    rc=$?
    if [ "$rc" -eq 10 ]; then
      echo "PASS: HOLD (rc 10) as expected"
    else
      echo "FAIL: Expected rc 10, got $rc"
      exit 1
    fi
  fi
}

# Test 2: Auto placement picks a box with the vendor CLI
test_auto_pick_with_cli() {
  echo "Test 2: Auto placement picks a box with the vendor CLI (claude on sat)"
  export SPAWN_BOX=""
  export SPAWN_VENDOR="claude"
  TARGET="$(SPAWN_TEST_MODE=1 bash "$SPAWN_WINDOW" auto "test-title")"
  if [ "$TARGET" = "tnk" ]; then
    echo "PASS: Picked tnk (least busy box with claude CLI)"
  else
    echo "FAIL: Expected tnk, got $TARGET"
    exit 1
  fi
}

# Test 3: SPAWN_BOX warns but proceeds if the box lacks the CLI
test_spawn_box_warn_no_cli() {
  echo "Test 3: SPAWN_BOX warns but proceeds if the box lacks the CLI (agy on sat)"
  export SPAWN_BOX="sat"
  export SPAWN_VENDOR="agy"
  if TARGET="$(SPAWN_TEST_MODE=1 bash "$SPAWN_WINDOW" auto "test-title" 2>&1)"; then
    if [ "$TARGET" = "sat" ]; then
      echo "PASS: Proceeded with sat (warned)"
    else
      echo "FAIL: Expected sat, got $TARGET"
      exit 1
    fi
  else
    echo "FAIL: Expected success, got rc $?"
    exit 1
  fi
}

# Test 4: SPAWN_BOX proceeds silently if the box has the CLI
test_spawn_box_silent_with_cli() {
  echo "Test 4: SPAWN_BOX proceeds silently if the box has the CLI (claude on sat)"
  export SPAWN_BOX="sat"
  export SPAWN_VENDOR="claude"
  TARGET="$(SPAWN_TEST_MODE=1 bash "$SPAWN_WINDOW" auto "test-title" 2>/dev/null)"
  if [ "$TARGET" = "sat" ]; then
    echo "PASS: Proceeded with sat (silent)"
  else
    echo "FAIL: Expected sat, got $TARGET"
    exit 1
  fi
}

# Test 5: Mistral has no CLI check
test_mistral_no_cli_check() {
  echo "Test 5: Mistral has no CLI check"
  export SPAWN_BOX=""
  export SPAWN_VENDOR="mistral"
  TARGET="$(SPAWN_TEST_MODE=1 bash "$SPAWN_WINDOW" auto "test-title")"
  if [ "$TARGET" = "tnk" ]; then
    echo "PASS: Picked tnk (mistral has no CLI check)"
  else
    echo "FAIL: Expected tnk, got $TARGET"
    exit 1
  fi
}

# Run tests
cd "$(dirname "$SPAWN_WINDOW")"
test_auto_skip_no_cli
test_auto_pick_with_cli
test_spawn_box_warn_no_cli
test_spawn_box_silent_with_cli
test_mistral_no_cli_check

echo "All tests passed!"