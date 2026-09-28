#!/usr/bin/env bash
# The agent harness parity check (specs/048), run here so the orc CI job gates
# it: csi-spl-orc/src/bash/features/spawn-agents/tests/test-harness-parity.sh.
# CI has no copy of the private frozen reference, so its part 4 is skipped.
exec env -u HARNESS_REF_DIR bash "$(cd "$(dirname "$0")" && pwd)/../features/spawn-agents/tests/test-harness-parity.sh"
