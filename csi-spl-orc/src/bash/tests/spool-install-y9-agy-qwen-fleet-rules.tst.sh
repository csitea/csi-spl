#!/usr/bin/env bash
# The y9 agy + qwen fleet-rule parts suite (spool-install, SPL-6533), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-agy-qwen-fleet-rules.sh"
