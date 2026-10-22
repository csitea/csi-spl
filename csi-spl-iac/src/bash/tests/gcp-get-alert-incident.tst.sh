#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gcp_get_alert_incident (SPL-2887) shows ONE alert incident, named
#          by its policy and open minute: the policy, the resource, the
#          timeline; as the env's OWN project SA, read-only. Reuses the fixture
#          of gcp-list-alert-incidents.tst.sh (fixtures/alert-incidents).
#   1. Cloud SQL down opened 08:03: the incident (08:03 .. 08:04, peak 0, the
#      resource), the condition, the timeline with VIOLATES / ok per point;
#      the 07:00 run (too short for the 120s duration) is not shown
#   2. only the named policy is read, over OPENED - 2 h .. ALERT_UNTIL
#   3. every gcloud call carries --project and --account of the dev key, the
#      token rides a -K file only, read-only
#   4. a minute with no incident exits 4 and lists the ones that did open;
#      a missing or disabled policy exits 3 and reads no series
#   5. CONTROLS: a missing key and a bad OPENED are refused before gcloud;
#      the same fixture with duration 0s opens the incident at 08:01, not 08:03
# gcloud and curl are stubs on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-get-alert-incident.func.sh"
FIX="$TEST_DIR/fixtures/alert-incidents"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
require_action "$ACTION"

fails=0

mkdir -p "$T/home/.gcp/.o"
stub gcloud '
echo "${CLOUDSDK_CONFIG:-<unset>}|${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-<unset>}|$*" >>"$GC_CALLS"
case "$*" in
  *"policies list"*) cat "$GC_POLICIES" ;;
  *"print-access-token"*) echo "tok-SECRET-123" ;;
esac'
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
  : >"$T/calls.log"; : >"$T/curl.log"; rm -f "$T/curl.log.cfg"
  env -u ENV -u CLOUDSDK_CONFIG -u PROJ_PATH -u POLICY -u OPENED PATH="$T/bin:$PATH" GC_CALLS="$T/calls.log" CURL_CALLS="$T/curl.log" \
    GC_POLICIES="${GC_POLICIES:-$FIX/policies.json}" FIX="$FIX" ACTION="$ACTION" \
    PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh" HOME="$T/home" ORG=o APP=a ALERT_UNTIL=2026-10-22T12:00:00Z "$@" \
    bash -c 'source "$PIN"; do_log(){ echo "$*"; }; do_require_var(){ [[ -n "$2" ]] || exit 1; }
      do_gcp_log_identity(){ echo "identity $1 $2"; }
      source "$ACTION"; do_gcp_get_alert_incident' >"$T/out.log" 2>&1
}
SQL='o-a-dev Cloud SQL down'

# --- 1. the incident -----------------------------------------------------------------
run_action ENV=dev POLICY="$SQL" OPENED=2026-10-22T08:03Z; rc=$?
[[ $rc -eq 0 ]] && pass "Cloud SQL down 08:03: exit 0" || fail "rc=$rc $(cat "$T/out.log")"
grep -qx "incident: 2026-10-22T08:03Z .. 2026-10-22T08:04Z  peak=0  resource=database_id=p:db" "$T/out.log" \
  && pass "the incident: open, last, peak, resource" || fail "incident line: $(cat "$T/out.log")"
grep -q '^condition: db up below 1 for 120s: metric.type = "fixture.test/db_up".* COMPARISON_LT 1 for 120s (align 60s ALIGN_MIN)$' "$T/out.log" \
  && pass "the condition: filter, comparison, threshold, duration, aggregation" || fail "condition: $(cat "$T/out.log")"
tl=$(sed -n '/^== timeline/,$p' "$T/out.log" | tail -n +2 | tr -s ' ')
want="2026-10-22T08:00:00Z 1 ok
2026-10-22T08:01:00Z 0 VIOLATES
2026-10-22T08:02:00Z 0 VIOLATES
2026-10-22T08:03:00Z 0 VIOLATES
2026-10-22T08:04:00Z 0 VIOLATES
2026-10-22T08:05:00Z 1 ok"
[[ "$tl" == "$want" ]] && pass "the timeline: duration + 3 periods before .. 3 after, each point judged" || fail "timeline:
$tl"
! grep -q '07:00' "$T/out.log" && pass "the 07:00 run (shorter than the duration) is not shown" || fail "07:00 shown"

