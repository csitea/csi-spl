#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_list_alert_incidents rebuilds the alert incidents of a window
#          by replaying each enabled policy's threshold conditions over their
#          timeSeries, as each env's OWN project SA, read-only.
#   1. ENV=dev on the fixture (fixtures/alert-incidents): the table per alert
#      type (count, first, last, series, resource) and one line per incident:
#      two runs on one series + one on a second PAGE = 3; a LT condition whose
#      run is shorter than its duration is NOT an incident, the longer one
#      opens <duration> after its first point; no data = SERIES 0; a disabled
#      policy is never read; an absence condition is named "not replayed"
#   2. every gcloud call carries --project and --account of the dev key, the key
#      is the credential override, a private CLOUDSDK_CONFIG is gone afterwards,
#      ~/.config/gcloud is never created; the token never reaches a command line
#   3. the window: SINCE=24h + ALERT_UNTIL -> interval start/end on every read
#   4. read-only: no create/update/delete call
#   5. CONTROLS: a bad SINCE and a missing key are refused before gcloud runs;
#      the same fixture with the duration dropped to 0s counts the short LT run
#      too (so case 1's "not an incident" is the duration rule, not a miss)
#   6. the policy combiner (fixtures policies-and.json, and_*): an AND policy
#      whose two conditions breach at different times = 0 incidents; overlapping
#      = 1 incident under the policy over the overlap; the same two conditions
#      under OR = one per condition; another combiner is named on stderr and
#      listed as OR
# gcloud and curl are stubs on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-list-alert-incidents.func.sh"
FIX="$TEST_DIR/fixtures/alert-incidents"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
require_action "$ACTION"

fails=0

mkdir -p "$T/home/.gcp/.o"
stub gcloud '
echo "${CLOUDSDK_CONFIG:-<unset>}|${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-<unset>}|$*" >>"$GC_CALLS"
[[ -d "$(dirname "${CLOUDSDK_CONFIG:-/nonexistent/x}")" ]] && echo seen >>"$GC_CALLS.cfg"
case "$*" in
  *"policies list"*) cat "$GC_POLICIES" ;;
  *"print-access-token"*) echo "tok-SECRET-123" ;;
esac'
# curl: reads its -K files, answers the fixture page of the metric in the filter
stub curl '
echo "$*" >>"$CURL_CALLS"
cfgs="" page=0 prev=""
for a in "$@"; do
  [[ "$prev" == "-K" ]] && cfgs+=$(cat "$a")$'"'"'\n'"'"'
  [[ "$a" == pageToken=* ]] && page=1
  prev="$a"
done
echo "$cfgs" >>"$CURL_CALLS.cfg"
m=""; [[ "$cfgs" =~ fixture\.test/([a-z_0-9]+) ]] && m="${BASH_REMATCH[1]}"
f="$FIX/$m.p$page.json"
[[ -f "$f" ]] && cat "$f" || echo "{}"'
printf '{"client_email":"sa-dev@p-dev.iam.gserviceaccount.com","project_id":"o-a-dev"}\n' >"$T/home/.gcp/.o/key-o-a-dev.json"

# run_action <env assignments...> -> rc; output in $T/out.log
run_action() {
  : >"$T/calls.log"; : >"$T/curl.log"; rm -f "$T/calls.log.cfg" "$T/curl.log.cfg"
  env -u ENV -u CLOUDSDK_CONFIG -u PROJ_PATH PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" CURL_CALLS="$T/curl.log" \
    GC_POLICIES="${GC_POLICIES:-$FIX/policies.json}" FIX="$FIX" ACTION="$ACTION" \
    PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh" HOME="$T/home" ORG=o APP=a "$@" \
    bash -c 'source "$PIN"; do_log(){ echo "$*"; }; do_require_var(){ [[ -n "$2" ]] || exit 1; }
      do_gcp_log_identity(){ echo "identity $1 $2"; }
      source "$ACTION"; do_gcp_list_alert_incidents' >"$T/out.log" 2>&1
}
row() { grep -E "^o-a-dev $1 " "$T/out.log" | tr -s ' '; }

