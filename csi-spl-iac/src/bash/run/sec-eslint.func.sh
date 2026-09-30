#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description JS security lint (eslint + eslint-plugin-security) over the WUI
# @description plain-JS (.mjs/.js), gated against .eslint-security-baseline.txt
# @description (count per rule+file) so only NEW findings fail. Runs a negative
# @description control first: a planted eval() eslint MUST flag
# @description (detect-eval-with-expression). A tool that reports nothing on it
# @description proves nothing and the action fails closed. A missing tool fails
# @description closed; it is never a skip.
# @param SEC_ESLINT_ROOT (optional) - repo root; default the parent of APP_PATH
# @param SEC_ESLINT_DIR (optional) - dir holding node_modules (real eslint); the
# @param        config is copied beside it so eslint-plugin-security resolves
# @param SEC_ESLINT_BIN (optional) - override the tool, used by the hermetic test
# @param SEC_ESLINT_CONFIG SEC_ESLINT_BASELINE SEC_ESLINT_DIRS (optional)
# @example SEC_ESLINT_DIR=/tmp/es ./run -a do_sec_eslint
#------------------------------------------------------------------------------

_sec_eslint_root() {
  if [[ -n "${SEC_ESLINT_ROOT:-}" ]]; then printf '%s\n' "$SEC_ESLINT_ROOT"; return 0; fi
  local base="${APP_PATH:-}"
  if [[ -n "$base" && -f "$base/../csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then (cd "$base/.." && pwd); return 0; fi
  if [[ -n "$base" && -f "$base/csi-spl-api/src/go/spool-hub-api/go.mod" ]]; then printf '%s\n' "$base"; return 0; fi
  do_log "FATAL SEC_ESLINT_ROOT is unset and APP_PATH is not the csi-spl tree"
  return 1
}

do_sec_eslint() {
  local root cfg baseline bin
  root=$(_sec_eslint_root) || return 1
  cfg="${SEC_ESLINT_CONFIG:-$root/.eslint-security.config.mjs}"
  baseline="${SEC_ESLINT_BASELINE:-$root/.eslint-security-baseline.txt}"
  [[ -f "$cfg" ]] || { do_log "FATAL no $cfg -- eslint without the security config is not this gate"; return 1; }
  [[ -f "$baseline" ]] || { do_log "FATAL no $baseline -- eslint without a baseline is not this gate"; return 1; }

  bin="${SEC_ESLINT_BIN:-}"
  if [[ -z "$bin" ]]; then
    [[ -n "${SEC_ESLINT_DIR:-}" && -x "$SEC_ESLINT_DIR/node_modules/.bin/eslint" ]] \
      || { do_log "FATAL eslint not found (set SEC_ESLINT_DIR to a dir with node_modules/.bin/eslint) -- the scan proved nothing"; return 1; }
    bin="$SEC_ESLINT_DIR/node_modules/.bin/eslint"
    # eslint-plugin-security is imported by the flat config; place the config
    # beside node_modules so Node resolves it.
    cp "$cfg" "$SEC_ESLINT_DIR/eslint.config.mjs"
    cfg="$SEC_ESLINT_DIR/eslint.config.mjs"
  fi

  # --- control: eslint must flag a planted eval() ---------------------------
  local ctl; ctl=$(mktemp -d)
  printf 'export function f(x){ return eval(x); }\n' >"$ctl/bad.mjs"
  do_log "INFO eslint-plugin-security control (want detect-eval-with-expression)"
  local n
  n=$(SEC_ESLINT_PHASE=control "$bin" --no-config-lookup -c "$cfg" -f json "$ctl/bad.mjs" 2>/dev/null \
      | python3 -c 'import json,sys
try: print(sum(len(f.get("messages",[])) for f in json.load(sys.stdin)))
except Exception: print(-1)')
  rm -rf "$ctl"
  if [[ "${n:-0}" -lt 1 ]]; then
    do_log "FATAL control: eslint flagged nothing on a planted eval (messages=${n:-0}) -- the check proved nothing"
    return 1
  fi

  # --- scan: the WUI .mjs/.js ------------------------------------------------
  local dirs="${SEC_ESLINT_DIRS:-csi-spl-wui/src}"
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(
    cd "$root" && find $dirs -type f \( -name '*.mjs' -o -name '*.js' \) 2>/dev/null | grep -v '/node_modules/' | sort
  )
  if [[ "${#files[@]}" -eq 0 ]]; then
    do_log "FATAL no .mjs/.js under $dirs -- refusing a scan that checks nothing"
    return 1
  fi
  local out; out=$(mktemp)
  do_log "INFO eslint-plugin-security on ${#files[@]} WUI JS file(s)"
  ( cd "$root" && SEC_ESLINT_PHASE=scan "$bin" --no-config-lookup -c "$cfg" -f json "${files[@]}" ) >"$out" 2>/dev/null || true
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out" 2>/dev/null; then
    do_log "FATAL eslint produced no parseable JSON -- the scan proved nothing"
    rm -f "$out"; return 1
  fi

  local newf; newf=$(python3 - "$out" "$baseline" "$root" <<'PY'
import json,sys,collections
data=json.load(open(sys.argv[1])); bl=sys.argv[2]; root=sys.argv[3].rstrip("/")+"/"
base=collections.Counter()
for line in open(bl):
    line=line.strip()
    if not line or line.startswith("#"): continue
    p=line.split("|")
    if len(p)>=3: base[(p[0],p[1])]=int(p[2])
cur=collections.Counter()
for f in data:
    fp=f.get("filePath","")
    rel=fp[len(root):] if fp.startswith(root) else fp
    for m in f.get("messages",[]):
        if m.get("ruleId"): cur[(m["ruleId"],rel)]+=1
new=[]
for k,n in sorted(cur.items()):
    if n>base.get(k,0): new.append(f"{k[0]} {k[1]}: {n} found, {base.get(k,0)} baselined")
print("\n".join(new))
PY
)
  if [[ -n "$newf" ]]; then
    do_log "FATAL eslint-plugin-security: NEW finding(s) beyond the baseline:"
    printf '%s\n' "$newf" | sed 's/^/  /'
    rm -f "$out"; return 1
  fi
  do_log "INFO eslint-plugin-security: no new findings (baseline holds)"
  rm -f "$out"
  return 0
}
