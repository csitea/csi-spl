#!/usr/bin/env bash
# spec 110: the fleet ~/.vibe/AGENTS.md render step of spool-install;
# it: csi-spl-orc/src/bash/features/spool-install/tests/test-vibe-agents.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-vibe-agents.sh"
