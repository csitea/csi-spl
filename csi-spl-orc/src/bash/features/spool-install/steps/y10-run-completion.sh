#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step (spec 069 lane Y10): ./run tab completion from csi-spl.
#
#   spl_install_run_completion <orc-dir> <rc-file> <dry 0|1>
#
# Makes <rc-file> (install.sh passes ~/.bashrc) source
# <orc-dir>/lib/bash/completions/run.completion.bash through ONE marked line.
# The first active line that sources any other run.completion.bash (the frozen
# engine's, a moved checkout's) is replaced by it in place; every further one
# is dropped, so the shell registers one completion. Commented lines are left
# alone. With none present the line is appended (the file is created).
# Idempotent: a current file is not rewritten. The first rewrite keeps the
# original as <rc-file>.bak-spool-install. A symlinked rc is written through.
# Dry run prints the unified diff and changes nothing.
# SPOOL_INSTALL_COMPLETION=0 skips the step.
# Returns 0, or 7 when the rc cannot be written.
#------------------------------------------------------------------------------
spl_install_run_completion() {
  local orc="$1" rc="$2" dry="${3:-0}" mark="# csi-spl: run completion (spec 069 Y10)"
  local src="$orc/lib/bash/completions/run.completion.bash" want new
  if [ "${SPOOL_INSTALL_COMPLETION:-1}" = 0 ]; then
    echo "spool-install: run completion: skipped (SPOOL_INSTALL_COMPLETION=0)" >&2
    return 0
  fi
  want="[ -r \"$src\" ] && . \"$src\"  $mark"
  new="$(mktemp)" || return 7
  { if [ -e "$rc" ]; then cat "$rc"; fi; } | awk -v want="$want" -v mark="$mark" '
    index($0, mark) || ($0 !~ /^[[:space:]]*#/ && index($0, "run.completion.bash")) {
      if (!done) print want
      done = 1
      next
    }
    { print }
    END { if (!done) print want }
  ' >"$new" || { rm -f "$new"; return 7; }
  if [ -e "$rc" ] && cmp -s "$new" "$rc"; then
    rm -f "$new"
    echo "spool-install: run completion: $rc already current" >&2
    return 0
  fi
  if [ "$dry" = 1 ]; then
    echo "would: make $rc source $src (diff below)"
    if [ -e "$rc" ]; then diff -u "$rc" "$new"; else diff -u /dev/null "$new"; fi
    rm -f "$new"
    return 0
  fi
  if [ -e "$rc" ] && [ ! -e "$rc.bak-spool-install" ]; then
    cp -p "$rc" "$rc.bak-spool-install" || { rm -f "$new"; return 7; }
  fi
  # cat > keeps the file's mode and owner and writes through a symlink.
  cat "$new" >"$rc" || { rm -f "$new"; return 7; }
  rm -f "$new"
  echo "spool-install: run completion: $rc sources $src" >&2
}
