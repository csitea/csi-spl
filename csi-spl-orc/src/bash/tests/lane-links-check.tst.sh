#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: C95, do_spl_lane_links_check (spec 153 3.20, SPL-4797; owner HUM-10, t1
#          0c2d08a2 msg 08ac07da: "the links must be enforced , by even some
#          kind of dispatcher , cron scheduled work to check them"). The hub is
#          a stub with the contract of `spool lane` (list).
#   1. the live lane rows with no topic or no issue are named, one per line;
#      a role seat (c-002, or a "role c-NNN (rotation" scope), a legacy id, a
#      done row, a complete row, an `unknown` value and a row older than
#      LINKS_CHECK_MAX_AGE_H are not; exit 3
#   2. DELIVER=1 sends ONE note to the lease holder (<ID>@<box>) on task
#      lane-links-check naming each lane; the same list again within
#      LINKS_CHECK_RESEND_MIN is not sent; a changed list is
#   3. a lease held on another machine: logged, nothing sent
#   4. every row complete: OK, exit 0, nothing sent
#   5. unanswered-sweep-cron.sh (a minute cron) runs it DELIVER=1 once per
#      LINKS_CHECK_EVERY_MIN, beside the sweep
#   RED CONTROL (master 022055fe6): the action did not exist.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/spool/dispatch"

cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
cat "$HUB_FILE"
STUB
cat >"$T/bin/send" <<'STUB'
#!/usr/bin/env bash
a="$*"; printf '%s\n' "${a//$'\n'/ }" >>"$SEND_LOG"  # one line per send
STUB
chmod +x "$T/bin/hub" "$T/bin/send"

U1=1a2b3c4d-1111-4222-8333-444455556666
row() {  # ID BOX TOPIC ISSUE STATE AGE_S [SCOPE]
  printf '{"agent_id":"%s","agent_box":"%s","branch":"%s-b","scope":"%s","topic":"%s","issue_key":"%s","state":"%s","age_s":%s}' \
    "$1" "$2" "$1" "${7:-scope $1}" "$3" "$4" "$5" "$6"
}
lanes() { printf '{"fleet":"main","lanes":[%s]}\n' "$(IFS=,; echo "$*")" >"$T/hub.json"; }
lanes "$(row c-601 sat "" SPL-1 live 60)" "$(row c-602 box-b "$U1" "" live 60)" "$(row c-603 sat "" "" live 60)" \
  "$(row c-002 sat "" "" live 60)" "$(row c-604 sat "" "" live 60 'role c-604 (rotation r1)')" \
  "$(row CLE-77922 box-b "" "" live 60)" "$(row c-605 sat "" "" "done" 60)" "$(row c-606 sat "$U1" SPL-2 live 60)" \
  "$(row c-607 sat unknown unknown live 60)" "$(row c-608 sat "" "" live 90000)"

run() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" LANE_FLEET=main LANE_BOX=sat LEASE_MACHINE=sat \
    LANE_HUB_CMD="$T/bin/hub" HUB_FILE="$T/hub.json" LINKS_CHECK_SEND="$T/bin/send" SEND_LOG="$T/send.log" \
    LINKS_CHECK_FROM=c-001 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-links-check.func.sh"
    do_spl_lane_links_check'
}

# 1. the list
out="$(run)"; rc=$?
want="c-601@sat discussion=MISSING issue=SPL-1 branch=c-601-b
c-602@box-b discussion=$U1 issue=MISSING branch=c-602-b
c-603@sat discussion=MISSING issue=MISSING branch=c-603-b"
[[ $rc -eq 3 && "$(grep -E '^c-' <<<"$out")" == "$want" && "$out" == *"WARN 3 live lane(s) of fleet main lack a discussion or an issue"* ]] &&
  pass "1. the three live lanes missing a discussion or an issue are named, exit 3" || fail "1. list (rc=$rc): $out"
bad=""; for id in c-002 c-604 CLE-77922 c-605 c-606 c-607 c-608; do [[ "$out" == *"$id@"* ]] && bad+=" $id"; done
[[ -z "$bad" ]] && pass "1. a role seat, a rotation seat, a legacy id, a done row, a complete row, 'unknown' and a row a day old are left out" ||
  fail "1. rows named:$bad"
[[ ! -e "$T/send.log" ]] && pass "1. without DELIVER nothing is sent" || fail "1. sent: $(cat "$T/send.log")"

