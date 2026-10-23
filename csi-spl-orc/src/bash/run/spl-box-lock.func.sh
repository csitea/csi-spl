#!/bin/bash
#------------------------------------------------------------------------------
# @description The box owner lock (spec 025 box-owner-lock.md, row B6,
# @description SPL-3014), two commands:
# @description create: run ON the sealed box to lock, as its OS user, at a
# @description terminal (spool asks for the lock secret). `spool lock create`
# @description signs the version 1 lock with K_lock and K_box; the signed
# @description statement is saved as <keys>/lock/lock.signed.json (0600, the
# @description file the box's delivery filter reads, 5.3), and the action
# @description prints the cnf entry for hub.box_locks_expected and the next
# @description steps. It talks to no hub: the owner confirms the lock in the
# @description WUI, which carries the statement (POST /v1/boxes/<box>/lock).
# @description show: READ-ONLY, from any box with the env's project SA: the
# @description cnf entry, the box_locks row and its audit summary, and whether
# @description the row matches cnf (the hub refuses the box when it does not).
# @description Owners are named by HUM-* id only.
# @param BOX_LOCK_CMD - required: create | show
# @param BOX_LOCK_OWNERS - create: required, comma-separated HUM-* owners
# @param BOX_LOCK_PEER_BOXES (optional) - create: comma-separated peer box ids
# @param BOX_LOCK_HIDE_POSTS (optional) - create: true (default) | false
# @param SPOOL_BIN (optional) - create: the spool binary, default spool on PATH
# @param SPOOL_KEYS_DIR (optional) - create: the box keys dir, default $HOME/.spool/keys (as spool)
# @param ENV - show: required, dev or prd
# @param BOX_LOCK_TENANT - show: required, the workspace id
# @param BOX_LOCK_BOX - show: required, the box id
# @example BOX_LOCK_CMD=create BOX_LOCK_OWNERS=HUM-1 ./run -a do_spl_box_lock
# @example ENV=dev BOX_LOCK_CMD=show BOX_LOCK_TENANT=t1 BOX_LOCK_BOX=box-a ./run -a do_spl_box_lock
#------------------------------------------------------------------------------
do_spl_box_lock() {
  case "${BOX_LOCK_CMD:-}" in
    create) _spl_box_lock_create ;;
    show) _spl_box_lock_show ;;
    *) do_log "FATAL BOX_LOCK_CMD must be create or show (got '${BOX_LOCK_CMD:-}')"; return 1 ;;
  esac
}

# spl_box_lock_ids_ok <tenant> <box> -> 0 when both are plain ids (they go
# into SQL as psql variables and into yq as strings; this keeps logs clean).
spl_box_lock_ids_ok() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]] || { do_log "FATAL BOX_LOCK_TENANT '$1' is not a workspace id"; return 1; }
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || { do_log "FATAL BOX_LOCK_BOX '$2' is not a box id"; return 1; }
}

# spl_box_lock_cnf_key <cnf yaml> <tenant> <box> -> the lock_pubkey cnf
# hub.box_locks_expected lists for the box, "" when it is not listed.
spl_box_lock_cnf_key() {
  T="$2" B="$3" yq -r '[(.env.hub.box_locks_expected // [])[] | select(.tenant == strenv(T) and .box == strenv(B)) | .lock_pubkey][0] // ""' "$1"
}