# --- 2. only that policy, the window --------------------------------------------------
nq=$(wc -l <"$T/curl.log")
[[ "$nq" -eq 1 ]] && grep -q 'fixture.test/db_up' "$T/curl.log.cfg" && ! grep -q 'five_xx' "$T/curl.log.cfg" \
  && pass "only the named policy's series are read" || fail "reads: $(cat "$T/curl.log.cfg")"
grep -q 'interval.startTime=2026-10-22T06:03:00Z --data-urlencode interval.endTime=2026-10-22T12:00:00Z' "$T/curl.log" \
  && pass "the window: OPENED - 2 h .. ALERT_UNTIL" || fail "window: $(cat "$T/curl.log")"

# --- 3. identity, token, read-only ----------------------------------------------------
got=$(cut -d'|' -f3 "$T/calls.log" | grep -c -- '--account=sa-dev@p-dev.iam.gserviceaccount.com')
[[ "$got" -eq 2 ]] && grep -q 'policies list --project=o-a-dev' "$T/calls.log" \
  && pass "both gcloud calls as the dev SA, the policies of the dev project" || fail "calls: $(cat "$T/calls.log")"
[[ "$(cut -d'|' -f2 "$T/calls.log" | sort -u)" == "$T/home/.gcp/.o/key-o-a-dev.json" ]] \
  && pass "the dev key is the credential override" || fail "override"
! grep -q 'tok-SECRET-123' "$T/curl.log" "$T/out.log" && grep -q 'Bearer tok-SECRET-123' "$T/curl.log.cfg" \
  && pass "the token rides a -K file, never a command line or the output" || fail "token leaked or missing"
! grep -qE '\b(create|update|delete)\b' "$T/calls.log" && pass "read-only: no create/update/delete" || fail "calls: $(cat "$T/calls.log")"

# --- 4. not found ---------------------------------------------------------------------
run_action ENV=dev POLICY="$SQL" OPENED=2026-10-22T08:02Z; rc=$?
[[ $rc -eq 4 ]] && grep -q '^no incident of o-a-dev Cloud SQL down opened at 2026-10-22T08:02Z' "$T/out.log" \
  && grep -q '^2026-10-22T08:03Z .. 2026-10-22T08:04Z  peak=0  database_id=p:db$' "$T/out.log" \
  && pass "another minute: exit 4, the incidents that did open are listed" || fail "wrong minute: rc=$rc $(cat "$T/out.log")"
for p in 'no such policy' 'o-a-dev disabled policy'; do
  run_action ENV=dev POLICY="$p" OPENED=2026-10-22T08:03Z; rc=$?
  [[ $rc -eq 3 && ! -s "$T/curl.log" ]] && pass "'$p': exit 3, no series read" || fail "'$p': rc=$rc $(cat "$T/out.log")"
done

# --- 5. controls ----------------------------------------------------------------------
run_action ENV=prd POLICY="$SQL" OPENED=2026-10-22T08:03Z; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'no SA key for prd' "$T/out.log" \
  && pass "CONTROL: no key -> refused, gcloud never called" || fail "no key: rc=$rc $(cat "$T/out.log")"
for bad in 'yesterday' '2026-10-22T08:03' '2026-13-40T99:99Z'; do
  run_action ENV=dev POLICY="$SQL" OPENED="$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "CONTROL: OPENED='$bad' refused, gcloud never called" || fail "OPENED='$bad': rc=$rc"
done
sed 's/"duration": "120s"/"duration": "0s"/' "$FIX/policies.json" >"$T/policies-0s.json"
GC_POLICIES="$T/policies-0s.json" run_action ENV=dev POLICY="$SQL" OPENED=2026-10-22T08:01Z; rc=$?
[[ $rc -eq 0 ]] && grep -q '^incident: 2026-10-22T08:01Z .. 2026-10-22T08:04Z' "$T/out.log" \
  && pass "CONTROL: duration 0s opens it at 08:01 (case 1's 08:03 is the duration rule)" || fail "duration control: rc=$rc $(cat "$T/out.log")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
