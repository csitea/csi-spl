#!/usr/bin/env bash
# S5 (spec 093 6.1): a loop. Among the heartbeat's last 8 calls, the newest
# call's (sig, res) pair occurs at least WD_LOOP_N (5) times.
# Usage: s5.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -n "$WD_PID" ]] && wd_has heartbeat || exit 0
jq -r --argjson n "${WD_LOOP_N:-5}" '
  [(.calls // [])[-8:][] | select(type == "object")] as $c
  | ($c | last) as $l
  | if $l == null then empty else
      ([$c[] | select(.sig == $l.sig and .res == $l.res)] | length) as $k
      | if $k >= $n then "HIT S5 sig=\($l.sig) res=\($l.res) n=\($k) last=\($l.ts) the same call with the same result \($k) times in the last \($c | length)" else empty end
    end' "$WD_CTX/heartbeat" 2>/dev/null
exit 0
