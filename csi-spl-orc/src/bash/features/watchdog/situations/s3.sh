#!/usr/bin/env bash
# S3 (spec 093 6.1, 102 4.3): no harness process. The agent's pane exists,
# no harness process runs under it (none carries its id, none is in the
# pane's process tree) and its foreground command is a shell; or (102) its
# pane is gone while its registry row is still open.
# Done, never a hit: its workdir is gone (it tore down, then exited), or
# lifetime/done is not older than the session start (/exit-clean writes it
# before the agent exits). A done older than the session is a stale one of a
# reused id: ignored. lifetime/rebirth (/exit-clean --rebirth) makes the hit
# a planned rebirth, `HIT S3 rebirth: ...`, the restart's cause `rebirth`.
# Usage: s3.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -z "$WD_PID" ]] || exit 0
wd_has rundir_gone && exit 0
done_ts="$(wd_f "done")" start="$(wd_f session_start)"
[[ "$start" =~ ^[0-9]+$ ]] || start=0
[[ "$done_ts" =~ ^[0-9]+$ ]] && (( done_ts >= start )) && exit 0
if [[ -n "$WD_PANE" ]]; then
  wd_has pane || exit 0
  grep -qxE -- "$WD_HARNESS_COMM_RE" <<<"$(wd_f tree)" && exit 0
  fg="$(wd_f fg)"
  grep -qxE 'sh|bash|zsh|dash|fish|sudo|su' <<<"$fg" || exit 0
  ev="pane $WD_PANE runs only '$fg', no harness process carries $WD_ID"
else
  wd_has registry_open || exit 0
  ev="pane $(wd_f registry_open) is gone, registry row open, no harness process carries $WD_ID"
fi
if wd_has rebirth; then
  echo "HIT S3 rebirth: lifetime/rebirth $(date -u -d "@$(wd_f rebirth)" +%FT%TZ 2>/dev/null); $ev"
else
  echo "HIT S3 $ev"
fi
