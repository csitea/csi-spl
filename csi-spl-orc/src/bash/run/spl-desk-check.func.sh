#!/bin/bash
#------------------------------------------------------------------------------
# @description Is a desk agent actually REACHABLE, or only apparently so? The
# @description sidecar being alive is not the same fact as the hub having a
# @description session for it, and the gap between them is silent: the box's
# @description read loop blocks for ever on a socket whose far end is gone, so
# @description a hub redeploy strands a desk with no error, no log line and a
# @description healthy-looking process. Measured on dev 2026-09-21: sidecar up
# @description 17 minutes, `hub session up` its last word, TCP still ESTAB,
# @description the hub answering `online: false`, and 8 owner messages accepted
# @description by the hub that never reached the box.
# @description This compares the two facts and says which one is wrong:
# @description   local  - the hub-run sidecar's pid file, and whether it lives
# @description   hub    - GET /v1/view/roster: is DESK_BOX online, and does it
# @description            carry DESK_AGENT
# @description Verdicts: ok | muted (everything green, but the sidecar runs
# @description SPOOL_POKE=0 so the agent is never TOLD - measured 2026-09-22,
# @description two owner messages sat unread in an agent inbox while this action
# @description said ok) | stranded (process alive, hub says offline - the silent
# @description one) | down (no sidecar) | unpinned (the hub does not know this
# @description box) | agent-missing (box online, agent not announced).
# @description It also prints spool_root, which is NOT /var/spool-hub: a desk has
# @description its own root under the state dir, and measuring the wrong tree is
# @description how an afternoon went into "the messages were never delivered"
# @description when they were sitting in the desk inbox all along (2026-09-22).
# @description Read-only. DESK_REPAIR=1 with DRY_RUN=0 restarts a desk that is
# @description stranded or down, which is the documented recovery until the box
# @description client detects a dead session by itself.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the seated agent id
# @param DESK_BOX (optional) - default box-desk
# @param DESK_REPAIR (optional) - 1 = restart a stranded/down desk (needs DRY_RUN=0)
# @description Also reports sidecar_stale_build: the bytes the process is
# @description running differ from the spool binary now on disk, so a restart
# @description would give it different code. Expect this to be TRUE often on a
# @description busy box - trunk moves and every action that builds rewrites the
# @description shared binary - so it is advisory, not a fault. It matters when
# @description you are about to MEASURE whether a fix works: do not measure a
# @description sidecar that predates it.
# @param DESK_ROSTER_JSON (optional) - read the roster from this file instead of
# @param   the hub (the tests' seam; also useful against a saved capture)
# @param PROBE_EMAIL / PROBE_PW_FILE (optional) - the member session the roster
# @param   read uses, as do_spl_roster_show documents them
# @param DRY_RUN (optional) - 1 (default) or 0; only DESK_REPAIR needs 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 ./run -a do_spl_desk_check
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_REPAIR=1 DRY_RUN=0 ./run -a do_spl_desk_check
#------------------------------------------------------------------------------
do_spl_desk_check() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  local repair="${DESK_REPAIR:-0}"
  [[ "$repair" == 0 || "$repair" == 1 ]] || { do_log "FATAL DESK_REPAIR must be 0 or 1, got: '$repair'"; return 1; }

  local d="$SPL_STATE_DIR/desk/$tenant/$box" pidf pid="" alive=0
  pidf="$d/spool/.hub/hub-run.pid"
  if spl_desk_alive "$pidf"; then alive=1; pid="$(cat "$pidf")"; fi

  local stale=0
  (( alive )) && spl_desk_stale_build "$pid" && stale=1

  # The EFFECTIVE prompt leg for THIS agent: the box-wide flag the sidecar
  # actually runs under (read from the process - it is consumed at exec, so
  # nothing else knows it) AND the per-agent marker the notifier reads.
  local boxpoke="" livepoke=""
  if (( alive )); then
    boxpoke="$(spl_desk_sidecar_poke "$pid")"
    if [[ -e "$d/spool/$agent/.no-poke" ]]; then livepoke=0
    else livepoke="$boxpoke"; fi
  fi

  local roster
  # NAME the failure. This used to be `roster="$(...)" || return 1`, and a
  # roster read that failed printed NOTHING AT ALL: the action exited 1 with
  # three framework lines and no reason. Measured 2026-09-22 with six agents on
  # the box, where the real answer was
  #   {"step": "login", "status": 429, "error": "rate_limited"}
  # and finding that took running roster-show.py by hand. A health check that
  # cannot say why it failed is the same defect as a desk that cannot say why a
  # message did not arrive, which is what this whole action exists for.
  local rrc=0
  roster="$(spl_desk_roster "$tenant")" || rrc=$?
  if (( rrc )); then
    do_log "FATAL cannot read the roster for $tenant (exit $rrc). What the read returned:"
    do_log "FATAL   ${roster:-<nothing>}"
    do_log "FATAL A 429 here is this box's own agents competing for the member login; retry, or pass DESK_ROSTER_JSON to read a saved capture."
    return 1
  fi
  local verdict
  verdict="$(spl_desk_verdict "$roster" "$box" "$agent" "$alive" "$livepoke")" || {
    do_log "FATAL cannot read the roster for $box/$agent"; return 1; }

  python3 - "$ENV" "$tenant" "$box" "$agent" "$pid" "$alive" "$verdict" "$d" "$stale" "$livepoke" "$boxpoke" <<'EOF_PY'
