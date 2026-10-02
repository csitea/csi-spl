#!/bin/bash
#------------------------------------------------------------------------------
# @description Live proof of SPL-987 (specs/038 FR-020..FR-022) on a cloud env's
# @description DEPLOYED hub: an agent added to a channel receives the posts
# @description made there BEFORE it was added, plus ONE summary poke.
# @description   1. a throwaway probe box (its own key, SPOOL_ROOT and hub-run
# @description      sidecar) is pinned with the tenant root key; its notifier is
# @description      a logger that records every poke instead of typing it
# @description   2. a fresh channel bf-probe-<utc> is created by the signed-in
# @description      test member, who seats the POSTER agent in it
# @description   3. the poster makes PROBE_POSTS channel posts (spool send
# @description      --channel), each a new topic
# @description   4. the member invites the TARGET agent (POST
# @description      /v1/channels/{ch}/agents, the WUI's Properties call)
# @description   5. PASS = the target's inbox holds exactly those posts and the
# @description      logger holds exactly one poke for it, reading
# @description      "added to #<ch>: <n> earlier messages in <n> topics"
# @description   6. a re-invite adds nothing (FR-022)
# @description The sidecar is stopped at the end; the channel stays (a test
# @description tenant's probe channel). Prints one JSON verdict. Use the dev
# @description test tenant or the prd e2e tenant only. Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (dev t1 / prd e2e)
# @param PROBE_POSTS (optional) - posts before the invite, 1..20, default 3
# @param PROBE_BOX (optional) - the probe box id, default box-bfprobe
# @param PROBE_POSTER (optional) - default PRB-9871
# @param PROBE_AGENT (optional) - the agent that is invited, default PRB-9872
# @param ROOT_KEY (optional) - the tenant root private key file (0600), default
# @param   <state>/m3-e2e/<tenant>/root.key (the M3 e2e harness writes it)
# @param MEMBER_EMAIL (optional) - default m3-e2e-human@example.com
# @param MEMBER_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_WAIT_SECS (optional) - how long to wait for the back-fill, default 60
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_backfill_probe
#------------------------------------------------------------------------------
do_spl_backfill_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" n="${PROBE_POSTS:-3}" box="${PROBE_BOX:-box-bfprobe}"
  local poster="${PROBE_POSTER:-PRB-9871}" target="${PROBE_AGENT:-PRB-9872}" wait="${PROBE_WAIT_SECS:-60}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 20 )) || { do_log "FATAL PROBE_POSTS must be 1..20, got: '$n'"; return 1; }
  [[ "$wait" =~ ^[0-9]+$ ]] || { do_log "FATAL PROBE_WAIT_SECS must be a whole number, got: '$wait'"; return 1; }
  [[ "$box" =~ ^box-[a-z0-9][a-z0-9-]{0,26}$ && "$box" != box-wui && "$box" != box-desk ]] ||
    { do_log "FATAL PROBE_BOX must be a throwaway box-* id (not box-wui / box-desk), got: '$box'"; return 1; }
  local a
  for a in "$poster" "$target"; do
    [[ "$a" =~ ^[A-Z]{2,4}-[0-9]+$ && "${a%%-*}" != HUM ]] || { do_log "FATAL '$a' is not an agent id"; return 1; }
  done
  [[ "$poster" != "$target" ]] || { do_log "FATAL PROBE_POSTER and PROBE_AGENT must differ"; return 1; }
  local api ch
  api="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  ch="bf-probe-$(date -u +%Y%m%d%H%M%S)"
  if (( dry )); then
    do_log "INFO DRY_RUN would: pin $box under $tenant at https://$api with a logger notifier, create #$ch,"
    do_log "INFO DRY_RUN would: seat $poster, post $n times, invite $target, and read its inbox + pokes"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0."
    return 0
  fi
  local key="${ROOT_KEY:-$SPL_STATE_DIR/m3-e2e/$tenant/root.key}"
  local pw="${MEMBER_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -s "$key" && "$(stat -c %a "$key")" == 600 ]] || { do_log "FATAL ROOT_KEY $key must be a non-empty 0600 file"; return 1; }
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set MEMBER_PW_FILE)"; return 1; }
  do_require_bin curl setsid || return 1
  spl_host_spool || return 1

  local d="$SPL_STATE_DIR/backfill-probe/$tenant/$ch" hub="https://$api"
  mkdir -p "$d/spool/$poster/inbox" "$d/spool/$target/inbox" "$d/spool/.hub" "$d/keys" || return 1
  chmod -R go-rwx "$d" || return 1
  # The logger notifier: one line per poke, "<args> | <body>". Nothing typed.
  cat >"$d/notify.sh" <<EOF