_spl_box_lock_create() {
  do_require_bin jq || return 1
  local spool="${SPOOL_BIN:-spool}" keys="${SPOOL_KEYS_DIR:-$HOME/.spool/keys}" st out signed body args=()
  [[ "${BOX_LOCK_OWNERS:-}" =~ ^HUM-[A-Za-z0-9_-]+(,HUM-[A-Za-z0-9_-]+)*$ ]] ||
    { do_log "FATAL BOX_LOCK_OWNERS must be comma-separated HUM-* ids (got '${BOX_LOCK_OWNERS:-}')"; return 1; }
  command -v "$spool" >/dev/null 2>&1 || { do_log "FATAL no spool binary '$spool' (set SPOOL_BIN)"; return 1; }
  st="$("$spool" lock status 2>/dev/null)" || { do_log "FATAL spool lock status failed"; return 1; }
  case "$st" in
    sealed|unlocked*) ;;
    *) do_log "FATAL this box is '$st': seal it first with 'spool lock seal' (spec 4.2)"; return 1 ;;
  esac
  signed="$keys/lock/lock.signed.json"
  [[ ! -e "$signed" ]] || { do_log "FATAL $signed exists: this box is locked already (a change is spool lock rebind / PUT)"; return 1; }
  args=(lock create --owners "$BOX_LOCK_OWNERS")
  [[ -n "${BOX_LOCK_PEER_BOXES:-}" ]] && args+=(--peer-boxes "$BOX_LOCK_PEER_BOXES")
  case "${BOX_LOCK_HIDE_POSTS:-true}" in
    true) ;;
    false) args+=(--hide-posts=false) ;;
    *) do_log "FATAL BOX_LOCK_HIDE_POSTS must be true or false"; return 1 ;;
  esac
  out="$("$spool" "${args[@]}")" || { do_log "FATAL spool lock create failed"; return 1; }
  if ! body="$(jq -er '.signed_body | fromjson | select(.version == 1 and .tenant_id != "" and .box_id != "" and .lock_pubkey != "")' <<<"$out" 2>/dev/null)" ||
    ! jq -e '(.signature // "") != "" and (.box_signature // "") != ""' <<<"$out" >/dev/null 2>&1; then
    do_log "FATAL spool lock create printed no signed version 1 lock"
    return 1
  fi
  (umask 077 && mkdir -p "$keys/lock" && printf '%s\n' "$out" >"$signed.tmp" && mv "$signed.tmp" "$signed") ||
    { do_log "FATAL cannot write $signed"; return 1; }
  do_log "OK saved the signed lock to $signed"
  jq -r '"cnf entry (csi-spl-cnf/csi-spl/<env>.env.yaml, hub.box_locks_expected):\n  - tenant: \(.tenant_id)\n    box: \(.box_id)\n    lock_pubkey: \(.lock_pubkey)"' <<<"$body"
  echo "next: 1) confirm the lock in the WUI as an owner (it POSTs $signed); 2) commit the cnf entry; 3) ENV=<env> BOX_LOCK_CMD=show ./run -a do_spl_box_lock"
}

_spl_box_lock_show() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${BOX_LOCK_TENANT:-}" box="${BOX_LOCK_BOX:-}" want
  spl_box_lock_ids_ok "$tenant" "$box" || return 1
  want="$(spl_box_lock_cnf_key "$SPL_CNF" "$tenant" "$box")" || { do_log "FATAL cannot read hub.box_locks_expected in $SPL_CNF"; return 1; }
  echo "cnf: $([[ -n "$want" ]] && echo "listed lock_pubkey=$want" || echo unlisted)"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  BOX_LOCK_WANT="$want" spl_via_proxy _spl_box_lock_show_run "$tenant" "$box"
}

# _spl_box_lock_show_run <tenant> <box>: the row, the audit summary and the
# verdict, in one READ ONLY transaction under the operator scope (rdb 0213).
_spl_box_lock_show_run() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off -v t="$1" -v b="$2" -v want="${BOX_LOCK_WANT:-}" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
\pset footer off
SELECT tenant_id, box_id, lock_pubkey, owners, peer_boxes, hide_posts, version, created_at, updated_at
  FROM box_locks WHERE tenant_id = :'t' AND box_id = :'b';
SELECT path, verdict, sum(count) AS count, max(last_at) AS last_at
  FROM box_lock_audit WHERE tenant_id = :'t' AND box_id = :'b'
 GROUP BY path, verdict ORDER BY max(last_at) DESC;
\pset tuples_only on
SELECT 'verdict: ' || CASE
         WHEN :'want' = '' AND l.box_id IS NULL THEN 'unlocked (no row, not in cnf)'
         WHEN :'want' = '' THEN 'locked, NOT in cnf: add its entry to hub.box_locks_expected'
         WHEN l.box_id IS NULL THEN 'REFUSED by the hub: cnf lists the box, no lock row'
         WHEN l.lock_pubkey <> :'want' THEN 'REFUSED by the hub: the row is under another lock_pubkey than cnf'
         ELSE 'locked, matches cnf' END
  FROM (SELECT 1) one LEFT JOIN box_locks l ON l.tenant_id = :'t' AND l.box_id = :'b';
ROLLBACK;
SQL
}
