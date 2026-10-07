#!/usr/bin/env bash
# S7 (spec 093 6.1): a modal dialog. modal=2: the offer "Make auto mode your
# default permission mode?" (2026-10-06/07: five seats froze on it for
# hours). The owner allows bypassPermissions only, so the watchdog answers
# "No, keep bypass permissions"; cursor=yes|no|? says where ❯ is. modal=1: a
# dismissable modal the lease knows (spl_lease_modal_hit: the auto-mode
# offer, ...), which the watchdog answers with ONE Escape. modal=0: a
# blocking screen (LEASE_BLOCK_RE: trust, onboarding, the login picker) where
# Escape could choose "No, exit": no key.
# Usage: s7.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -n "$WD_PID" ]] && wd_has pane || exit 0
lib="${WD_LEASE_LIB:-$(dirname "$0")/../../../run/spl-dispatch-lease.func.sh}"
# shellcheck source=../../../run/spl-dispatch-lease.func.sh
. "$lib" >/dev/null 2>&1 || exit 0
text="$(wd_f pane)"

# The default-mode offer on the last WD_S7_TAIL (24) lines of the screen,
# below a trailing idle prompt: the title, its Yes line and its No line, each
# a dialog line (spl_lease_modal_line: no other letters on it). An agent that
# quotes the dialog in its reply has its prompt below the quote, so the quote
# is transcript, not the dialog.
s7_default_offer() {
  local -a lines=() bare=()
  local i n floor lo t="" y="" no="" cur="?" s
  local yes_re='yes, set auto mode as my default( permission mode)?' no_re='no, keep bypass permissions'
  mapfile -t lines < <(tail -n "${WD_S7_TAIL:-24}" <<<"$text")
  n=${#lines[@]}
  # an unnumbered "❯ No, keep ..." reads as a composer: blank the options
  for ((i = 0; i < n; i++)); do
    s="${lines[i]}"
    if spl_lease_modal_line "$yes_re" "$s" >/dev/null || spl_lease_modal_line "$no_re" "$s" >/dev/null; then s=""; fi
    bare+=("$s")
  done
  floor="$(spl_lease_modal_floor "${bare[@]}")"
  lo=$((floor + 1))
  for ((i = lo; i < n; i++)); do
    s="${lines[i]}"
    if [[ -z "$t" ]] && spl_lease_modal_line 'make auto mode your default( permission mode)?\??' "$s" >/dev/null; then t="$i"; continue; fi
    [[ -n "$t" ]] || continue
    if [[ -z "$y" ]] && spl_lease_modal_line "$yes_re" "$s" >/dev/null; then
      y="$i"; [[ "$s" =~ ^[[:space:]]*(❯|›|\>) ]] && cur=yes
    elif [[ -z "$no" ]] && spl_lease_modal_line "$no_re" "$s" >/dev/null; then
      no="$i"; [[ "$s" =~ ^[[:space:]]*(❯|›|\>) ]] && cur=no
    fi
  done
  [[ -n "$t" && -n "$y" && -n "$no" ]] || return 1
  echo "cursor=$cur Make auto mode your default permission mode?"
}
hit="$(s7_default_offer)" && { echo "HIT S7 modal=2 $hit"; exit 0; }
hit="$(spl_lease_modal_hit "$text")"
[[ -n "$hit" ]] && { echo "HIT S7 modal=1 $(wd_short 80 <<<"$hit")"; exit 0; }
hit="$(wd_foot | grep -oiE -m1 -- "${LEASE_BLOCK_RE:-$LEASE_BLOCK_RE_DEFAULT}" | sed -n 1p)"
[[ -n "$hit" ]] && echo "HIT S7 modal=0 $hit"
exit 0
