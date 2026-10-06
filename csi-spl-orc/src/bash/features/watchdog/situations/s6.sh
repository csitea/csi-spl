#!/usr/bin/env bash
# S6 (spec 093 6.1): unsent text in the input box. The box held the same
# non-empty text for more than WD_INPUT_MAX s (120), the agent is idle (the
# heartbeat says idle; with no heartbeat, no moving spinner), and no attached
# client was active in the last 120 s. poke=1 when the text is poke-shaped
# (starts with ": 'SPOOL "): only that one is cleared and re-poked. A box
# holding only a prompt glyph (agy's ">") is empty.
# Usage: s6.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
max="${WD_INPUT_MAX:-120}"
[[ -n "$WD_PID" ]] && wd_has input || exit 0
# an empty agy / grok prompt reads back as its bare prompt glyph: no text
txt="$(wd_f input)"
[[ "$txt" =~ ^[[:space:]]*(\>|❯|›)?[[:space:]]*$ ]] && exit 0
age="$(wd_f input_age)"
[[ "$age" =~ ^[0-9]+$ ]] && (( age > max )) || exit 0
c="$(wd_f client_age)"
[[ "$c" =~ ^[0-9]+$ ]] && (( c <= ${WD_HUMAN_IDLE:-120} )) && exit 0
if wd_has heartbeat; then
  [[ "$(wd_hb state)" == idle ]] || exit 0
else
  wd_spin_moving && exit 0
fi
poke=0
[[ "$txt" == ": 'SPOOL "* ]] && poke=1
echo "HIT S6 poke=$poke input held ${age}s: $(wd_short 80 <<<"$txt")"
