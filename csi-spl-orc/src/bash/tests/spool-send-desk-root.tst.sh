#!/usr/bin/env bash
# spool-send.sh refuses a lane's send on a workspace desk's spool root
# (SPL-3959): c-189's result 8458b482 (2026-10-27) was written into
# <cloud>/prd/desk/<tenant>/tnk/spool/c-423/inbox, the lane it was for reads
# the fleet root, and nothing read it. On a desk-shaped root
# (.../desk/<tenant>/<box>/spool) a --from that is not one of the desk's seats
# is refused, exit 9, nothing written; the same send on the fleet-shaped root
# is delivered; the desk's own seats (a role seat, the id a desk alias links
# to) still send there. Hermetic: own roots, no hub, no poke.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../features/spawn-agents/tests/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
FLEET="$SPOOL_ROOT"
DESK="$T_TMP/cloud/prd/desk/acme/tnk/spool"
for r in "$FLEET" "$DESK"; do
  mkdir -p "$r/c-423/inbox"
  printf 'c-423\tclaude\t%%0\t/x\t20260101T000000Z\n' >>"$r/registry.tsv"
done
jsons() { find "$1" -name '*.json' 2>/dev/null | wc -l; }
send() {  # ROOT FROM
  SPOOL_ROOT="$1" bash "$SS" --from "$2" --to c-423 --kind result --body "the result" --no-poke
}

# ---- red control: a lane on a desk root -------------------------------------
err="$(send "$DESK" c-189 2>&1 >/dev/null)"; rc=$?
eq "lane c-189 on a desk root: refused, exit 9" 9 "$rc"
has "…the line names the root" "$DESK" "$err"
has "…and says nothing was sent" "Nothing was sent" "$err"
has "…and the issue" "SPL-3959" "$err"
eq "…nothing written under the desk root" 0 "$(jsons "$DESK")"
send "$DESK/" c-189 >/dev/null 2>&1
eq "…the root with a trailing slash: refused too, exit 9" 9 "$?"

# ---- the same send on the fleet root is delivered ---------------------------
send "$FLEET" c-189 >/dev/null 2>&1; rc=$?
eq "lane c-189 on the fleet root: sent, exit 0" 0 "$rc"
eq "…delivered into c-423's fleet inbox" 1 "$(find "$FLEET/c-423/inbox" -name '*.json' | wc -l)"

# ---- the desk's own seats still send on it -----------------------------------
ln -s c-684 "$DESK/RSP-01"
ln -s c-189 "$DESK/c-777"
send "$DESK" c-001 >/dev/null 2>&1
eq "role seat c-001 on its desk root: sent, exit 0" 0 "$?"
send "$DESK" c-684 >/dev/null 2>&1
eq "c-684, the id desk alias RSP-01 links to: sent, exit 0" 0 "$?"
eq "…both delivered into the desk inbox" 2 "$(find "$DESK/c-423/inbox" -name '*.json' | wc -l)"
send "$DESK" c-189 >/dev/null 2>&1
eq "a lane-shaped link (c-777 -> c-189) seats nobody: refused, exit 9" 9 "$?"

# ---- not a desk root: a look-alike path is not refused ----------------------
LOOK="$T_TMP/desk/acme/spool"
mkdir -p "$LOOK/c-423/inbox"
printf 'c-423\tclaude\t%%0\t/x\t20260101T000000Z\n' >>"$LOOK/registry.tsv"
send "$LOOK" c-189 >/dev/null 2>&1
eq "a root with no <tenant>/<box> under desk/: sent, exit 0" 0 "$?"

t_done
