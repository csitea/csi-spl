#!/bin/bash
#------------------------------------------------------------------------------
# @description Plan (and, with DRY_RUN=0, provision) a list of terraform steps
# @description across envs, serially, through the committed make targets
# @description (tf-runner container, project key; never host terraform).
# @description Harvested from the 2026-09-19 sweep.sh / .plan-all.sh
# @description (adhoc-harvest.md). Per env + step: `make do-tf-plan`, then a
# @description GATE -- the sweep STOPS (nothing further applied) on a plan with
# @description an Error, no summary, anything to destroy or "must be replaced";
# @description "No changes" is skipped; otherwise DRY_RUN=0 runs
# @description `make do-provision` and requires "Apply complete!".
# @description Envs run in ENVS order for every step (025 delegation wants
# @description ENVS="prd dev"). One sweep per box at a time: do_tf_init wipes
# @description the step's bin dir, so two runs on one env + step break each
# @description other. Run it from the main checkout's csi-spl-orc.
# @description DRY_RUN=1 (default): plan only, nothing applied.
# @param STEPS (optional) - space-separated steps; default every csi-spl-iac
# @param   src/terraform step dir, in order
# @param ENVS (optional) - default "dev prd"
# @param DRY_RUN (optional) - 1 (default): plan only. 0: provision past the gate.
# @param TF_SWEEP_LOG_DIR (optional) - default $HOME/.local/share/<org>-<app>/tf-sweep
# @example STEPS="017-github-wif-deploy 030-cloud-run-hub" ./run -a do_tf_sweep_steps
# @example STEPS=030-cloud-run-hub ENVS="dev prd" DRY_RUN=0 ./run -a do_tf_sweep_steps
#------------------------------------------------------------------------------
do_tf_sweep_steps() {
  local dry
  dry="$(_tf_sweep_dry)" || return 2
  local -a steps envs
  _tf_sweep_lists steps envs "${STEPS:-}" || return 1
  local log
  log="$(_tf_sweep_log sweep)" || return 1
  do_log "INFO tf sweep (DRY_RUN=$dry) steps: ${steps[*]} envs: ${envs[*]} log: $log"

  local s e o sum a
  for s in "${steps[@]}"; do
    for e in "${envs[@]}"; do
      o="$(_tf_sweep_make do-tf-plan "$e" "$s")"
      sum="$(grep -oE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy|No changes' <<<"$o" | head -1)"
      if [[ -z "$sum" ]] || grep -qE '^(│ )?Error|must be replaced' <<<"$o" || [[ "$sum" =~ ,\ [1-9][0-9]*\ to\ destroy ]]; then
        printf '%s\n' "$o" >>"$log"
        do_log "FATAL STOP $s $e plan: ${sum:-no plan summary} (destroy / replace / error gate; see $log)"; return 1
      fi
      if [[ "$sum" == "No changes" || "$dry" == 1 ]]; then
        _tf_sweep_note "$log" "$s $e | $sum | apply skipped ($([[ "$sum" == "No changes" ]] && echo no-op || echo DRY_RUN))"
        continue
      fi
      o="$(_tf_sweep_make do-provision "$e" "$s")"
      a="$(grep -oE 'Apply complete! Resources: [0-9]+ added, [0-9]+ changed, [0-9]+ destroyed' <<<"$o" | head -1)"
      [[ -n "$a" ]] || { printf '%s\n' "$o" >>"$log"; do_log "FATAL STOP $s $e: apply failed (see $log)"; return 1; }
      _tf_sweep_note "$log" "$s $e | $sum | $a"
    done
  done
  do_log "OK tf sweep done (DRY_RUN=$dry): ${steps[*]}"
}

# _tf_sweep_dry -> prints DRY_RUN (1 default); fails unless it is 0 or 1
_tf_sweep_dry() {
  local d="${DRY_RUN:-1}"
  [[ "$d" == 0 || "$d" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $d" >&2; return 1; }
  printf '%s' "$d"
}

# _tf_sweep_lists <steps array name> <envs array name> <STEPS value>: fills both;
# every step must be a csi-spl-iac src/terraform dir, every env dev or prd.
_tf_sweep_lists() {
  local -n _st="$1" _en="$2"
  local tf_root="$APP_PATH/$(basename "$PROJ_PATH" -orc)-iac/src/terraform" x
  [[ -d "$tf_root" ]] || { do_log "FATAL no terraform steps dir $tf_root"; return 1; }
  if [[ -n "$3" ]]; then
    read -ra _st <<<"$3"
  else
    mapfile -t _st < <(find "$tf_root" -mindepth 1 -maxdepth 1 -type d -name '[0-9][0-9][0-9]-*' -printf '%f\n' | sort)
  fi
  read -ra _en <<<"${ENVS:-dev prd}"
  (( ${#_st[@]} && ${#_en[@]} )) || { do_log "FATAL no steps / envs to sweep"; return 1; }
  for x in "${_st[@]}"; do [[ "$x" =~ ^[0-9]{3}-[a-z0-9-]+$ && -d "$tf_root/$x" ]] || { do_log "FATAL unknown step '$x' (not in $tf_root)"; return 1; }; done
  for x in "${_en[@]}"; do [[ "$x" == dev || "$x" == prd ]] || { do_log "FATAL ENVS may hold dev and prd only, got '$x'"; return 1; }; done
}

# _tf_sweep_log <kind> -> prints a new log path under TF_SWEEP_LOG_DIR
_tf_sweep_log() {
  local d="${TF_SWEEP_LOG_DIR:-$HOME/.local/share/$(basename "$PROJ_PATH" -orc)/tf-sweep}"
  mkdir -p "$d" || return 1
  printf '%s/%s-%s.log' "$d" "$1" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# _tf_sweep_note <log> <msg> -> logs INFO <msg> and appends <msg> to <log>
_tf_sweep_note() { do_log "INFO $2"; printf '%s\n' "$2" >>"$1"; }

# _tf_sweep_make <target> <env> <step> -> the target's output, ANSI stripped.
# TF_SWEEP_MAKE overrides the make binary (tests).
_tf_sweep_make() {
  ENV="$2" STEP="$3" "${TF_SWEEP_MAKE:-make}" -C "$PROJ_PATH" "$1" ENV="$2" STEP="$3" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
}
