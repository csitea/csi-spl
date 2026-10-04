#!/bin/bash
#------------------------------------------------------------------------------
# @description Verify the master/failover dispatchers (the counterpart of
# @description do_spl_dispatch_setup). Prints one markdown table, a row per
# @description fact, then exits 1 when any row is a GAP:
# @description   per dispatcher: its claude process (found by SPOOL_AGENT_ID),
# @description   model, permission mode (must be auto), desk settings loaded
# @description   (the session started after its settings.local.json) and their
# @description   allow rule matching the desk-reply command its brief teaches
# @description   (one command, no &&/;/|/$()), a desk
# @description   seat in every workspace, unread inbox messages
# @description   the lease: holder is a dispatcher and its age is under LEASE_STALE
# @description   the renew and watch loops: each holds its run lock
# @description   the unanswered sweep: its last delivered run is under
# @description   DISPATCH_SWEEP_STALE s old, with its open count (SPEC 3.2)
# @description   per workspace: inbound - humans posted in the last
# @description   DISPATCH_SILENCE_WINDOW min and the dispatchers' desk received
# @description   files, and no post was stored unsigned (CLE-77876)
# @description   per workspace and channel: every OD seat (orchestrator, master,
# @description   failover) of every fleet box subscribed, where the workspace
# @description   seats it (owner 2026-10-03, SPEC 2.1; the hub delivers a web UI
# @description   post to a channel's subscribed agents; do_spl_dispatch_subscribe
# @description   fixes it); per workspace: every such OD seat seated (rostered)
# @description Read-only: one read of the hub DB per workspace (as the env SA,
# @description DISPATCH_CHECK_SUBS=0 skips it), no write.
# @param ENV - required: dev or prd, the hub the desks seat at
# @param DISPATCH_MASTER / DISPATCH_FAILOVER / DISPATCH_ORCH (optional) - as do_spl_dispatch_setup
# @param DISPATCH_TENANTS (optional) - as do_spl_dispatch_setup
# @param DISPATCH_MODEL (optional) - when set, a dispatcher on another model is a GAP
# @param DISPATCH_UNREAD_MAX (optional) - more unread than this is a GAP, default 20
# @param DISPATCH_CHECK_SUBS (optional) - 0 skips the channel rows (no DB read)
# @param DISPATCH_SWEEP (optional) - 0 skips the sweep row
# @param DISPATCH_SWEEP_STALE (optional) - seconds, default 1800 (three missed 10-min ticks)
# @param DISPATCH_DEPLOY_LAG (optional) - 0 skips the deploy-lag rows (CLE-77918:
# @param   a hub / WUI input unserved on dev or prd after DISPATCH_LAG_GRACE min is a GAP)
# @param DISPATCH_ROTATE_STALE (optional) - seconds since the last dispatcher rotation (spec 060 FR-072), default 10800
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
      wt="$(spl_dispatch_worktree "$id")"
      if [[ ! -f "$wt/.claude/settings.local.json" ]]; then
        row "$id desk-reply permission" "no $wt/.claude/settings.local.json" "GAP run do_spl_dispatch_setup"
      elif ! spl_dispatch_reply_allowed "$id" "$wt/.claude/settings.local.json"; then
        row "$id desk-reply permission" "no allow rule matches the brief's desk-reply command" \
          "GAP the taught command is not one command the rule allows: DRY_RUN=0 do_spl_dispatch_setup, relaunch $id"
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
  # the inbound rows judge the desk against the lease holder's box
  spl_lease_read; spl_lease_conf
  if [[ "${DISPATCH_CHECK_SUBS:-1}" != 0 ]]; then
    spl_dispatch_with_subs spl_dispatch_check_tenant ||
      row "channel subscriptions" "could not read them for: $DISPATCH_TENANTS" "GAP see the log"
  fi
  spl_lease_read
  local age=$(( $(spl_lease_now) - LT ))
  spl_lease_conf
  local hid; hid="$(spl_lease_holder_id)"
  if spl_lease_remote && [[ "$LH" != *@unreachable ]] && (( age <= LEASE_STALE )); then
    row lease "$LH, ${age}s old" "ok (fleet: held on another machine, this one stands by)"
  elif [[ "$hid" != "$DISPATCH_MASTER" && "$hid" != "$DISPATCH_FAILOVER" ]]; then
    row lease "$LH" "GAP holder is not a dispatcher"
  elif (( age > LEASE_STALE )); then
    row lease "$LH, ${age}s old" "GAP stale (over ${LEASE_STALE}s)"
  else
    v=ok; [[ "$hid" == "$DISPATCH_FAILOVER" ]] && v="ok (failover active)"
    row lease "$LH, ${age}s old" "$v"
  fi
  local loops=(renew watch)
  spl_lease_conf; [[ -n "${LEASE_FLEET:-}" ]] && loops=(fleet)
  for v in "${loops[@]}"; do
    spl_lease_running "$v" && row "lease $v loop" "pid $(cat "$LEASE_DIR/$v.pid" 2>/dev/null)" ok ||
      row "lease $v loop" "not running" "GAP LEASE_CMD=ensure do_spl_dispatch_lease"
  done
  [[ "${DISPATCH_SWEEP:-1}" != 0 ]] && spl_sweep_check_row
  spl_rotate_check_row
  spl_dispatch_deploy_lag_rows
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
  local pid="$1" root="${LEASE_PROC_ROOT:-/proc}" m home cwd sid
  m="$(spl_dispatch_cmd_flag "$pid" --model)"
  [[ -n "$m" ]] && { echo "$m"; return 0; }
  if declare -F spool_proc_environ >/dev/null; then
    home="$(spool_proc_environ "$root" "$pid" | tr '\0' '\n' | sed -n 's/^HOME=//p' | sed -n 1p)"
  else
    home="$(tr '\0' '\n' < "$root/$pid/environ" 2>/dev/null | sed -n 's/^HOME=//p' | sed -n 1p)"
  fi
  cwd="$(readlink "$root/$pid/cwd" 2>/dev/null)"
  [[ -z "$cwd" ]] && declare -F spool_proc_as_owner >/dev/null &&
    cwd="$(spool_proc_as_owner "$root" "$pid" readlink "$root/$pid/cwd")"
  [[ -n "$home" && -n "$cwd" ]] || return 0
  local dir
  dir="$home/.claude/projects/$(tr '/.' '--' <<<"$cwd")"
  sid="$(spl_dispatch_cmd_flag "$pid" --resume)"
  # shellcheck disable=SC2016
  local pick='f=""; [ -n "$2" ] && [ -f "$1/$2.jsonl" ] && f="$1/$2.jsonl"
    [ -n "$f" ] || f="$(ls -t "$1"/*.jsonl 2>/dev/null | sed -n 1p)"
    [ -n "$f" ] && grep -o "\"model\":\"[^\"]*\"" "$f" 2>/dev/null | tail -1'
  # The agent user's home is its own: read its transcript through it.
  if [[ -r "$dir" ]] || ! declare -F spool_proc_as_owner >/dev/null; then
    bash -c "$pick" _ "$dir" "$sid"
  else
    spool_proc_as_owner "$root" "$pid" bash -c "$pick" _ "$dir" "$sid"
  fi | cut -d'"' -f4
}

