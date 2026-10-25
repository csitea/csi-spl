#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2542 (Cloud Run radar step 5) -- 070 pages on hub capacity:
#   1. instances_at_max: run.googleapis.com/container/instance_count of the hub
#      service, per revision, COMPARISON_GT var.hub_max_instances - 1 (= "at
#      max"), for var.instances_at_max_seconds, to every 03 channel
#   2. memory_high: container/memory/utilizations p99, per revision, above
#      var.memory_utilization_threshold for var.memory_high_seconds, same channels
#   3. the rendered dev/prd tfvars carry hub_max_instances = cnf
#      hub.cloud_run.max_instances (one key per fact, never a second literal)
#   4. the memory threshold pages before the hub's GOMEMLIMIT (030 tfvars)
#   5. CONTROLS: "GT max" (never fires: an instance count never passes its
#      max) and a policy with no channels both fail the rule; a planted low
#      memory threshold fires on a dev-shaped series where the cnf one stays
#      quiet (condition semantics only, nothing applied)
#   6. SPL-3424 (alerts fix round row 01, owner Q1 = A): instances_at_max
#      pages only when the revision is at max AND busy: a second condition,
#      container/cpu/utilizations p99 per revision above
#      var.instances_at_max_cpu_p99 for the same duration, combiner "AND";
#      the rendered tfvars carry the cnf value. CONTROLS: combiner "OR" and a
#      literal threshold fail the rule; an idle at-max hour stays quiet
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
TF="$PROJ_ROOT/src/terraform/070-gcp-monitoring/05-policies.tf"
CNF="$PROJ_ROOT/../csi-spl-cnf/csi-spl"

# block <tf text> <resource name> -> that alert policy's resource block
block() {
  awk -v r="$2" '$0 ~ "^resource \"google_monitoring_alert_policy\" \"" r "\"" {on=1} on{print} on&&/^}/{exit}' <<<"$1"
}
# attr <block> <key> -> the right-hand side of the first "<key> = ..." line
attr() {
  local v; v="$(sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*)\$/\1/p" <<<"$1")"
  printf '%s\n' "${v%%$'\n'*}"
}
# rule <block> <metric> <comparison> <threshold expr> <duration var> -> 0 when it holds
rule() {
  local b="$1"
  [[ "$(attr "$b" notification_channels)" == "local.channels" ]] || return 1
  grep -q "metric.type = \\\\\"run.googleapis.com/$2\\\\\" AND \${local.run}" <<<"$b" || return 1
  [[ "$(attr "$b" comparison)" == "\"$3\"" ]] || return 1
  [[ "$(attr "$b" threshold_value)" == "$4" ]] || return 1
  [[ "$(attr "$b" duration)" == "\"\${var.$5}s\"" ]] || return 1
  [[ "$(attr "$b" group_by_fields)" == '["resource.label.revision_name"]' ]] || return 1
}

tf="$(cat "$TF")"
im="$(block "$tf" instances_at_max)"; mh="$(block "$tf" memory_high)"
rule "$im" container/instance_count COMPARISON_GT "var.hub_max_instances - 1" instances_at_max_seconds \
  && pass "instances_at_max: instance_count per revision >= max for instances_at_max_seconds, every channel" \
  || fail "instances_at_max breaks the rule: $im"
rule "$mh" container/memory/utilizations COMPARISON_GT var.memory_utilization_threshold memory_high_seconds \
  && pass "memory_high: p99 memory per revision > threshold for memory_high_seconds, every channel" \
  || fail "memory_high breaks the rule: $mh"
[[ "$(attr "$mh" per_series_aligner)" == '"ALIGN_PERCENTILE_99"' ]] && pass "memory_high aligns p99" || fail "memory_high aligner: $(attr "$mh" per_series_aligner)"
grep -q 'google_monitoring_alert_policy.instances_at_max.name' "$PROJ_ROOT/src/terraform/070-gcp-monitoring/06-outputs.tf" \
  && grep -q 'google_monitoring_alert_policy.memory_high.name' "$PROJ_ROOT/src/terraform/070-gcp-monitoring/06-outputs.tf" \
  && pass "both policies are in the alert_policies output" || fail "alert_policies output misses a capacity policy"

# --- 5. controls on the rule ------------------------------------------------------
gt_max="${im/var.hub_max_instances - 1/var.hub_max_instances}"
rule "$gt_max" container/instance_count COMPARISON_GT "var.hub_max_instances - 1" instances_at_max_seconds \
  && fail "CONTROL 'GT max' (never fires) passed the rule" || pass "CONTROL 'GT max' (never fires) fails the rule"
no_ch="$(grep -v notification_channels <<<"$im")"
rule "$no_ch" container/instance_count COMPARISON_GT "var.hub_max_instances - 1" instances_at_max_seconds \
  && fail "CONTROL a policy with no channels passed the rule" || pass "CONTROL a policy with no channels fails the rule"

