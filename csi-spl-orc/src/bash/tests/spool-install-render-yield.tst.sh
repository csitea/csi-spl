#!/usr/bin/env bash
# render-yield.sh's hermetic suite, run here so the orc CI job gates it:
# csi-spl-orc/src/bash/features/spool-install/tests/test-render-yield.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-render-yield.sh"
