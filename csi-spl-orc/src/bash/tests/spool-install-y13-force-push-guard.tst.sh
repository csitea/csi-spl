#!/usr/bin/env bash
# The force-push block suite (spool-install Y13), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y13-force-push-guard.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y13-force-push-guard.sh"