import json, sys
env, tenant, box, agent, pid, alive, verdict, state, stale, poke, boxpoke = sys.argv[1:]
v, online, listed, hello = (verdict.split("\t") + ["", "", ""])[:4]
print(json.dumps({"env": env, "tenant": tenant, "box": box, "agent": agent,
                  "verdict": v, "sidecar_pid": int(pid) if pid else None,
                  "sidecar_alive": alive == "1", "hub_box_online": online == "1",
                  "hub_lists_agent": listed == "1", "hub_last_hello_at": hello or None,
                  "sidecar_stale_build": stale == "1", "state_dir": state,
                  "spool_root": state + "/spool",
                  "terminal_poke": None if poke == "" else poke == "1",
                  "terminal_poke_box": None if boxpoke == "" else boxpoke == "1",
                  "agent_muted": poke == "0" and boxpoke == "1"}, sort_keys=True))
EOF_PY
  (( stale )) && do_log "INFO the sidecar of $box is NOT running the spool binary now on disk: restart it (do_spl_desk_up rebuilds) before measuring anything that depends on a recent fix"
  local v="${verdict%%$'\t'*}"
  case "$v" in
    ok) do_log "OK $agent on $box is reachable in $tenant ($ENV): the sidecar is up AND the hub has a session for it"
        do_log "OK its inbox is $d/spool/$agent/inbox (the DESK root, not /var/spool-hub)"; return 0 ;;
    muted)
      do_log "FAIL $agent on $box is MUTED in $tenant ($ENV): every leg is green and the sidecar runs SPOOL_POKE=0."
      do_log "FAIL A DM lands in $d/spool/$agent/inbox and is shown in the notice strip, and the agent is never TOLD - an agent reads its prompt, not its pane."
      if [[ -e "$d/spool/$agent/.no-poke" ]]; then
        do_log "FAIL This ONE seat is muted by $d/spool/$agent/.no-poke. Recover: DESK_POKE=1 DRY_RUN=0 do_spl_desk_up"
      else
        do_log "FAIL The WHOLE BOX is muted: the sidecar runs SPOOL_POKE=0, so every agent on $box is in this state. Recover: DESK_BOX_POKE=1 DRY_RUN=0 do_spl_desk_up (the flag is read at exec, so the sidecar is restarted)"
      fi ;;
    stranded)
      do_log "FAIL $agent on $box is STRANDED in $tenant ($ENV): the sidecar (pid $pid) is alive and the hub says the box is OFFLINE."
      do_log "FAIL Messages the hub accepts are NOT reaching this box, and nothing logs it. Recover: DESK_REPAIR=1 DRY_RUN=0" ;;
    down)        do_log "FAIL no live hub-run sidecar for $box in $tenant ($ENV). Recover: do_spl_desk_up" ;;
    unpinned)    do_log "FAIL the hub does not know box $box in $tenant ($ENV): it was never pinned, or the pin was revoked" ;;
    agent-missing) do_log "FAIL box $box is online in $tenant ($ENV) but the hub does not list $agent on it" ;;
  esac
  spl_desk_repair "$v" "$repair" "$tenant" "$box" "$agent"
}

# spl_desk_same_file <a> <b>: 0 when both exist and hold identical bytes.
spl_desk_same_file() {
  local a b
  [[ -r "$1" && -r "$2" ]] || return 2
  a="$(sha256sum <"$1" 2>/dev/null | cut -d" " -f1)" || return 2
  b="$(sha256sum <"$2" 2>/dev/null | cut -d" " -f1)" || return 2
  [[ -n "$a" && "$a" == "$b" ]]
}

