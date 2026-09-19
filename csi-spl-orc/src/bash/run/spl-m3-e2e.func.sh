#!/bin/bash
#------------------------------------------------------------------------------
# @description M3 end to end on a CLOUD env (dev first): authenticated humans
# @description chat with agents and command them on the same v:1 bus. The
# @description repeatable proof behind 014 acceptance, 005 SC-001 and the dev
# @description part of 006 T011c (record: csi-spl-doc/specs/014-spool-wui-dispatch/
# @description acceptance-dev.md). Steps, each printed PASS/FAIL with evidence:
# @description   0  two box clients on THIS machine (box-e2e-a / box-e2e-b, own
# @description      key + SPOOL_ROOT each) pinned by the tenant root key, and
# @description      the hub's box-wui key pinned (--force: dev's key is
# @description      ephemeral, a hub restart mints a new one)
# @description   a  box-a -> box-b `spool send`, drained by hub-sync, listed by
# @description      /v1/view/threads (the WUI viewer's API)
# @description   b  a member human on /v1/wui/ws: an ambient #lobby note
# @description      reaches no box; a leading @EZB-1 mention does
# @description   c  a task to EZB-1 is box-wui SIGNED; box-b's hub-run verifies
# @description      it on its local box-wui pin; its kind=result reaches the
# @description      browser's thread
# @description   d  DM (no channel) human <-> agent; presence online/offline
# @description      as box-b's hub-run connects / stops
# @description   e1 CONTROL forged / unsigned copies of the signed task, replayed
# @description      to a clone of box-b by a local fake hub: exit 78, nothing
# @description      written (a genuine copy: exit 0, written)
# @description   e2 CONTROL a never-invited human: login for the tenant 403
# @description      not_allowed; its tenant-less session cannot dispatch
# @description The member human is a native (015) account; the dev hub's
# @description debug tokens verify it. The FIRST run of a state dir seats it
# @description with `spool hub-invite --role member` over the Cloud SQL proxy
# @description (010 T018) BEFORE it ever signs in with the tenant: on a
# @description zero-member tenant with bootstrap on, a first sign-in would make
# @description the test account the tenant OWNER. Later runs reuse the marker.
# @description Secrets (root key, passwords, cookies) stay in 0600 files under
# @description the state dir; the log carries none of them.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant (dev: t1)
# @param ROOT_KEY_JSON - required: the 0600 JSON do_spl_tenant_create wrote
# @param   (field root_private_key); or ROOT_KEY = a root.key file instead
# @param M3_HUMAN_EMAIL (optional) - member human, default m3-e2e-human@example.com
# @param M3_OUTSIDER_EMAIL (optional) - never invited, default m3-e2e-outsider@example.com
# @param GCP_ACCOUNT (optional) - the invite's DSN read + proxy identity
# @param   (do_gcp_account); run in a throwaway CLOUDSDK_CONFIG holding the
# @param   project key, as 006 T011d did. Only used when an invite is needed.
# @param SPL_STATE_DIR (optional) - default $HOME/.local/share/<org>-<app>/cloud/<env>
# @example ENV=dev TENANT_ID=t1 ROOT_KEY_JSON=/var/csi/csi-spl/tenants/dev/t1.<ts>.json ./run -a do_spl_m3_e2e
#------------------------------------------------------------------------------
do_spl_m3_e2e() {
  do_require_bin yq python3 curl || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }

  local st="$SPL_STATE_DIR/m3-e2e/$tenant"
  mkdir -p "$st" && chmod 700 "$st" || return 1
  local key="$st/root.key"
  ( umask 077
    if [[ -n "${ROOT_KEY_JSON:-}" ]]; then
      python3 -c 'import json,sys; open(sys.argv[2],"w").write(json.load(open(sys.argv[1]))["root_private_key"].strip()+"\n")' \
        "$ROOT_KEY_JSON" "$key"
    elif [[ -n "${ROOT_KEY:-}" ]]; then
      cp "$ROOT_KEY" "$key"
    else
      false
    fi ) 2>/dev/null || { do_log "FATAL need ROOT_KEY_JSON (field root_private_key) or ROOT_KEY for tenant $tenant"; return 1; }
  [[ -s "$key" ]] || { do_log "FATAL empty tenant root key from ${ROOT_KEY_JSON:-$ROOT_KEY}"; return 1; }

  spl_host_spool || return 1

  export M3_HUB_URL="https://$tenant.$SPL_FQDN" M3_AUTH_URL="https://$SPL_FQDN" M3_STATE="$st" \
    M3_SPOOL="$SPL_SPOOL" M3_ROOT_KEY="$key" \
    M3_HUMAN_EMAIL="${M3_HUMAN_EMAIL:-m3-e2e-human@example.com}" \
    M3_OUTSIDER_EMAIL="${M3_OUTSIDER_EMAIL:-m3-e2e-outsider@example.com}"
  local py="$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/m3-e2e.py" rc=0
  python3 "$py" auth-check || rc=$?
  if [[ $rc == 3 ]]; then
    spl_m3_invite "$tenant" "$M3_HUMAN_EMAIL" || return 1
    rc=0; M3_INVITED=1 python3 "$py" auth-check || rc=$?
  fi
  [[ $rc == 0 ]] || { do_log "FATAL the member human cannot sign in to $tenant (auth-check exit $rc)"; return 1; }

  python3 "$py" run || { do_log "FAIL M3 e2e on $ENV/$tenant: see $st/results.json"; return 1; }
  do_log "OK M3 e2e on $ENV/$tenant: every step PASS ($st/results.json)"
}

# spl_m3_invite <tenant> <email>: `spool hub-invite --role member` through the
# Cloud SQL proxy (the path do_spl_tenant_create uses). The DSN stays in a local.
spl_m3_invite() {
  do_gcp_pin_account "$SPL_CNF" || return 1
  local cloud_dsn dsn out
  cloud_dsn="$(spl_read_dsn)"
  [[ -n "$cloud_dsn" ]] || { do_log "FATAL cannot read $SPL_DSN_SECRET in $SPL_PROJECT as $GCP_ACCOUNT"; return 1; }
  spl_sql_proxy_start || return 1
  dsn="$(spl_proxy_dsn "$cloud_dsn" "$SPL_PROXY_PORT")" || { spl_sql_proxy_stop; do_log "FATAL unexpected DSN shape in $SPL_DSN_SECRET"; return 1; }
  out="$(SPOOL_HUB_DB_DSN="$dsn" "$SPL_SPOOL" hub-invite --tenant "$1" --email "$2" --role member 2>&1)"
  local rc=$?
  spl_sql_proxy_stop
  [[ $rc == 0 ]] || { do_log "FATAL hub-invite $2 to $1: $out"; return 1; }
  do_log "OK invited $2 to $1 as member: $out"
}
