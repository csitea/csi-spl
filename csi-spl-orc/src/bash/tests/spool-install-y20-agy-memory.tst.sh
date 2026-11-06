#!/usr/bin/env bash
# spool-install step Y20 (SPL-4911): agy loads the claude memory index; the feature test
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y20-agy-memory.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y20-agy-memory.sh"
