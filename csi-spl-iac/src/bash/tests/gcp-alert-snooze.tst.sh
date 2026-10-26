#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: an owner-approved 040 apply snoozes the error_logs and sql_down
#          alert policies (SPL-3457, alerts fix round row 03 part A,
#          csi-spl-doc/doc/md/planned-apply-alert-snooze.md).
#   1. `make -n do-provision ENV=dev STEP=040-cloud-sql-postgres` names
#      do_gcp_alert_snooze start BEFORE the apply (do_provision) and end
#      AFTER it
#   2. CONTROL: STEP=070-gcp-monitoring names no snooze
#   3. DRY_RUN unset: no `gcloud ... snoozes create` (stub log has none), the
#      create it would make is printed; every gcloud call as the dev SA
#   4. DRY_RUN=0 start: one create over both policies, window now..+60 min,
#      its name kept in the state file
#   5. DRY_RUN=0 end: the kept snooze ends 15 min from now, state file gone
#   6. end with no state file: nothing to end, rc 0, no gcloud update
#   7. a policy that is not there -> refused, no create
#   8. create refused (no monitoring.snoozes.create) -> non-zero, reported
#   9. SNOOZE_CMD / DRY_RUN outside their values -> refused, no gcloud call
#  10. CONTROL: no key -> refused, no monitoring call at all
# gcloud is a stub on PATH. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gcp-alert-snooze.func.sh"
ORC="$APP_ROOT/csi-spl-orc"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

# --- 1. + 2. the make plan --------------------------------------------------------
plan() { make -s -n -C "$ORC" do-provision ENV=dev STEP="$1" 2>&1; }
p040="$(plan 040-cloud-sql-postgres)"
ln_start=$(grep -n -m1 'SNOOZE_CMD=start.*do_gcp_alert_snooze' <<<"$p040" | cut -d: -f1)
ln_apply=$(grep -n -m1 'run -a do_provision' <<<"$p040" | cut -d: -f1)
ln_end=$(grep -n -m1 'SNOOZE_CMD=end.*do_gcp_alert_snooze' <<<"$p040" | cut -d: -f1)
[[ -n "$ln_start" && -n "$ln_apply" && "$ln_start" -lt "$ln_apply" ]] \
  && pass "1. 040 plan starts do_gcp_alert_snooze before the apply" || fail "1. 040 start: start=${ln_start:-none} apply=${ln_apply:-none}"
[[ -n "$ln_end" && -n "$ln_apply" && "$ln_end" -gt "$ln_apply" ]] \
  && pass "1. 040 plan ends the snooze after the apply" || fail "1. 040 end: end=${ln_end:-none} apply=${ln_apply:-none}"
p070="$(plan 070-gcp-monitoring)"
grep -q 'run -a do_provision' <<<"$p070" && ! grep -q -i snooze <<<"$p070" \
  && pass "2. CONTROL: 070 plan applies and names no snooze" || fail "2. 070: $p070"

command -v yq >/dev/null || { echo "SKIP: no yq"; exit "$((fails > 0))"; }
command -v jq >/dev/null || { echo "SKIP: no jq"; exit "$((fails > 0))"; }
require_action "$ACTION"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# stub gcloud: logs "<argv>"; a policy list answers one name per display name
# unless STUB_NO_POLICY matches it; create prints a snooze name unless
# STUB_CREATE_DENY=1
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "monitoring policies list"*)
    f="$(arg --filter "$@")"
    [[ -n "${STUB_NO_POLICY:-}" && "$f" == *"$STUB_NO_POLICY"* ]] && exit 0
    [[ "$f" == *"error log rate"* ]] && echo projects/csi-spl-dev/alertPolicies/111
    [[ "$f" == *"Cloud SQL down"* ]] && echo projects/csi-spl-dev/alertPolicies/222 ;;
  "monitoring snoozes create"*)
    [[ "${STUB_CREATE_DENY:-0}" == 1 ]] && { echo "ERROR: (gcloud.monitoring.snoozes.create) PERMISSION_DENIED: monitoring.snoozes.create" >&2; exit 1; }
    echo projects/csi-spl-dev/snoozes/555 ;;
esac
exit 0
EOF
chmod +x "$T/stub/gcloud"

# act [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u SNOOZE_CMD \
    HOME="$T/home" PATH="$T/stub:$PATH" ACTION_FILE="$ACTION" STUB_LOG="$T/calls.log" \
    ALERT_SNOOZE_STATE_FILE="$T/state/snooze.name" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$ACTION_FILE"; do source "$f"; done
    do_gcp_alert_snooze' >"$T/out" 2>&1
}
mon_calls() { grep -c '^monitoring ' "$T/calls.log"; }
mon_calls_as_sa() { grep '^monitoring ' "$T/calls.log" | grep -- "--account=$DEV_SA" | grep -c -- '--project=csi-spl-dev'; }
ts_re='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# --- 3. dry run (the default) -------------------------------------------------------
act SNOOZE_CMD=start; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'snoozes create' "$T/calls.log" && grep -q 'DRY_RUN would run: gcloud monitoring snoozes create' "$T/out" \
  && pass "3. DRY_RUN unset: no snoozes create, the create it would make is printed" || fail "3. dry: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
