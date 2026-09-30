#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description actionlint over .github/workflows for this repo. Runs a negative
# @description control first: a planted workflow with a real error (a job that
# @description `needs:` a non-existent job) MUST be flagged. A tool that reports
# @description nothing on it proves nothing and the action fails closed. Then it
# @description lints every workflow file; any finding is non-zero. A missing
# @description tool fails closed; it is never a skip.
# @param SEC_ACTIONLINT_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_ACTIONLINT_BIN (optional) - override the tool, used by the hermetic test
# @example ./run -a do_sec_actionlint
#------------------------------------------------------------------------------

_SEC_ACTIONLINT_VER=1.7.7

_sec_actionlint_root() {
  if [[ -n "${SEC_ACTIONLINT_ROOT:-}" ]]; then printf '%s\n' "$SEC_ACTIONLINT_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_ACTIONLINT_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_actionlint_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

# A workflow every actionlint version flags: a job that needs a job that does
# not exist. The directory is removed by the caller.
_sec_actionlint_control_dir() {
  local d
  d=$(mktemp -d) || return 1
  mkdir -p "$d/.github/workflows"
  cat >"$d/.github/workflows/bad.yml" <<'EOF'
name: bad
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    needs: [does-not-exist]
    steps:
      - run: echo hi
EOF
  printf '%s\n' "$d"
}

do_sec_actionlint() {
  local bin="${SEC_ACTIONLINT_BIN:-actionlint}"
  _sec_actionlint_need "$bin" || return 1
  local root ctl rc
  root=$(_sec_actionlint_root) || return 1
  [[ -d "$root/.github/workflows" ]] || { do_log "FATAL no $root/.github/workflows -- nothing to lint"; return 1; }

  ctl=$(_sec_actionlint_control_dir) || return 1
  do_log "INFO actionlint $_SEC_ACTIONLINT_VER control (want a finding, non-zero exit)"
  rc=0
  ( cd "$ctl" && SEC_ACTIONLINT_PHASE=control "$bin" -no-color ) >"$ctl/out" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] || ! grep -qiE 'needs|does-not-exist|error' "$ctl/out"; then
    do_log "FATAL control: actionlint reported no finding on a broken workflow (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$ctl/out"
    rm -rf "$ctl"
    return 1
  fi
  rm -rf "$ctl"

  do_log "INFO actionlint on $root/.github/workflows"
  local log; log=$(mktemp)
  rc=0
  ( cd "$root" && SEC_ACTIONLINT_PHASE=scan "$bin" -no-color ) >"$log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    do_log "INFO actionlint: no findings"
    rm -f "$log"
    return 0
  fi
  do_log "FATAL actionlint: findings (exit $rc)"
  sed 's/^/  /' "$log"
  rm -f "$log"
  return 1
}
