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
# A pid that carries the id is no harness when the pane shows the launch
# wrapper's own end screen for this id ("<kind> session '<id>' ended. Pane
# kept open", restore-core / spawn-core) in its bottom WD_ENDED_TAIL
# non-blank lines (40: the spawn block wraps), a shell in front and no
# harness under the pane: it is a job the ended session left behind (a
# `pnpm dev &` inherits SPOOL_AGENT_ID). Without this the watchdog took it
# for the harness and the dead session waited until something killed it
# (m-419 sat 2026-10-18, n=1, 4 nuxt pids: OK every tick for hours; the
# other box 02:06Z, back only after the fence TERMed the pid).
# `HIT S3 left behind: ...`; the restart then neither kills the job nor
# counts it as a second session.
# Usage: s3.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -z "$WD_PID" || -n "$WD_PANE" ]] || exit 0
wd_has rundir_gone && exit 0
done_ts="$(wd_f "done")" start="$(wd_f session_start)"
[[ "$start" =~ ^[0-9]+$ ]] || start=0
[[ "$done_ts" =~ ^[0-9]+$ ]] && (( done_ts >= start )) && exit 0
if [[ -n "$WD_PANE" ]]; then
  wd_has pane || exit 0
  grep -qxE -- "$WD_HARNESS_COMM_RE" <<<"$(wd_f tree)" && exit 0
  fg="$(wd_f fg)"
  grep -qxE 'sh|bash|zsh|dash|fish|sudo|su' <<<"$fg" || exit 0
  if [[ -n "$WD_PID" ]]; then
    foot="$(wd_f pane | grep -v '^[[:space:]]*$' | tail -n "${WD_ENDED_TAIL:-40}")"
    grep -qE "session '${WD_ID}(@[a-z0-9-]+)?' ended\. Pane kept open" <<<"$foot" || exit 0
    ev="left behind: pane $WD_PANE shows $WD_ID's session ended and runs only '$fg'; pid $WD_PID carrying $WD_ID is no harness"
  else
    ev="pane $WD_PANE runs only '$fg', no harness process carries $WD_ID"
  fi
else
  wd_has registry_open || exit 0
  ev="pane $(wd_f registry_open) is gone, registry row open, no harness process carries $WD_ID"
fi
if wd_has rebirth; then
  echo "HIT S3 rebirth: lifetime/rebirth $(date -u -d "@$(wd_f rebirth)" +%FT%TZ 2>/dev/null); $ev"
else
  echo "HIT S3 $ev"
fi
