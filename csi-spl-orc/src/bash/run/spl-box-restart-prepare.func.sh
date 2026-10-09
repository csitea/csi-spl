#!/bin/bash
#------------------------------------------------------------------------------
# @description Prepare THIS box for a restart (the pre-boot steps 2.1 and 2.3
# @description of csi-spl-doc/specs/102-agent-lifetime/drill-reboot-2026-10-07.md
# @description as one named action; 2026-10-08 a box went down before prose
# @description steps ran): (a) the desk-cron checkout to origin/master, detached,
# @description with its sha and the count of spl_wd_boot_pass; (b) a snapshot
# @description <SPOOL_ROOT>/dispatch/box-restart/<utc>.before: btime, every
# @description registry id with a live agent process (id, pid, pane) and the
# @description watchdog's verdict list (dispatch/wd.<id> younger than 300 s);
# @description (c) a spool note to every live agent but the sender: reach a
# @description safe point, push your WIP. Dry run unless DRY_RUN=0: the plan
# @description is printed, nothing is fetched, written or sent. After the boot:
# @description do_spl_box_restart_check.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param BOX_RESTART_FROM (optional) - the sender of the notes; default SPOOL_AGENT_ID
# @param BOX_RESTART_TASK (optional) - the task_id of the notes
# @param BOX_RESTART_DESK (optional) - default /opt/csi/csi-spl-desk-cron
# @example ./run -a do_spl_box_restart_prepare
# @example DRY_RUN=0 BOX_RESTART_FROM=c-001 ./run -a do_spl_box_restart_prepare
#------------------------------------------------------------------------------
# Test seams: LEASE_PROC_ROOT (/proc), BOX_RESTART_PS_CMD (ps), BOX_RESTART_SEND
# (spool-send.sh), BOX_RESTART_NOW (the snapshot's UTC stamp).
declare -F spool_proc_env_get >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/proc-owner.inc.sh"
SPL_BRS_RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

do_spl_box_restart_prepare() {
  local dry="${DRY_RUN:-1}" root="${SPOOL_ROOT:-/var/spool-hub}" utc snap dir rc=0
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  utc="${BOX_RESTART_NOW:-$(date -u +%Y%m%dT%H%M%SZ)}"
  dir="$root/dispatch/box-restart"; snap="$dir/$utc.before"
  [[ "$dry" == 1 ]] && do_log "INFO DRY RUN: nothing is fetched, written or sent (DRY_RUN=0 does it)"
  spl_brs_desk "$dry" || rc=1
  if [[ "$dry" == 1 ]]; then
    do_log "INFO PLAN snapshot $snap:"
    spl_brs_snapshot "$root" | sed 's/^/  /'
  else
    { mkdir -p "$dir" && spl_brs_snapshot "$root" > "$snap.tmp" && mv "$snap.tmp" "$snap"; } ||
      { do_log "ERROR the snapshot $snap was not written"; return 1; }
    do_log "OK snapshot $snap"
    sed 's/^/  /' "$snap"
  fi
  spl_brs_notify "$dry" "$snap" || rc=1
  return "$rc"
}

# (a) the desk-cron checkout on origin/master (the dry run only prints it).
spl_brs_desk() {
  local dry="$1" desk="${BOX_RESTART_DESK:-/opt/csi/csi-spl-desk-cron}"
  if [[ "$dry" == 1 ]]; then
    do_log "INFO PLAN git -C $desk fetch -q origin master && git -C $desk checkout -q --detach origin/master"
  elif ! { git -C "$desk" fetch -q origin master && git -C "$desk" checkout -q --detach origin/master; }; then
    do_log "ERROR the desk-cron checkout $desk is not on origin/master"
    return 1
  fi
  do_log "INFO desk-cron sha $(spl_brs_desk_sha), spl_wd_boot_pass count $(spl_brs_desk_pass) (needs at least 2)"
  return 0
}

spl_brs_desk_sha() { git -C "${BOX_RESTART_DESK:-/opt/csi/csi-spl-desk-cron}" rev-parse --short HEAD 2>/dev/null || echo none; }
spl_brs_desk_pass() {
  grep -c spl_wd_boot_pass "${BOX_RESTART_DESK:-/opt/csi/csi-spl-desk-cron}/csi-spl-orc/src/bash/run/spl-watchdog.func.sh" 2>/dev/null || echo 0
}

# (b) the snapshot, on stdout: btime, the desk sha and count, one agent line
# per live id, the wd verdict ids.
spl_brs_snapshot() {
  local root="$1" now f m ids=""
  printf 'btime\t%s\n' "$(spl_brs_btime)"
  printf 'desk_sha\t%s\n' "$(spl_brs_desk_sha)"
  printf 'wd_boot_pass\t%s\n' "$(spl_brs_desk_pass)"
  spl_brs_agents "$root" | awk -F'\t' -v OFS='\t' '!s[$1]++ {print "agent", $1, $2, $3, $4}'
  now="$(date +%s)"
  for f in "$root"/dispatch/wd.[acgmq]-[0-9][0-9][0-9]; do
    [[ -f "$f" ]] || continue
    m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    (( now - m < 300 )) && ids+="${ids:+ }${f##*/wd.}"
  done
  printf 'wd\t%s\n' "$ids"
}

