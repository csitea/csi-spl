#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description Snooze the hub error-log and database-down alerts around a
# @description planned database apply (SPL-3457, alerts fix round row 03 part A,
# @description csi-spl-doc/doc/md/planned-apply-alert-snooze.md). An owner-
# @description approved 040 apply restarts Cloud SQL for about a minute and the
# @description hub's loops log ERROR on every tick of it, which paged
# @description error_logs (and can page sql_down) for a change already agreed.
# @description `make do-provision STEP=040-cloud-sql-postgres` calls it: start
# @description before the apply, end after it.
# @description SNOOZE_CMD=start: one Monitoring snooze over the 070 policies
# @description "<org>-<app>-<env> hub error log rate" (error_logs) and
# @description "<org>-<app>-<env> Cloud SQL down" (sql_down), from now to now +
# @description ALERT_SNOOZE_MAX_MIN, so a hung or failed apply still ends it;
# @description its name is kept in ALERT_SNOOZE_STATE_FILE.
# @description SNOOZE_CMD=end: the kept snooze now ends ALERT_SNOOZE_AFTER_MIN
# @description from now (the apply + 15 min); nothing kept = nothing to end.
# @description Runs as the env's project SA (do_gcp_pin_account) in a private
# @description gcloud config. DRY_RUN=1 (default) reads the policies and prints
# @description the call it would make; DRY_RUN=0 makes it. A missing
# @description monitoring.snoozes.create / .update permission is reported,
# @description never worked around with another account.
# @param ENV - required: dev or prd
# @param SNOOZE_CMD - required: start or end
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ALERT_SNOOZE_MAX_MIN (optional) - the window start opens, minutes (default 60)
# @param ALERT_SNOOZE_AFTER_MIN (optional) - minutes the snooze lasts after end (default 15)
# @param ALERT_SNOOZE_STATE_FILE (optional) - where start keeps the snooze name
# @param   (default ${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/alert-snooze-<env>.name)
# @example ENV=dev SNOOZE_CMD=start ./run -a do_gcp_alert_snooze
# @example ENV=prd SNOOZE_CMD=end DRY_RUN=0 ./run -a do_gcp_alert_snooze
#------------------------------------------------------------------------------
do_gcp_alert_snooze() {
  local cmd="${SNOOZE_CMD:-}" dry="${DRY_RUN:-1}"
  local max_min="${ALERT_SNOOZE_MAX_MIN:-60}" after_min="${ALERT_SNOOZE_AFTER_MIN:-15}"
  [[ "$cmd" == start || "$cmd" == end ]] || { do_log "FATAL SNOOZE_CMD must be start or end, got: '$cmd'"; return 2; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  [[ "$max_min" =~ ^[1-9][0-9]*$ && "$after_min" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL ALERT_SNOOZE_MAX_MIN and ALERT_SNOOZE_AFTER_MIN must be positive integers, got: $max_min / $after_min"; return 2; }

  local _spl_sdk_saved _spl_sdk_dir
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN
  do_gcp_spl_proj_id || return 1
  do_gcp_pin_account || return 1
  local state="${ALERT_SNOOZE_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/alert-snooze-$ENV.name}"
  if [[ "$cmd" == start ]]; then
    _spl_alert_snooze_start "$PROJ_ID" "$GCP_ACCOUNT" "$dry" "$max_min" "$state" "$ORG-$APP-$ENV"
  else
    _spl_alert_snooze_end "$PROJ_ID" "$GCP_ACCOUNT" "$dry" "$after_min" "$state"
  fi
}

#------------------------------------------------------------------------------
# @description Print the resource name of the alert policy whose display name
# @description is $3 in project $1, read as $2; fails when there is not
# @description exactly one.
# @param $1 project, $2 account, $3 display name
#------------------------------------------------------------------------------
_spl_alert_snooze_policy() {
  local p="$1" sa="$2" dn="$3" names n
  names="$(gcloud monitoring policies list --project="$p" --account="$sa" \
    --filter="displayName=\"$dn\"" --format='value(name)' 2>&1)" ||
    { do_log "FATAL cannot list alert policies in $p as $sa (monitoring.alertPolicies.list?): $names" >&2; return 1; }
  n="$(grep -c . <<<"$names")"
  [[ "$n" == 1 ]] || { do_log "FATAL $n alert policies named \"$dn\" in $p, need exactly 1 (is 070 applied?)" >&2; return 1; }
  echo "$names"
}

#------------------------------------------------------------------------------
# @description SNOOZE_CMD=start of do_gcp_alert_snooze.
# @param $1 project, $2 account, $3 dry (0|1), $4 window minutes, $5 state file,
# @param $6 the 070 local.name (<org>-<app>-<env>) the display names start with
#------------------------------------------------------------------------------
_spl_alert_snooze_start() {
  local p="$1" sa="$2" dry="$3" max_min="$4" state="$5" tf_name="$6" dn pols=() pol
  for dn in "$tf_name hub error log rate" "$tf_name Cloud SQL down"; do
    pol="$(_spl_alert_snooze_policy "$p" "$sa" "$dn")" || return 1
    pols+=("$pol")
  done
  local s e list
  s="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  e="$(date -u -d "$s + $max_min min" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  list="$(IFS=,; echo "${pols[*]}")"
  local args=(monitoring snoozes create --project="$p"
    --display-name="planned apply 040 $s" --criteria-policies="$list"
    --start-time="$s" --end-time="$e" --format='value(name)')
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would run: gcloud ${args[*]} --account=$sa"
    do_log "OK DRY_RUN nothing changed. Re-run with DRY_RUN=0 to snooze error_logs and sql_down until $e."
    return 0
  fi
  local name
  name="$(gcloud "${args[@]}" --account="$sa" 2>&1)" ||
    { do_log "ERROR snooze not created in $p as $sa (monitoring.snoozes.create?): $name"; return 1; }
  [[ "$name" == projects/*/snoozes/* ]] || { do_log "ERROR snooze create answered no name: $name"; return 1; }
  mkdir -p "$(dirname "$state")" && echo "$name" >"$state" ||
    { do_log "ERROR snooze $name created but not kept in $state: it ends at $e by itself"; return 1; }
  do_log "OK snooze $name: error_logs and sql_down quiet from $s until $e at the latest"
}

#------------------------------------------------------------------------------
# @description SNOOZE_CMD=end of do_gcp_alert_snooze.
# @param $1 project, $2 account, $3 dry (0|1), $4 minutes left, $5 state file
#------------------------------------------------------------------------------
_spl_alert_snooze_end() {
  local p="$1" sa="$2" dry="$3" after_min="$4" state="$5" name e
  name="$(cat "$state" 2>/dev/null)"
  [[ -n "$name" ]] || { do_log "INFO no snooze kept in $state: nothing to end"; return 0; }
  e="$(date -u -d "+$after_min min" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  local args=(monitoring snoozes update "$name" --project="$p" --end-time="$e")
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would run: gcloud ${args[*]} --account=$sa"
    return 0
  fi
  local out
  out="$(gcloud "${args[@]}" --account="$sa" 2>&1)" ||
    { do_log "WARN snooze $name not shortened (monitoring.snoozes.update? already over?): $out; it ends at its own end time"; rm -f "$state"; return 1; }
  rm -f "$state"
  do_log "OK snooze $name now ends at $e ($after_min min after the apply)"
}
