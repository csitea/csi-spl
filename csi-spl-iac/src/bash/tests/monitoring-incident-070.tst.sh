#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2867 (prd incident 2026-10-22: sign-in 503 after 10 s, /v1/view/*
#   up to 193 s, /v1/health 200 throughout) -- 070 pages on both:
#   1. signin_5xx: a log metric on Cloud Run's request log of the hub, path
#      var.signin_path, status >= 500; its policy pages at
#      var.signin_5xx_per_5min in 300 s, to every 03 channel
#   2. view_slow: a DISTRIBUTION log metric of the request latency on
#      var.view_path; its policy pages when the p95 over 300 s stays above
#      var.view_p95_seconds for var.view_slow_seconds, OR when view_path
#      answers var.view_5xx_per_5min 5xx in 300 s (the hub's per-view limit,
#      SPL-2866, turns a slow view into a 503 and caps the p95), same channels
#   3. every threshold is a variable, and the rendered dev/prd tfvars carry it
#      with the cnf value (steps.070-gcp-monitoring, one key per fact)
#   4. both policies are in the alert_policies output
#   5. CONTROLS: the terraform without either policy, without either metric,
#      and a tfvars without either threshold each fail the check; a policy
#      with no channels fails the rule; the incident's measured series fire
#      with the cnf thresholds where the week's normal series stays quiet
#   6. SPL-2934: a fresh apply that creates a log metric and a policy on it
#      failed 404 on the 7 s old metric (Monitoring lags Logging by minutes):
#      every policy on a same-step log metric depends_on a time_sleep (from
#      hashicorp/time, declared) with a create_duration and the metric's id
#      in its triggers, so one apply waits for a new metric; controls drop
#      each piece
#   7. SPL-3232: hub_errors leaves out the hub's own "http 5xx" line (the
#      message logServerError writes, read from the Go source), which rate_5xx
#      already counts: one stall paged twice on 10-22; a real error line, a
#      "handler panic" and Cloud Run's own entries (no message) stay counted
#   8. SPL-3477 (owner answer A, msg 917de544): every alert policy carries its
#      severity, so the alert email subject is no longer "No severity":
#      CRITICAL hub down, Cloud SQL down, sign-in 5xx; ERROR 5xx rate, error
#      log rate, 429 streak; WARNING max instances, memory high, slow views.
#      Controls: a policy without severity, a swapped one and a 10th policy
#      outside the map each fail
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
TFD="$PROJ_ROOT/src/terraform/070-gcp-monitoring"
CNF="$PROJ_ROOT/../csi-spl-cnf/csi-spl"
KEYS=(signin_path signin_5xx_per_5min view_path view_p95_seconds view_slow_seconds view_5xx_per_5min)

# block <tf text> <type> <name> -> that resource's block
block() {
  awk -v r="^resource \"$2\" \"$3\"" '$0 ~ r {on=1} on{print} on&&/^}/{exit}' <<<"$1"
}
# attr <block> <key> -> the right-hand side of the first "<key> = ..." line
attr() {
  local v; v="$(sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*)\$/\1/p" <<<"$1")"
  printf '%s\n' "${v%%$'\n'*}"
}
has() { grep -qF -- "$2" <<<"$1"; }

