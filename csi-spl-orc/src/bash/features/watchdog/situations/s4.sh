#!/usr/bin/env bash
# S4 (spec 093 6.1): one tool call over its limit. The heartbeat is in-tool
# and the call has run longer than its cap (wd_tool_cap: 15 min, Agent /
# Monitor / Workflow 60 min, WebFetch / WebSearch 5 min). Not when the
# claude transcript shows no open tool_use: a PreToolUse whose PostToolUse
# never came leaves an idle session in-tool (6.2, c-486 2026-10-07: one
# with no tool_use, 3 s after a Stop, got an Escape into the idle prompt).
# Usage: s4.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -n "$WD_PID" && "$(wd_hb state)" == in-tool ]] || exit 0
tool="$(wd_hb tool)"
since="$(wd_epoch "$(wd_hb tool_since)")"
[[ -n "$since" ]] || exit 0
cap="$(wd_tool_cap "$tool")"
(( WD_NOW - since > cap )) || exit 0
wd_open_tool || exit 0
echo "HIT S4 tool=$tool since=$since ran $(( (WD_NOW - since) / 60 )) min > cap $((cap / 60)) min"