# spl_desk_stale_build <pid>: 0 when the RUNNING process is not the binary now
# on disk - it started before a rebuild and is executing older code.
#
# Compared by CONTENT, not by mtime. Every agent on this box shares
# $SPL_STATE_DIR/bin/spool and any action calling spl_host_spool rewrites it,
# so "the file is newer than the process" is true almost always and says
# nothing (measured 2026-09-21: it reported stale one minute after a restart
# that had just rebuilt). /proc/<pid>/exe still reads the bytes the process
# actually runs, even once the path has been replaced, so hashing both answers
# the question that matters: is the running code the current code.
spl_desk_stale_build() {
  local pid="$1" bin="$SPL_STATE_DIR/bin/spool"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ -r "/proc/$pid/exe" && -r "$bin" ]] || return 1
  spl_desk_same_file "/proc/$pid/exe" "$bin" && return 1
  return 0
}

# spl_desk_roster <tenant>: the live roster JSON, or the file DESK_ROSTER_JSON
# names. Same member session do_spl_roster_show documents.
spl_desk_roster() {
  local tenant="$1" api pw
  if [[ -n "${DESK_ROSTER_JSON:-}" ]]; then
    [[ -r "$DESK_ROSTER_JSON" ]] || { do_log "FATAL cannot read DESK_ROSTER_JSON $DESK_ROSTER_JSON"; return 1; }
    cat "$DESK_ROSTER_JSON"; return 0
  fi
  api="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set PROBE_PW_FILE, or DESK_ROSTER_JSON)"; return 1; }
  PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" \
    PROBE_EMAIL="${PROBE_EMAIL:-m3-e2e-human@example.com}" PROBE_PW_FILE="$pw" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/roster-show.py"
}

# spl_desk_verdict <roster json> <box> <agent> <alive> [poke]: "<verdict>\t<online>\t<listed>\t<last hello>"
spl_desk_verdict() {
  python3 - "$1" "$2" "$3" "$4" "${5:-}" <<'EOF_PY'
import json, sys
raw, box, agent, alive = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
poke = sys.argv[5] if len(sys.argv) > 5 else ""
try:
    boxes = (json.loads(raw) or {}).get("boxes", [])
except ValueError:
    sys.exit(1)
row = next((b for b in boxes if isinstance(b, dict) and b.get("box_id") == box), None)
online = bool(row and row.get("online") and not row.get("revoked"))
listed = bool(row and agent in (row.get("agents") or []))
hello = (row or {}).get("last_hello_at") or ""
if row is None:
    v = "unpinned"
elif not alive:
    v = "down"
elif not online:
    # The silent one: this process believes it has a session the hub has
    # forgotten, so it waits on a socket nothing will ever write to again.
    v = "stranded"
elif not listed:
    v = "agent-missing"
elif poke == "0":
    # Everything a health check used to look at is green here. The message is
    # delivered, the strip shows it, and the one leg that reaches the agent -
    # its prompt - is switched off, so nothing is acted on and nothing logs a
    # failure. That is worse than down: down is visible.
    v = "muted"
else:
    v = "ok"
print("\t".join([v, "1" if online else "0", "1" if listed else "0", hello]))
EOF_PY
}

# spl_desk_repair <verdict> <repair> <tenant> <box> <agent>: the documented
# recovery, only for the two verdicts a restart actually fixes.
spl_desk_repair() {
  local v="$1" repair="$2" tenant="$3" box="$4" agent="$5"
  [[ "$v" == ok ]] && return 0
  if [[ "$repair" != 1 ]]; then
    do_log "INFO not repairing (DESK_REPAIR is not 1)"; return 1
  fi
  [[ "$v" == stranded || "$v" == down || "$v" == muted ]] || {
    do_log "FATAL '$v' is not something a restart fixes; look at the pin and the tenant"; return 1; }
  if spl_dry_run; then
    do_log "INFO DRY_RUN would: restart the desk $agent@$box in $tenant ($v). Re-run with DRY_RUN=0."
    return 1
  fi
  do_log "INFO repairing a '$v' desk: do_spl_desk_down then do_spl_desk_up for $agent@$box"
  TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="$agent" DRY_RUN=0 do_spl_desk_down || return 1
  # A muted desk is repaired by turning the prompt leg back ON - restarting it
  # with the same SPOOL_POKE=0 would come back muted and report success.
  TENANT_ID="$tenant" DESK_BOX="$box" DESK_AGENT="$agent" DESK_POKE=1 DRY_RUN=0 do_spl_desk_up || return 1
  do_log "OK repaired: $agent@$box has a fresh sidecar and the hub has a session for it again"
}