# signin_ok <policies tf> -> 0 when the sign-in metric + policy hold the rule
signin_ok() {
  local m p
  m="$(block "$1" google_logging_metric signin_5xx)"; p="$(block "$1" google_monitoring_alert_policy signin_5xx)"
  [[ -n "$m" && -n "$p" ]] || return 1
  has "$m" '${local.request_log} AND httpRequest.requestUrl : \"${var.signin_path}\" AND httpRequest.status >= 500' || return 1
  has "$1" 'request_log = "${local.run} AND logName : \"run.googleapis.com%2Frequests\""' || return 1
  [[ "$(attr "$p" notification_channels)" == "local.channels" ]] || return 1
  has "$p" 'logging.googleapis.com/user/${google_logging_metric.signin_5xx.name}' || return 1
  [[ "$(attr "$p" comparison)" == '"COMPARISON_GT"' ]] || return 1
  [[ "$(attr "$p" threshold_value)" == "var.signin_5xx_per_5min - 1" ]] || return 1
  [[ "$(attr "$p" alignment_period)" == '"300s"' ]] || return 1
  [[ "$(attr "$p" per_series_aligner)" == '"ALIGN_DELTA"' ]] || return 1
}
# view_ok <policies tf> -> 0 when the view latency metric + policy hold the rule
view_ok() {
  local m p
  m="$(block "$1" google_logging_metric view_latency)"; p="$(block "$1" google_monitoring_alert_policy view_slow)"
  [[ -n "$m" && -n "$p" ]] || return 1
  has "$m" '${local.request_log} AND httpRequest.requestUrl : \"${var.view_path}\"' || return 1
  has "$m" 'value_extractor = "REGEXP_EXTRACT(httpRequest.latency, \"([0-9.]+)s\")"' || return 1
  [[ "$(attr "$m" value_type)" == '"DISTRIBUTION"' && "$(attr "$m" unit)" == '"s"' ]] || return 1
  [[ "$(attr "$p" notification_channels)" == "local.channels" ]] || return 1
  has "$p" 'logging.googleapis.com/user/${google_logging_metric.view_latency.name}' || return 1
  [[ "$(attr "$p" comparison)" == '"COMPARISON_GT"' ]] || return 1
  [[ "$(attr "$p" threshold_value)" == "var.view_p95_seconds" ]] || return 1
  [[ "$(attr "$p" duration)" == '"${var.view_slow_seconds}s"' ]] || return 1
  [[ "$(attr "$p" alignment_period)" == '"300s"' ]] || return 1
  [[ "$(attr "$p" cross_series_reducer)" == '"REDUCE_PERCENTILE_95"' ]] || return 1
  m="$(block "$1" google_logging_metric view_5xx)"
  [[ -n "$m" ]] || return 1
  has "$m" '${local.request_log} AND httpRequest.requestUrl : \"${var.view_path}\" AND httpRequest.status >= 500' || return 1
  has "$p" 'logging.googleapis.com/user/${google_logging_metric.view_5xx.name}' || return 1
  has "$p" 'threshold_value = var.view_5xx_per_5min - 1' || return 1
  [[ "$(grep -c '^  conditions {' <<<"$p")" == 2 && "$(attr "$p" combiner)" == '"OR"' ]] || return 1
}
# vars_ok <rendered tfvars> <env> -> 0 when every key is there with its cnf value
vars_ok() {
  local k want got
  for k in "${KEYS[@]}"; do
    want="$(yq -o=json -I=0 ".env.steps[\"070-gcp-monitoring\"].$k" "$CNF/$2.env.yaml")"
    [[ -n "$want" && "$want" != null ]] || want="$(yq -o=json -I=0 ".env.steps[\"070-gcp-monitoring\"].$k" "$CNF/all.env.yaml")"
    [[ -n "$want" && "$want" != null ]] || return 1
    got="$(sed -nE "s/^${k}[[:space:]]*=[[:space:]]*(.*)\$/\1/p" <<<"$1")"
    [[ "$got" == "$want" ]] || { echo "  $2 $k: tfvars '$got' cnf '$want'"; return 1; }
  done
}

tf="$(cat "$TFD/05-policies.tf")"
signin_ok "$tf" && pass "signin_5xx: request-log 5xx on signin_path, >= signin_5xx_per_5min in 300 s, every channel" \
  || fail "signin_5xx metric/policy missing or breaks the rule"
view_ok "$tf" && pass "view_slow: request-log latency on view_path, p95 over 300 s > view_p95_seconds for view_slow_seconds, every channel" \
  || fail "view_latency metric / view_slow policy missing or breaks the rule"
for k in "${KEYS[@]}"; do
  grep -q "^variable \"$k\"" "$TFD/02-variables.tf" && pass "variable $k declared" || fail "variable $k not declared"
done
out="$(cat "$TFD/06-outputs.tf")"
has "$out" google_monitoring_alert_policy.signin_5xx.name && has "$out" google_monitoring_alert_policy.view_slow.name \
  && pass "both policies are in the alert_policies output" || fail "alert_policies output misses signin_5xx or view_slow"
for env in dev prd; do
  v="$(cat "$CNF/$env/tf/070-gcp-monitoring.vars.tfvars")"
  vars_ok "$v" "$env" && pass "$env rendered 070 tfvars carry ${KEYS[*]} = cnf" || fail "$env rendered 070 tfvars miss or differ from cnf"
done

