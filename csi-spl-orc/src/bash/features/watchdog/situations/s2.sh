#!/usr/bin/env bash
# S2 (spec 093 6.1): a login, limit or access screen. The transcript's last
# assistant entry is an API error matching the stall banners, or the
# heartbeat carries api_error, or the pane footer shows a banner with no
# moving spinner (with or without a reset time) and the transcript's last
# turn is not a good one (a stale banner after /login, 6.2). kind=login|limit
# tells the watchdog whether to DM the owner (login, access) or wait (limit).
# Usage: s2.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
kind() { if grep -qiE 'limit' <<<"$1"; then echo limit; else echo login; fi; }
last="$(wd_last_turn)"
if [[ "$last" == error$'\t'* ]]; then
  txt="${last#error$'\t'}"
  if grep -qiE -- "$WD_STALL_RE" <<<"$txt"; then
    echo "HIT S2 kind=$(kind "$txt") transcript: $(wd_short <<<"$txt")"
    exit 0
  fi
fi
api="$(wd_hb api_error)"
if [[ -n "$api" ]] && grep -qiE -- "$WD_STALL_RE" <<<"$api"; then
  echo "HIT S2 kind=$(kind "$api") heartbeat: $(wd_short <<<"$api")"
  exit 0
fi
wd_has pane || exit 0
foot="$(wd_foot)"
hit="$(grep -oiE -m1 -- "$WD_STALL_RE" <<<"$foot" | sed -n 1p)"
[[ -n "$hit" ]] || exit 0
wd_spin_moving && exit 0
[[ "$last" == ok ]] && exit 0
reset="$(grep -oiE -- '(resets|automatically)([[:space:]]+at)?[[:space:]]+[^·]+' <<<"$foot" | sed -n 1p | wd_short 40)"
echo "HIT S2 kind=$(kind "$hit") pane: $hit${reset:+, $reset}"