# --- 1. the replay ----------------------------------------------------------------
run_action ENV=dev SINCE=24h ALERT_UNTIL=2026-10-22T12:00:00Z; rc=$?
[[ $rc -eq 0 ]] && pass "ENV=dev: exit 0" || fail "ENV=dev: rc=$rc $(cat "$T/out.log")"
r=$(row 'hub 5xx rate')
[[ "$r" == "o-a-dev hub 5xx rate 3 2026-10-22T09:50Z 2026-10-22T11:00Z 2 revision_name=hub-dev-00041 revision_name=hub-dev-00042" ]] \
  && pass "5xx: two runs on one series + one on page 2 = 3, both revisions" || fail "5xx row: '$r'"
r=$(row 'Cloud SQL down')
[[ "$r" == "o-a-dev Cloud SQL down 1 2026-10-22T08:03Z 2026-10-22T08:04Z 1 database_id=p:db" ]] \
  && pass "LT 120s: the 60s run is no incident; the 180s one opens 120s after its first point" || fail "sql row: '$r'"
r=$(row 'hub 429 streak')
[[ "$r" == "o-a-dev hub 429 streak 0 - - 0 -" ]] && pass "no data: count 0 with SERIES 0" || fail "429 row: '$r'"
grep -q 'heartbeat absent.*not replayed: conditionAbsent' "$T/out.log" \
  && pass "an absence condition is named, not silently dropped" || fail "absent row missing: $(cat "$T/out.log")"
! grep -q 'disabled' "$T/out.log" && ! grep -q 'fixture.test/disabled' "$T/curl.log.cfg" \
  && pass "a disabled policy is never read" || fail "disabled policy was read"
n=$(grep -cE '^2026-10-22T[0-9:]+Z \.\. ' "$T/out.log")
[[ "$n" -eq 4 ]] && grep -q '^2026-10-22T09:50Z .. 2026-10-22T09:55Z  o-a-dev hub 5xx rate .*peak=9  revision_name=hub-dev-00041' "$T/out.log" \
  && pass "one line per incident (4), with its peak" || fail "incident lines: n=$n $(cat "$T/out.log")"

# --- 2. identity, config, token -----------------------------------------------------
got=$(cut -d'|' -f3 "$T/calls.log" | grep -c -- '--account=sa-dev@p-dev.iam.gserviceaccount.com')
pl=$(grep -c 'policies list --project=o-a-dev --account=sa-dev@p-dev.iam.gserviceaccount.com' "$T/calls.log")
[[ "$got" -eq 2 && "$pl" -eq 1 ]] && pass "both gcloud calls as the dev SA, the policies on the dev project" || fail "calls: $(cat "$T/calls.log")"
ovr=$(cut -d'|' -f2 "$T/calls.log" | sort -u)
[[ "$ovr" == "$T/home/.gcp/.o/key-o-a-dev.json" ]] && pass "the dev key is the credential (override, nothing activated)" || fail "override='$ovr'"
cfg=$(cut -d'|' -f1 "$T/calls.log" | sort -u)
[[ "$cfg" != "<unset>" && -s "$T/calls.log.cfg" && ! -e "$(dirname "$cfg")" ]] \
  && pass "a private CLOUDSDK_CONFIG, removed afterwards" || fail "config dir: '$cfg'"
[[ ! -e "$T/home/.config/gcloud" ]] && pass "the shared ~/.config/gcloud is never created" || fail "HOME/.config/gcloud written"
! grep -q 'tok-SECRET-123' "$T/curl.log" "$T/out.log" && grep -q 'Bearer tok-SECRET-123' "$T/curl.log.cfg" \
  && pass "the token rides a -K file, never a command line or the output" || fail "token leaked or missing"