# --- 3. + 4. rendered tfvars ------------------------------------------------------
for env in dev prd; do
  m="$(yq -r ".env.hub.cloud_run.max_instances // \"\"" "$CNF/$env.env.yaml")"
  [[ -n "$m" && "$m" != null ]] || m="$(yq -r '.env.hub.cloud_run.max_instances' "$CNF/all.env.yaml")"
  vars="$CNF/$env/tf/070-gcp-monitoring.vars.tfvars"
  got="$(sed -nE 's/^hub_max_instances[[:space:]]*=[[:space:]]*([0-9]+)$/\1/p' "$vars")"
  [[ -n "$got" && "$got" == "$m" ]] && pass "$env 070 hub_max_instances $got = cnf max_instances $m" || fail "$env 070 hub_max_instances '$got' != cnf '$m'"
  cpu="$(sed -nE 's/^instances_at_max_cpu_p99[[:space:]]*=[[:space:]]*([0-9.]+)$/\1/p' "$vars")"
  want="$(yq -r '.env.steps["070-gcp-monitoring"].instances_at_max_cpu_p99' "$CNF/all.env.yaml")"
  [[ -n "$cpu" && "$cpu" == "$want" ]] && pass "$env 070 instances_at_max_cpu_p99 $cpu = cnf" || fail "$env 070 instances_at_max_cpu_p99 '$cpu' != cnf '$want'"
  thr="$(sed -nE 's/^memory_utilization_threshold[[:space:]]*=[[:space:]]*([0-9.]+)$/\1/p' "$vars")"
  mem="$(yq -r '.env.hub.cloud_run.memory' "$CNF/all.env.yaml")"; mem="${mem%Mi}"
  lim="$(grep -oE '"SPOOL_HUB_GOMEMLIMIT": "[0-9]+MiB"' "$CNF/$env/tf/030-cloud-run-hub.vars.tfvars" | grep -oE '[0-9]+')"
  awk -v t="$thr" -v l="$lim" -v m="$mem" 'BEGIN{exit !(t > 0 && l > 0 && m > 0 && t < l / m)}' \
    && pass "$env memory threshold $thr pages below GOMEMLIMIT ${lim}MiB of ${mem}Mi" || fail "$env memory threshold '$thr' vs GOMEMLIMIT '$lim' of '$mem'"
done

# --- 5. a planted low threshold fires where the cnf one stays quiet ---------------
# fires <threshold> <minutes> <values...> -> 0 when <minutes> points in a row
# are above the threshold: what COMPARISON_GT + duration does, one point a minute
fires() {
  local t="$1" n="$2"; shift 2
  awk -v t="$t" -v n="$n" 'BEGIN{for(i=3;i<ARGC;i++){r=(ARGV[i]>t)?r+1:0; if(r>=n) exit 0} exit 1}' x x "$@"
}
# dev-shaped: p99 memory per minute measured 0.16..0.28 (7 days to 2026-10-19)
series=(0.16 0.18 0.16 0.20 0.25 0.28 0.22 0.16 0.17 0.19)
cnf_thr="$(yq -r '.env.steps["070-gcp-monitoring"].memory_utilization_threshold' "$CNF/all.env.yaml")"
cnf_min=$(( $(yq -r '.env.steps["070-gcp-monitoring"].memory_high_seconds' "$CNF/all.env.yaml") / 60 ))
fires "$cnf_thr" "$cnf_min" "${series[@]}" && fail "cnf threshold $cnf_thr fires on the dev series" || pass "cnf threshold $cnf_thr stays quiet on the dev series"
fires 0.1 "$cnf_min" "${series[@]}" && pass "CONTROL planted threshold 0.1 fires on the dev series" || fail "CONTROL planted threshold 0.1 did not fire"

# --- 6. at max AND busy (SPL-3424) -------------------------------------------------
# cond <block> <metric> -> the conditions { } sub-block that reads that metric
cond() {
  awk -v m="run.googleapis.com/$2" '/^  conditions \{/{on=1; buf=""} on{buf=buf $0 "\n"} on&&/^  \}/{on=0; if(index(buf, m)) printf "%s", buf}' <<<"$1"
}
# busy <block> -> 0 when the policy ANDs a CPU p99 condition on the cnf variable
busy() {
  local c; c="$(cond "$1" container/cpu/utilizations)"
  [[ "$(attr "$1" combiner)" == '"AND"' && -n "$c" ]] || return 1
  rule "$(printf '  notification_channels = local.channels\n%s' "$c")" container/cpu/utilizations COMPARISON_GT \
    var.instances_at_max_cpu_p99 instances_at_max_seconds || return 1
  [[ "$(attr "$c" per_series_aligner)" == '"ALIGN_PERCENTILE_99"' ]]
}
busy "$im" && pass "instances_at_max: AND a CPU p99 per revision > instances_at_max_cpu_p99 for instances_at_max_seconds" \
  || fail "instances_at_max does not AND a CPU p99 condition on var.instances_at_max_cpu_p99: $im"
busy "$(sed -E 's/^(  combiner *= )"AND"/\1"OR"/' <<<"$im")" \
  && fail "CONTROL combiner OR passed the busy rule" || pass "CONTROL combiner OR fails the busy rule"
busy "$(sed -E 's/(threshold_value = )var.instances_at_max_cpu_p99/\10.6/' <<<"$im")" \
  && fail "CONTROL a literal CPU threshold passed the busy rule" || pass "CONTROL a literal CPU threshold fails the busy rule"
# the prd episode of 2026-10-21: at max for an hour, CPU p99 <= 0.06 -> quiet
cpu_thr="$(yq -r '.env.steps["070-gcp-monitoring"].instances_at_max_cpu_p99' "$CNF/all.env.yaml")"
at_min=$(( $(yq -r '.env.steps["070-gcp-monitoring"].instances_at_max_seconds' "$CNF/all.env.yaml") / 60 ))
idle=(); hot=(); for ((i = 0; i <= at_min; i++)); do idle+=(0.06); hot+=(0.75); done
fires "$cpu_thr" "$at_min" "${idle[@]}" && fail "an idle at-max hour (CPU p99 0.06) fires at '$cpu_thr'" || pass "an idle at-max hour (CPU p99 0.06) stays quiet at $cpu_thr"
fires "$cpu_thr" "$at_min" "${hot[@]}" && pass "CONTROL a busy at-max hour (CPU p99 0.75) fires at $cpu_thr" || fail "CONTROL a busy at-max hour did not fire at '$cpu_thr'"

[[ $fails -eq 0 ]] && echo "PASS: all monitoring-capacity-070.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
