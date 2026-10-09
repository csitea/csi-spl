#!/usr/bin/env bash
# The kill-guard suite (spool-install Y11), run here so the orc CI job gates
# it: csi-spl-orc/src/bash/features/spool-install/tests/test-y11-kill-guard.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y11-kill-guard.sh"
