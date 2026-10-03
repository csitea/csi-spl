#!/usr/bin/env bash
# The box-sessions save/boot suite (spec 069 Y2), run here so the orc CI job
# gates it: csi-spl-orc/src/bash/features/box-sessions/tests/test-box-sessions.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/box-sessions/tests/test-box-sessions.sh"
