#!/bin/bash
#------------------------------------------------------------------------------
# @description Verify the master/failover dispatchers (the counterpart of
# @description do_spl_dispatch_setup). Prints one markdown table, a row per
# @description fact, then exits 1 when any row is a GAP:
# @description   per dispatcher: its claude process (found by SPOOL_AGENT_ID),
# @description   model, permission mode (must be auto), desk settings loaded
# @description   (the session started after its settings.local.json), a desk
# @description   seat in every workspace, unread inbox messages
# @description   the lease: holder is a dispatcher and its age is under LEASE_STALE
# @description   the renew and watch loops: each holds its run lock
# @description Read-only: no hub call, no write.
# @param ENV - required: dev or prd, the hub the desks seat at
# @param DISPATCH_MASTER / DISPATCH_FAILOVER / DISPATCH_ORCH (optional) - as do_spl_dispatch_setup
# @param DISPATCH_TENANTS (optional) - as do_spl_dispatch_setup
# @param DISPATCH_MODEL (optional) - when set, a dispatcher on another model is a GAP
# @param DISPATCH_UNREAD_MAX (optional) - more unread than this is a GAP, default 20
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ENV=prd ./run -a do_spl_dispatch_check
#------------------------------------------------------------------------------
do_spl_dispatch_check() {
  spl_dispatch_cnf || return 1
  rm -rf "$SPL_DISPATCH_TMP"
  local id pid gaps=0 v t seats miss n wt mode model
  local max="${DISPATCH_UNREAD_MAX:-20}"
  echo "| what | value | verdict |"
  echo "|---|---|---|"
  row() { echo "| $1 | $2 | $3 |"; [[ "$3" == GAP* ]] && gaps=$((gaps + 1)); return 0; }
  for id in "$DISPATCH_MASTER" "$DISPATCH_FAILOVER"; do
    pid="$(spl_lease_agent_pid "$id")"
    if [[ -z "$pid" ]]; then
      row "$id process" "none with SPOOL_AGENT_ID=$id" "GAP not running"
    else
      row "$id process" "pid $pid, SPOOL_AGENT_ID=$id" ok
      mode="$(spl_dispatch_cmd_flag "$pid" --permission-mode)"
      [[ "$mode" == auto ]] && row "$id permission mode" auto ok || row "$id permission mode" "${mode:-default}" "GAP not auto"
      model="$(spl_dispatch_model "$pid")"
      if [[ -n "${DISPATCH_MODEL:-}" && -n "$model" && "$model" != "$DISPATCH_MODEL"* ]]; then
        row "$id model" "$model" "GAP not $DISPATCH_MODEL"
      else
        row "$id model" "${model:-unknown}" ok
      fi
      wt="${DISPATCH_REPO}-wt/$id"
      if [[ ! -f "$wt/.claude/settings.local.json" ]]; then
        row "$id desk-reply permission" "no $wt/.claude/settings.local.json" "GAP run do_spl_dispatch_setup"
      elif spl_dispatch_stale_settings "$pid" "$wt/.claude/settings.local.json"; then
        row "$id desk-reply permission" "written after the session started" "GAP relaunch $id"
      else
        row "$id desk-reply permission" loaded ok
      fi
    fi
    seats=0 miss=""
    for t in $DISPATCH_TENANTS; do
      if spl_dispatch_seated "$id" "$t"; then seats=$((seats + 1)); else miss+=" $t"; fi
    done
    [[ -z "$miss" ]] && row "$id desks" "$seats/$(wc -w <<<"$DISPATCH_TENANTS") workspaces" ok ||
      row "$id desks" "$seats/$(wc -w <<<"$DISPATCH_TENANTS"), missing:$miss" "GAP seat it"
    n="$(find "${SPOOL_ROOT:-/var/spool-hub}/$id/inbox" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    (( n > max )) && row "$id unread" "$n" "GAP over $max" || row "$id unread" "$n" ok
  done
  spl_lease_read
  local age=$(( $(spl_lease_now) - LT ))
  if [[ "$LH" != "$DISPATCH_MASTER" && "$LH" != "$DISPATCH_FAILOVER" ]]; then
    row lease "$LH" "GAP holder is not a dispatcher"
  elif (( age > LEASE_STALE )); then
    row lease "$LH, ${age}s old" "GAP stale (over ${LEASE_STALE}s)"
  else
    v=ok; [[ "$LH" == "$DISPATCH_FAILOVER" ]] && v="ok (failover active)"
    row lease "$LH, ${age}s old" "$v"
  fi
  for v in renew watch; do
    spl_lease_running "$v" && row "lease $v loop" "pid $(cat "$LEASE_DIR/$v.pid" 2>/dev/null)" ok ||
      row "lease $v loop" "not running" "GAP LEASE_CMD=ensure do_spl_dispatch_lease"
  done
  echo
  if (( gaps )); then echo "dispatch check: $gaps gap(s)"; return 1; fi
  echo "dispatch check: no gap"
}

# The value after <flag> on the process's command line (or "<flag>=v").
spl_dispatch_cmd_flag() {
  local a prev="" root="${LEASE_PROC_ROOT:-/proc}"
  while IFS= read -r -d '' a; do
    [[ "$prev" == "$2" ]] && { echo "$a"; return 0; }
    [[ "$a" == "$2="* ]] && { echo "${a#*=}"; return 0; }
    prev="$a"
  done < "$root/$1/cmdline"
  return 0
}

# --model from the command line, else the last model the session's transcript
# recorded (<HOME>/.claude/projects/<cwd with / and . as ->/<session>.jsonl).
spl_dispatch_model() {
  local pid="$1" root="${LEASE_PROC_ROOT:-/proc}" m home cwd sid f
  m="$(spl_dispatch_cmd_flag "$pid" --model)"
  [[ -n "$m" ]] && { echo "$m"; return 0; }
  home="$(tr '\0' '\n' < "$root/$pid/environ" 2>/dev/null | sed -n 's/^HOME=//p' | head -1)"
  cwd="$(readlink "$root/$pid/cwd" 2>/dev/null)"
  [[ -n "$home" && -n "$cwd" ]] || return 0
  local dir="$home/.claude/projects/$(tr '/.' '--' <<<"$cwd")"
  sid="$(spl_dispatch_cmd_flag "$pid" --resume)"
  if [[ -n "$sid" && -f "$dir/$sid.jsonl" ]]; then f="$dir/$sid.jsonl"
  else f="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)"; fi
  [[ -n "$f" ]] || return 0
  grep -o '"model":"[^"]*"' "$f" 2>/dev/null | tail -1 | cut -d'"' -f4
}
