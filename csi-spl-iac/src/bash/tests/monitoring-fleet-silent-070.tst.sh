#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-4632 (2026-11-01: one box benched with the other offline for
#   7 h, no page; every box alert is posted by a box through the hub) -- 070
#   pages when every box of a fleet is silent, from Cloud Monitoring, so no box
#   has to be up to deliver it:
#   1. the hub writes one info line per stored beat: message boxBeatLogMsg
#      with a tenant field (internal/hub/box_beat.go, read from the Go source)
#   2. box_beats: a log metric on that exact message and level, its tenant
#      label extracted from jsonPayload.tenant
#   3. fleet_silent: an ABSENCE condition on box_beats summed per
#      metric.label.tenant, for var.fleet_silent_seconds, CRITICAL, to every
#      03 channel, waiting on time_sleep.log_metrics (SPL-2934), in the
#      alert_policies output
#   4. the variable is validated and the rendered dev/prd tfvars carry cnf
#      steps.070-gcp-monitoring.fleet_silent_seconds
#   5. semantics on minute series of beats per box: both boxes silent past
#      the limit fires; the 11-01 shape (one box up) stays quiet
#   6. CONTROLS: a threshold condition, grouping by box, a literal duration,
#      no channels, a message the hub does not write and a metric without
#      the tenant label each fail; grouping by box fires with one box up
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
TFD="$PROJ_ROOT/src/terraform/070-gcp-monitoring"
CNF="$PROJ_ROOT/../csi-spl-cnf/csi-spl"
GO="$PROJ_ROOT/../csi-spl-api/src/go/spool-hub-api/internal/hub/box_beat.go"

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

