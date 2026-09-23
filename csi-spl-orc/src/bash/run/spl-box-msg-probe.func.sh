#!/bin/bash
#------------------------------------------------------------------------------
# @description Send ONE clearly labelled test message from a probe box on THIS
# @description machine into a cloud tenant, and print the hub's answer: the
# @description smallest box-path proof that a message reaches the hub (and so
# @description its Postgres, shown by do_spl_db_message_show). Works on prd:
# @description no debug token, no human, no invite.
# @description   1. the probe box (default box-orc-probe, agent ORC-1) gets its
# @description      own SPOOL_ROOT + key under the state dir; the FIRST run
# @description      mints the key and pins it with the tenant root key
# @description      (`spool hub-pin`, POST /v1/pins: the documented pin path);
# @description      later runs reuse key and pin
# @description   2. `spool hub-sync` (hello)
# @description   3. `spool send --kind note` from the probe agent to ITSELF on
# @description      the probe box, body "[orc-probe] <label> <utc>", so no other
# @description      box or human receives it. SPOOL_MIRROR_LOCAL=1: a same-box
# @description      send otherwise stays local and never reaches the hub
# @description   4. `spool hub-sync` again: the hub delivers it back
# @description   5. `spool hub-tail --task <id> --json`: the hub reads it back
# @description      from its store; the run FAILS unless the msg_id is there
# @description Prints one JSON line (msg_id, task_id, body_sha256_16, the sync
# @description reports, the tail) and nothing secret: the root key is copied
# @description into a 0600 scratch file and removed. Remove the probe box with
# @description `spool hub-pin --revoke` (printed at the end).
# @description Dry run unless DRY_RUN=0.
# @description TEARDOWN: the box is pinned ONCE and reused by every later
# @description run, so nothing here removes it and the roster keeps it
# @description forever. When the rig is finished with, run
# @description   ENV=<env> TENANT_ID=<t> BOX_IDS=<box> DRY_RUN=0 ./run -a do_spl_box_purge
# @description (pin-semantics.md 6: a signed revoke would NOT take it out of
# @description GET /v1/view/roster - only removing the pin row does).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param ROOT_KEY_JSON - required: the 0600 JSON do_spl_tenant_create wrote (root_private_key)
# @param PROBE_BOX (optional) - default box-orc-probe
# @param PROBE_AGENT (optional) - default ORC-1
# @param PROBE_LABEL (optional) - free text in the body, default "message-to-db"
# @param PROBE_TASK (optional) - post into this existing topic (a task UUID, e.g.
#   the tenant lobby) instead of a fresh one, so a browser following that
#   topic sees the box send pushed live (013 US7, CLE-3412)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 ROOT_KEY_JSON=/var/csi/csi-spl/tenants/prd/t1.<ts>.json DRY_RUN=0 ./run -a do_spl_box_msg_probe
#------------------------------------------------------------------------------
do_spl_box_msg_probe() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-orc-probe}" agent="${PROBE_AGENT:-ORC-1}"
  local label="${PROBE_LABEL:-message-to-db}" rkj="${ROOT_KEY_JSON:-}" ptask="${PROBE_TASK:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL PROBE_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ "$agent" =~ ^[A-Z]{2,4}-[0-9]+$ ]] || { do_log "FATAL PROBE_AGENT '$agent' is not an agent id (e.g. ORC-1)"; return 1; }
  [[ "$label" =~ ^[A-Za-z0-9._\ -]{1,64}$ ]] || { do_log "FATAL PROBE_LABEL must be 1..64 of [A-Za-z0-9._ -]"; return 1; }
  [[ -z "$ptask" || "$ptask" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { do_log "FATAL PROBE_TASK must be a lowercase task UUID, got: '$ptask'"; return 1; }
  [[ -s "$rkj" ]] || { do_log "FATAL ROOT_KEY_JSON must name the tenant's saved create JSON (got '$rkj')"; return 1; }
  [[ "$(stat -c %a "$rkj")" == 600 ]] || { do_log "FATAL $rkj must be mode 0600"; return 1; }

  local hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")" d="$SPL_STATE_DIR/probe/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: keygen + hub-pin $box under $tenant at $hub (first run only; state $d)"
    do_log "INFO DRY_RUN would: send one note $agent@$box -> $agent@$box${ptask:+ into task $ptask} body '[orc-probe] $label <utc>', hub-sync, hub-tail"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to send."
    return 0
  fi
  do_require_bin curl || return 1
  spl_host_spool || return 1
  mkdir -p "$d/spool/$agent" "$d/keys" && chmod -R go-rwx "$d" || return 1
  _probe() { SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" SPOOL_MIRROR_LOCAL=1 "$SPL_SPOOL" "$@"; }

  local out rc=0
  if [[ ! -f "$d/pinned" ]]; then
    local pub key
    pub="$(_probe keygen 2>&1)" || { do_log "FATAL keygen for $box: $pub"; return 1; }
    key="$(umask 077 && mktemp)" || return 1
    python3 -c 'import json,sys; open(sys.argv[2],"w").write(json.load(open(sys.argv[1]))["root_private_key"].strip()+"\n")' \
      "$rkj" "$key" 2>/dev/null || { rm -f "$key"; do_log "FATAL no root_private_key in $rkj"; return 1; }
    out="$(_probe hub-pin --box "$box" --pubkey "$pub" --root-key "$key" 2>&1)" || rc=$?
    rm -f "$key"
    (( rc == 0 )) || { do_log "FATAL hub-pin $box under $tenant: $out"; return 1; }
    printf '%s\n' "$pub" >"$d/pinned"
    do_log "INFO pinned $box ($pub) under $tenant at $hub"
  fi

  local sync1 sent sync2 tail stamp body
  sync1="$(_probe hub-sync 2>&1)" || { do_log "FATAL first hub-sync of $box: $sync1"; return 1; }
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  body="[orc-probe] $label $stamp"
  local task_arg=()
  [[ -n "$ptask" ]] && task_arg=(--task "$ptask")
  sent="$(_probe send --from "$agent" --to "$agent" --to-box "$box" "${task_arg[@]}" --kind note --body "$body" 2>&1)" ||
    { do_log "FATAL send from $agent@$box: $sent"; return 1; }
  sync2="$(_probe hub-sync 2>&1)" || { do_log "FATAL second hub-sync of $box: $sync2"; return 1; }
  local task msg
  task="$(yq -p json -r '.task_id // ""' <<<"$sent")"
  msg="$(yq -p json -r '.msg_id // ""' <<<"$sent")"
  tail="$(_probe hub-tail --task "$task" --json 2>&1)" || rc=$?
  unset -f _probe
  python3 - "$ENV" "$tenant" "$hub" "$box" "$agent" "$body" "$sent" "$sync1" "$sync2" "$tail" <<'EOF_PY'
import hashlib, json, sys
env, tenant, hub, box, agent, body, sent, s1, s2, tail = sys.argv[1:]
def js(s):
    try:
        return json.loads(s)
    except ValueError:
        return s
sent = js(sent)
rows = [js(l) for l in tail.splitlines() if l.strip()]
print(json.dumps({"env": env, "tenant": tenant, "hub": hub, "box": box, "agent": agent,
                  "msg_id": sent.get("msg_id") if isinstance(sent, dict) else None,
                  "task_id": sent.get("task_id") if isinstance(sent, dict) else None,
                  "body": body, "body_sha256_16": hashlib.sha256(body.encode()).hexdigest()[:16],
                  "send": sent, "sync_before": js(s1), "sync_after": js(s2), "hub_tail": rows}, sort_keys=True))
EOF_PY
  (( rc == 0 )) || { do_log "FAIL hub-tail of task $task: $tail"; return 1; }
  grep -q "\"msg_id\": *\"$msg\"" <<<"$tail" || { do_log "FAIL the hub does not hold $msg (task $task): hub-tail returned no such message"; return 1; }
  do_log "OK probe note sent by $agent@$box into $tenant ($ENV). Remove the box: spool hub-pin --box $box --revoke --root-key <root key> (SPOOL_HUB_URL=$hub SPOOL_TENANT=$tenant)"
}