# --- 5. controls: each alert removed is caught ------------------------------------
drop() { awk -v r="^resource \"$2\" \"$3\"" '$0 ~ r {on=1} !on{print} on&&/^}/{on=0}' <<<"$1"; }
signin_ok "$(drop "$tf" google_monitoring_alert_policy signin_5xx)" && fail "CONTROL tf without the signin_5xx policy passed" || pass "CONTROL tf without the signin_5xx policy fails"
signin_ok "$(drop "$tf" google_logging_metric signin_5xx)" && fail "CONTROL tf without the signin_5xx metric passed" || pass "CONTROL tf without the signin_5xx metric fails"
view_ok "$(drop "$tf" google_monitoring_alert_policy view_slow)" && fail "CONTROL tf without the view_slow policy passed" || pass "CONTROL tf without the view_slow policy fails"
view_ok "$(drop "$tf" google_logging_metric view_latency)" && fail "CONTROL tf without the view_latency metric passed" || pass "CONTROL tf without the view_latency metric fails"
view_ok "$(drop "$tf" google_logging_metric view_5xx)" && fail "CONTROL tf without the view_5xx metric passed" || pass "CONTROL tf without the view_5xx metric fails"
view_ok "${tf/view_5xx_per_5min - 1/view_5xx_per_5min}" && fail "CONTROL a view 5xx condition at threshold+1 passed" || pass "CONTROL a view 5xx condition at threshold+1 fails"
view_ok "${tf/REDUCE_PERCENTILE_95/REDUCE_MEAN}" && fail "CONTROL a mean in place of the p95 passed" || pass "CONTROL a mean in place of the p95 fails"
no_ch="$(grep -v 'notification_channels = local.channels' <<<"$tf")"
signin_ok "$no_ch" && fail "CONTROL a sign-in policy with no channels passed" || pass "CONTROL a sign-in policy with no channels fails"
v="$(cat "$CNF/dev/tf/070-gcp-monitoring.vars.tfvars")"
vars_ok "$(grep -v '^signin_5xx_per_5min' <<<"$v")" dev >/dev/null && fail "CONTROL tfvars without signin_5xx_per_5min passed" || pass "CONTROL tfvars without signin_5xx_per_5min fails"
vars_ok "$(grep -v '^view_p95_seconds' <<<"$v")" dev >/dev/null && fail "CONTROL tfvars without view_p95_seconds passed" || pass "CONTROL tfvars without view_p95_seconds fails"
vars_ok "$(grep -v '^view_5xx_per_5min' <<<"$v")" dev >/dev/null && fail "CONTROL tfvars without view_5xx_per_5min passed" || pass "CONTROL tfvars without view_5xx_per_5min fails"

# --- 5. the measured series, condition semantics only (nothing applied) -----------
# fires <threshold> <points in a row> <values...> -> 0 when that many points
# in a row are above the threshold (COMPARISON_GT + duration, a point a minute)
fires() {
  local t="$1" n="$2"; shift 2
  awk -v t="$t" -v n="$n" 'BEGIN{for(i=3;i<ARGC;i++){r=(ARGV[i]>t)?r+1:0; if(r>=n) exit 0} exit 1}' x x "$@"
}
c() { yq -r ".env.steps[\"070-gcp-monitoring\"].$1" "$CNF/all.env.yaml"; }
s_cnf="$(c signin_5xx_per_5min)"; v_thr="$(c view_p95_seconds)"; v_sec="$(c view_slow_seconds)"; v5_cnf="$(c view_5xx_per_5min)"
if [[ ! "$s_cnf" =~ ^[0-9]+$ || ! "$v_thr" =~ ^[0-9.]+$ || ! "$v_sec" =~ ^[0-9]+$ || ! "$v5_cnf" =~ ^[0-9]+$ ]]; then
  fail "cnf steps.070-gcp-monitoring misses a threshold: signin_5xx_per_5min '$s_cnf' view_p95_seconds '$v_thr' view_slow_seconds '$v_sec' view_5xx_per_5min '$v5_cnf'"
  echo "FAIL: $fails"; exit 1
