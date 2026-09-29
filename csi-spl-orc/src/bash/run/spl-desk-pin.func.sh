#!/bin/bash
#------------------------------------------------------------------------------
# @description Give a desk box its key and its hub pin WITHOUT seating an
# @description agent: the step the installer (specs/037) runs for a user who
# @description is not on this box. Three modes, one action:
# @description   self   - ROOT_KEY_JSON set: the user is the tenant admin; the
# @description            box key is minted (or reused) and pinned with the
# @description            tenant root key (`spool hub-pin`, POST /v1/pins,
# @description            the only pin path the hub has)
# @description   admin  - BOX_PUBKEY + ROOT_KEY_JSON set: pin SOMEONE ELSE's
# @description            box key, the line a pending user hands their admin;
# @description            nothing is written locally. With PIN_REVOKE=1 (and
# @description            no BOX_PUBKEY) the box's pin is REVOKED instead
# @description   check  - neither: mint (or reuse) the box key, then ask the
# @description            hub (`spool hub-sync`) whether it is pinned yet. Not
# @description            pinned -> exit 3 and print the admin line
# @description A box that is pinned gets <state>/desk/<tenant>/<box>/pinned,
# @description which do_spl_desk_up reads: its first run then needs no
# @description ROOT_KEY_JSON. Prints one JSON line; nothing secret (the root
# @description key goes through a 0600 scratch file, removed).
# @description Dry run unless DRY_RUN=0.
# @param ENV - required: dev or prd; or self - a self-hosted hub at
# @param   SPOOL_HUB_URL, any host, no cnf (specs/047 W4, do_spl_desk_cnf)
# @param TENANT_ID - required: the tenant slug
# @param DESK_BOX (optional) - default box-desk
# @param ROOT_KEY_JSON (optional) - the tenant's 0600 create JSON (root_private_key),
# @param   or a 0600 bare base64 key file (the compose stack's tenant-root.key)
# @param BOX_PUBKEY (optional) - admin mode: the base64 box public key to pin
# @param PIN_REVOKE (optional) - 1: admin mode revokes DESK_BOX's pin (needs
# @param   ROOT_KEY_JSON; the box's owner re-runs the installer to be pinned again)
# @param SPOOL_HUB_URL (optional) - dev / prd: when set it must equal the cnf
# @param   hub (https://<env.dns.api_fqdn>): a mismatch is refused, because the
# @param   desk would run against the cnf hub anyway. ENV=self: the hub itself
# @param   (required on the first run, saved for later ones)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_BOX=box-alice DRY_RUN=0 ./run -a do_spl_desk_pin
# @example ENV=dev TENANT_ID=t1 DESK_BOX=box-alice BOX_PUBKEY=<b64> ROOT_KEY_JSON=<file> DRY_RUN=0 ./run -a do_spl_desk_pin
# @example ENV=self SPOOL_HUB_URL=http://localhost:8080 TENANT_ID=main DESK_BOX=box-alice ROOT_KEY_JSON=<file> DRY_RUN=0 ./run -a do_spl_desk_pin
#------------------------------------------------------------------------------
do_spl_desk_pin() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-box-desk}" rkj="${ROOT_KEY_JSON:-}" other="${BOX_PUBKEY:-}"
  local revoke="${PIN_REVOKE:-0}"
  [[ "$revoke" == 0 || "$revoke" == 1 ]] || { do_log "FATAL PIN_REVOKE must be 0 or 1, got: '$revoke'"; return 1; }
  spl_desk_validate "$tenant" "$box" CLE-0 || return 1
  local hub="$SPL_HUB_URL" d
  if [[ "$ENV" != self && -n "${SPOOL_HUB_URL:-}" && "${SPOOL_HUB_URL%/}" != "$hub" ]]; then
    do_log "FATAL SPOOL_HUB_URL=$SPOOL_HUB_URL but the $ENV cnf hub is $hub: pick the ENV whose hub that is, or ENV=self for a self-hosted hub"; return 1
  fi
  if [[ -n "$other" ]]; then
    [[ "$other" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { do_log "FATAL BOX_PUBKEY is not a base64 ed25519 public key"; return 1; }
    [[ -n "$rkj" ]] || { do_log "FATAL BOX_PUBKEY (admin mode) needs ROOT_KEY_JSON"; return 1; }
  fi
  if (( revoke )); then
    [[ -z "$other" ]] || { do_log "FATAL PIN_REVOKE=1 takes no BOX_PUBKEY"; return 1; }
    [[ -n "$rkj" ]] || { do_log "FATAL PIN_REVOKE=1 needs ROOT_KEY_JSON"; return 1; }
  fi
  [[ -z "$rkj" || -s "$rkj" ]] || { do_log "FATAL ROOT_KEY_JSON $rkj is missing or empty"; return 1; }
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  local mode=check
  [[ -n "$rkj" ]] && mode=self
  [[ -n "$other" ]] && mode=admin
  (( revoke )) && mode=revoke
  if (( dry )); then
    case "$mode" in
      revoke) do_log "INFO DRY_RUN would: REVOKE the pin of $box under $tenant at $hub (tenant root key)" ;;
      admin) do_log "INFO DRY_RUN would: hub-pin $box to the given key under $tenant at $hub (tenant root key)" ;;
      self)  do_log "INFO DRY_RUN would: mint or reuse the key of $box in $d/keys, then hub-pin it under $tenant at $hub" ;;
      check) do_log "INFO DRY_RUN would: mint or reuse the key of $box in $d/keys, then ask $hub whether it is pinned" ;;
    esac
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  spl_host_spool || return 1
  if [[ "$mode" == admin || "$mode" == revoke ]]; then
    local ad; ad="$(umask 077 && mktemp -d)" || return 1
    spl_desk_pin_hub "$ad" "$box" "$tenant" "$hub" "$other" "$rkj"; local rc=$?
    rm -rf "$ad"
    (( rc == 0 )) || return 1
    if [[ "$mode" == revoke ]]; then
      spl_desk_pin_json "$ENV" "$tenant" "$hub" "$box" "" "" 0 ""
      do_log "OK revoked the pin of $box under $tenant at $hub"
      return 0
    fi
    spl_desk_pin_json "$ENV" "$tenant" "$hub" "$box" "$other" "" 1 ""
    do_log "OK pinned $box ($other) under $tenant at $hub: its owner re-runs the installer to seat it"
    return 0
  fi
  mkdir -p "$d/spool/.hub" "$d/keys" && chmod -R go-rwx "$d" || { do_log "FATAL cannot create $d"; return 1; }
  local pub
  if [[ -s "$d/pinned" ]]; then
    pub="$(cat "$d/pinned")"
    spl_desk_pin_json "$ENV" "$tenant" "$hub" "$box" "$pub" "$d" 1 ""
    do_log "OK $box is already pinned under $tenant ($d/pinned)"
    return 0
  fi
  pub="$(spl_desk_box_pub "$d" "$box" "$tenant" "$hub")" || return 1
  if [[ "$mode" == self ]]; then
    spl_desk_pin_hub "$d" "$box" "$tenant" "$hub" "$pub" "$rkj" || return 1
  else
    local out
    if ! out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-sync 2>&1)"; then
      local selfhub=""; [[ "$ENV" == self ]] && selfhub=" SPOOL_HUB_URL=$hub"
      local admin="ENV=$ENV$selfhub TENANT_ID=$tenant DESK_BOX=$box BOX_PUBKEY=$pub ROOT_KEY_JSON=<the tenant create JSON or root key file> DRY_RUN=0 ./run -a do_spl_desk_pin"
      spl_desk_pin_json "$ENV" "$tenant" "$hub" "$box" "$pub" "$d" 0 "$admin"
      do_log "WARN $box is not pinned under $tenant yet (hub said: $(printf '%s' "$out" | tail -n 1 | cut -c1-200))"
      do_log "WARN ask a tenant admin to run: $admin"
      do_log "WARN or, without this repo: SPOOL_HUB_URL=$hub SPOOL_TENANT=$tenant spool hub-pin --box $box --pubkey $pub --root-key <root private key: a file, the key text, or - for stdin>"
      return 3
    fi
  fi
  printf '%s\n' "$pub" >"$d/pinned"
  spl_desk_pin_json "$ENV" "$tenant" "$hub" "$box" "$pub" "$d" 1 ""
  do_log "OK $box ($pub) is pinned under $tenant at $hub: spool-agent can seat agents on it"
}