[[ "$(mon_calls)" -ge 2 && "$(mon_calls)" == "$(mon_calls_as_sa)" ]] \
  && pass "3. every monitoring call as the dev project SA on csi-spl-dev" || fail "3. identity: $(cat "$T/calls.log")"
[[ ! -e "$T/state/snooze.name" ]] && pass "3. dry run keeps no state" || fail "3. state written in a dry run"

# --- 4. start for real ---------------------------------------------------------------
act SNOOZE_CMD=start DRY_RUN=0; rc=$?
create="$(grep '^monitoring snoozes create' "$T/calls.log")"
[[ $rc -eq 0 && "$(grep -c '^monitoring snoozes create' "$T/calls.log")" == 1 ]] \
  && pass "4. DRY_RUN=0 start: one snoozes create" || fail "4. start: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"
grep -q -- '--criteria-policies=projects/csi-spl-dev/alertPolicies/111,projects/csi-spl-dev/alertPolicies/222' <<<"$create" \
  && pass "4. the snooze covers error_logs and sql_down" || fail "4. policies: $create"
s="$(grep -oE -- "--start-time=$ts_re" <<<"$create" | cut -d= -f2)"; e="$(grep -oE -- "--end-time=$ts_re" <<<"$create" | cut -d= -f2)"
win=$(( $(date -u -d "${e:-x}" +%s 2>/dev/null || echo 0) - $(date -u -d "${s:-x}" +%s 2>/dev/null || echo 0) ))
[[ "$win" == 3600 ]] && pass "4. window now..+60 min (ALERT_SNOOZE_MAX_MIN default)" || fail "4. window ${win}s: $create"
[[ "$(cat "$T/state/snooze.name" 2>/dev/null)" == projects/csi-spl-dev/snoozes/555 ]] \
  && pass "4. the snooze name is kept for the end" || fail "4. state: $(cat "$T/state/snooze.name" 2>&1)"

# --- 5. end for real -------------------------------------------------------------------
act SNOOZE_CMD=end DRY_RUN=0; rc=$?
upd="$(grep '^monitoring snoozes update' "$T/calls.log")"
e="$(grep -oE -- "--end-time=$ts_re" <<<"$upd" | cut -d= -f2)"
left=$(( $(date -u -d "${e:-x}" +%s 2>/dev/null || echo 0) - $(date -u +%s) ))
[[ $rc -eq 0 && "$upd" == "monitoring snoozes update projects/csi-spl-dev/snoozes/555 "* && $left -ge 880 && $left -le 900 ]] \
  && pass "5. DRY_RUN=0 end: the kept snooze ends 15 min from now" || fail "5. end: rc=$rc left=$left $upd $(cat "$T/out")"
[[ ! -e "$T/state/snooze.name" ]] && pass "5. the state file is gone" || fail "5. state kept"

# --- 6. end with nothing to end ---------------------------------------------------------
act SNOOZE_CMD=end DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'snoozes update' "$T/calls.log" && grep -q 'nothing to end' "$T/out" \
  && pass "6. end with no kept snooze: nothing to end" || fail "6. rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 7. a missing policy ---------------------------------------------------------------
act SNOOZE_CMD=start DRY_RUN=0 STUB_NO_POLICY='Cloud SQL down'; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'snoozes create' "$T/calls.log" && grep -q 'Cloud SQL down' "$T/out" \
  && pass "7. a policy that is not there: refused, named, no create" || fail "7. rc=$rc $(cat "$T/out")"

# --- 8. create refused --------------------------------------------------------------------
rm -rf "$T/state"
act SNOOZE_CMD=start DRY_RUN=0 STUB_CREATE_DENY=1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'monitoring.snoozes.create' "$T/out" && [[ ! -e "$T/state/snooze.name" ]] \
  && pass "8. create refused: non-zero, the permission is reported, no state" || fail "8. rc=$rc $(cat "$T/out")"

# --- 9. bad values -------------------------------------------------------------------------
act SNOOZE_CMD=pause; rc1=$?; c1=$(wc -l <"$T/calls.log")
act SNOOZE_CMD=start DRY_RUN=2; rc2=$?; c2=$(wc -l <"$T/calls.log")
[[ $rc1 -ne 0 && $rc2 -ne 0 && $c1 == 0 && $c2 == 0 ]] \
  && pass "9. SNOOZE_CMD=pause and DRY_RUN=2 refused before any gcloud call" || fail "9. rc=$rc1/$rc2 calls=$c1/$c2"

# --- 10. CONTROL: no key -----------------------------------------------------------------
mv "$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/key.json"
act SNOOZE_CMD=start DRY_RUN=0; rc=$?
[[ $rc -ne 0 && "$(mon_calls)" == 0 ]] \
  && pass "10. CONTROL: no key -> refused, no monitoring call" || fail "10. rc=$rc $(cat "$T/calls.log")"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-dev.json"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit "$((fails > 0))"