#!/bin/sh
printf '%s | %s\n' "\$*" "\$(cat)" >>"$d/pokes.log"
EOF
  chmod 0700 "$d/notify.sh"

  local pub out rc=0
  pub="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- keygen 2>&1)" || { do_log "FATAL keygen for $box: $pub"; return 1; }
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-pin --box "$box" --pubkey "$pub" --root-key "$key" 2>&1)" || rc=$?
  (( rc == 0 )) || { do_log "FATAL hub-pin $box under $tenant: $out"; return 1; }
  SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" SPOOL_HUB_URL="$hub" \
    SPOOL_TENANT="$tenant" SPOOL_NOTIFY_CMD="$d/notify.sh" \
    spl_desk_detach "$d/spool/.hub/hub-run.log" "$SPL_SPOOL" hub-run
  local pid=$!
  printf '%s\n' "$pid" >"$d/spool/.hub/hub-run.pid"
  spl_backfill_probe_run "$d" "$box" "$tenant" "$hub" "$api" "$ch" "$poster" "$target" "$n" "$wait" "$pw"
  rc=$?
  kill "$pid" 2>/dev/null
  return $rc
}

# spl_backfill_probe_run <dir> <box> <tenant> <hub> <api> <ch> <poster> <target>
# <n> <wait secs> <pw file>: steps 2..6 against a live probe sidecar.
spl_backfill_probe_run() {
  local d="$1" box="$2" tenant="$3" hub="$4" api="$5" ch="$6" poster="$7" target="$8" n="$9" wait="${10}" pw="${11}"
  local seat="$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/channel-agent-add.py" out i
  spl_desk_wait_roster "$d" "$box" "$target" 30 || { do_log "FATAL the hub never announced $target on $box"; return 1; }
  out="$(SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ch" SEAT_AGENTS="$poster" SEAT_BOX="$box" SEAT_CREATE=1 python3 "$seat")" ||
    { do_log "FATAL creating #$ch and seating $poster: $out"; return 1; }
  local sent=()
  for ((i = 1; i <= n; i++)); do
    out="$(SPOOL_SUBMIT_SOCKET=off spl_desk_spool "$d" "$box" "$tenant" "$hub" -- send --from "$poster" --channel "$ch" \
      --body "SPL-987 back-fill probe post $i of $n in #$ch" 2>&1)" || { do_log "FATAL post $i: $out"; return 1; }
    sent+=("$(printf '%s' "$out" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)")
  done
  local before
  before="$(find "$d/spool/$target/inbox" -name '*.json' | wc -l)"
  out="$(SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ch" SEAT_AGENTS="$target" SEAT_BOX="$box" SEAT_CREATE=0 python3 "$seat")" ||
    { do_log "FATAL inviting $target into #$ch: $out"; return 1; }
  local got=0 pokes=0
  for ((i = 0; i < wait * 2; i++)); do
    got="$(find "$d/spool/$target/inbox" -name '*.json' | wc -l)"
    pokes="$(grep -c -- "--to $target " "$d/pokes.log" 2>/dev/null)" || pokes=0
    (( got - before >= n && pokes >= 1 )) && break
    sleep 0.5
  done
  # FR-022: a re-invite must add nothing.
  SEAT_API="https://$api" SEAT_TENANT="$tenant" SEAT_EMAIL="${MEMBER_EMAIL:-m3-e2e-human@example.com}" \
    SEAT_PW_FILE="$pw" SEAT_CHANNEL="$ch" SEAT_AGENTS="$target" SEAT_BOX="$box" SEAT_CREATE=0 python3 "$seat" >/dev/null 2>&1
  sleep 5
  got="$(find "$d/spool/$target/inbox" -name '*.json' | wc -l)"
  pokes="$(grep -c -- "--to $target " "$d/pokes.log" 2>/dev/null)" || pokes=0
  local line want="added to #$ch: $n earlier $( ((n == 1)) && echo message || echo messages) in $n $( ((n == 1)) && echo topic || echo topics)"
  line="$(grep -- "--to $target " "$d/pokes.log" 2>/dev/null | head -1)"
  local ok=1 ids missing=""
  ids="$(cat "$d/spool/$target/inbox/"*.json 2>/dev/null)"
  for i in "${sent[@]}"; do
    [[ -n "$i" && "$ids" == *"$i"* ]] || { ok=0; missing+="$i "; }
  done
  (( got - before == n && pokes == 1 )) || ok=0
  [[ "$line" == *"$want"* ]] || ok=0
  python3 -c 'import json,sys; print(json.dumps({"verdict": "PASS" if sys.argv[1]=="1" else "FAIL",
    "channel": sys.argv[2], "box": sys.argv[3], "agent": sys.argv[4], "posts": int(sys.argv[5]),
    "inbox_new": int(sys.argv[6]), "pokes": int(sys.argv[7]), "missing": sys.argv[8].split(),
    "poke_line": sys.argv[9].split(" | ",1)[-1], "state_dir": sys.argv[10]}, sort_keys=True))' \
    "$ok" "$ch" "$box" "$target" "$n" "$((got - before))" "$pokes" "$missing" "$line" "$d"
  (( ok )) || { do_log "FAIL the back-fill of $target in #$ch did not match (see the JSON line)"; return 1; }
  do_log "OK $target received the $n earlier posts of #$ch and exactly one summary poke"
}
