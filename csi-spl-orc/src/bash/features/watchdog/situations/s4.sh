#!/usr/bin/env bash
# S4 (spec 093 6.1): one tool call over its limit. The heartbeat is in-tool
# and the call has run longer than its cap (wd_tool_cap: 15 min, Agent /
# Monitor / Workflow 60 min, WebFetch / WebSearch 5 min).
# Usage: s4.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -n "$WD_PID" && "$(wd_hb state)" == in-tool ]] || exit 0
tool="$(wd_hb tool)"
since="$(wd_epoch "$(wd_hb tool_since)")"
[[ -n "$since" ]] || exit 0
cap="$(wd_tool_cap "$tool")"
(( WD_NOW - since > cap )) || exit 0
echo "HIT S4 tool=$tool since=$since ran $(( (WD_NOW - since) / 60 )) min > cap $((cap / 60)) min"
