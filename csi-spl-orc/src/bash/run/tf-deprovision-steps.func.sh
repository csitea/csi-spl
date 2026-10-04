#!/bin/bash
#------------------------------------------------------------------------------
# @description Destroy a list of terraform steps across envs, serially, through
# @description the committed make targets (tf-runner container, project key),
# @description proving each one: `make do-tf-state-list` before (= what goes),
# @description `make do-deprovision`, then the state list again, which MUST be
# @description empty -- the sweep stops at the first step that is not.
# @description Harvested from the 2026-09-19 destroy.sh (adhoc-harvest.md).
# @description Destroying needs the owner's go for that call (repo CLAUDE.md):
# @description STEPS has NO default, and DRY_RUN=1 (the default) only lists what
# @description each step holds. Take do_gcp_backup_env and do_gcp_audit_iam first.
# @description Same one-sweep-per-box rule as do_tf_sweep_steps.
# @param STEPS - required: space-separated steps, destroyed in the order given
# @param ENVS (optional) - default "dev prd"
# @param DRY_RUN (optional) - 1 (default): state list only. 0: destroy.
# @param TF_SWEEP_LOG_DIR (optional) - default $HOME/.local/share/<org>-<app>/tf-sweep
# @example STEPS=050-gcs-files ./run -a do_tf_deprovision_steps
# @example STEPS="120-github-general-secrets" ENVS=dev DRY_RUN=0 ./run -a do_tf_deprovision_steps
#------------------------------------------------------------------------------
do_tf_deprovision_steps() {
  [[ -n "${STEPS:-}" ]] || { do_log "FATAL STEPS is required: a destroy sweep never defaults to every step"; return 1; }
  local dry
  dry="$(_tf_sweep_dry)" || return 2
  local -a steps envs
  _tf_sweep_lists steps envs "$STEPS" || return 1
  local log
  log="$(_tf_sweep_log deprovision)" || return 1
  do_log "INFO tf deprovision (DRY_RUN=$dry) steps: ${steps[*]} envs: ${envs[*]} log: $log"

  local s e before n o d after
  for s in "${steps[@]}"; do
    for e in "${envs[@]}"; do
      before="$(_tf_state_resources "$e" "$s")"; n="$(grep -c . <<<"$before")"
      if (( n == 0 )); then _tf_sweep_note "$log" "$s $e | state empty | nothing to destroy"; continue; fi
      if [[ "$dry" == 1 ]]; then
        _tf_sweep_note "$log" "$s $e | DRY_RUN would destroy $n: $(tr '\n' ' ' <<<"$before")"; continue
      fi
      o="$(_tf_sweep_make do-deprovision "$e" "$s")"
      d="$(grep -oE 'Destroy complete! Resources: [0-9]+ destroyed' <<<"$o" | sed -n 1p)"
      after="$(_tf_state_resources "$e" "$s" | grep -c .)"
      if [[ -z "$d" || "$after" -ne 0 ]]; then
        printf '%s\n' "$o" >>"$log"
        do_log "FATAL STOP $s $e: ${d:-destroy failed}; $after resource(s) still in state (see $log)"; return 1
      fi
      _tf_sweep_note "$log" "$s $e | $n in state: $(tr '\n' ' ' <<<"$before")| $d | state after: 0"
    done
  done
  do_log "OK tf deprovision done (DRY_RUN=$dry): ${steps[*]}"
}

# _tf_state_resources <env> <step> -> one resource address per line
_tf_state_resources() {
  _tf_sweep_make do-tf-state-list "$1" "$2" | grep -E '^(data\.|module\.|google_|terraform_data|random_|null_|github_)' || true
}