# --- 3. the window -------------------------------------------------------------------
nq=$(wc -l <"$T/curl.log")
nw=$(grep -c 'interval.startTime=2026-10-21T12:00:00Z --data-urlencode interval.endTime=2026-10-22T12:00:00Z' "$T/curl.log")
[[ "$nq" -eq 4 && "$nw" -eq 4 ]] && pass "SINCE=24h: 3 conditions + 1 next page, each read over the 24 h window" || fail "reads: nq=$nq nw=$nw"

# --- 4. read-only --------------------------------------------------------------------
! grep -qE '\b(create|update|delete)\b' "$T/calls.log" && pass "read-only: no create/update/delete" || fail "calls: $(cat "$T/calls.log")"

# --- 5. controls ---------------------------------------------------------------------
run_action ENV=dev SINCE=yesterday; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "CONTROL: a bad SINCE is refused, gcloud never called" || fail "bad SINCE: rc=$rc"
run_action ENV=stg; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "CONTROL: no key -> refused, gcloud never called" || fail "no key: rc=$rc"
sed 's/"duration": "120s"/"duration": "0s"/' "$FIX/policies.json" >"$T/policies-0s.json"
GC_POLICIES="$T/policies-0s.json" run_action ENV=dev SINCE=24h ALERT_UNTIL=2026-10-22T12:00:00Z
r=$(row 'Cloud SQL down')
[[ "$r" == "o-a-dev Cloud SQL down 2 2026-10-22T07:00Z 2026-10-22T08:04Z 1 database_id=p:db" ]] \
  && pass "CONTROL: duration 0s counts the short run too" || fail "duration control: '$r'"

# --- 6. the combiner -------------------------------------------------------------------
GC_POLICIES="$FIX/policies-and.json" run_action ENV=dev SINCE=24h ALERT_UNTIL=2026-10-22T12:00:00Z; rc=$?
[[ $rc -eq 0 ]] && pass "combiner fixture: exit 0" || fail "combiner fixture: rc=$rc $(cat "$T/out.log")"
r=$(row 'and apart')
[[ "$r" == "o-a-dev and apart 0 - - 2 -" ]] \
  && pass "AND, conditions breach at different times: 0 incidents" || fail "AND apart row: '$r'"
r=$(row 'and overlap')
[[ "$r" == "o-a-dev and overlap 1 2026-10-22T10:05Z 2026-10-22T10:10Z 2 revision_name=hub-dev-00050" ]] \
  && grep -q '^2026-10-22T10:05Z .. 2026-10-22T10:10Z  o-a-dev and overlap .*peak=2  revision_name=hub-dev-00050$' "$T/out.log" \
  && pass "AND, overlapping: 1 incident over the overlap 10:05..10:10" || fail "AND overlap row: '$r' $(cat "$T/out.log")"
r=$(row 'or two')
[[ "$r" == "o-a-dev or two 2 2026-10-22T10:00Z 2026-10-22T11:05Z 2 revision_name=hub-dev-00050" ]] \
  && pass "OR: the same two conditions list one incident each" || fail "OR row: '$r'"
r=$(row 'odd combiner')
[[ "$r" == "o-a-dev odd combiner 2 2026-10-22T10:00Z 2026-10-22T11:05Z 2 revision_name=hub-dev-00050" ]] \
  && grep -q '^WARN o-a-dev odd combiner: combiner AND_WITH_MATCHING_RESOURCE is not replayed' "$T/out.log" \
  && pass "an unknown combiner is named and listed per condition" || fail "odd combiner: '$r' $(cat "$T/out.log")"
n=$(grep -cE '^2026-10-22T[0-9:]+Z \.\. ' "$T/out.log")
[[ "$n" -eq 5 ]] && pass "combiner fixture: 5 incident lines (0 + 1 + 2 + 2)" || fail "incident lines: n=$n"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
