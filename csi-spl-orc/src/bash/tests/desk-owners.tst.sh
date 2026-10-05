#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_owners (specs/017 FR-SEC-031). No cloud call, no tmux.
#   1. without DESK_OWNERS it lists mirror-to / operator / owners, writes nothing
#   2. the dry run writes nothing; DRY_RUN=0 writes <desk>/owners 0600, deduped
#   3. a non-human id is refused and the file is left as it was
#   4. the notifier reads the written file: an owner is verbatim, another
#      human is framed (CONTROL: the same id before the write is framed)
# The fixture desk is box-desk, the id spl_desk_box_default returns when
# SPOOL_TEST=1 and SPOOL_BOX_ENV is empty (the live box.env is not read).
# in_orc also sets SPOOL_DESK_BOX=box-desk, so an outer SPOOL_DESK_BOX cannot
# move the seat. The notifier seat is c-007 (specs/061), not a legacy id.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/prd" ENV=prd \
    SPOOL_TEST=1 SPOOL_BOX_ENV= SPOOL_DESK_BOX=box-desk "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_desk_owners'
}

SEAT="$T/state/prd/desk/t1/box-desk"
mkdir -p "$SEAT/spool/c-007/inbox"
echo HUM-10 >"$SEAT/mirror-to"; echo HUM-10 >"$SEAT/operator"

# 1. list only
in_orc TENANT_ID=t1 >"$T/o" 2>&1
[[ $? -eq 0 && ! -e "$SEAT/owners" ]] && grep -q 'mirror-to: HUM-10' "$T/o" && grep -q 'owners: (none)' "$T/o" &&
  pass "1. without DESK_OWNERS it lists the sources and writes nothing" || fail "1. list: $(cat "$T/o")"

# notifier view of HUM-5 BEFORE the write (the control for 4)
frame() {  # FROM
  SPOOL_ROOT="$SEAT/spool" bash -c '
    F="$1"; . "$F/lib/spool-notify.inc.sh"
    printf "{\"to\":\"c-007\"}" >"$SPOOL_ROOT/c-007/inbox/20260101T000000Z--$2--x-aaaaaaaa.json"
    spool_notify_frame P c-007 "$2" T-1 aaaaaaaa-x; printf "%s" "$P"' _ "$PROJ_ROOT/src/bash/features/spawn-agents" "$1"
}
before="$(frame HUM-5)"

# 2. dry run, then the write
in_orc TENANT_ID=t1 DESK_OWNERS='HUM-5,HUM-10 HUM-5' >"$T/o" 2>&1
[[ $? -eq 0 && ! -e "$SEAT/owners" ]] && grep -q 'DRY_RUN would write' "$T/o" &&
  pass "2. the dry run writes nothing" || fail "2. dry run: $(cat "$T/o")"
in_orc TENANT_ID=t1 DESK_OWNERS='HUM-5,HUM-10 HUM-5' DRY_RUN=0 >"$T/o" 2>&1
[[ $? -eq 0 && "$(cat "$SEAT/owners")" == "HUM-5 HUM-10" ]] &&
  pass "2. DRY_RUN=0 writes the ids once each" || fail "2. write: $(cat "$T/o") / $(cat "$SEAT/owners" 2>&1)"
[[ "$(stat -c %a "$SEAT/owners")" == 600 ]] && pass "2. owners is 0600" || fail "2. mode $(stat -c %a "$SEAT/owners")"

# 3. refusals
in_orc TENANT_ID=t1 DESK_OWNERS='HUM-5 c-009' DRY_RUN=0 >"$T/o" 2>&1
[[ $? -ne 0 && "$(cat "$SEAT/owners")" == "HUM-5 HUM-10" ]] && grep -q "not a human id" "$T/o" &&
  pass "3. an agent id is refused and the file is unchanged" || fail "3. refusal: $(cat "$T/o")"
in_orc TENANT_ID=t9 >"$T/o" 2>&1
[[ $? -ne 0 ]] && grep -q "no desk" "$T/o" && pass "3. a tenant with no desk is refused" || fail "3. no desk: $(cat "$T/o")"

# 4. the notifier reads it
[[ "$before" == "[DM from HUM-5 - not this desk's owner"* ]] &&
  pass "4. CONTROL: before the write HUM-5 is framed as not the owner" || fail "4. before: '$before'"
after="$(frame HUM-5)"
[[ -z "$after" ]] && pass "4. after the write HUM-5's DM is verbatim" || fail "4. after: '$after'"
other="$(frame HUM-1)"
[[ "$other" == "[DM from HUM-1 - not this desk's owner"* ]] && pass "4. another human is still framed" || fail "4. other: '$other'"

(( fails == 0 )) && echo "=== all desk-owners.tst.sh assertions" || { echo "FAIL: $fails assertion(s)"; exit 1; }
