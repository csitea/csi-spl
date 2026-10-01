#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description actionlint over .github/workflows for this repo. Runs a negative
# @description control first: a planted workflow with a real error (a job that
# @description `needs:` a non-existent job) MUST be flagged. A tool that reports
# @description nothing on it proves nothing and the action fails closed. Then it
# @description lints every workflow file; any finding is non-zero. A second
# @description control proves the shellcheck leg on run: blocks ran (actionlint
# @description skips it SILENTLY when shellcheck is not on PATH). A missing
# @description tool fails closed; it is never a skip.
# @param SEC_ACTIONLINT_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_ACTIONLINT_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_ACTIONLINT_FILES (optional) - newline list of root-relative workflow files
# @param        to lint INSTEAD of every workflow (the pre-push lint part)
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
  # Second control, for the run: blocks: actionlint runs shellcheck ONLY when the
  # binary is on PATH, and skips it silently otherwise (exit 0, no output),
  # so a box without shellcheck read a wf85 red as green. This error-level
  # SC2144 must come back as a shellcheck finding.
  cat >"$d/.github/workflows/sc.yml" <<'EOF'
name: sc
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: if [ -f *.log ]; then echo has-log; fi
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
  # Lint the planted file explicitly: actionlint's bare auto-discovery needs a
  # git project in a parent dir and exits 3 ("no project was found") in a bare
  # temp dir, which is a tool error, not a finding. An explicit path lints the
  # file and exits 1 on the job-needs error, which is the finding the control wants.
  SEC_ACTIONLINT_PHASE=control "$bin" -no-color "$ctl/.github/workflows/bad.yml" >"$ctl/out" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] || ! grep -qiE 'needs|does-not-exist|error' "$ctl/out"; then
    do_log "FATAL control: actionlint reported no finding on a broken workflow (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$ctl/out"
    rm -rf "$ctl"
    return 1
  fi
  rc=0
  SEC_ACTIONLINT_PHASE=control-shellcheck "$bin" -no-color "$ctl/.github/workflows/sc.yml" >"$ctl/out" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] || ! grep -qE 'shellcheck|SC2144' "$ctl/out"; then
    do_log "FATAL control: actionlint did not run shellcheck on a run: block (exit $rc) -- is shellcheck on PATH? the run: scripts would go unchecked"
    sed 's/^/  /' "$ctl/out"
    rm -rf "$ctl"
    return 1
  fi
  rm -rf "$ctl"

  do_log "INFO actionlint on $root/.github/workflows"
  local log; log=$(mktemp)
  rc=0
  # actionlint shells out to shellcheck for each `run:` block. Exclude the pure
  # style/info codes that are noise in CI step scripts: SC2015 (A && B || C is
  # not if-then-else, info), SC2034 (a `for i in` counter read as "unused",
  # warning), SC2001 (sed vs ${v//}, style). All actionlint-native checks and
  # the security-relevant shellcheck codes (injection SC2086, etc.) still fail
  # the gate. Override with SEC_ACTIONLINT_SHELLCHECK_OPTS.
  local sc_opts="${SEC_ACTIONLINT_SHELLCHECK_OPTS:--e SC2015 -e SC2034 -e SC2001}"
  local files=() f
  if [[ -n "${SEC_ACTIONLINT_FILES:-}" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done <<<"$SEC_ACTIONLINT_FILES"
  fi
  ( cd "$root" && SEC_ACTIONLINT_PHASE=scan SHELLCHECK_OPTS="$sc_opts" "$bin" -no-color "${files[@]}" ) >"$log" 2>&1 || rc=$?
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
