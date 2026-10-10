#!/usr/bin/env bash
# The vibe push guard suite (spool-install Y12), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y12-vibe-push-guard.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y12-vibe-push-guard.sh"
