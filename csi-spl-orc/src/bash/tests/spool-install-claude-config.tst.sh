#!/usr/bin/env bash
# spec 069 Y4: the fleet CLAUDE.md + settings.json render step of spool-install;
# it: csi-spl-orc/src/bash/features/spool-install/tests/test-claude-config.sh.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/spool-install/tests/test-claude-config.sh"
