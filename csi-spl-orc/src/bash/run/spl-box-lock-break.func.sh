#!/bin/bash
#------------------------------------------------------------------------------
# @description The box owner lock's break-glass (spec 025 box-owner-lock.md
# @description 8.3, row B6, SPL-3014): when the owner lost BOTH the lock
# @description secret and the recovery code, delete the box's box_locks row
# @description under the operator scope and write one lifted audit row (path
# @description break). It is the power of 8.2 given a name and a trail.
# @description It never runs without the owner's go for that call
# @description (BOX_LOCK_GO = the owner's message id), and it REFUSES while
# @description the box is still in cnf hub.box_locks_expected, in the working
# @description cnf or in the cnf on origin/master (fetched first): the removal
# @description must be a commit on trunk, visible in git history, before the
# @description row can go. A dry run (the default) reads the row only.
# @description Not built: the post to the owner's DM (8.3); the action says so.
# @param ENV - required: dev or prd
# @param BOX_LOCK_TENANT - required: the workspace id
# @param BOX_LOCK_BOX - required: the box id
# @param BOX_LOCK_GO - required with DRY_RUN=0: the owner's go (message id)
# @param DRY_RUN (optional) - 1 (default): read only; 0: delete the row
# @param BOX_LOCK_REPO (optional) - the git checkout whose origin/master cnf is checked, default this repo
# @example ENV=dev BOX_LOCK_TENANT=t1 BOX_LOCK_BOX=box-a ./run -a do_spl_box_lock_break
# @example ENV=dev BOX_LOCK_TENANT=t1 BOX_LOCK_BOX=box-a BOX_LOCK_GO=<msg-id> DRY_RUN=0 ./run -a do_spl_box_lock_break
#------------------------------------------------------------------------------
do_spl_box_lock_break() {
  do_require_bin yq psql git || return 1
  local tenant="${BOX_LOCK_TENANT:-}" box="${BOX_LOCK_BOX:-}" dry="${DRY_RUN:-1}" repo trunk_cnf
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_box_lock_ids_ok "$tenant" "$box" || return 1
  if [[ "$dry" == 0 && ! "${BOX_LOCK_GO:-}" =~ ^[0-9a-f]{8}([0-9a-f-]{0,28})$ ]]; then
    do_log "FATAL BOX_LOCK_GO must be the owner's go for this call (a message id); the break-glass never runs without it"
    return 1
  fi
  do_spl_cloud_cnf || return 1
  [[ -z "$(spl_box_lock_cnf_key "$SPL_CNF" "$tenant" "$box")" ]] ||
    { do_log "FATAL $tenant:$box is in hub.box_locks_expected of the $ENV cnf: remove it on trunk first (8.3)"; return 1; }
  repo="${BOX_LOCK_REPO:-$(git -C "$PROJ_PATH" rev-parse --show-toplevel 2>/dev/null)}"
  git -C "$repo" fetch -q origin master 2>/dev/null ||
    { do_log "FATAL cannot fetch origin master in '$repo': the trunk cnf must be checked"; return 1; }
  trunk_cnf="$(mktemp)"
  git -C "$repo" show "origin/master:csi-spl-cnf/csi-spl/$ENV.env.yaml" >"$trunk_cnf" 2>/dev/null ||
    { rm -f "$trunk_cnf"; do_log "FATAL origin/master has no csi-spl-cnf/csi-spl/$ENV.env.yaml"; return 1; }
  if [[ -n "$(spl_box_lock_cnf_key "$trunk_cnf" "$tenant" "$box")" ]]; then
    rm -f "$trunk_cnf"
    do_log "FATAL $tenant:$box is still in hub.box_locks_expected on origin/master: land its removal first (8.3)"
    return 1
  fi
  rm -f "$trunk_cnf"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  BOX_LOCK_DRY="$dry" spl_via_proxy _spl_box_lock_break_run "$tenant" "$box" || return 1
  if [[ "$dry" == 0 ]]; then
    do_log "INFO the owner's DM note (8.3) is not built yet: tell the owner on the go's topic ($BOX_LOCK_GO)"
  fi
}

# _spl_box_lock_break_run <tenant> <box>: one transaction under the operator
# scope. Dry: the row's count. Else the delete and its audit row, committed
# only when a row went; a box with no row is refused and nothing is written.
_spl_box_lock_break_run() {
  local out
  if [[ "${BOX_LOCK_DRY:-1}" == 1 ]]; then
    PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
      psql -X -q -t -A -v ON_ERROR_STOP=1 -P pager=off -v t="$1" -v b="$2" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT 'dry_run: would delete ' || count(*) || ' box_locks row(s)' FROM box_locks WHERE tenant_id = :'t' AND box_id = :'b';
ROLLBACK;
SQL
    return
  fi
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -t -A -v ON_ERROR_STOP=1 -P pager=off -v t="$1" -v b="$2" <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
WITH gone AS (DELETE FROM box_locks WHERE tenant_id = :'t' AND box_id = :'b' RETURNING tenant_id, box_id),
     audit AS (INSERT INTO box_lock_audit (tenant_id, box_id, path, verdict, first_at, last_at)
               SELECT tenant_id, box_id, 'break', 'lifted', now(), now() FROM gone RETURNING 1)
SELECT count(*) AS broke FROM audit \gset
\if :broke
COMMIT;
\echo broke: deleted 1 box_locks row, audit lifted/break
\else
ROLLBACK;
\echo broke: none
\endif
SQL
)" || return 1
  echo "$out"
  [[ "$out" == *"broke: deleted 1"* ]] || { do_log "FATAL no box_locks row for $1:$2: nothing to break"; return 1; }
}
