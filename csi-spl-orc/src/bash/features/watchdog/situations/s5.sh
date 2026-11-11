#!/usr/bin/env bash
# S5 (spec 093 6.1): a loop. Among the heartbeat's last 8 calls made in the
# current turn, the newest call's (sig, res) pair occurs at least WD_LOOP_N
# (5) times. A call older than the heartbeat's turn_since (a user prompt, a
# poke, came after it) is not counted: 8 pokes each answered by the same call
# are 8 turns, not a loop (SPL-5335). No turn_since, or a ts it cannot read:
# the call counts.
# Usage: s5.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -n "$WD_PID" ]] && wd_has heartbeat || exit 0
jq -r --argjson n "${WD_LOOP_N:-5}" '
  def ep: try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null;
  ((.turn_since // "") | ep) as $t
  | [(.calls // [])[-8:][] | select(type == "object")
      | select($t == null or ((.ts // "") | ep) == null or ((.ts // "") | ep) >= $t)] as $c
  | ($c | last) as $l
  | if $l == null then empty else
      ([$c[] | select(.sig == $l.sig and .res == $l.res)] | length) as $k
      | if $k >= $n then "HIT S5 sig=\($l.sig) res=\($l.res) n=\($k) last=\($l.ts) the same call with the same result \($k) times in the last \($c | length) of this turn" else empty end
    end' "$WD_CTX/heartbeat" 2>/dev/null
exit 0
