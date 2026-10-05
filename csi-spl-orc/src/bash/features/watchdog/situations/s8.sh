#!/usr/bin/env bash
# S8 (spec 093 6.1): the hook is silent. The harness lives and its transcript
# shows progress (a non-error reply or a tool result) in the last
# WD_HOOK_SILENT s (300), but heartbeat.json is absent or older than that.
# Not a stuck agent: a broken or missing hook. The watchdog reads progress
# from the transcript for it (wd_progress) and reports the GAP once.
# Usage: s8.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
max="${WD_HOOK_SILENT:-300}"
[[ -n "$WD_PID" ]] || exit 0
t="$(wd_transcript_progress)"
[[ "$t" =~ ^[0-9]+$ ]] && (( WD_NOW - t <= max )) || exit 0
hb="$(wd_epoch "$(wd_hb ts)")"
if [[ -z "$hb" ]]; then
  echo "HIT S8 no heartbeat.json, transcript progress $((WD_NOW - t))s ago"
elif (( WD_NOW - hb > max )); then
  echo "HIT S8 heartbeat $((WD_NOW - hb))s old, transcript progress $((WD_NOW - t))s ago"
fi
exit 0
