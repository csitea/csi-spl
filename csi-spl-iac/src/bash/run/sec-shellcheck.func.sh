#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Bash static analysis (shellcheck) for this repo's shell, gate on
# @description ERROR level. Runs a negative control first: a planted broken
# @description script shellcheck MUST flag. A tool that reports nothing on it
# @description proves nothing and the action fails closed. Then it scans every
# @description *.sh under the iac + orc + cnf bash trees at severity error.
# @description A missing tool fails closed; it is never a skip.
# @param SEC_SHELLCHECK_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_SHELLCHECK_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_SHELLCHECK_SEVERITY (optional) - default error
# @param SEC_SHELLCHECK_FILES (optional) - newline list of root-relative *.sh to scan
# @param        INSTEAD of the whole tree (the pre-push lint part: touched files only)
# @example ./run -a do_sec_shellcheck
#------------------------------------------------------------------------------

_SEC_SHELLCHECK_VER=0.10.0

_sec_shellcheck_root() {
  if [[ -n "${SEC_SHELLCHECK_ROOT:-}" ]]; then printf '%s\n' "$SEC_SHELLCHECK_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_SHELLCHECK_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_shellcheck_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

# A script shellcheck flags at error level regardless of version: `-f` with a
# glob (SC2144). Directory removed by the caller.
_sec_shellcheck_control_dir() {
  local d
  d=$(mktemp -d) || return 1
  cat >"$d/bad.sh" <<'EOF'
#!/bin/bash
if [ -f *.log ]; then
  echo has-log
fi
EOF
  printf '%s\n' "$d"
}

do_sec_shellcheck() {
  local bin="${SEC_SHELLCHECK_BIN:-shellcheck}"
  _sec_shellcheck_need "$bin" || return 1
  local root sev ctl rc
  root=$(_sec_shellcheck_root) || return 1
  sev="${SEC_SHELLCHECK_SEVERITY:-error}"

  ctl=$(_sec_shellcheck_control_dir) || return 1
  do_log "INFO shellcheck $_SEC_SHELLCHECK_VER control (want a finding at -S $sev, non-zero)"
  rc=0
  SEC_SHELLCHECK_PHASE=control "$bin" -S "$sev" -f gcc "$ctl/bad.sh" >"$ctl/out" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]] || ! grep -qE 'SC[0-9]{4}' "$ctl/out"; then
    do_log "FATAL control: shellcheck reported nothing on a broken script (exit $rc) -- the check proved nothing"
    sed 's/^/  /' "$ctl/out"
    rm -rf "$ctl"
    return 1
  fi
  rm -rf "$ctl"

  # Scope: the bash the owner named -- "every bash action" -- plus its libs and
  # tests under iac + orc + cnf. The hub (csi-spl-api) bash is the hub lane's;
  # extending shellcheck there is a follow-up (coordination + one SC2144 there).
  local scan_dirs=() d
  for d in \
    "$root/csi-spl-iac/src/bash" "$root/csi-spl-iac/lib/bash" \
    "$root/csi-spl-orc/src/bash" "$root/csi-spl-orc/lib/bash" \
    "$root/csi-spl-cnf/src/bash"; do
    [[ -d "$d" ]] && scan_dirs+=("$d")
  done
  if [[ "${#scan_dirs[@]}" -eq 0 ]]; then
    do_log "FATAL no bash tree found under $root -- refusing a scan that checks nothing"
    return 1
  fi

  local files=() f
  if [[ -n "${SEC_SHELLCHECK_FILES:-}" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$root/$f"); done <<<"$SEC_SHELLCHECK_FILES"
  else
    while IFS= read -r f; do files+=("$f"); done < <(
      find "${scan_dirs[@]}" -type f -name '*.sh' 2>/dev/null | grep -v '/node_modules/' | sort
    )
  fi
  if [[ "${#files[@]}" -eq 0 ]]; then
    do_log "FATAL no *.sh found under the bash trees -- refusing a scan that checks nothing"
    return 1
  fi

  do_log "INFO shellcheck -S $sev on ${#files[@]} script(s) (iac + orc + cnf)"
  local log; log=$(mktemp)
  rc=0
  SEC_SHELLCHECK_PHASE=scan "$bin" -S "$sev" -f gcc "${files[@]}" >"$log" 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    do_log "INFO shellcheck: no $sev-level findings"
    rm -f "$log"
    return 0
  fi
  do_log "FATAL shellcheck: $sev-level findings (or tool error, exit $rc)"
  sed 's/^/  /' "$log"
  rm -f "$log"
  return 1
}
