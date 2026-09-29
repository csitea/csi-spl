#!/usr/bin/env bash
# spawn-grok-task.sh — the grok adapter of spawn-chain-core.inc.sh (task mode;
# specs/048, SPL-1160). The core documents both modes.
#
# Usage: spawn-grok-task.sh <TITLE> <WORKDIR> <BRIEF_FILE>
set -uo pipefail
CHAIN_KIND=grok
_ch_core="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/spawn-chain-core.inc.sh"
# shellcheck source=spawn-chain-core.inc.sh
. "$_ch_core" || { echo "ERROR: cannot load $_ch_core" >&2; exec bash; }
task_main "$@"
