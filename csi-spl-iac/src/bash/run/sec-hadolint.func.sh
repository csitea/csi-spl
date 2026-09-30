#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Dockerfile lint (hadolint) for this repo, gate on ERROR level.
# @description Runs a negative control first: a planted Dockerfile hadolint MUST
# @description flag. A tool that reports nothing on it proves nothing and the
# @description action fails closed. Then it lints every Dockerfile in the tree
# @description against .hadolint.yaml (failure-threshold error). A missing tool
# @description fails closed; it is never a skip.
# @param SEC_HADOLINT_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_HADOLINT_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_HADOLINT_CONFIG (optional) - config; default <root>/.hadolint.yaml
# @example ./run -a do_sec_hadolint
#------------------------------------------------------------------------------

_SEC_HADOLINT_VER=2.12.0

_sec_hadolint_root() {
  if [[ -n "${SEC_HADOLINT_ROOT:-}" ]]; then printf '%s\n' "$SEC_HADOLINT_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_HADOLINT_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_hadolint_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

# A Dockerfile every hadolint version flags (unpinned latest tag + ADD of a
# remote url + a cd in RUN). Run with the default threshold so ANY finding is
# non-zero. The directory is removed by the caller.
_sec_hadolint_control_file() {
  local d
  d=$(mktemp -d) || return 1
  cat >"$d/Dockerfile" <<'EOF'
FROM ubuntu:latest
ADD https://example.com/app.tar.gz /app
RUN cd /app && echo build
EOF
  printf '%s\n' "$d"
}

do_sec_hadolint() {
  local bin="${SEC_HADOLINT_BIN:-hadolint}"
  _sec_hadolint_need "$bin" || return 1
  local root cfg ctl rc
  root=$(_sec_hadolint_root) || return 1
  cfg="${SEC_HADOLINT_CONFIG:-$root/.hadolint.yaml}"
  [[ -f "$cfg" ]] || { do_log "FATAL no $cfg -- hadolint default rules alone are not this gate"; return 1; }

  ctl=$(_sec_hadolint_control_file) || return 1
  do_log "INFO hadolint $_SEC_HADOLINT_VER control (want a finding, non-zero exit)"
  rc=0
  SEC_HADOLINT_PHASE=control "$bin" --no-color "$ctl/Dockerfile" >"$ctl/out" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] || ! grep -qE 'DL[0-9]{4}|SC[0-9]{4}' "$ctl/out"; then
    do_log "FATAL control: hadolint reported no finding on a bad Dockerfile (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$ctl/out"
    rm -rf "$ctl"
    return 1
  fi
  rm -rf "$ctl"

  local dfs=()
  while IFS= read -r f; do dfs+=("$f"); done < <(
    find "$root" -path '*/node_modules' -prune -o -path "$root/tpl-gen" -prune \
      -o -path '*/bin/*' -prune \
      -o \( -iname 'Dockerfile' -o -iname 'Dockerfile.*' -o -iname '*.dockerfile' \) -print 2>/dev/null | sort
  )
  if [[ "${#dfs[@]}" -eq 0 ]]; then
    do_log "FATAL no Dockerfile found under $root -- refusing a scan that checks nothing"
    return 1
  fi
  do_log "INFO hadolint --config $cfg on ${#dfs[@]} Dockerfile(s) (gate: error)"
  local log; log=$(mktemp)
  rc=0
  SEC_HADOLINT_PHASE=scan "$bin" --config "$cfg" --no-color "${dfs[@]}" >"$log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    do_log "INFO hadolint: no error-level findings"
    rm -f "$log"
    return 0
  fi
  do_log "FATAL hadolint: error-level findings (or tool error, exit $rc)"
  sed 's/^/  /' "$log"
  rm -f "$log"
  return 1
}
