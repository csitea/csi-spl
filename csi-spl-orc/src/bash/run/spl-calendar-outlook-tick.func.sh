#!/bin/bash
#------------------------------------------------------------------------------
# @description One tick of the Outlook calendar sync (spec 180 FR-10, T5,
# @description section 3 answer A, owner go 2d4322f2): every 30 min from 06:30
# @description to 20:30 Europe/Helsinki, Monday to Friday (29 runs a day; the
# @description window is checked here, the cron row fires every :00 and :30).
# @description Each tick queues the committed export script
# @description (src/powershell/outlook-calendar-export.ps1) as one remote run
# @description on the Outlook box through the box link's own action, waits
# @description for its result, imports the result's stdout with
# @description do_spl_calendar_import_outlook, then deletes the export (the
# @description result's stdout and the temp copy). Logs the four counts only.
# @description Name-neutral (SPL-1910): the box link's checkout, its action,
# @description its results dir and the target (env, workspace, owner) come
# @description from the box-local KEY=VALUE file OUTLOOK_IMPORT_ENV, read and
# @description never sourced, outside git. No file (no LINK_HOME) = no-op,
# @description exit 0. A lock keeps two ticks apart. DRY_RUN=1 (default):
# @description prints what it would queue, queues nothing.
# @param OUTLOOK_IMPORT_ENV (optional) - the box-local file, default $XDG_CONFIG_HOME/csi-spl/outlook-import.env
# @param OUTLOOK_IMPORT_LINK_HOME (optional) - env or file: the box link checkout whose `run -a <action>` queues a remote run; unset = no-op
# @param OUTLOOK_IMPORT_LINK_ACTION (optional) - env or file: the action that queues it (reads CMD, CWD, TIMEOUT, LABEL; prints the run id); needed with LINK_HOME
# @param OUTLOOK_IMPORT_LINK_RESULTS (optional) - env or file: the results dir, <dir>/<id>/{result.json,stdout.txt}; needed with LINK_HOME
# @param OUTLOOK_IMPORT_PS (optional) - env or file: the box's powershell.exe as the remote shell sees it, default the WSL path of Windows PowerShell
# @param OUTLOOK_IMPORT_TARGET_ENV (optional) - env or file: dev or prd; needed with LINK_HOME
# @param OUTLOOK_IMPORT_TENANT (optional) - env or file: the workspace slug; needed with LINK_HOME
# @param OUTLOOK_IMPORT_OWNER (optional) - env or file: the member, a HUM-* id; needed with LINK_HOME
# @param OUTLOOK_IMPORT_DAYS (optional) - days to export, default 14
# @param OUTLOOK_IMPORT_WAIT_S (optional) - seconds to wait for the result, default 600
# @param OUTLOOK_IMPORT_POLL_S (optional) - seconds between result checks, default 10
# @param OUTLOOK_IMPORT_ANYTIME (optional) - 1 runs outside the window (a manual tick), default 0
# @param OUTLOOK_IMPORT_DRY (optional) - 1 exports and checks the file, imports with DRY_RUN=1; default 0
# @param OUTLOOK_IMPORT_NOW (optional) - tests: the epoch the window check reads, default now
# @param OUTLOOK_IMPORT_STATE (optional) - the lock's dir, default $XDG_STATE_HOME/csi-spl
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_calendar_outlook_tick
# @example OUTLOOK_IMPORT_ANYTIME=1 DRY_RUN=0 ./run -a do_spl_calendar_outlook_tick
#------------------------------------------------------------------------------
do_spl_calendar_outlook_tick() {
  local dry="${DRY_RUN:-1}" cf="${OUTLOOK_IMPORT_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/csi-spl/outlook-import.env}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  spl_outlook_tick_env "$cf"
  [[ -n "${OUTLOOK_IMPORT_LINK_HOME:-}" ]] ||
    { do_log "OK no box link configured on this box (no OUTLOOK_IMPORT_LINK_HOME, no $cf): nothing to sync"; return 0; }
  _spl_outlook_tick_check || return 1
  if [[ "${OUTLOOK_IMPORT_ANYTIME:-0}" != 1 ]] && ! spl_outlook_tick_in_window "${OUTLOOK_IMPORT_NOW:-$(date +%s)}"; then
    do_log "OK outside the sync window (06:30-20:30 Europe/Helsinki, Mon-Fri): nothing to do"; return 0
  fi
  local ps1="$PROJ_PATH/src/powershell/outlook-calendar-export.ps1" cmd
  [[ -r "$ps1" ]] || { do_log "FATAL the export script is missing: $ps1"; return 1; }
  cmd="$(spl_outlook_tick_cmd "$ps1" "${OUTLOOK_IMPORT_DAYS:-14}" "${OUTLOOK_IMPORT_PS:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}")" || return 1
  if [[ "$dry" == 1 ]]; then
    do_log "OK DRY_RUN would queue the export (${#cmd} bytes, -Days ${OUTLOOK_IMPORT_DAYS:-14}) through the box link, then import it into $OUTLOOK_IMPORT_TENANT ($OUTLOOK_IMPORT_TARGET_ENV) for $OUTLOOK_IMPORT_OWNER; queued nothing"
    return 0
  fi
  local st="${OUTLOOK_IMPORT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl}" rc
  mkdir -p "$st" || { do_log "FATAL cannot create $st"; return 1; }
  { exec 7>"$st/outlook-import.lock"; } 2>/dev/null || { do_log "FATAL cannot open $st/outlook-import.lock"; return 1; }
  flock -n 7 || { do_log "INFO another Outlook sync tick holds the lock - skipped"; exec 7>&-; return 0; }
  _spl_outlook_tick_run "$cmd"
  rc=$?
  exec 7>&-
  return "$rc"
}

