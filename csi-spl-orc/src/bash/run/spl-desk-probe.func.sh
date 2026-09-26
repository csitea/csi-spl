#!/bin/bash
#------------------------------------------------------------------------------
# @description Prove the round trip of a desk agent (do_spl_desk_up) end to
# @description end, the way a human uses it:
# @description   1. a scripted MEMBER session signs in and opens /v1/wui/ws
# @description      (the same login and socket m3-e2e.py uses - one renderer of
# @description      the WS protocol on this box, not two)
# @description   2. the hub's roster answers that DESK_AGENT sits on DESK_BOX
# @description      and the box is online (what turns the DM page's dot green)
# @description   3. the member DMs DESK_AGENT; the hub must ack it to DESK_BOX
# @description   4. the message must be in the agent's inbox on THIS machine
# @description   5. it must be VISIBLE in the agent's own tmux pane - the pane
# @description      whose window name carries the id (specs/028). When no live
# @description      window carries it, that step is OBSERVED, not FAIL: the
# @description      message is still delivered
# @description   6. the documented reply leg (do_spl_desk_reply) must put the
# @description      answer back in the SAME topic, and the browser's socket
# @description      must receive it
# @description The probe writes results.json next to the desk state and prints
# @description one PASS/FAIL line per step. It sends real messages into the
# @description tenant, so it is a dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the seated agent id
# @param DESK_BOX (optional) - default box-desk, the same value do_spl_desk_up used
# @param DESK_HUMAN_EMAIL (optional) - the member that DMs the agent; default the
# @param   m3-e2e member of this state dir (m3-e2e-human@example.com on dev).
# @param   Its password lives in the m3-e2e state dir, 0600, and is never printed
# @param DESK_NOTIFY_CMD (optional) - the box's terminal-leg renderer; the probe
# @param   asks it for its verdict when the pane shows nothing (its exit code is
# @param   poke-line.md section 3). Default the orc feature's spool-notify.sh
# @param DESK_TMUX_SOCK (optional) - the tmux socket the panes live on,
# @param   default /tmp/tmux-<uid>/default
# @param DESK_CHANNEL (optional) - SPL-950: post a topic into this channel and a
# @param   thread reply under it (no channel tag, to ALL-0) instead of a DM; the
# @param   reply must reach DESK_AGENT, which must be a member of the channel
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=CLE-00 DRY_RUN=0 ./run -a do_spl_desk_probe
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_CHANNEL=spl-950-probe DRY_RUN=0 ./run -a do_spl_desk_probe
#------------------------------------------------------------------------------
do_spl_desk_probe() {
  do_require_bin python3 yq tmux || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" agent="${DESK_AGENT:-}" ch="${DESK_CHANNEL:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  [[ -z "$ch" || "$ch" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL DESK_CHANNEL must be a channel id, got: '$ch'"; return 1; }

  local api_fqdn hub d
  api_fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api_fqdn" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  hub="https://$api_fqdn"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    if [[ -n "$ch" ]]; then
      do_log "INFO DRY_RUN would: sign a member in, post a topic into #$ch on $hub and a thread reply under it, assert the reply in $agent@$box's inbox and pane, and answer with do_spl_desk_reply"
    else
      do_log "INFO DRY_RUN would: sign a member in, DM $agent@$box on $hub, assert its inbox and its pane, and answer with do_spl_desk_reply"
    fi
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to probe."
    return 0
  fi
  [[ -d "$d/spool/$agent" ]] || { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first ($d)"; return 1; }
  spl_host_spool || return 1

  # The member human and its 0600 password file are the m3-e2e state dir's: the
  # account is already invited there, so the probe never touches the invite path.
  local m3st="$SPL_STATE_DIR/m3-e2e/$tenant"
  mkdir -p "$m3st" && chmod 700 "$m3st" || return 1
  local orc="$APP_PATH/$SPL_ORG_APP-orc"
  local reply_cmd
  reply_cmd="$(python3 -c 'import json,sys; print(json.dumps([sys.argv[1], "-a", "do_spl_desk_reply"]))' "$orc/run")"
  local out="$d/probe-results.json" rc=0
  DESK_AGENT="$agent" DESK_BOX="$box" DESK_ROOT="$d/spool" DESK_OUT="$out" DESK_CHANNEL="$ch" \
  DESK_REPLY_CMD="$reply_cmd" DESK_REPLY_CWD="$orc" \
  DESK_NOTIFY_CMD="${DESK_NOTIFY_CMD-$orc/src/bash/features/spawn-agents/scripts/spool-notify.sh}" \
  DESK_TMUX_SOCK="${DESK_TMUX_SOCK:-/tmp/tmux-$(id -u)/default}" \
  ENV="$ENV" TENANT_ID="$tenant" DRY_RUN=0 \
  M3_HUB_URL="$hub" M3_AUTH_URL="$hub" M3_TENANT="$tenant" M3_STATE="$m3st" M3_SPOOL="$SPL_SPOOL" \
  M3_HUMAN_EMAIL="${DESK_HUMAN_EMAIL:-m3-e2e-human@example.com}" \
    python3 "$orc/src/bash/scripts/desk-probe.py" || rc=$?
  (( rc == 0 )) || { do_log "FAIL the desk round trip of $agent@$box in $tenant ($ENV): see $out"; return 1; }
  do_log "OK the desk round trip of $agent@$box in $tenant ($ENV): every step PASS ($out)"
}
