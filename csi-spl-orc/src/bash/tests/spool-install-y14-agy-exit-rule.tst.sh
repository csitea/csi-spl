#!/usr/bin/env bash
# The agy exit-after-ACCEPTED rule suite (spool-install Y14), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y14-agy-exit-rule.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y14-agy-exit-rule.sh"
