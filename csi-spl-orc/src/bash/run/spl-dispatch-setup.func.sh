#!/bin/bash
#------------------------------------------------------------------------------
# @description Set up the master/failover dispatchers on this box
# @description (SPEC-spool-fleet-roles.md; the setup prompt is
# @description csi-spl-doc/doc/md/HOWTO-setup-dispatchers.md). Idempotent:
# @description each step checks first and does only what is missing.
# @description   1. the shared post-drop dir (mode 2777)
# @description   2. <spool root>/dispatch/lease.conf (the lease opt-in)
# @description   3. both briefs, rendered from features/dispatch/brief-dispatcher.tpl.md
# @description   4. each dispatcher's worktree <repo>-wt/<id>, BEFORE its spawn
# @description   5. its .claude/settings.local.json allowing ONLY desk replies
# @description      (+ the path in git's info/exclude). A running session does
# @description      not load a settings file created after it started: that
# @description      is reported as RELAUNCH, never done here
# @description   6. the spawn (fixed id, auto permission mode) when no live
# @description      claude process carries that id
# @description   7. a desk in every workspace (do_spl_desk_up) where unseated
# @description   8. the legacy registry row, when DISPATCH_LEGACY_REGISTRY is set
# @description   9. the lease loops (do_spl_dispatch_lease ensure)
# @description  10. the channel subscriptions (do_spl_dispatch_subscribe): both
# @description      dispatchers in every channel, the orchestrator in none. It
# @description      reads the hub DB even in the dry run (DISPATCH_SUBSCRIBE=0 skips)
# @description  11. the unanswered-post sweep cron (do_spl_unanswered_sweep_install_cron,
# @description      SPEC 3.2: the pull that finds posts nobody answered;
# @description      DISPATCH_SWEEP=0 skips)
# @description Dry run unless DRY_RUN=0: prints one "PLAN <step> <what>" line
# @description per action and touches nothing. Verify with do_spl_dispatch_check.
# @param ENV - required: dev or prd, the hub the desks seat at
# @param DISPATCH_MASTER (optional) - default CLE-002
# @param DISPATCH_FAILOVER (optional) - default CLE-003
# @param DISPATCH_ORCH (optional) - default CLE-001
# @param DISPATCH_TENANTS (optional) - space-separated workspaces; default every
# @param   workspace with a pinned desk box under the state dir
# @param DISPATCH_SKIP_TENANTS (optional) - also left out of that default, on top of the test workspaces (spl_test_workspaces: e2e, <spool root>/dispatch/test-workspaces, SWEEP_SKIP_RE)
# @param DISPATCH_REPO (optional) - the git checkout the worktrees branch off; default this tree
# @param DISPATCH_POSTS_DIR (optional) - default <spool root>/dispatch/posts
# @param DISPATCH_ROOT_KEY_DIR (optional) - dir holding <workspace>.json tenant
# @param   root keys, needed only for a desk box that is not pinned yet
# @param DISPATCH_LEGACY_REGISTRY (optional) - a second registry.tsv to carry the rows
# @param DISPATCH_SUBSCRIBE (optional) - 0 skips step 10 (no hub DB read or write)
# @param DISPATCH_FLEET (optional) - fleet mode (CLE-77911): the fleet's name; with it lease.conf also gets
# @param   LEASE_FLEET / LEASE_MACHINE (DISPATCH_MACHINE, default the desk box id: the <box> of <ID>@<box>) / LEASE_PRIORITY
# @param   (DISPATCH_PRIORITY, e.g. pc,sat) / LEASE_ENV ($ENV) / LEASE_TENANT (DISPATCH_LEASE_TENANT) /
# @param   LEASE_DESK_BOX (DESK_BOX: each machine needs its own desk box id in a workspace).
# @param   LEASE_MACHINE / LEASE_DESK_BOX are written only when DISPATCH_MACHINE / DESK_BOX are
# @param   set; otherwise both follow box.env SPOOL_DESK_BOX (a box rename needs no edit here).
# @param   Unset, the fleet lines already in lease.conf are KEPT: a re-run never silently leaves fleet mode
# @param DISPATCH_SWEEP (optional) - 0 skips step 11 (the sweep cron)
# @param DISPATCH_ASKS_OWNER / DISPATCH_ASKS_RERAISE_MIN / DISPATCH_ASKS_OWNER_MIN (optional) - the asks
# @param   timer's knobs (CLE-77929, do_spl_asks_tick): written to lease.conf as ASKS_OWNER (the owner's
# @param   HUM-<n>: the DM leg for an ask unacked ASKS_OWNER_MIN), ASKS_RERAISE_MIN, ASKS_OWNER_MIN.
# @param DISPATCH_ASKS_LOCK_MIN / DISPATCH_ASKS_MAX_RAISES (optional) - the share-group deltas (CLE-77942):
# @param   ASKS_LOCK_MIN (an acked ask's holder quiet that long is released, default 60) and
# @param   ASKS_MAX_RAISES (the delivery limit before the dead-letter to the owner, default 4).
# @param   Unset, the ASKS_ lines already in lease.conf are KEPT
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ./run -a do_spl_dispatch_setup
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_dispatch_setup
#------------------------------------------------------------------------------
# this machine's desk box id (specs/058), also when sourced on its own
declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"

