#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Go SAST (gosec) on the hub module, gate on HIGH severity against a
# @description count-per-(rule,file) baseline (.gosec-baseline.txt). Runs a
# @description negative control first: a planted G404 (weak-rand) module gosec
# @description MUST flag. A tool that reports nothing on it proves nothing and
# @description the action fails closed. Then it scans the hub and fails on any
# @description HIGH finding that exceeds the baseline (a NEW rule, file, or extra
# @description occurrence). Every gosec rule stays active. A missing tool fails
# @description closed; it is never a skip.
# @param SEC_GOSEC_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_GOSEC_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_GOSEC_BASELINE (optional) - baseline file; default <root>/.gosec-baseline.txt
# @param SEC_GOSEC_WRITE_BASELINE (optional) - 1 to rewrite the baseline counts
# @param SEC_GOSEC_GO_FALLBACK (optional) - dir holding go when go is not on PATH;
# @param   default /usr/local/go/bin (sudo's secure_path drops it)
# @example ./run -a do_sec_gosec
#------------------------------------------------------------------------------

_SEC_GOSEC_VER=2.22.4

# shellcheck source=../../../lib/bash/funcs/sec-baseline.func.sh
declare -F _sec_baseline_gate >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/sec-baseline.func.sh"

_sec_gosec_root() {
  if [[ -n "${SEC_GOSEC_ROOT:-}" ]]; then printf '%s\n' "$SEC_GOSEC_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_GOSEC_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

_sec_gosec_need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  do_log "FATAL $1 is not on PATH -- the scan proved nothing"
  return 1
}

# gosec loads packages through the go toolchain: without go on PATH it reports
# nothing (control issues=-1). Put go on PATH from the fallback dir, or refuse.
_sec_gosec_go() {
  command -v go >/dev/null 2>&1 && return 0
  local fb="${SEC_GOSEC_GO_FALLBACK:-/usr/local/go/bin}"
  if [[ -x "$fb/go" ]]; then
    export PATH="$fb:$PATH"
    do_log "INFO go is not on PATH -- using $fb/go"
    return 0
  fi
  do_log "FATAL go is not on PATH and not at $fb/go -- gosec cannot load packages; install go or set SEC_GOSEC_GO_FALLBACK"
  return 1
}

# A bare gosec name that is not on PATH resolves to $(go env GOPATH)/bin, where
# 'go install' puts it. Prints the command to run.
_sec_gosec_bin() {
  local bin="$1" gp
  if [[ "$bin" != */* ]] && ! command -v "$bin" >/dev/null 2>&1; then
    gp=$(go env GOPATH 2>/dev/null) || gp=""
    [[ -n "$gp" && -x "$gp/bin/$bin" ]] && bin="$gp/bin/$bin"
  fi
  printf '%s\n' "$bin"
}

# A minimal buildable module gosec flags with G404 (weak rng), HIGH severity.
_sec_gosec_control_dir() {
  local d
  d=$(mktemp -d) || return 1
  cat >"$d/go.mod" <<'EOF'
module example.com/gosec-control

go 1.21
EOF
  cat >"$d/main.go" <<'EOF'
package main

import "math/rand"

func main() {
	token := rand.Intn(1000000)
	_ = token
}
EOF
  printf '%s\n' "$d"
}

do_sec_gosec() {
  _sec_gosec_go || return 1
  local bin
  bin=$(_sec_gosec_bin "${SEC_GOSEC_BIN:-gosec}")
  _sec_gosec_need "$bin" || return 1
  local root mod baseline ctl rc
  root=$(_sec_gosec_root) || return 1
  mod="$root/csi-spl-api/src/go/spool-hub-api"
  [[ -f "$mod/go.mod" ]] || { do_log "FATAL no go.mod at $mod"; return 1; }
  baseline="${SEC_GOSEC_BASELINE:-$root/.gosec-baseline.txt}"
  [[ -f "$baseline" ]] || { do_log "FATAL no $baseline -- gosec without a baseline is not this gate"; return 1; }

  # --- control: gosec must report a finding on a planted G404 module ---------
  ctl=$(_sec_gosec_control_dir) || return 1
  do_log "INFO gosec $_SEC_GOSEC_VER control (want a G404 finding)"
  rc=0
  SEC_GOSEC_PHASE=control "$bin" -fmt=json -quiet -severity high "$ctl/..." >"$ctl/out.json" 2>/dev/null || rc=$?
  local n
  n=$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("Issues",[])))
except Exception: print(-1)' "$ctl/out.json" 2>/dev/null)
  rm -rf "$ctl"
  if [[ "$n" -lt 1 ]]; then
    do_log "FATAL control: gosec reported no finding on a planted G404 module (issues=$n) -- the check proved nothing"
    return 1
  fi

  # --- scan: gosec on the hub, HIGH severity, JSON --------------------------
  local out; out=$(mktemp)
  do_log "INFO gosec -severity high on $mod"
  ( cd "$mod" && SEC_GOSEC_PHASE=scan "$bin" -fmt=json -quiet -severity high ./... ) >"$out" 2>/dev/null || true
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
    do_log "FATAL gosec produced no parseable JSON -- the scan proved nothing (tool/build error)"
    rm -f "$out"
    return 1
  fi

  local counts; counts=$(mktemp)
  python3 - "$out" >"$counts" <<'PY'
import json,sys,collections
cur=collections.Counter()
for i in json.load(open(sys.argv[1])).get("Issues",[]):
    cur[(i["rule_id"],i["file"].split("spool-hub-api/")[-1])]+=1
for (rule,rel),n in sorted(cur.items()): print(f"{rule}|{rel}|{n}")
PY
  rm -f "$out"
  rc=0
  if [[ "${SEC_GOSEC_WRITE_BASELINE:-0}" == 1 ]]; then
    _sec_baseline_write "$counts" "$baseline" || rc=1
  else
    _sec_baseline_gate "gosec high-severity" "$counts" "$baseline" || rc=1
  fi
  rm -f "$counts"
  return "$rc"
}
