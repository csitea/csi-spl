#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2866 (prd incident 2026-10-22) -- the hub's view limit
#          (cnf env.hub.env.SPOOL_HUB_VIEW_TIMEOUT) is set and frees the pool
#          before sign-in gives up:
#            - it is > 0 in dev and prd (0 = no limit, the incident's state);
#            - the limit plus the request context's grace (viewDeadlineGrace,
#              view_deadline.go) is under the sign-in budget (native.go ctx),
#              so a view cut at its limit hands its connection back while a
#              sign-in queued behind it is still waiting;
#            - the rendered dev and prd 030 tfvars carry the cnf value.
#          CONTROLS: 0 (off) is refused; 9 s (9 + 1 = the 10 s sign-in
#          budget) is refused; 5 s passes.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
CNF="$PROJ_ROOT/../csi-spl-cnf/csi-spl"
HUB_GO="$PROJ_ROOT/../csi-spl-api/src/go/spool-hub-api/internal"

# secs <go duration: 5s | 2m | 1h> -> whole seconds ("" when unparsable)
secs() {
  case "$1" in
    *ms) echo "" ;;
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "" ;;
  esac
}

# fits <view s> <grace s> <sign-in s> -> 0 when the limit meets the rule
fits() {
  local v="$1" g="$2" s="$3"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 && v + g < s ))
}

signin="$(sed -nE 's/.*context\.WithTimeout\(r\.Context\(\), ([0-9]+)\*time\.Second\).*/\1/p' "$HUB_GO/auth/native.go" | sed -n 1p)"
[[ -n "$signin" ]] && pass "sign-in budget (native.go ctx) is ${signin}s" || fail "no N*time.Second sign-in ctx in native.go"
grace_raw="$(sed -nE 's/^const viewDeadlineGrace = (.*)$/\1/p' "$HUB_GO/hub/view_deadline.go")"
case "$grace_raw" in
  time.Second) grace=1 ;;
  [0-9]*' * time.Second') grace="${grace_raw%% *}" ;;
  *) grace="" ;;
esac
[[ -n "$grace" ]] && pass "viewDeadlineGrace is ${grace}s" || fail "viewDeadlineGrace '$grace_raw' unreadable in view_deadline.go"

for env in dev prd; do
  raw="$(yq -r '.env.hub.env.SPOOL_HUB_VIEW_TIMEOUT // ""' "$CNF/all.env.yaml")"
  o="$(yq -r '.env.hub.env.SPOOL_HUB_VIEW_TIMEOUT // ""' "$CNF/$env.env.yaml")"
  [[ -n "$o" && "$o" != null ]] && raw="$o"
  v="$(secs "$raw")"
  fits "${v:-0}" "${grace:-1}" "${signin:-0}" && pass "$env view limit $raw: > 0 and + ${grace}s grace < ${signin}s sign-in" \
    || fail "$env view limit '$raw': needs > 0 and + ${grace}s grace < the ${signin}s sign-in budget"
  r="$(sed -nE 's/^environment_variables[[:space:]]*=[[:space:]]*//p' "$CNF/$env/tf/030-cloud-run-hub.vars.tfvars" |
    python3 -c 'import json,sys; print(json.loads(sys.stdin.read() or "{}").get("SPOOL_HUB_VIEW_TIMEOUT", ""))')"
  [[ "$r" == "$raw" ]] && pass "$env rendered 030 tfvars SPOOL_HUB_VIEW_TIMEOUT = $r" \
    || fail "$env rendered 030 tfvars SPOOL_HUB_VIEW_TIMEOUT '$r' != cnf '$raw' (ENV=$env ./run -a do_tpl_gen)"
done

fits 0 1 10 && fail "CONTROL 0 (no limit) passed" || pass "CONTROL 0 (no limit) is refused"
fits 9 1 10 && fail "CONTROL 9 s (+ 1 s = the 10 s sign-in budget) passed" || pass "CONTROL 9 s breaks the sign-in bound"
fits 5 1 10 && pass "CONTROL 5 s passes" || fail "CONTROL 5 s refused"

[[ $fails -eq 0 ]] && echo "PASS: all hub-view-timeout-030.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
