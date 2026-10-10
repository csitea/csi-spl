#!/bin/bash
#------------------------------------------------------------------------------
# A cost source of the factory (spl-cost-source.func.sh, spec 123 4.6).
#------------------------------------------------------------------------------
# Cost source gcp (spec 123 4.2, 4.6): the GCP billing export, read by
# csi-spl-iac do_spl_estate_cost_read (build lane 2) for the trailing
# env.cost.reread_days window ending DAY, so a late or revised export row of
# an earlier day is re-read every night. That reader writes its own
# cost_lines (origin billing_export) and cost_coverage (source gcp) to the
# ENV hub DB, so this source answers OUT.self; it runs with the caller's
# DRY_RUN (1 = read and print, write nothing). COST_IAC_DIR overrides the
# sibling <org>-<app>-iac checkout.
spl_cost_source_gcp() {
  local day="$1" out="$2" iac="${COST_IAC_DIR:-${PROJ_PATH%-orc}-iac}" dry="${DRY_RUN:-1}"
  [[ -x "$iac/run" ]] || { echo "no iac checkout with a run script at $iac" >&2; return 1; }
  ( cd "$iac" && ENV="$ENV" DAY="$day" DRY_RUN="$dry" ./run -a do_spl_estate_cost_read ) >"$out.log" 2>&1 ||
    { grep -E 'FATAL|ERROR' "$out.log" | tail -n 1 >&2; return 1; }
  printf 'the billing export window ending %s (env.cost.reread_days), %s by do_spl_estate_cost_read\n' \
    "$day" "$([[ "$dry" == 0 ]] && echo written || echo 'read, DRY_RUN: not written,')" >"$out.self"
}
