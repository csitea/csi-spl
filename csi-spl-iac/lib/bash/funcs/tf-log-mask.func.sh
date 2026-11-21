#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description A stdin-to-stdout filter for terraform output: every billing
# @description account id (XXXXXX-XXXXXX-XXXXXX, hex) keeps only its last 4
# @description chars (XXXXXX-XXXXXX-XX<last 4>). do_tf_apply, do_tf_destroy
# @description and their target / local-bucket twins pipe terraform through it
# @description before their tee, so stdout and the tf_*.log get the masked text
# @description (SPL-5797: a step-002 apply left the full id 9 times in its log).
# @description Unbuffered (sed -u): terraform's progress still streams.
# @example terraform apply 2>&1 | do_tf_log_mask | tee -a "$log"
#------------------------------------------------------------------------------
do_tf_log_mask() {
  sed -u -E 's/[0-9A-Fa-f]{6}-[0-9A-Fa-f]{6}-[0-9A-Fa-f]{2}([0-9A-Fa-f]{4})/XXXXXX-XXXXXX-XX\1/g'
}

#------------------------------------------------------------------------------
# @description Create a terraform log 0640 before the first `tee -a` writes it,
# @description and lower one that already exists (SPL-5822): with the caller's
# @description umask (0002 on the boxes) tee made dat/log/tf_*.log 0664, so
# @description every local user read terraform's output and output values.
# @description The file is born under umask 027, so it is never briefly 0664.
# @example do_tf_log_open "$tf_apply_log_fle" || return 1
#------------------------------------------------------------------------------
do_tf_log_open() {
  [[ -n "${1:-}" ]] || { echo "do_tf_log_open: the log file" >&2; return 1; }
  local f="$1"
  mkdir -p "${f%/*}" && (umask 027 && : >>"$f") && chmod 0640 "$f"
}