# 0 when the desk-reply command <id>'s brief teaches (the first `...` span
# naming do_spl_desk_reply; no brief: spl_dispatch_reply_cmd) is ONE command
# and an allow rule Bash(<glob>) in <settings> matches it, * matching anything.
# 2026-10-03: the check said "loaded ok" while c-002's prd reply, taught as
# `cd <main checkout> && ... DESK_BODY="$(cat f)" ...`, was refused.
spl_dispatch_reply_allowed() {
  local brief="$DISPATCH_BRIEF_DIR/brief-dispatcher-$1.md"
  python3 - "$2" "$brief" "$(spl_dispatch_reply_cmd "$1")" <<'PY'
import json, os, re, sys
settings, brief, default = sys.argv[1:4]
cmd = default
if os.path.isfile(brief):
    spans = [s for s in re.findall(r"`([^`]*)`", open(brief).read()) if "do_spl_desk_reply" in s]
    cmd = spans[0] if spans else ""
if not cmd or re.search(r"&&|\|\||[;|`\n]|\$\(", cmd):
    sys.exit(1)
try:
    rules = json.load(open(settings)).get("permissions", {}).get("allow", [])
except (OSError, ValueError):
    sys.exit(1)
for r in rules:
    m = re.fullmatch(r"Bash\((.*)\)", r, re.S)
    if m and re.fullmatch(".*".join(map(re.escape, m.group(1).split("*"))), cmd, re.S):
        sys.exit(0)
sys.exit(1)
PY
}

