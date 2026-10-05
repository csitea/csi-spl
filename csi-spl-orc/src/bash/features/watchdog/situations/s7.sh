#!/usr/bin/env bash
# S7 (spec 093 6.1): a modal dialog. modal=1: a dismissable modal the lease
# knows (spl_lease_modal_hit: the auto-mode offer, ...), which the watchdog
# answers with ONE Escape. modal=0: a blocking screen (LEASE_BLOCK_RE: trust,
# onboarding, the login picker) where Escape could choose "No, exit": no key.
# Usage: s7.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -n "$WD_PID" ]] && wd_has pane || exit 0
lib="${WD_LEASE_LIB:-$(dirname "$0")/../../../run/spl-dispatch-lease.func.sh}"
# shellcheck source=../../../run/spl-dispatch-lease.func.sh
. "$lib" >/dev/null 2>&1 || exit 0
text="$(wd_f pane)"
hit="$(spl_lease_modal_hit "$text")"
[[ -n "$hit" ]] && { echo "HIT S7 modal=1 $(wd_short 80 <<<"$hit")"; exit 0; }
hit="$(wd_foot | grep -oiE -m1 -- "${LEASE_BLOCK_RE:-$LEASE_BLOCK_RE_DEFAULT}" | sed -n 1p)"
[[ -n "$hit" ]] && echo "HIT S7 modal=0 $hit"
exit 0
