#!/usr/bin/env bash
# spool-install hands the engine-rendered skills over (specs/069 Y5), run here
# so the orc CI job gates it: features/spool-install/tests/test-y5-adopt.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-y5-adopt.sh"