# --- 1. the hub's line -------------------------------------------------------------
msg="$(sed -nE 's/^const boxBeatLogMsg = "([^"]+)"$/\1/p' "$GO")"
[[ -n "$msg" ]] && pass "the hub's beat line message is \"$msg\" (boxBeatLogMsg)" || fail "no boxBeatLogMsg const in $GO"
grep -qE 'Log\.Info\(\)\.Str\("tenant", x\.tenant\).*\.Msg\(boxBeatLogMsg\)' "$GO" \
  && pass "the hub logs it at info with the session's tenant" || fail "box_beat.go does not log Info().Str(\"tenant\", x.tenant)...Msg(boxBeatLogMsg)"

# metric_ok <tf> <message> -> 0 when box_beats counts that message at info, labelled by tenant
metric_ok() {
  local m; m="$(block "$1" google_logging_metric box_beats)"
  [[ -n "$m" ]] || { echo "  no box_beats metric"; return 1; }
  has "$(attr "$m" filter)" "\${local.run} AND jsonPayload.message = \\\"$2\\\" AND jsonPayload.level = \\\"info\\\"" || { echo "  filter: $(attr "$m" filter)"; return 1; }
  [[ "$(attr "$m" tenant)" == '"EXTRACT(jsonPayload.tenant)"' ]] || { echo "  no tenant label extractor"; return 1; }
  grep -qE '^[[:space:]]*key[[:space:]]*=[[:space:]]*"tenant"$' <<<"$m" || { echo "  no tenant label in the descriptor"; return 1; }
}
# policy_ok <tf> -> 0 when fleet_silent is the absence rule of section 3
policy_ok() {
  local p; p="$(block "$1" google_monitoring_alert_policy fleet_silent)"
  [[ -n "$p" ]] || { echo "  no fleet_silent policy"; return 1; }
  grep -q '^    condition_absent {' <<<"$p" || { echo "  not an absence condition"; return 1; }
  has "$(attr "$p" filter)" 'logging.googleapis.com/user/${google_logging_metric.box_beats.name}' || { echo "  filter: $(attr "$p" filter)"; return 1; }
  [[ "$(attr "$p" duration)" == '"${var.fleet_silent_seconds}s"' ]] || { echo "  duration: $(attr "$p" duration)"; return 1; }
  [[ "$(attr "$p" cross_series_reducer)" == '"REDUCE_SUM"' ]] || { echo "  reducer: $(attr "$p" cross_series_reducer)"; return 1; }
  [[ "$(attr "$p" group_by_fields)" == '["metric.label.tenant"]' ]] || { echo "  group_by: $(attr "$p" group_by_fields)"; return 1; }
  [[ "$(attr "$p" notification_channels)" == "local.channels" ]] || { echo "  channels: $(attr "$p" notification_channels)"; return 1; }
  [[ "$(attr "$p" severity)" == '"CRITICAL"' ]] || { echo "  severity: $(attr "$p" severity)"; return 1; }
  has "$(attr "$p" depends_on)" 'time_sleep.log_metrics' || { echo "  no depends_on time_sleep.log_metrics"; return 1; }
}

tf="$(cat "$TFD/05-policies.tf")"
metric_ok "$tf" "$msg" && pass "box_beats counts the hub's \"$msg\" info lines, labelled by tenant" || fail "box_beats breaks the rule"
policy_ok "$tf" && pass "fleet_silent: no box beat of a tenant for fleet_silent_seconds, CRITICAL, every channel" || fail "fleet_silent breaks the rule"
grep -q 'google_monitoring_alert_policy.fleet_silent.name' "$TFD/06-outputs.tf" \
  && pass "fleet_silent is in the alert_policies output" || fail "alert_policies output misses fleet_silent"
grep -qE '^    box_beats += google_logging_metric\.box_beats\.id$' <<<"$(block "$tf" time_sleep log_metrics)" \
  && pass "time_sleep.log_metrics waits for box_beats" || fail "time_sleep.log_metrics has no box_beats trigger"

# --- 4. variable + rendered tfvars ----------------------------------------------------
v="$(awk '/^variable "fleet_silent_seconds"/{on=1} on{print} on&&/^}/{exit}' "$TFD/02-variables.tf")"
has "$v" 'var.fleet_silent_seconds >= 120 && var.fleet_silent_seconds <= 84600 && var.fleet_silent_seconds % 60 == 0' \
  && pass "fleet_silent_seconds is validated to 120..84600 whole minutes" || fail "fleet_silent_seconds validation: $v"
want="$(yq -r '.env.steps["070-gcp-monitoring"].fleet_silent_seconds' "$CNF/all.env.yaml")"
[[ "$want" =~ ^[0-9]+$ ]] && pass "cnf fleet_silent_seconds = $want" || fail "cnf fleet_silent_seconds '$want'"
for env in dev prd; do
  got="$(sed -nE 's/^fleet_silent_seconds[[:space:]]*=[[:space:]]*([0-9]+)$/\1/p' "$CNF/$env/tf/070-gcp-monitoring.vars.tfvars")"
  [[ -n "$got" && "$got" == "$want" ]] && pass "$env 070 fleet_silent_seconds $got = cnf" || fail "$env 070 fleet_silent_seconds '$got' != cnf '$want'"
done

# --- 5. semantics: one point a minute per box, beats in that minute ------------------
# fires <group> <minutes> <box a series> <box b series> -> 0 when some group's
# sum stays 0 for <minutes> points in a row (absence, REDUCE_SUM per group).
# group "tenant": both boxes are one fleet; group "box": each box alone.
fires() {
  local g="$1" n="$2"
  awk -v g="$g" -v n="$n" -v a="$3" -v b="$4" 'BEGIN{
    k = split(a, A, " "); split(b, B, " ")
    for (i = 1; i <= k; i++) {
      if (g == "tenant") { r = (A[i] + B[i] == 0) ? r + 1 : 0; if (r >= n) exit 0 }
      else { ra = (A[i] == 0) ? ra + 1 : 0; rb = (B[i] == 0) ? rb + 1 : 0; if (ra >= n || rb >= n) exit 0 }
    }
    exit 1 }'
}
mins=$(( want / 60 ))
up="" off=""; for ((i = 0; i < mins + 2; i++)); do up+="6 "; off+="0 "; done
fires tenant "$mins" "$off" "$off" && pass "both boxes silent for $((mins + 2)) min fires at $mins min" || fail "both boxes silent did not fire"
fires tenant "$mins" "$up" "$off" && fail "one box up (the 11-01 shape) fires" || pass "one box up (the 11-01 shape) stays quiet"
fires tenant "$mins" "$up" "$up" && fail "both boxes up fires" || pass "both boxes up stays quiet"
short=""; for ((i = 0; i < mins - 1; i++)); do short+="0 "; done; short+="6 6 6"
fires tenant "$mins" "$short" "$short" && fail "a $((mins - 1)) min gap of both fires" || pass "a $((mins - 1)) min gap of both stays quiet"

# --- 6. controls ------------------------------------------------------------------------
policy_ok "${tf/condition_absent \{/condition_threshold \{}" >/dev/null && fail "CONTROL a threshold condition passed" || pass "CONTROL a threshold condition fails"
policy_ok "${tf/\[\"metric.label.tenant\"\]/[\"metric.label.box\"]}" >/dev/null && fail "CONTROL grouping by box passed" || pass "CONTROL grouping by box fails"
fires box "$mins" "$up" "$off" && pass "CONTROL grouping by box fires with one box up" || fail "CONTROL grouping by box stayed quiet with one box up"
policy_ok "${tf/\"\$\{var.fleet_silent_seconds\}s\"/\"600s\"}" >/dev/null && fail "CONTROL a literal duration passed" || pass "CONTROL a literal duration fails"
policy_ok "$(sed '/resource "google_monitoring_alert_policy" "fleet_silent"/,/^}/{/notification_channels/d}' <<<"$tf")" >/dev/null \
  && fail "CONTROL a policy with no channels passed" || pass "CONTROL a policy with no channels fails"
metric_ok "$tf" "box beats" >/dev/null && fail "CONTROL a message the hub does not write passed" || pass "CONTROL a message the hub does not write fails"
metric_ok "$(grep -v 'EXTRACT(jsonPayload.tenant)' <<<"$tf")" "$msg" >/dev/null && fail "CONTROL a metric without the tenant label passed" || pass "CONTROL a metric without the tenant label fails"

[[ $fails -eq 0 ]] && echo "PASS: all monitoring-fleet-silent-070.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