fi
s_thr=$(( s_cnf - 1 )); v5_thr=$(( v5_cnf - 1 )); v_n=$(( v_sec / 60 ))
(( v_n > 0 )) || v_n=1
# Measured read-only as the prd SA from the hub's request log, one point a
# minute, each the sliding 5 min ending there. Sign-in 5xx: 2026-10-22
# 09:40..10:10Z, and 08:30..09:30Z (0 every minute; that week sign-in 5xx came
# only inside three degraded windows).
incident_signin=(0 0 0 0 0 0 0 1 1 1 1 1 0 1 1 1 2 2 1 1 1 0 1 1 1 2 2 1 2 2 1)
normal_signin=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)
fires "$s_thr" 1 "${incident_signin[@]}" && pass "the incident's sign-in 5xx fire with the cnf threshold" || fail "the incident's sign-in 5xx stay quiet"
fires "$s_thr" 1 "${normal_signin[@]}" && fail "a normal hour fires the sign-in alert" || pass "a normal hour stays quiet on sign-in"
# /v1/view/* p95 (s): 09:40..10:10Z; 08:30..09:30Z (max 0.9); 03:25..03:41Z
# (the week's biggest non-incident peak, 9-10 s for 5 min, which pages)
incident_view=(0.3 0.3 0.5 0.5 3.1 37.7 37.7 48.9 44.1 44.1 37.0 59.6 54.5 79.7 79.7 74.8 68.0 68.0 40.8 24.3 15.8 17.6 17.6 34.1 115.8 165.9 172.2 172.2 172.2 165.9 66.4)
normal_view=(0.3 0.3 0.4 0.4 0.3 0.2 0.2 0.3 0.3 0.3 0.4 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.5 0.4 0.5 0.5 0.4 0.4 0.5 0.7 0.7 0.7 0.9 0.6 0.5)
peak_view=(0.0 0.1 0.1 0.1 0.1 0.0 0.1 0.1 10.5 9.1 9.1 9.1 9.1 7.6 0.1 0.1 0.1)
blip_view=(0.3 0.4 0.5 10.5 0.5 0.4 0.3 0.4 0.5)
fires "$v_thr" "$v_n" "${incident_view[@]}" && pass "the incident's view p95 fires with the cnf ${v_thr} s for ${v_n} min" || fail "the incident's view p95 stays quiet"
fires "$v_thr" "$v_n" "${normal_view[@]}" && fail "a normal hour fires the view alert" || pass "a normal hour stays quiet on views"
fires "$v_thr" "$v_n" "${peak_view[@]}" && pass "the 10-22T03:35Z peak (9-10 s for 5 min) pages" || fail "the 10-22T03:35Z peak stays quiet"
fires "$v_thr" "$v_n" "${blip_view[@]}" && fail "a one-minute 10.5 s blip fires the view alert" || pass "a one-minute 10.5 s blip stays quiet"
fires "$v_thr" 1 "${blip_view[@]}" && pass "CONTROL with no duration the blip fires (view_slow_seconds matters)" || fail "CONTROL with no duration the blip stayed quiet"
# SPL-2866: the hub cuts a view at 5 s (+1 s grace) with 503 view_timeout, so
# the latency the p95 sees is capped near 6 s: the threshold must sit under it
capped=(); for x in "${incident_view[@]}"; do capped+=("$(awk -v x="$x" 'BEGIN{print (x>6)?6:x}')"); done
fires "$v_thr" "$v_n" "${capped[@]}" && pass "the incident capped at 6 s (per-view limit live) still fires the p95" || fail "the incident capped at 6 s stays quiet on the p95"
fires 10 "$v_n" "${capped[@]}" && fail "CONTROL a 10 s threshold fired on the capped incident" || pass "CONTROL a 10 s threshold misses the capped incident (it must sit under the limit)"
fires 200 "$v_n" "${incident_view[@]}" && fail "CONTROL a 200 s threshold fired on the incident" || pass "CONTROL a 200 s threshold misses the incident (the threshold matters)"
# /v1/view/* 5xx per sliding 5 min: 09:40..10:10Z, and 10-21 18:00..18:59Z
# (the week's highest outside the degraded windows: 2)
incident_v5=(0 0 0 0 0 4 4 5 5 5 1 5 4 6 6 7 3 3 1 1 0 2 2 2 7 8 6 6 6 1 0)
other_v5=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 2 2 2 2 1 0 0 0 0 0 0 0 0 0 0 0 0)
fires "$v5_thr" 1 "${incident_v5[@]}" && pass "the incident's view 5xx fire with the cnf ${v5_cnf} in 5 min" || fail "the incident's view 5xx stay quiet"
fires "$v5_thr" 1 "${other_v5[@]}" && fail "10-21T18Z (2 view 5xx in 5 min) fires" || pass "10-21T18Z (2 view 5xx in 5 min) stays quiet"
fires 0 1 "${other_v5[@]}" && pass "CONTROL a threshold of 1 fires on 10-21T18Z" || fail "CONTROL a threshold of 1 stayed quiet on 10-21T18Z"