# 2. DELIVER=1 to the lease holder
printf 'c-002@sat %s\n' "$(date +%s)" >"$T/spool/dispatch/lease"
out="$(run DELIVER=1)"; rc=$?
s="$(cat "$T/send.log" 2>/dev/null)"
[[ $rc -eq 0 && "$(grep -c . <<<"$s")" -eq 1 && "$s" == "--from c-001 --to c-002@sat --kind note --task lane-links-check --body **LANES WITHOUT LINKS: 3 live lane(s)"* &&
   "$s" == *"- c-601@sat discussion=MISSING issue=SPL-1"* && "$s" == *"- c-603@sat discussion=MISSING issue=MISSING"* ]] &&
  pass "2. DELIVER=1: one note to the lease holder c-002@sat on task lane-links-check, each lane named" || fail "2. deliver (rc=$rc): $out | $s"
out="$(run DELIVER=1)"; rc=$?
[[ $rc -eq 0 && "$(grep -c . "$T/send.log")" -eq 1 && "$out" == *"not sent again"* ]] &&
  pass "2. the same list within LINKS_CHECK_RESEND_MIN is not sent again" || fail "2. resend (rc=$rc): $out | $(cat "$T/send.log")"
out="$(run DELIVER=1 LINKS_CHECK_RESEND_MIN=0)"
[[ "$(grep -c . "$T/send.log")" -eq 2 ]] && pass "2. control: past LINKS_CHECK_RESEND_MIN it is sent again" || fail "2. resend control: $out"
lanes "$(row c-601 sat "" SPL-1 live 60)"
out="$(run DELIVER=1)"
[[ "$(grep -c . "$T/send.log")" -eq 3 && "$(tail -1 "$T/send.log")" == *"1 live lane(s)"* ]] &&
  pass "2. a changed list is sent at once" || fail "2. changed: $out | $(cat "$T/send.log")"

# 3. the lease on another machine
: >"$T/send.log"; rm -f "$T/spool/dispatch/lane-links-check.last"
printf 'c-002@box-b %s\n' "$(date +%s)" >"$T/spool/dispatch/lease"
out="$(run DELIVER=1)"; rc=$?
[[ $rc -eq 0 && ! -s "$T/send.log" && "$out" == *"is on another machine"* ]] &&
  pass "3. a lease held on another machine: logged, nothing sent (that machine's check sends)" || fail "3. remote (rc=$rc): $out | $(cat "$T/send.log")"

# 4. all complete
lanes "$(row c-606 sat "$U1" SPL-2 live 60)" "$(row c-607 sat unknown unknown live 60)"
out="$(run DELIVER=1)"; rc=$?
[[ $rc -eq 0 && ! -s "$T/send.log" && "$out" == *"OK every live lane of fleet main names its discussion and its issue"* ]] &&
  pass "4. every row complete: OK, nothing sent" || fail "4. complete (rc=$rc): $out"

# 5. the minute cron runs the check once per LINKS_CHECK_EVERY_MIN
O="$T/tree/csi-spl-orc"; mkdir -p "$O/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/unanswered-sweep-cron.sh" "$O/src/bash/scripts/"
printf '#!/usr/bin/env bash\necho "$2 DELIVER=${DELIVER:-} DRY_RUN=${DRY_RUN:-}" >>"$RUN_LOG"\n' >"$O/run"; chmod +x "$O/run"
cron() { env SPOOL_ROOT="$T/spool" SWEEP_CRON_TOOLS=bash RUN_LOG="$T/run.log" "$@" bash "$O/src/bash/scripts/unanswered-sweep-cron.sh" >>"$T/cron.out" 2>&1; }
cron; rc1=$?; cron; rc2=$?
[[ $rc1 -eq 0 && $rc2 -eq 0 && "$(grep -c '^do_spl_lane_links_check DELIVER=1' "$T/run.log")" -eq 1 && "$(grep -c '^do_spl_unanswered_sweep' "$T/run.log")" -eq 2 ]] &&
  pass "5. two minute ticks: the sweep runs twice, the links check once (DELIVER=1)" || fail "5. cron (rc $rc1 $rc2): $(cat "$T/run.log") $(cat "$T/cron.out")"
cron LINKS_CHECK_EVERY_MIN=0
[[ "$(grep -c '^do_spl_lane_links_check' "$T/run.log")" -eq 2 ]] && pass "5. control: LINKS_CHECK_EVERY_MIN=0 runs it on the next tick" ||
  fail "5. cron control: $(cat "$T/run.log")"

echo
if [ "$fails" -eq 0 ]; then echo "lane-links-check: all passed"; exit 0; fi
echo "lane-links-check: $fails FAILED"; exit 1