# _spl_outlook_tick_check: the file's values are well formed.
_spl_outlook_tick_check() {
  [[ -n "${OUTLOOK_IMPORT_LINK_RESULTS:-}" && "${OUTLOOK_IMPORT_LINK_ACTION:-}" =~ ^[a-z][a-z0-9_-]*$ ]] ||
    { do_log "FATAL OUTLOOK_IMPORT_LINK_ACTION (an action name) and OUTLOOK_IMPORT_LINK_RESULTS must be set with OUTLOOK_IMPORT_LINK_HOME"; return 1; }
  [[ -x "$OUTLOOK_IMPORT_LINK_HOME/run" ]] || { do_log "FATAL no runnable $OUTLOOK_IMPORT_LINK_HOME/run"; return 1; }
  [[ "${OUTLOOK_IMPORT_TARGET_ENV:-}" == dev || "${OUTLOOK_IMPORT_TARGET_ENV:-}" == prd ]] ||
    { do_log "FATAL OUTLOOK_IMPORT_TARGET_ENV must be dev or prd, got: '${OUTLOOK_IMPORT_TARGET_ENV:-}'"; return 1; }
  [[ "${OUTLOOK_IMPORT_TENANT:-}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "${OUTLOOK_IMPORT_OWNER:-}" =~ ^HUM-[0-9]+$ ]] ||
    { do_log "FATAL OUTLOOK_IMPORT_TENANT (a slug) and OUTLOOK_IMPORT_OWNER (a HUM-* id) must be set"; return 1; }
  [[ "${OUTLOOK_IMPORT_DAYS:-14}" =~ ^[1-9][0-9]?$ && "${OUTLOOK_IMPORT_WAIT_S:-600}" =~ ^[1-9][0-9]*$ && "${OUTLOOK_IMPORT_POLL_S:-10}" =~ ^[1-9][0-9]*$ ]] ||
    { do_log "FATAL OUTLOOK_IMPORT_DAYS, _WAIT_S and _POLL_S must be whole numbers"; return 1; }
}

# _spl_outlook_tick_run <cmd>: queue, wait, import, delete the export.
_spl_outlook_tick_run() {
  local q id dir f rc
  q="$(cd "$OUTLOOK_IMPORT_LINK_HOME" && CMD="$1" CWD=/tmp TIMEOUT=300 LABEL=spl-outlook-export ./run -a "$OUTLOOK_IMPORT_LINK_ACTION" 2>&1)" ||
    { do_log "FATAL the box link refused to queue the export: $(tail -n 2 <<<"$q" | tr '\n' ' ')"; return 1; }
  id="$(grep -oE '[0-9a-f]{12}' <<<"$q" | tail -n 1)"
  [[ -n "$id" ]] || { do_log "FATAL the box link printed no run id: $(tail -n 2 <<<"$q" | tr '\n' ' ')"; return 1; }
  dir="$OUTLOOK_IMPORT_LINK_RESULTS/$id"
  spl_outlook_tick_wait "$dir" ||
    { do_log "FATAL no result for run $id after ${OUTLOOK_IMPORT_WAIT_S:-600}s (Outlook box offline?): the hub keeps the previous rows"; return 1; }
  if [[ "$(jq -r '.exit' "$dir/result.json")" != 0 ]]; then
    do_log "FATAL the export on the Outlook box failed (run $id, exit $(jq -r '.exit' "$dir/result.json")): the hub keeps the previous rows"
    rm -f "$dir/stdout.txt"; return 1
  fi
  f="$(umask 077; mktemp)" || return 1
  tr -d '\r' <"$dir/stdout.txt" >"$f"
  rm -f "$dir/stdout.txt"
  ENV="$OUTLOOK_IMPORT_TARGET_ENV" TENANT_ID="$OUTLOOK_IMPORT_TENANT" EVENT_OWNER="$OUTLOOK_IMPORT_OWNER" \
    IMPORT_FILE="$f" DRY_RUN="$([[ "${OUTLOOK_IMPORT_DRY:-0}" == 1 ]] && echo 1 || echo 0)" do_spl_calendar_import_outlook
  rc=$?
  rm -f "$f"
  if (( rc == 0 )); then do_log "OK Outlook sync tick: run $id imported, export deleted"
  else do_log "WARN Outlook sync tick: run $id, import rc $rc, export deleted"; fi
  return "$rc"
}

# spl_outlook_tick_wait <dir>: wait until <dir>/result.json parses and
# stdout.txt is there, at most OUTLOOK_IMPORT_WAIT_S seconds.
spl_outlook_tick_wait() {
  local end=$(( $(date +%s) + ${OUTLOOK_IMPORT_WAIT_S:-600} ))
  while :; do
    [[ -f "$1/stdout.txt" ]] && jq -e 'has("exit")' "$1/result.json" >/dev/null 2>&1 && return 0
    (( $(date +%s) < end )) || return 1
    sleep "${OUTLOOK_IMPORT_POLL_S:-10}"
  done
}

# spl_outlook_tick_in_window <epoch>: Mon-Fri, 06:30..20:30 Europe/Helsinki.
spl_outlook_tick_in_window() {
  local dow hm
  read -r dow hm < <(TZ=Europe/Helsinki date -d "@$1" '+%u %H%M')
  (( dow <= 5 && 10#$hm >= 630 && 10#$hm <= 2030 ))
}

# spl_outlook_tick_cmd <ps1> <days> <powershell.exe>: the remote shell. It
# writes the script to the Windows temp dir, runs it with -OutFile STDOUT and
# removes it again; the box link returns its stdout.
spl_outlook_tick_cmd() {
  grep -q '^SPL_PS1_EOF$' "$1" && { do_log "FATAL the export script holds the heredoc end line"; return 1; }
  printf '%s\n' "P='$3'" 'cd /mnt/c || exit 3' \
    'WT=$("$P" -NoProfile -NonInteractive -Command '"'"'[IO.Path]::GetTempPath()'"'"' | tr -d '"'"'\r'"'"')' \
    'WL=$(wslpath -u "$WT")' "cat > \"\$WL/spl-outlook-export.ps1\" <<'SPL_PS1_EOF'"
  cat "$1"
  printf '%s\n' 'SPL_PS1_EOF' \
    "timeout 240 \"\$P\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"\${WT}spl-outlook-export.ps1\" -Days $2 -OutFile STDOUT" \
    'rc=$?' 'rm -f "$WL/spl-outlook-export.ps1"' 'exit $rc'
}

# The box-local KEY=VALUE file: sets each OUTLOOK_IMPORT_* key the
# environment left unset. Read, never sourced.
spl_outlook_tick_env() {  # FILE
  local k v
  [[ -r "$1" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      OUTLOOK_IMPORT_LINK_HOME|OUTLOOK_IMPORT_LINK_ACTION|OUTLOOK_IMPORT_LINK_RESULTS|OUTLOOK_IMPORT_PS|OUTLOOK_IMPORT_TARGET_ENV|OUTLOOK_IMPORT_TENANT|OUTLOOK_IMPORT_OWNER)
        [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "${v//\$HOME/$HOME}" ;;
    esac
  done < <(grep -E '^OUTLOOK_IMPORT_[A-Z_]+=[^[:space:];|&`]+$' "$1")
}
