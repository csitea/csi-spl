#!/usr/bin/env bash
# S9 (spec 102 8.1): stuck, read from what is ABSENT, never from what text is
# on the screen. ALL of these hold for WD_STUCK_MIN (10 min):
#   1. the harness process lives (a pid)
#   2. no progress (wd_progress) for that long
#   3. not in a tool within its cap (S4's cap)
#   4. the pane did not change since the input of 5 was delivered: pane_age,
#      kept by the watchdog over `s9.sh --norm` of the screen (poke lines and
#      the bottom WD_S9_STATUS_ROWS (1) rows removed), covers the window give
#      or take WD_S9_SLACK s (60)
#   5. a keystroke reached the pane and not the model: the oldest line of
#      <id>/lifetime/input.log ("<ts> <kind>", written by every poke sender;
#      "refused-<kind>" when the sender refused it because the screen reads as
#      unsent text, as a select dialog's "❯ 1. ..." row does) after the last
#      UserPromptSubmit (heartbeat turn_since + heartbeat.log)
# A harness whose hook emits no UserPromptSubmit (heartbeat harness is not
# claude, or no heartbeat) reads 5 as "an input after the last progress" and
# waits 2 x WD_STUCK_MIN. A dialog of any wording swallows the keystroke; an
# idle agent with nothing typed into it fails 5 and is left alone.
# An unread inbox file newer than the last progress and the last input, older
# than WD_S9_POKE_GRACE s (60), is not input yet: one line `POKE <file>` asks
# the watchdog to poke it once (no HIT); that poke starts the window. Only
# once input.log exists: until a sender of this tree has poked the agent, no
# file reads as unpoked (a box mid-rollout is not poked twice per message).
# Usage: s9.sh ID PID PANE (WD_CTX set; see lib.inc.sh; reads input_log,
#        hblog, pane_age besides the shared files)
#        s9.sh --norm   the screen on stdin, the text condition 4 hashes
#        s9.sh --scrub  the screen on stdin, secrets as [scrubbed] (the S9 snapshot)
if [[ "${1:-}" == --norm ]]; then
  r="${WD_S9_STATUS_ROWS:-1}"; [[ "$r" =~ ^[0-9]+$ ]] || r=1
  grep -v -- ": 'SPOOL " | sed -e 's/[[:space:]]*$//' | awk -v r="$r" '{ l[NR] = $0 } $0 != "" { last = NR }
    END { n = 0; for (i = last; i > 0 && n < r; i--) if (l[i] != "") { n++; cut = i }
          if (n == 0) cut = last + 1
          for (i = 1; i < cut; i++) print l[i] }'
  exit 0
fi
if [[ "${1:-}" == --scrub ]]; then
  sed -E -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/c\[scrubbed]' \
    -e 's/(xox[abposr]-|gh[opsu]_|github_pat_|glpat-|sk-ant-|sk-|AKIA|AIza|ya29\.)[A-Za-z0-9_.-]{8,}/[scrubbed]/g' \
    -e 's/((password|passwd|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1[scrubbed]/Ig' \
    -e 's/(Bearer[[:space:]]+)[A-Za-z0-9_.=-]{8,}/\1[scrubbed]/g'
  exit 0
fi
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -n "$WD_PID" ]] || exit 0
stuck=$(( ${WD_STUCK_MIN:-10} * 60 ))

# epochs of the ISO times on stdin (first field per line), one per line
s9_epochs() { awk 'NF { print $1 }' | date -u -f - +%s 2>/dev/null; return 0; }
s9_max() { sort -n | tail -1; }

rule=ups win="$stuck"
[[ "$(wd_hb harness)" == claude ]] || { rule=2x; win=$((2 * stuck)); }
prog="$(wd_progress)"
base="$(wd_epoch "$(wd_hb turn_since)")"
if [[ "$rule" == ups ]]; then
  b2="$( { echo "${base:-0}"; wd_f hblog | awk '$2 == "UserPromptSubmit" { print $1 }' | s9_epochs; } | s9_max)"
  base="${b2:-0}"
else
  base="${prog:-0}"
fi
[[ "$base" =~ ^[0-9]+$ ]] || base=0
inputs="$(wd_f input_log | s9_epochs)"
first="$(awk -v b="$base" '$1 > b' <<<"$inputs" | sort -n | head -1)"

if [[ -z "$first" ]]; then
  # nothing typed waits for the model: an unpoked unread file gets ONE poke
  last_in="$(s9_max <<<"$inputs")"
  [[ -n "$last_in" ]] || exit 0
  wd_f inbox | awk -v p="${prog:-0}" -v i="${last_in:-0}" -v now="$WD_NOW" -v g="${WD_S9_POKE_GRACE:-60}" -v me="$WD_ID" \
    '$1 > p && $1 > i && now - $1 >= g && $4 != me && $4 !~ ("^" me "@") { print "POKE " $2 }'
  exit 0
fi
(( WD_NOW - first >= win )) || exit 0
# rule 2x has no UserPromptSubmit to prove the model took the keystroke; an
# input box drawn EMPTY proves it left the box (a-849 2026-10-10, n=1: an
# agy seat idle on its own timer after answering the poke was taken over).
# Text still on the prompt, or no box (a dialog), still counts.
[[ "$rule" == 2x ]] && wd_box_empty && exit 0
if [[ -n "$prog" ]]; then (( WD_NOW - prog >= win )) || exit 0; fi
if [[ "$(wd_hb state)" == in-tool ]]; then
  since="$(wd_epoch "$(wd_hb tool_since)")"
  [[ -n "$since" ]] && (( WD_NOW - since <= $(wd_tool_cap "$(wd_hb tool)") )) && exit 0
fi
pa="$(wd_f pane_age)"
[[ "$pa" =~ ^[0-9]+$ ]] && (( pa + ${WD_S9_SLACK:-60} >= WD_NOW - first )) || exit 0
echo "HIT S9 input=$((WD_NOW - first))s prog=$([[ -n "$prog" ]] && echo "$((WD_NOW - prog))s" || echo unknown) pane=${pa}s rule=$rule"
exit 0
