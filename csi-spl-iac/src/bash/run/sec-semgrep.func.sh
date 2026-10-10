#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description SAST (Semgrep) over the hub Go + WUI TS trees with the
# @description p/golang + p/javascript + p/owasp-top-ten rulesets, gated against
# @description .semgrep-baseline.txt (count per rule+file) so only NEW findings
# @description fail. Runs a negative control first: a planted eval() Semgrep MUST
# @description flag with a local rule. A tool that reports nothing on it proves
# @description nothing and the action fails closed. A missing tool fails closed.
# @param SEC_SEMGREP_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_SEMGREP_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_SEMGREP_BASELINE (optional) - baseline; default <root>/.semgrep-baseline.txt
# @param SEC_SEMGREP_DIRS (optional) - scan dirs (root-relative)
# @param SEC_SEMGREP_CONFIG (optional) - semgrep --config args; default the p/ rulesets
# @param SEC_SEMGREP_WRITE_BASELINE (optional) - 1 to rewrite the baseline counts
# @example ./run -a do_sec_semgrep
#------------------------------------------------------------------------------

_SEC_SEMGREP_VER=1.178.0

# shellcheck source=../../../lib/bash/funcs/sec-baseline.func.sh
declare -F _sec_baseline_gate >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/sec-baseline.func.sh"

_sec_semgrep_root() {
  if [[ -n "${SEC_SEMGREP_ROOT:-}" ]]; then printf '%s\n' "$SEC_SEMGREP_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_SEMGREP_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_semgrep_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

do_sec_semgrep() {
  local bin="${SEC_SEMGREP_BIN:-semgrep}"
  _sec_semgrep_need "$bin" || return 1
  local root baseline
  root=$(_sec_semgrep_root) || return 1
  baseline="${SEC_SEMGREP_BASELINE:-$root/.semgrep-baseline.txt}"
  [[ -f "$baseline" ]] || { do_log "FATAL no $baseline -- semgrep without a baseline is not this gate"; return 1; }

  # --- control: a local rule that must flag a planted eval() -----------------
  local ctl; ctl=$(mktemp -d)
  cat >"$ctl/rule.yaml" <<'EOF'
rules:
  - id: control-eval
    patterns:
      - pattern: eval(...)
    message: control eval
    languages: [javascript]
    severity: ERROR
EOF
  printf 'function f(x){ return eval(x); }\n' >"$ctl/bad.js"
  do_log "INFO semgrep $_SEC_SEMGREP_VER control (want a finding on a planted eval)"
  local n
  n=$(SEC_SEMGREP_PHASE=control "$bin" scan --config "$ctl/rule.yaml" --metrics=off --quiet --json "$ctl/bad.js" 2>/dev/null \
      | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("results",[])))
except Exception: print(-1)')
  rm -rf "$ctl"
  if [[ "${n:-0}" -lt 1 ]]; then
    do_log "FATAL control: semgrep flagged nothing on a planted eval (results=${n:-0}) -- the check proved nothing"
    return 1
  fi

  # --- scan: the p/ rulesets over the code, JSON -----------------------------
  local dirs="${SEC_SEMGREP_DIRS:-csi-spl-api/src/go/spool-hub-api csi-spl-wui/src}"
  local cfg="${SEC_SEMGREP_CONFIG:---config p/golang --config p/javascript --config p/owasp-top-ten}"
  local out; out=$(mktemp)
  do_log "INFO semgrep scan ($cfg) on: $dirs"
  # shellcheck disable=SC2086
  ( cd "$root" && SEC_SEMGREP_PHASE=scan "$bin" scan $cfg --metrics=off --quiet --json $dirs ) >"$out" 2>/dev/null || true
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
    do_log "FATAL semgrep produced no parseable JSON -- the scan proved nothing (tool/network error)"
    rm -f "$out"
    return 1
  fi

  local counts rc=0; counts=$(mktemp)
  python3 - "$out" "$root" >"$counts" <<'PY'
import json,sys,collections
root=sys.argv[2].rstrip("/")+"/"
cur=collections.Counter()
for i in json.load(open(sys.argv[1])).get("results",[]):
    p=i["path"]; p=p[len(root):] if p.startswith(root) else p.lstrip("./")
    cur[(i["check_id"],p)]+=1
for (rule,p),n in sorted(cur.items()): print(f"{rule}|{p}|{n}")
PY
  rm -f "$out"
  if [[ "${SEC_SEMGREP_WRITE_BASELINE:-0}" == 1 ]]; then
    _sec_baseline_write "$counts" "$baseline" || rc=1
  else
    # shellcheck disable=SC2086
    _sec_baseline_gate semgrep "$counts" "$baseline" $dirs || rc=1
  fi
  rm -f "$counts"
  return "$rc"
}
