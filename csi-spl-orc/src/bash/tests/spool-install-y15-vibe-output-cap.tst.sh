#!/usr/bin/env bash
# The vibe output cap suite (spool-install Y15, SPL-2217), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y15-vibe-output-cap.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y15-vibe-output-cap.sh"
