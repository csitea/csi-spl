#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2252 (Cloud Run radar step 7) -- the hub's request timeout sits
#          between the hub's socket max life and an hour:
#            - at least 2 x SPOOL_HUB_WS_MAX_LIFE (cnf, else the config.go
#              default), so Cloud Run never cuts a healthy socket before the
#              hub's own 1012 max_life close (SPL-1981) does;
#            - at most 900 s, so a request the hub never answers (the stuck
#              prd instance of 2026-10-16 held 1751 of them for 3600 s) frees
#              its instance and its concurrency slot within 15 minutes;
#            - the rendered dev and prd 030 tfvars carry the cnf value.
#          CONTROLS: the old 3600 breaks the upper bound; 300 (= the max life)
#          breaks the lower one; a max life of 0 (no cap) is refused.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
CNF="$PROJ_ROOT/../csi-spl-cnf/csi-spl"
CONFIG_GO="$PROJ_ROOT/../csi-spl-api/src/go/spool-hub-api/internal/config/config.go"
TIMEOUT_MAX=900

# secs <go duration: 5m | 300s | 1h> -> seconds ("" when unparsable)
secs() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "" ;;
  esac
}

# fits <timeout s> <max life s> -> 0 when the timeout meets the rule
fits() {
  local t="$1" life="$2"
  (( life > 0 && t >= 2 * life && t <= TIMEOUT_MAX && t <= 3600 ))
}

def="$(sed -nE 's/.*env:"SPOOL_HUB_WS_MAX_LIFE" envDefault:"([^"]+)".*/\1/p' "$CONFIG_GO")"
[[ -n "$def" ]] && pass "config.go SPOOL_HUB_WS_MAX_LIFE default is $def" || fail "no SPOOL_HUB_WS_MAX_LIFE envDefault in $CONFIG_GO"
for env in dev prd; do
  t="$(yq -r '.env.hub.cloud_run.timeout_seconds' "$CNF/all.env.yaml")"
  o="$(yq -r '.env.hub.cloud_run.timeout_seconds // ""' "$CNF/$env.env.yaml")"
  [[ -n "$o" && "$o" != null ]] && t="$o"
  life_raw="$(yq -r '.env.hub.env.SPOOL_HUB_WS_MAX_LIFE // ""' "$CNF/all.env.yaml")"
  o="$(yq -r '.env.hub.env.SPOOL_HUB_WS_MAX_LIFE // ""' "$CNF/$env.env.yaml")"
  [[ -n "$o" && "$o" != null ]] && life_raw="$o"
  [[ -z "$life_raw" || "$life_raw" == null ]] && life_raw="$def"
  life="$(secs "$life_raw")"
  fits "$t" "${life:-0}" && pass "$env timeout ${t}s: >= 2 x max life ${life_raw} and <= ${TIMEOUT_MAX}s" \
    || fail "$env timeout '${t}' vs max life '${life_raw}': needs >= 2 x max life and <= ${TIMEOUT_MAX}"
  r="$(sed -nE 's/^timeout_seconds[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$CNF/$env/tf/030-cloud-run-hub.vars.tfvars")"
  [[ "$r" == "$t" ]] && pass "$env rendered 030 tfvars timeout_seconds = $r" || fail "$env rendered 030 tfvars timeout_seconds '$r' != cnf '$t' (ENV=$env ./run -a do_tpl_gen)"
done

fits 3600 300 && fail "CONTROL the old 3600 s passed" || pass "CONTROL the old 3600 s breaks the ${TIMEOUT_MAX} s bound"
fits 300 300 && fail "CONTROL 300 s at a 5 min max life passed" || pass "CONTROL 300 s at a 5 min max life breaks the 2 x bound"
fits 600 0 && fail "CONTROL a max life of 0 (no cap) passed" || pass "CONTROL a max life of 0 (no cap) is refused"

[[ $fails -eq 0 ]] && echo "PASS: all hub-request-timeout-030.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