# One row per channel of workspace <t>: every seated OD seat of every fleet
# box that serves <t> in it (a missing one is a GAP), and one row for the OD
# seats of those boxes <t> does not seat (the hub refuses their subscription).
# A box with no OD seat in <t> at all is its own desks row's business.
spl_dispatch_check_tenant() {
  local t="$1" data="$2" ch fb a want have miss unseated="" boxes
  boxes="$(spl_dispatch_served_boxes "$data")"
  for fb in $boxes; do
    for a in $(spl_dispatch_od_ids); do
      spl_dispatch_rostered "$data" "$fb" "$a" || unseated+=" $a@$fb"
    done
  done
  for ch in $(sed -n 's/^chan|//p' <<<"$data"); do
    want=0 have=0 miss=""
    for fb in $boxes; do
      for a in $(spl_dispatch_od_ids); do
        spl_dispatch_rostered "$data" "$fb" "$a" || continue
        want=$((want + 1))
        if spl_dispatch_subbed "$data" "$ch" "$fb" "$a"; then have=$((have + 1)); else miss+=" $a@$fb"; fi
      done
    done
    if [[ -z "$miss" ]]; then
      row "$t #$ch" "OD seats $have/$want" ok
    else
      row "$t #$ch" "OD seats $have/$want, missing:$miss" "GAP do_spl_dispatch_subscribe"
    fi
  done
  [[ -z "$unseated" ]] && row "$t OD seats" "every fleet OD seat seated" ok ||
    row "$t OD seats" "unseated:$unseated" "GAP seat it (do_spl_desk_up), then do_spl_dispatch_subscribe"
  local l bad
  bad="$(spl_dispatch_inbound "$t" "$data")"
  # The fleet dispatch lease held on another box (spec fleet-roles 4.1): its
  # desk receives the posts, this box's desk is silent by design - no GAP.
  if spl_lease_remote && [[ "$LH" != *@unreachable ]] && grep -q '^SILENT ' <<<"$bad"; then
    bad="$(grep -v '^SILENT ' <<<"$bad")"
    [[ -z "$bad" ]] && { row "$t inbound" "this box's desk is not the dispatch desk" "ok (held by $LH)"; return 0; }
  fi
  if [[ -z "$bad" ]]; then
    l="$(sed -n 's/^hum|\([^|]*\)|.*/\1/p' <<<"$data" | sed -n 1p)"
    row "$t inbound" "${l:-0} human posts in ${DISPATCH_SILENCE_WINDOW:-120} min" ok
  else
    while IFS= read -r l; do row "$t inbound" "${l#* "$t" }" "GAP ${l%% *}"; done <<<"$bad"
  fi
}

# The dispatcher's worktree: the identity map's (<spool root>/agents/<id>.json,
# written at spawn), else <main checkout>-wt/<id>. Never the running checkout.
spl_dispatch_worktree() {
  local m="${SPOOL_ROOT:-/var/spool-hub}/agents/$1.json" w=""
  [[ -f "$m" ]] && w="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("worktree") or "")' "$m" 2>/dev/null)"
  [[ -n "$w" && -d "$w" ]] && { echo "$w"; return 0; }
  echo "${DISPATCH_REPO}-wt/$1"
}

# The dispatcher rotation (spec 060 FR-072): a GAP when its last DONE is
# older than DISPATCH_ROTATE_STALE s while the switch is on and this machine
# holds the dispatch lease. Needs the lease read (LH) and row().
spl_rotate_check_row() {
  local last age stale="${DISPATCH_ROTATE_STALE:-10800}"
  if declare -F spl_dispatch_rotate_on >/dev/null && ! spl_dispatch_rotate_on; then
    row "dispatch rotation" "switched off (rotate.conf)" ok; return 0
  fi
  if spl_lease_remote; then
    row "dispatch rotation" "the lease is held on another machine" "ok (not rotated here)"; return 0
  fi
  last="$(cat "$LEASE_DIR/rotate.dispatch.last" 2>/dev/null)"
  if [[ ! "$last" =~ ^[0-9]+$ ]]; then
    row "dispatch rotation" "never ran" "GAP DRY_RUN=0 do_spl_dispatch_rotate_install_cron, then read $LEASE_DIR/rotate.log"; return 0
  fi
  age=$(( $(spl_lease_now) - last ))
  if (( age > stale )); then
    row "dispatch rotation" "last done ${age}s ago" "GAP over ${stale}s - read $LEASE_DIR/rotate.log"
  else
    row "dispatch rotation" "last done ${age}s ago" ok
  fi
}
