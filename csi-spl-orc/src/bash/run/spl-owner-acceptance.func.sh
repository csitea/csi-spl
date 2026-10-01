#!/bin/bash
#------------------------------------------------------------------------------
# @description specs/031 — run the OWNER ACCEPTANCE cases from the WEB UI, in
# @description the topic the owner is watching, with one PASS/FAIL line per
# @description case posted back into that topic.
# @description
# @description The owner asked for this shape, not for a log: "put the same bot
# @description into the the web ui", "and start testing with it all of those
# @description terminal to msg cases", "here and make it do all of the test
# @description ases", "for te showing up of the messages ...". So the run is a
# @description transcript the owner can read where they already are.
# @description
# @description What it does:
# @description   1. resolves the bot's OWN member and its 0600 password from
# @description      the m3-e2e state dir of this env+tenant - the account that
# @description      harness already invited. NEVER the owner's account
# @description   2. drives a headless Chrome through
# @description      csi-spl-wui/tests/e2e/owner-acceptance-bot.proof.mjs: it
# @description      signs in, opens OA_TOPIC on OA_PEER, and runs the cases
# @description   3. each message case asserts BOTH halves - the row in the WUI
# @description      and the same message VISIBLE in the agent's pane, through
# @description      pane-seen.sh (the 028 rules live in bash, once)
# @description   4. the reply leg is do_spl_desk_reply into the SAME topic
# @description   5. evidence (screenshots, timings, results.json) lands in OUT
# @description
# @description The three timings are kept APART and never added: wui_ms (the
# @description row appearing), pane_s (delivery and visible in the terminal),
# @description reply_ms (how long the agent took to answer). A blended number
# @description would hide which leg is slow, which is the owner's own rule.
# @description
# @description It posts real messages into a real tenant's topic, so it is a
# @description DRY RUN unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the desk is seated in
# @param OA_TOPIC - required: the task UUID of the topic to run in (the
# @param   `?topic=` of the URL the owner is watching)
# @param OA_AGENT (optional) - the desk agent to talk to, default CLE-00
# @param OA_BOX (optional) - the desk box, default box-desk
# @param OA_EMAIL (optional) - the bot's member; default the m3-e2e member of
# @param   this state dir (dev: m3-e2e-human@example.com). Its password is read
# @param   from the 0600 $SPL_STATE_DIR/m3-e2e/<tenant>/pw-human and never printed
# @param OA_OUT (optional) - the proof dir, default
# @param   $SPL_STATE_DIR/owner-acceptance/<tenant>/<utc>
# @param OA_WUI_URL (optional) - the WUI origin, default https://<env.dns.fqdn>
# @param OA_PANE_TIMEOUT (optional) - seconds to wait for a pane, default 45
# @param OA_LIMIT_MS (optional) - budget for the sender's own row, default 1500
# @param OA_CASE_PAUSE_MS (optional) - pause between cases so the owner can
# @param   follow the run, default 4000
# @param OA_POST_RESULTS (optional) - 1 (default) posts the PASS/FAIL lines
# @param   into the topic; 0 keeps the topic clean and prints them only
# @param OA_TMUX_SOCK (optional) - the tmux socket the panes live on,
# @param   default /tmp/tmux-<uid>/default
# @param CHROME_PATH (optional) - default /usr/bin/google-chrome
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 OA_TOPIC=<uuid> DRY_RUN=0 ./run -a do_spl_owner_acceptance
#------------------------------------------------------------------------------
do_spl_owner_acceptance() {
  do_require_bin python3 yq node || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  local tenant="${TENANT_ID:-}" agent="${OA_AGENT:-CLE-00}" box="${OA_BOX:-$(spl_desk_box_default)}"
  local topic="${OA_TOPIC:-}"
  spl_desk_validate "$tenant" "$box" "$agent" || return 1
  spl_oa_validate "$topic" || return 1

  local wui out orc proof_js
  wui="${OA_WUI_URL:-https://$SPL_FQDN}"
  orc="$APP_PATH/$SPL_ORG_APP-orc"
  proof_js="$APP_PATH/$SPL_ORG_APP-wui/tests/e2e/owner-acceptance-bot.proof.mjs"
  out="${OA_OUT:-$SPL_STATE_DIR/owner-acceptance/$tenant/$(date -u +%Y%m%dT%H%M%SZ)}"

  local st="$SPL_STATE_DIR/m3-e2e/$tenant"
  local email="${OA_EMAIL:-m3-e2e-human@example.com}" pwf="$st/pw-human"

  if (( dry )); then
    do_log "INFO DRY_RUN would: sign $email in to $wui, open $wui/dm/$agent@$box?topic=$topic,"
    do_log "INFO DRY_RUN   run 7 cases there, assert each in $agent's pane via pane-seen.sh,"
    do_log "INFO DRY_RUN   answer with do_spl_desk_reply, and post a PASS/FAIL line per case into that topic."
    do_log "INFO DRY_RUN   evidence would land in $out"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to run the acceptance cases."
    return 0
  fi

  [[ -f "$proof_js" ]] || { do_log "FATAL no acceptance bot at $proof_js"; return 1; }
  [[ -s "$pwf" ]] || { do_log "FATAL no password for $email at $pwf: run do_spl_m3_e2e once for $ENV/$tenant to seat and verify that member"; return 1; }
  [[ -d "$SPL_STATE_DIR/desk/$tenant/$box/spool/$agent" ]] ||
    { do_log "FATAL no desk for $agent on $box in $tenant: run do_spl_desk_up first"; return 1; }

  local chrome="${CHROME_PATH:-/usr/bin/google-chrome}"
  [[ -x "$chrome" ]] || { do_log "FATAL no Chrome at $chrome (set CHROME_PATH)"; return 1; }
  local pc
  pc="$(command -v puppeteer-core 2>/dev/null)"
  mkdir -p "$out" && chmod 700 "$out" || return 1

  # The two legs the bot cannot do itself, each a NAMED thing in the tree
  # rather than an inline shell string invented here: the 028 pane assert, and
  # the documented reply action. $AGENT / $NEEDLE / $TIMEOUT and $TASK / $BODY
  # are set by the bot for each call.
  local pane_cmd reply_cmd
  pane_cmd="bash '$orc/src/bash/scripts/pane-seen.sh' --agent \"\$AGENT\" --needle \"\$NEEDLE\" --timeout \"\$TIMEOUT\" --sock '${OA_TMUX_SOCK:-/tmp/tmux-$(id -u)/default}'"
  reply_cmd="cd '$orc' && ENV='$ENV' TENANT_ID='$tenant' DESK_AGENT='$agent' DESK_BOX='$box' DESK_TASK=\"\$TASK\" DESK_BODY=\"\$BODY\" DRY_RUN=0 ./run -a do_spl_desk_reply"

  do_log "INFO owner acceptance on $ENV/$tenant: $email -> $agent@$box, topic $topic, evidence $out"
  local rc=0
  # `env`, not an assignment prefix: PANE_CMD and REPLY_CMD are whole shell
  # commands, and a multi-line assignment prefix carrying one is a parse that
  # fails obscurely (measured 2026-09-21: exit 127, "PANE_CMD=bash …: No such
  # file or directory", with the value read as the command name).
  local -a envv=(
    "BASE=$wui" "EMAIL=$email" "PW_FILE=$pwf" "PEER=$agent@$box" "OWNER_TOPIC=$topic"
    "OUT=$out" "TENANT=$tenant" "CHROME_PATH=$chrome"
    "PANE_CMD=$pane_cmd" "REPLY_CMD=$reply_cmd"
    "CASE_PAUSE_MS=${OA_CASE_PAUSE_MS:-4000}" "LIMIT_MS=${OA_LIMIT_MS:-1500}"
    "PANE_TIMEOUT=${OA_PANE_TIMEOUT:-45}" "POST_RESULTS=${OA_POST_RESULTS:-1}"
  )
  [[ -n "$pc" ]] && envv+=("PUPPETEER_CORE=$pc")
  ( cd "$APP_PATH/$SPL_ORG_APP-wui" && env "${envv[@]}" node "$proof_js" ) || rc=$?

  if (( rc == 0 )); then
    do_log "OK owner acceptance on $ENV/$tenant: every case PASS ($out/results.json)"
  else
    # A failing owner case is information. The action still reports where the
    # evidence is, because that is what the next reader needs.
    do_log "FAIL owner acceptance on $ENV/$tenant: a case did not pass (exit $rc). Evidence: $out/results.json"
  fi
  return $rc
}

# spl_oa_validate <topic>: the topic is the `?topic=` of the URL the owner
# watches, so it has to be a task UUID. A wrong one would silently start a NEW
# conversation next to the one they are reading, which is worse than an error.
spl_oa_validate() {
  local topic="${1:-}"
  [[ -n "$topic" ]] || { do_log "FATAL OA_TOPIC must be the task UUID of the topic to run in (the ?topic= of the URL)"; return 1; }
  [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL OA_TOPIC must be a lowercase task UUID, got: '$topic'"; return 1; }
  return 0
}
