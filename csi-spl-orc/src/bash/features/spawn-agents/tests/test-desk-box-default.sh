#!/usr/bin/env bash
# test-desk-box-default.sh — specs/058: each machine of a fleet seats its OWN
# desk box id. The hub keeps one socket per (tenant, box id) and the last hello
# evicts the other (hub multimachine_test.go), so two machines that both
# default to box-desk knock each other offline.
#   1-3  spl_desk_box_default: box-desk with no config; box.env; the env wins
#   4-5  box-config.sh writes SPOOL_DESK_BOX and refuses a non-box id / box-wui
#   6    box-config.sh refuses a malformed SPOOL_AGENT_ID_RANGE
#   7    spool-agent.sh's seat plan names the configured box
#   8    no desk action or script keeps a literal box-desk default
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
ORC="$T_REPO/csi-spl-orc"
LIB="$ORC/lib/bash/funcs/spl-desk-box.func.sh"
BC="$T_SCRIPTS/box-config.sh"
export SPOOL_BOX_ENV="$SPOOL_ROOT/box.env"
mkdir -p "$SPOOL_ROOT"
res() { env -u SPOOL_DESK_BOX bash -c '. "$1"; spl_desk_box_default' _ "$LIB"; }

eq "1. no config -> box-desk (one machine unchanged)" box-desk "$(res)"
bash "$BC" SPOOL_DESK_BOX=box-desk-sat >/dev/null
eq "2. box.env names this machine's desk box" box-desk-sat "$(res)"
eq "3. the environment wins" box-x "$(SPOOL_DESK_BOX=box-x bash -c '. "$1"; spl_desk_box_default' _ "$LIB")"

rc=0; bash "$BC" SPOOL_DESK_BOX=Box_Desk >/dev/null 2>&1 || rc=$?
eq "4. box-config refuses a non-box id" 2 "$rc"
rc=0; bash "$BC" SPOOL_DESK_BOX=box-wui >/dev/null 2>&1 || rc=$?
eq "5. box-config refuses box-wui (the hub's own box)" 2 "$rc"
rc=0; bash "$BC" SPOOL_AGENT_ID_RANGE=lots >/dev/null 2>&1 || rc=$?
eq "6. box-config refuses a malformed id band" 2 "$rc"

out="$(env -u SPOOL_DESK_BOX bash "$T_SCRIPTS/spool-agent.sh" --dry-run --as CLE-58 --env dev claude 2>&1)"
has "7. spool-agent seats on the configured desk box" "DESK_BOX=box-desk-sat " "$out"

left="$(grep -rnE --include='*.sh' -e '[A-Z_]BOX:-box-desk\}|\{3:-box-desk\}|BOX="box-desk"' "$ORC/src/bash/run" "$ORC/src/bash/scripts" "$ORC/lib/bash/funcs" "$T_SCRIPTS" || true)"
eq "8. no literal box-desk default left" "" "$left"

t_done