# spl_desk_box_pub <state dir> <box> <tenant> <hub>: the box's public key,
# minting the key once. A key that exists is reused (its last 32 bytes are the
# public half), so a user whose pin is pending keeps ONE key across re-runs -
# the key the admin was handed.
spl_desk_box_pub() {
  local d="$1" box="$2" kf="$1/keys/box-$2.key" pub
  if [[ -s "$kf" ]]; then
    python3 -c 'import base64,sys; k=base64.b64decode(open(sys.argv[1]).read().strip()); assert len(k)==64; print(base64.b64encode(k[32:]).decode())' \
      "$kf" 2>/dev/null || { do_log "FATAL $kf is not an ed25519 box key"; return 1; }
    return 0
  fi
  pub="$(spl_desk_spool "$d" "$box" "$3" "$4" -- keygen 2>&1)" || { do_log "FATAL keygen for $box: $pub"; return 1; }
  do_log "INFO minted the key of $box ($kf)" >&2
  printf '%s\n' "$pub"
}

# spl_desk_pin_hub <spool dir> <box> <tenant> <hub> <pubkey> <root key json>:
# POST /v1/pins signed with the root key, which only ever sits in a 0600
# scratch file. An EMPTY pubkey revokes the pin (DELETE /v1/pins/<box>).
spl_desk_pin_hub() {
  local d="$1" box="$2" tenant="$3" hub="$4" pub="$5" rkj="$6" key out rc=0
  [[ "$(stat -c %a "$rkj")" == 600 ]] || { do_log "FATAL $rkj must be mode 0600"; return 1; }
  key="$(umask 077 && mktemp)" || return 1
  spl_root_key_to_file "$rkj" "$key" ||
    { rm -f "$key"; do_log "FATAL $rkj holds no tenant root key (a create JSON with root_private_key, or a bare base64 key)"; return 1; }
  local -a what=(--pubkey "$pub"); [[ -n "$pub" ]] || what=(--revoke)
  out="$(spl_desk_spool "$d" "$box" "$tenant" "$hub" -- hub-pin --box "$box" "${what[@]}" --root-key "$key" 2>&1)" || rc=$?
  rm -f "$key"
  (( rc == 0 )) || { do_log "FATAL hub-pin $box under $tenant: $out"; return 1; }
  [[ -z "$pub" ]] || do_log "INFO pinned $box ($pub) under $tenant at $hub"
}

spl_desk_pin_json() {
  python3 - "$@" <<'EOF_PY'
import json, sys
env, tenant, hub, box, pub, state, pinned, admin = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "hub": hub, "box": box, "box_pubkey": pub,
                  "state_dir": state or None, "pinned": pinned == "1", "admin_cmd": admin or None},
                 sort_keys=True))
EOF_PY
}
