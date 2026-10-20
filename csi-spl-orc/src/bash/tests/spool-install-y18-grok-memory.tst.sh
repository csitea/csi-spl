#!/usr/bin/env bash
# spool-install step Y18 (SPL-2738): grok loads the claude memory index; the feature test
# gates it: csi-spl-orc/src/bash/features/spool-install/tests/test-y18-grok-memory.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y18-grok-memory.sh"
