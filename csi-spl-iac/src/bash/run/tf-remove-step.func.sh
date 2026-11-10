#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description Remove all files of a given step: src/terraform/<STEP>* and its
# @description tf templates src/tpl/%org%-%app%/%env%/tf/<STEP>*, relative to
# @description the cwd (the ./run root). A step is matched exactly:
# @description <STEP>, <STEP>.*, <STEP>-remote-bucket, <STEP>-remote-bucket.*
# @description (STEP=05 is not 050-gcs-files).
# @description A dry run unless DRY_RUN=0: by default it lists the paths that
# @description would go and removes nothing. A set that matches nothing is
# @description named in a WARNING and the other set still goes; when neither
# @description matches, it refuses (non-zero) and removes nothing.
# @param STEP - required; an empty STEP would match every step
# @param DRY_RUN 1 (default) lists only, 0 removes
# @example STEP=007-dns DRY_RUN=0 ./run -a do_tf_remove_step
#------------------------------------------------------------------------------
do_tf_remove_step() {
  local step="${STEP:?STEP must be set}" dry_run="${DRY_RUN:-1}"
  local tf_dir='src/terraform' tpl_dir
  local tf_paths=() tpl_paths=()
  tpl_dir=$(tf_step_tpl_dir)
  mapfile -t tf_paths < <(tf_step_paths "${tf_dir}" "${step}")
  mapfile -t tpl_paths < <(tf_step_paths "${tpl_dir}" "${step}")

  if ((${#tf_paths[@]} + ${#tpl_paths[@]} == 0)); then
    do_log "FATAL nothing of step ${step} under ${tf_dir} or ${tpl_dir}; nothing removed"
    return 1
  fi
  ((${#tf_paths[@]})) || do_log "WARNING no ${tf_dir}/${step}* to remove; only the templates go"
  ((${#tpl_paths[@]})) || do_log "WARNING no ${tpl_dir}/${step}* to remove; only the terraform dirs go"

  if [[ "${dry_run}" != 0 ]]; then
    do_log "INFO DRY_RUN: would remove step ${step}:"
    printf '%s\n' "${tf_paths[@]}" "${tpl_paths[@]}"
    do_log "INFO DRY_RUN: nothing removed; DRY_RUN=0 removes"
    return 0
  fi

  do_log "WARNING removing ALL files from step ${step} permanently in 5 seconds"
  sleep 5

  rm -rv "${tf_paths[@]}" "${tpl_paths[@]}"
}

# tf_step_tpl_dir: the one dir of the step tfvars templates, relative to the
# iac root; do_tf_new_step writes and checks it, do_tf_remove_step removes
# from it (SPL-5243).
tf_step_tpl_dir() { echo 'src/tpl/%org%-%app%/%env%/tf'; }

# tf_step_paths <dir> <step>: the paths of exactly that step under <dir>, one
# per line: <step>, <step>.*, <step>-remote-bucket, <step>-remote-bucket.*.
# Not a prefix glob: STEP=05 would otherwise match 050-gcs-files.
tf_step_paths() {
  local d="$1" s="$2" p
  for p in "$d/$s" "$d/$s".* "$d/$s-remote-bucket" "$d/$s-remote-bucket".*; do
    [[ -e "$p" ]] && echo "$p"
  done
  return 0
}