# --- 6. SPL-2934: a policy on a same-step log metric waits for it -----------------
# wait_ok <policies tf> <providers tf> -> 0 when every policy that filters on a
# google_logging_metric of this step depends_on a time_sleep that declares a
# create_duration and holds each such metric's id in its triggers
wait_ok() {
  local pol p ms m w ws n=0
  grep -q 'source *= *"hashicorp/time"' <<<"$2" || { echo "  hashicorp/time not declared"; return 1; }
  for pol in $(sed -nE 's/^resource "google_monitoring_alert_policy" "([a-z0-9_]+)".*/\1/p' <<<"$1"); do
    p="$(block "$1" google_monitoring_alert_policy "$pol")"
    ms="$(grep -oE 'google_logging_metric\.[a-z0-9_]+\.name' <<<"$p" | cut -d. -f2 | sort -u)"
    [[ -n "$ms" ]] || continue
    n=$((n + 1))
    w="$(sed -nE 's/^[[:space:]]*depends_on[[:space:]]*=[[:space:]]*\[.*time_sleep\.([a-z0-9_]+).*/\1/p' <<<"$p" | sed -n 1p)"
    [[ -n "$w" ]] || { echo "  policy $pol: no depends_on a time_sleep"; return 1; }
    ws="$(block "$1" time_sleep "$w")"
    [[ -n "$ws" ]] || { echo "  policy $pol: time_sleep.$w not defined"; return 1; }
    [[ "$(attr "$ws" create_duration)" =~ ^\"[0-9]+[sm]\"$ ]] || { echo "  time_sleep.$w: no create_duration"; return 1; }
    for m in $ms; do
      grep -qE "= google_logging_metric\.$m\.id\$" <<<"$ws" || { echo "  time_sleep.$w: no trigger on google_logging_metric.$m.id"; return 1; }
    done
  done
  (( n > 0 )) || { echo "  no policy on a log metric found"; return 1; }
}
prov="$(cat "$TFD/01-providers.tf")"
wait_ok "$tf" "$prov" && pass "every policy on a same-step log metric waits for it (time_sleep, create_duration, metric id trigger)" \
  || fail "a policy on a same-step log metric does not wait for its propagation"
wait_ok "$(grep -v 'depends_on' <<<"$tf")" "$prov" >/dev/null && fail "CONTROL policies without depends_on passed" || pass "CONTROL policies without depends_on fail"
wait_ok "$(drop "$tf" time_sleep log_metrics)" "$prov" >/dev/null && fail "CONTROL tf without the time_sleep passed" || pass "CONTROL tf without the time_sleep fails"
wait_ok "$(grep -v 'create_duration' <<<"$tf")" "$prov" >/dev/null && fail "CONTROL a time_sleep without create_duration passed" || pass "CONTROL a time_sleep without create_duration fails"
wait_ok "$(grep -v '= google_logging_metric.view_5xx.id' <<<"$tf")" "$prov" >/dev/null && fail "CONTROL a trigger set without view_5xx passed" || pass "CONTROL a trigger set without view_5xx fails"
wait_ok "$tf" "$(grep -v 'hashicorp/time' <<<"$prov")" >/dev/null && fail "CONTROL providers without hashicorp/time passed" || pass "CONTROL providers without hashicorp/time fails"

# --- 7. SPL-3232: the hub's own 5xx line is not an error log entry --------------
# counted <hub_errors block> <level> <message> -> 0 when an entry of the hub
# (not the request log) with that zerolog level and message is counted: its
# level is in the filter, and no "NOT jsonPayload.message = ..." names it
counted() {
  local f; f="$(attr "$1" filter)"
  has "$f" "jsonPayload.level = \\\"$2\\\"" || return 1
  ! has "$f" "NOT jsonPayload.message = \\\"$3\\\""
}
GO="$PROJ_ROOT/../csi-spl-api/src/go/spool-hub-api/internal/hub/server.go"
msg5="$(sed -n '/^func (s \*Server) logServerError/,/^}/p' "$GO" | sed -nE 's/^[[:space:]]*ev\.Msg\("([^"]+)"\)$/\1/p')"
[[ "$msg5" == "http 5xx" ]] && pass "the hub writes its 5xx line as message \"$msg5\" (logServerError)" \
  || fail "logServerError's message is '$msg5', not 'http 5xx': re-match the hub_errors filter"
he="$(block "$tf" google_logging_metric hub_errors)"
[[ -n "$he" ]] || fail "hub_errors metric missing"
counted "$he" error "$msg5" && fail "hub_errors counts the hub's own \"$msg5\" line (rate_5xx counts it: one stall pages twice)" \
  || pass "hub_errors leaves out the hub's own \"$msg5\" line"
counted "$he" error "store: query failed" && pass "hub_errors still counts a real error line" || fail "hub_errors drops a real error line"
counted "$he" error "handler panic" && pass "hub_errors still counts a handler panic" || fail "hub_errors drops a handler panic"
has "$(attr "$he" filter)" 'severity >= ERROR' && pass "hub_errors still counts Cloud Run's own ERROR entries (no jsonPayload.message)" \
  || fail "hub_errors lost severity >= ERROR"
has "$(attr "$he" filter)" 'NOT logName : \"run.googleapis.com%2Frequests\"' && pass "hub_errors still leaves out the request log" \
  || fail "hub_errors counts the request log"
counted "${he/ AND NOT jsonPayload.message = \\\"$msg5\\\"/}" error "$msg5" && pass "CONTROL the filter without the exclusion counts the 5xx line" \
  || fail "CONTROL the filter without the exclusion still leaves out the 5xx line"

# --- 8. SPL-3477: each policy has exactly its owner-mapped severity --------------
declare -A SEV=(
  [uptime]=CRITICAL [sql_down]=CRITICAL [signin_5xx]=CRITICAL
  [rate_5xx]=ERROR [error_logs]=ERROR [rate_429]=ERROR
  [instances_at_max]=WARNING [memory_high]=WARNING [view_slow]=WARNING
)
# sev_ok <policies tf> -> 0 when the policies are exactly the mapped ones and
# each has one severity line, equal to its mapped value
sev_ok() {
  local pols pol p n got
  pols="$(sed -nE 's/^resource "google_monitoring_alert_policy" "([a-z0-9_]+)".*/\1/p' <<<"$1" | sort)"
  [[ "$pols" == "$(printf '%s\n' "${!SEV[@]}" | sort)" ]] || { echo "  policies: $(tr '\n' ' ' <<<"$pols")"; return 1; }
  for pol in $pols; do
    p="$(block "$1" google_monitoring_alert_policy "$pol")"
    n="$(grep -cE '^  severity[[:space:]]*=' <<<"$p")"
    got="$(sed -nE 's/^  severity[[:space:]]*=[[:space:]]*"([A-Z]+)"$/\1/p' <<<"$p")"
    [[ "$n" == 1 && "$got" == "${SEV[$pol]}" ]] || { echo "  $pol: severity '$got' ($n lines), want ${SEV[$pol]}"; return 1; }
  done
}
sev_ok "$tf" && pass "each of the ${#SEV[@]} alert policies has its mapped severity (CRITICAL 3, ERROR 3, WARNING 3)" \
  || fail "an alert policy misses its mapped severity"
sev_ok "$(sed '0,/^  severity .*"CRITICAL"$/{//d}' <<<"$tf")" >/dev/null && fail "CONTROL a policy without severity passed" || pass "CONTROL a policy without severity fails"
sev_ok "$(sed '0,/"WARNING"$/s//"ERROR"/' <<<"$tf")" >/dev/null && fail "CONTROL a WARNING swapped to ERROR passed" || pass "CONTROL a WARNING swapped to ERROR fails"
sev_ok "$tf"$'\nresource "google_monitoring_alert_policy" "extra" {\n  severity = "ERROR"\n}' >/dev/null && fail "CONTROL a policy outside the map passed" || pass "CONTROL a policy outside the map fails"

[[ $fails -eq 0 ]] && echo "PASS: all monitoring-incident-070.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