# The box's boot time (epoch s) from <proc root>/stat.
spl_brs_btime() { awk '$1 == "btime" {print $2; exit}' "${LEASE_PROC_ROOT:-/proc}/stat" 2>/dev/null || true; }

# "<id>\t<pid>\t<pane>\t<comm>" per top-level agent process of a registry id:
# a claude/grok/agy/qwen/vibe/node/bun process carrying SPOOL_AGENT_ID=<id>
# with no ancestor carrying the same id (an MCP child of a claude is not a
# second session), whose comm is a harness of the id's kind: an m- seat counts
# only with its vibe, never with a stray node. The pane is the registry row's.
# Drill 5 (2026-10-09): the old list had no vibe, so the snapshot missed every
# m- seat and the check passed while one was down.
spl_brs_agents() {
  local root="$1" ps
  ps="$(mktemp)"
  spl_brs_ps > "$ps"
  # shellcheck disable=SC2046 # pids, split on purpose
  spool_proc_env_get "${LEASE_PROC_ROOT:-/proc}" SPOOL_AGENT_ID \
    $(awk '$3 ~ /^(claude|grok|agy|qwen|vibe|node|bun)$/ {print $1}' "$ps") 2>/dev/null |
    awk -v ps="$ps" -v reg="$root/registry.tsv" '
      function fits(i, c,  k) { k = substr(i, 1, 1)
        if (k == "m") return c == "vibe"
        return c == "node" || c == "bun" || (k == "c" && c == "claude") || (k == "g" && c == "grok") ||
               (k == "a" && c == "agy") || (k == "q" && c == "qwen") }
      FILENAME == ps { pp[$1] = $2; cm[$1] = $3; next }
      FILENAME == reg { split($0, r, "\t"); i = r[1]; sub(/@.*/, "", i); pane[i] = (r[3] == "" ? "-" : r[3]); next }
      { id[$1] = $2; order[++n] = $1 }
      END { for (k = 1; k <= n; k++) { p = order[k]; i = id[p]; if (!(i in pane)) continue
              q = pp[p]; top = 1
              for (d = 0; d < 64 && q > 1; d++) { if (id[q] == i) { top = 0; break }; q = pp[q] }
              if (top && fits(i, cm[p])) print i "\t" p "\t" pane[i] "\t" cm[p] } }' "$ps" "$root/registry.tsv" - | sort
  rm -f "$ps"
}

# "pid ppid comm args..." for every process. mistral's vibe renames itself
# "Vibe CLI" (two words): its comm reads vibe here, one word per field, as in
# spl_wd_ps.
spl_brs_ps() {
  local -a cmd=(ps -e -o "pid=,ppid=,comm=,args=")
  # shellcheck disable=SC2206 # a command line, split on purpose
  [[ -n "${BOX_RESTART_PS_CMD:-}" ]] && cmd=($BOX_RESTART_PS_CMD)
  "${cmd[@]}" 2>/dev/null | awk '$3 == "Vibe" && $4 == "CLI" {$3 = "vibe"; $4 = ""; $0 = $0} {print}' || true
}

# The harness kind of an agent id: c- claude, m- mistral, a- agy, g- grok,
# q- qwen.
spl_brs_kind() {
  case "${1:0:1}" in c) echo claude ;; m) echo mistral ;; a) echo agy ;; g) echo grok ;; q) echo qwen ;; *) echo other ;; esac
}

# (c) one note per live agent but the sender.
spl_brs_notify() {
  local dry="$1" snap="$2" from="${BOX_RESTART_FROM:-${SPOOL_AGENT_ID:-}}" id rc=0 body
  local send="${BOX_RESTART_SEND:-$SPL_BRS_RUN_DIR/../features/spawn-agents/scripts/spool-send.sh}"
  body="BOX RESTART soon (snapshot ${snap##*/}): reach a safe point now, commit and push your WIP; after the boot the watchdog brings you back."
  if [[ "$dry" == 0 && -z "$from" ]]; then do_log "ERROR no sender: set BOX_RESTART_FROM"; return 1; fi
  for id in $(spl_brs_agents "${SPOOL_ROOT:-/var/spool-hub}" | cut -f1 | sort -u); do
    [[ "$id" == "$from" ]] && continue
    if [[ "$dry" == 1 ]]; then do_log "INFO PLAN note to $id: $body"; continue; fi
    if bash "$send" --from "$from" --to "$id" --kind note ${BOX_RESTART_TASK:+--task "$BOX_RESTART_TASK"} --body "$body" >/dev/null 2>&1; then
      do_log "OK note to $id"
    else do_log "ERROR the note to $id was not sent"; rc=1; fi
  done
  return "$rc"
}