do_spl_dispatch_setup() {
  spl_dispatch_cnf || return 1
  local rc
  spl_dispatch_setup_steps; rc=$?
  rm -rf "$SPL_DISPATCH_TMP"
  return $rc
}

spl_dispatch_setup_steps() {
  local dry=1 id role peer rule first brief wt
  [[ "${DRY_RUN:-1}" == 0 ]] && dry=0
  [[ "${DRY_RUN:-1}" == 0 || "${DRY_RUN:-1}" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  SPL_DISPATCH_DRY=$dry

  # 1. post-drop dir
  if [[ -d "$DISPATCH_POSTS_DIR" && "$(stat -c %a "$DISPATCH_POSTS_DIR")" == 2777 ]]; then
    spl_dispatch_ok posts-dir "$DISPATCH_POSTS_DIR"
  else
    spl_dispatch_do posts-dir "mkdir -p + chmod 2777 $DISPATCH_POSTS_DIR" \
      bash -c 'mkdir -p "$1" && chmod 2777 "$1"' _ "$DISPATCH_POSTS_DIR" || return 1
  fi

  # 2. lease.conf
  local conf
  spl_dispatch_lease_conf_text || return 1
  if [[ "$(cat "$LEASE_CONF" 2>/dev/null)" == "$conf" ]]; then
    spl_dispatch_ok lease-conf "$LEASE_CONF"
  else
    spl_dispatch_do lease-conf "write $LEASE_CONF ($DISPATCH_MASTER / $DISPATCH_FAILOVER / $DISPATCH_ORCH)" \
      bash -c 'printf "%s\n" "$2" > "$1"' _ "$LEASE_CONF" "$conf" || return 1
  fi

  for id in "$DISPATCH_MASTER" "$DISPATCH_FAILOVER"; do
    if [[ "$id" == "$DISPATCH_MASTER" ]]; then
      role=master peer="$DISPATCH_FAILOVER"
      rule="You are the master: you normally hold it. If a lease message says otherwise, obey it."
      first="Start dispatching: read your inbox, then run steadily; check it at every natural breakpoint."
    else
      role=failover peer="$DISPATCH_MASTER"
      rule="You are the failover: stay STANDBY (read nothing, post nothing) until a 'DISPATCH LEASE: you are now ACTIVE' message. Then dispatch your own inbox AND $DISPATCH_MASTER's unread inbox (\`spool recv --as $DISPATCH_MASTER\`; skip what $DISPATCH_MASTER's outbox shows it already handled) until 'STANDBY'."
      first="Go STANDBY: confirm the lease shows $DISPATCH_MASTER, then wait for a lease message."
    fi
    # 3. brief
    brief="$DISPATCH_BRIEF_DIR/brief-dispatcher-$id.md"
    spl_dispatch_render "$id" "$role" "$peer" "$rule" "$first" > "$SPL_DISPATCH_TMP/brief" || return 1
    if cmp -s "$SPL_DISPATCH_TMP/brief" "$brief"; then
      spl_dispatch_ok brief "$brief"
    else
      spl_dispatch_do brief "render $brief" bash -c 'mkdir -p "$(dirname "$2")" && cp "$1" "$2"' _ "$SPL_DISPATCH_TMP/brief" "$brief" || return 1
    fi
    # 4. worktree, before the spawn so the session starts with its settings;
    # the one do_spl_dispatch_check reads (the identity map's, else
    # <main checkout>-wt/<id>), so setup and check never name two dirs
    wt="$(spl_dispatch_worktree "$id")"
    if [[ -d "$wt" ]]; then
      spl_dispatch_ok worktree "$wt"
    else
      spl_dispatch_do worktree "git worktree add $wt -b $id-dispatcher-$role origin/master" \
        git -C "$DISPATCH_REPO" worktree add -b "$id-dispatcher-$role" "$wt" origin/master || return 1
    fi
    # 5. settings
    spl_dispatch_settings "$id" "$wt" || return 1
    # 6. spawn
    spl_dispatch_spawn "$id" "$role" "$brief" "$wt" || return 1
    # 7. desks
    spl_dispatch_desks "$id" || return 1
    # 8. legacy registry
    spl_dispatch_legacy_row "$id" || return 1
  done

  # 9. lease loops
  spl_dispatch_do lease-loops "LEASE_CMD=ensure do_spl_dispatch_lease" \
    spl_dispatch_lease_ensure || return 1

  # 10. channel subscriptions (its own plan lines; a subshell, so its scratch
  # dir is not this one)
  if [[ "${DISPATCH_SUBSCRIBE:-1}" != 0 ]]; then
    ( DRY_RUN=$dry do_spl_dispatch_subscribe ) || return 1
  fi

  # 11. the unanswered-post sweep cron (its own crontab diff in the dry run)
  if [[ "${DISPATCH_SWEEP:-1}" != 0 ]]; then
    ( DRY_RUN=$dry do_spl_unanswered_sweep_install_cron ) || return 1
  fi
  ((dry)) && do_log "OK DRY_RUN nothing was touched - re-run with DRY_RUN=0 to apply"
  return 0
}

# spl_dispatch_lease_conf_text: sets the caller's conf to the lease.conf this
# setup wants - the three roles, the fleet keys (given, or carried over from
# the current file so a re-run keeps fleet mode) and the asks timer's knobs
# (given, or carried over). 1 with the FATAL on a malformed knob.
spl_dispatch_lease_conf_text() {
  local k v
  conf="$(printf 'LEASE_MASTER=%s\nLEASE_FAILOVER=%s\nLEASE_ORCH=%s\n' "$DISPATCH_MASTER" "$DISPATCH_FAILOVER" "$DISPATCH_ORCH")"
  if [[ -n "${DISPATCH_FLEET:-}" ]]; then
    conf+=$'\n'"$(printf 'LEASE_FLEET=%s\nLEASE_PRIORITY=%s\nLEASE_ENV=%s\nLEASE_TENANT=%s' \
      "$DISPATCH_FLEET" "${DISPATCH_PRIORITY:-}" "$ENV" "${DISPATCH_LEASE_TENANT:-}")"
    # the machine and its desk box are pinned only when given: unset, both
    # follow box.env SPOOL_DESK_BOX, so a box rename needs no lease.conf edit
    [[ -n "${DISPATCH_MACHINE:-}" ]] && conf+=$'\n'"LEASE_MACHINE=$DISPATCH_MACHINE"
    [[ -n "${DESK_BOX:-}" ]] && conf+=$'\n'"LEASE_DESK_BOX=$DESK_BOX"
  elif grep -qE '^LEASE_FLEET=' "$LEASE_CONF" 2>/dev/null; then
    # a re-run without DISPATCH_FLEET keeps fleet mode: dropping it would let
    # this machine act beside the fleet's holder
    conf+=$'\n'"$(grep -E '^LEASE_(FLEET|MACHINE|PRIORITY|ENV|TENANT|DESK_BOX)=' "$LEASE_CONF")"
  fi
  # the asks timer's knobs (CLE-77929): given ones are written, the others
  # carried over from the current file, so a re-run never drops them
  for k in OWNER RERAISE_MIN OWNER_MIN LOCK_MIN MAX_RAISES; do
    v="DISPATCH_ASKS_$k"; v="${!v:-}"
    if [[ -z "$v" ]]; then
      v="$(sed -n "s/^ASKS_$k=//p" "$LEASE_CONF" 2>/dev/null | tail -1)"
    fi
    [[ -z "$v" ]] && continue
    [[ "$k" == OWNER && ! "$v" =~ ^HUM-[0-9]+$ ]] && { do_log "FATAL DISPATCH_ASKS_OWNER must be a human id (HUM-<n>), got '$v'"; return 1; }
    [[ "$k" != OWNER && ! "$v" =~ ^[0-9]+$ ]] && { do_log "FATAL DISPATCH_ASKS_$k must be minutes, got '$v'"; return 1; }
    conf+=$'\n'"ASKS_$k=$v"
  done
}

# Ids, dirs and the workspace list, shared with do_spl_dispatch_check.
spl_dispatch_cnf() {
  [[ "${ENV:-}" =~ ^(dev|prd)$ ]] || { do_log "FATAL ENV must be dev or prd"; return 1; }
  spl_lease_init ro || return 1
  # the role ids lease.conf names (spec 061 L6: c-001..003 after the switch);
  # a hard-coded CLE-00N here read both live dispatchers as "not running"
  spl_lease_conf
  DISPATCH_MASTER="${DISPATCH_MASTER:-${LEASE_MASTER:-c-002}}"
  DISPATCH_FAILOVER="${DISPATCH_FAILOVER:-${LEASE_FAILOVER:-c-003}}"
  DISPATCH_ORCH="${DISPATCH_ORCH:-${LEASE_ORCH:-c-001}}"
  local v
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  declare -F spl_dispatch_worktree >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-check.func.sh"
  for v in DISPATCH_MASTER DISPATCH_FAILOVER DISPATCH_ORCH; do
    spl_is_participant_id "${!v}" || { do_log "FATAL $v is not an agent id: '${!v}'"; return 1; }
  done
  [[ "$DISPATCH_MASTER" != "$DISPATCH_FAILOVER" ]] || { do_log "FATAL master and failover are the same id"; return 1; }
  # the MAIN checkout, also when this runs from another worktree of it (the
  # desk cron's checkout): the dispatcher worktrees sit next to the main one
  if [[ -z "${DISPATCH_REPO:-}" ]]; then
    local here common
    here="${APP_PATH:-$(cd "$PROJ_PATH/.." && pwd)}"
    common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    if [[ "$common" == */.git ]]; then DISPATCH_REPO="${common%/.git}"; else DISPATCH_REPO="$here"; fi
  fi
  DISPATCH_POSTS_DIR="${DISPATCH_POSTS_DIR:-$LEASE_DIR/posts}"
  DISPATCH_BRIEF_DIR="${DISPATCH_BRIEF_DIR:-$LEASE_DIR/briefs}"
  DISPATCH_BOX_USER="${DISPATCH_BOX_USER:-${SPOOL_BOX_USER:-$(id -un)}}"
  local org_app; org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"
  DISPATCH_STATE_DIR="${SPL_STATE_DIR:-$HOME/.local/share/$org_app/cloud/$ENV}"
  DISPATCH_DESK_BOX="${DESK_BOX:-$(spl_desk_box_default)}"
  if [[ -z "${DISPATCH_TENANTS:-}" ]]; then
    local d
    for d in "$DISPATCH_STATE_DIR"/desk/*/"$DISPATCH_DESK_BOX"/pinned; do
      [[ -e "$d" ]] || continue
      d="${d%/"$DISPATCH_DESK_BOX"/pinned}"; d="${d##*/}"
      if [[ " ${DISPATCH_SKIP_TENANTS-} " == *" $d "* ]] || spl_test_workspace "$d"; then continue; fi
      DISPATCH_TENANTS+="${DISPATCH_TENANTS:+ }$d"
    done
  fi
  [[ -n "${DISPATCH_TENANTS:-}" ]] || { do_log "FATAL no workspace: set DISPATCH_TENANTS (none pinned under $DISPATCH_STATE_DIR/desk)"; return 1; }
  SPL_DISPATCH_TMP="$(mktemp -d)" || return 1
}

spl_dispatch_lease_ensure() { LEASE_CMD=ensure do_spl_dispatch_lease; }

spl_dispatch_ok() { echo "OK   $1 $2"; }

# PLAN line in a dry run; the command itself otherwise.
spl_dispatch_do() {
  local step="$1" what="$2"; shift 2
  echo "PLAN $step $what"
  (( SPL_DISPATCH_DRY )) && return 0
  "$@" || { do_log "FATAL $step failed: $what"; return 1; }
}

spl_dispatch_render() {
  local tpl="$PROJ_PATH/src/bash/features/dispatch/brief-dispatcher.tpl.md"
  [[ -f "$tpl" ]] || { do_log "FATAL no brief template $tpl"; return 1; }
  ID="$1" ROLE="$2" PEER="$3" LEASE_RULE="$4" FIRST_STEP="$5" ORCH="$DISPATCH_ORCH" MASTER="$DISPATCH_MASTER" \
  FAILOVER="$DISPATCH_FAILOVER" SROOT="${SPOOL_ROOT:-/var/spool-hub}" POSTS="$DISPATCH_POSTS_DIR" ENVN="$ENV" \
  TENANTS="$(echo "$DISPATCH_TENANTS" | sed 's/ /, /g')" ORC="$PROJ_PATH" BOXU="$DISPATCH_BOX_USER" \
  python3 - "$tpl" <<'PY'
import os, sys
s = open(sys.argv[1]).read()
e = os.environ
for k, v in {"ID": e["ID"], "ROLE": e["ROLE"], "PEER": e["PEER"], "LEASE_RULE": e["LEASE_RULE"],
             "FIRST_STEP": e["FIRST_STEP"], "ORCH": e["ORCH"], "MASTER": e["MASTER"],
             "FAILOVER": e["FAILOVER"], "SPOOL_ROOT": e["SROOT"], "POSTS_DIR": e["POSTS"],
             "ENV": e["ENVN"], "TENANTS": e["TENANTS"], "ORC": e["ORC"], "BOX_USER": e["BOXU"]}.items():
    s = s.replace("{" + k + "}", v)
sys.stdout.write(s)
PY
}

# The one permission a dispatcher gets beyond auto mode: desk replies.
spl_dispatch_settings_json() {
  printf '{\n  "permissions": {\n    "allow": [\n      "Bash(sudo -u %s env ENV=%s * ./run -a do_spl_desk_reply)"\n    ]\n  }\n}\n' \
    "$DISPATCH_BOX_USER" "$ENV"
}

spl_dispatch_settings() {
  local id="$1" wt="$2" f="$2/.claude/settings.local.json" exc pid
  spl_dispatch_settings_json > "$SPL_DISPATCH_TMP/settings"
  if cmp -s "$SPL_DISPATCH_TMP/settings" "$f"; then
    spl_dispatch_ok settings "$f"
  else
    spl_dispatch_do settings "write $f (desk replies only)" \
      bash -c 'mkdir -p "$(dirname "$2")" && cp "$1" "$2"' _ "$SPL_DISPATCH_TMP/settings" "$f" || return 1
  fi
  exc="$(git -C "$DISPATCH_REPO" rev-parse --git-common-dir 2>/dev/null)/info/exclude"
  [[ "$exc" == /* ]] || exc="$DISPATCH_REPO/$exc"
  if grep -qx '.claude/settings.local.json' "$exc" 2>/dev/null; then
    spl_dispatch_ok exclude "$exc"
  else
    spl_dispatch_do exclude "add .claude/settings.local.json to $exc" \
      bash -c 'mkdir -p "$(dirname "$1")" && echo .claude/settings.local.json >> "$1"' _ "$exc" || return 1
  fi
  pid="$(spl_lease_agent_pid "$id")"
  if [[ -n "$pid" ]] && spl_dispatch_stale_settings "$pid" "$f"; then
    echo "RELAUNCH $id pid=$pid started before $f: relaunch it (resume its session) so the setting loads"
  fi
  return 0
}

# 0 when the process started before the settings file was last written (or the
# file is absent): such a session runs without it.
spl_dispatch_stale_settings() {
  local start mt
  start="$(stat -c %Y "${LEASE_PROC_ROOT:-/proc}/$1" 2>/dev/null)" || return 0
  mt="$(stat -c %Y "$2" 2>/dev/null)" || return 0
  (( start < mt ))
}

spl_dispatch_spawn() {
  local id="$1" role="$2" brief="$3" pid reuse=0
  pid="$(spl_lease_agent_pid "$id")"
  if [[ -n "$pid" ]]; then spl_dispatch_ok spawn "$id runs (pid $pid)"; return 0; fi
  [[ -d "${SPOOL_ROOT:-/var/spool-hub}/$id" ]] && reuse=1
  spl_dispatch_do spawn "spawn-window.sh claude $id $DISPATCH_REPO $brief dispatcher-$role (SPAWN_REUSE_ID=$reuse)" \
    env SPAWN_REUSE_ID=$reuse bash "$PROJ_PATH/src/bash/features/spawn-agents/scripts/spawn-window.sh" \
    claude "$id" "$DISPATCH_REPO" "$brief" "dispatcher-$role"
}

# 0 when <id> has a seat in workspace <t> on this box.
spl_dispatch_seated() {
  [[ -d "$DISPATCH_STATE_DIR/desk/$2/$DISPATCH_DESK_BOX/spool/$1" ]]
}

spl_dispatch_desks() {
  local id="$1" t key
  for t in $DISPATCH_TENANTS; do
    if spl_dispatch_seated "$id" "$t"; then spl_dispatch_ok desk "$id in $t"; continue; fi
    key=""
    [[ ! -e "$DISPATCH_STATE_DIR/desk/$t/$DISPATCH_DESK_BOX/pinned" && -n "${DISPATCH_ROOT_KEY_DIR:-}" ]] &&
      key="$DISPATCH_ROOT_KEY_DIR/$t.json"
    spl_dispatch_do desk "do_spl_desk_up ENV=$ENV TENANT_ID=$t DESK_AGENT=$id${key:+ ROOT_KEY_JSON=$key}" \
      env TENANT_ID="$t" DESK_AGENT="$id" DESK_BOX="$DISPATCH_DESK_BOX" ${key:+ROOT_KEY_JSON="$key"} DRY_RUN=0 \
      "$PROJ_PATH/run" -a do_spl_desk_up || return 1
  done
}

# Copy <id>'s newest row from the spool registry into the legacy registry.
spl_dispatch_legacy_row() {
  local id="$1" leg="${DISPATCH_LEGACY_REGISTRY:-}" row
  [[ -n "$leg" ]] || return 0
  row="$(grep -P "^\Q$id\E\t" "${SPOOL_ROOT:-/var/spool-hub}/registry.tsv" 2>/dev/null | tail -1)"
  if [[ -z "$row" ]]; then
    (( SPL_DISPATCH_DRY )) && { echo "PLAN legacy-registry copy $id's row after its spawn"; return 0; }
    do_log "WARN no $id row in the spool registry - nothing to copy"; return 0
  fi
  if grep -qxF "$row" "$leg" 2>/dev/null; then spl_dispatch_ok legacy-registry "$id"; return 0; fi
  spl_dispatch_do legacy-registry "append $id's row to $leg" bash -c 'printf "%s\n" "$2" >> "$1"' _ "$leg" "$row"
}
