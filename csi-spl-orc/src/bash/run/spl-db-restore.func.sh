#!/bin/bash
#------------------------------------------------------------------------------
# @description RESTORE one hub DB dump (the 045 daily `gcloud sql export`) into
# @description a target, then count every table and compare against the live
# @description env read-only. The restore half of spec 029 and of the spec 044
# @description contingency runbook (§4.2, gap T078). Three targets:
# @description   local            a THROWAWAY postgres container on this box,
# @description                    removed whatever happens (the default; the
# @description                    only target that never touches GCP)
# @description   database:<name>  a NEW throwaway database spool_restore_* on
# @description                    the env's own Cloud SQL instance, via
# @description                    `gcloud sql import sql` (the real restore
# @description                    path, timed), dropped after the count unless
# @description                    KEEP=1
# @description   env              the env's hub database itself - the disaster
# @description                    restore into a RE-CREATED instance. Refused
# @description                    while that database holds any table (a
# @description                    restore never merges into live data), and on
# @description                    prd refused without ALLOW_PRD_RESTORE=1
# @description Where the dump comes from (BACKUP_SOURCE):
# @description   env  the env's 045 bucket, read as the env's project SA
# @description   bkp  the OFF-PROJECT copy gs://csi-spl-bkp-<env>/<env>/db (iac
# @description        046), read as the csi-spl-bkp SA - the one that survives
# @description        a destroy of csi-spl-<env>. Default once cnf
# @description        steps.046.copy_enabled is true.
# @description `gcloud sql import` reads the object as the INSTANCE's service
# @description agent, which has objectAdmin on the 045 bucket only, so a bkp
# @description dump bound for Cloud SQL is staged into 045 under restore/ first
# @description (through this box: the two identities never share a grant) and
# @description removed after the import.
# @description Prints the per-table comparison and one timing line: RPO (age
# @description of the dump) and RTO (download/import -> counted).
# @description DRY_RUN=1 (the default) resolves the dump and the target and
# @description touches nothing.
# @param ENV - required: dev or prd, the env whose dump is restored
# @param BACKUP_URI (optional) - a gs:// .sql.gz in the chosen source, or latest (default)
# @param BACKUP_SOURCE (optional) - env | bkp; default bkp when cnf 046 copy_enabled is true, else env
# @param TARGET (optional) - local (default) | database:spool_restore_<x> | env
# @param ALLOW_PRD_RESTORE (optional) - 1 lets TARGET=env write into prd
# @param KEEP (optional) - 1 keeps a database:<name> target after the count
# @param DRY_RUN (optional) - 1 (default) plan only; 0 restore
# @param SPL_RESTORE_IMAGE (optional) - the local target image, default postgres:16-alpine
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_db_restore
# @example ENV=dev TARGET=database:spool_restore_drill DRY_RUN=0 ./run -a do_spl_db_restore
#------------------------------------------------------------------------------
do_spl_db_restore() {
  do_require_bin gcloud python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local target="${TARGET:-local}" uri="${BACKUP_URI:-latest}" bucket dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_db_restore_target_ok "$target" || return 1
  bucket="$(spl_db_backup_bucket)" || return 1
  spl_offsite_cnf || return 1
  local src="${BACKUP_SOURCE:-}"
  [[ -n "$src" ]] || { src=env; [[ "$SPL_OFFSITE_ENABLED" == true ]] && src=bkp; }
  # under <env>/ only: restore/ holds staged copies, never a source
  local base="gs://$bucket/$ENV"
  case "$src" in
    env) ;;
    bkp) base="gs://$SPL_OFFSITE_BUCKET/$ENV/db" ;;
    *) do_log "FATAL BACKUP_SOURCE must be env or bkp, got: $src"; return 1 ;;
  esac
  export SPL_RESTORE_WHO="$src"
  [[ "$src" != bkp ]] || spl_bkp_key >/dev/null || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  if [[ "$uri" == latest ]]; then
    uri="$(spl_gs_names "$base" "$src" | grep '\.sql\.gz$' | tail -1)"
    [[ -n "$uri" ]] || { do_log "FATAL $ENV: no dump under $base"; return 1; }
    uri="$base/$uri"
  fi
  [[ "$uri" == "$base/"*.sql.gz ]] ||
    { do_log "FATAL BACKUP_URI must be a .sql.gz object under $base (BACKUP_SOURCE=$src), got: $uri"; return 1; }
  local rpo
  rpo="$(spl_db_restore_age "$uri")" || return 1
  do_log "INFO $ENV: restore $uri (age ${rpo}s, read as the $src identity) -> $target"

  if (( dry )); then
    do_log "OK DRY RUN: nothing restored. DRY_RUN=0 to restore."
    printf 'uri=%s target=%s rpo_s=%s\n' "$uri" "$target" "$rpo"
    return 0
  fi

  local t0 rc=0
  t0="$(date +%s)"
  case "$target" in
    local) spl_db_restore_local "$uri" || rc=$? ;;
    *) spl_db_restore_cloud "$uri" "$target" || rc=$? ;;
  esac
  local rto=$(( $(date +%s) - t0 ))
  printf 'uri=%s target=%s rpo_s=%s rto_s=%s rc=%s\n' "$uri" "$target" "$rpo" "$rto" "$rc"
  (( rc == 0 )) && do_log "OK $ENV: restored $uri -> $target; RPO ${rpo}s, RTO ${rto}s"
  return $rc
}

# spl_db_restore_target_ok <target> -> refuses what the action must never do:
# an unknown target, a throwaway database whose name could be a real one, and
# prd's own database without the explicit flag.
spl_db_restore_target_ok() {
  case "$1" in
    local) return 0 ;;
    database:*)
      [[ "${1#database:}" =~ ^spool_restore_[a-z0-9_]{1,40}$ ]] ||
        { do_log "FATAL TARGET=database:<name> must name spool_restore_<a-z0-9_>, got: $1"; return 1; }
      [[ "${1#database:}" != "$SPL_DB_NAME" ]] || { do_log "FATAL TARGET names the live database"; return 1; } ;;
    env)
      [[ "$ENV" != prd || "${ALLOW_PRD_RESTORE:-0}" == 1 ]] ||
        { do_log "FATAL TARGET=env on prd writes the production database: set ALLOW_PRD_RESTORE=1 to mean it"; return 1; } ;;
    *) do_log "FATAL TARGET must be local, database:spool_restore_<x> or env, got: $1"; return 1 ;;
  esac
}

# spl_db_restore_age <uri> -> seconds since the object was written: the RPO a
# restore of it would have.
spl_db_restore_age() {
  local c
  c="$(_spl_db_restore_gcloud storage objects describe "$1" --format='value(creation_time)' 2>/dev/null)"
  [[ -n "$c" ]] || { do_log "FATAL $ENV: cannot read $1 as $GCP_ACCOUNT"; return 1; }
  python3 -c 'import sys,datetime as d; t=d.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((d.datetime.now(d.timezone.utc)-t).total_seconds()))' "$c"
}

# spl_db_restore_local <uri> -> download, restore into the throwaway container
# and compare against live: exactly do_spl_db_backup_verify's machinery, so the
# daily proof and the restore can never drift apart.
spl_db_restore_local() {
  local work rc=0
  work="$(mktemp -d)" || return 1
  chmod 700 "$work"
  _spl_db_restore_local_in "$1" "$work" || rc=$?
  # no RETURN trap: spl_db_backup_restore_counts sets and clears its own, and
  # a trap is shell-global, so ours would be dropped with it
  rm -rf "$work"
  return $rc
}

_spl_db_restore_local_in() {
  local work="$2"
  _spl_db_restore_gcloud storage cp "$1" "$work/dump.sql.gz" >/dev/null 2>&1 ||
    { do_log "FATAL $ENV: cannot download $1"; return 1; }
  gunzip -f "$work/dump.sql.gz" || { do_log "FATAL $ENV: $1 is not gzip"; return 4; }
  do_require_bin docker psql || return 1
  spl_db_backup_restore_counts "$work/dump.sql" >"$work/restored.txt" || return $?
  spl_via_proxy _spl_db_backup_live_counts >"$work/live.txt" ||
    { do_log "FATAL $ENV: cannot read the live counts"; return 1; }
  spl_db_backup_compare "$work/restored.txt" "$work/live.txt"
}

# spl_db_restore_cloud <uri> <target> -> `gcloud sql import sql` into a new
# throwaway database (database:<name>) or into the env's hub database (env),
# then the same count comparison, read through the proxy as the runtime login.
spl_db_restore_cloud() {
  local uri="$1" target="$2" db rc=0 staged=""
  if [[ "$SPL_RESTORE_WHO" == bkp ]]; then
    staged="$(spl_db_restore_stage "$uri")" || return 1
    uri="$staged"
  fi
  if [[ "$target" == env ]]; then
    db="$SPL_DB_NAME"
    local n
    n="$(spl_via_proxy _spl_db_restore_table_count "$db")" || { do_log "FATAL $ENV: cannot read $db"; return 1; }
    [[ "$n" == 0 ]] ||
      { do_log "FATAL $ENV: $db already holds $n table(s); a restore never merges into live data - restore into a re-created instance"; return 1; }
  else
    db="${target#database:}"
    gcloud sql databases create "$db" --instance="$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" \
      --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      { do_log "FATAL $ENV: cannot create the throwaway database $db (does it exist already?)"; return 1; }
    do_log "INFO $ENV: created the throwaway database $db on $SPL_SQL_INSTANCE"
  fi

  # AS THE SCHEMA OWNER. The export carries no OWNER TO, so every object is
  # owned by whoever imports it, and the dump's ALTER DEFAULT PRIVILEGES FOR
  # ROLE <owner> is refused to anyone who is not that role - measured
  # 2026-09-29 on dev: the default import user died on exactly that line
  # ("permission denied to change default privileges"). Importing as the
  # owner reproduces the live layout (rdb owner/runtime split, spec 017).
  gcloud sql import sql "$SPL_SQL_INSTANCE" "$uri" --database="$db" --user="$SPL_DB_OWNER_USER" \
    --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --quiet >/dev/null 2>"$SPL_STATE_DIR/restore-import.log" || rc=3
  if (( rc == 0 )); then
    do_log "INFO $ENV: imported $uri into $db"
    local restored live
    restored="$(spl_via_proxy _spl_db_restore_counts_in "$db")" || rc=1
    live="$(spl_via_proxy _spl_db_backup_live_counts)" || rc=1
    if (( rc == 0 )); then
      spl_db_backup_compare <(printf '%s\n' "$restored") <(printf '%s\n' "$live") || rc=$?
    else
      do_log "FATAL $ENV: cannot read the counts"
    fi
  else
    do_log "FATAL $ENV: import failed: $(tail -5 "$SPL_STATE_DIR/restore-import.log" 2>/dev/null | tr '\n' ' ')"
  fi

  if [[ -n "$staged" ]]; then
    gcloud storage rm "$staged" --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 ||
      do_log "WARN $ENV: could not remove the staged copy $staged (the 045 lifecycle removes it)"
  fi
  if [[ "$target" == database:* && "${KEEP:-0}" != 1 ]]; then
    if gcloud sql databases delete "$db" --instance="$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" \
      --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1; then
      do_log "INFO $ENV: dropped the throwaway database $db"
    else
      do_log "ERROR $ENV: could not drop $db - drop it now: gcloud sql databases delete $db --instance=$SPL_SQL_INSTANCE --project=$SPL_PROJECT --account=$GCP_ACCOUNT"
      (( rc == 0 )) && rc=6
    fi
  fi
  return $rc
}

# _spl_db_restore_gcloud <args> -> gcloud as the identity that reads the
# chosen source: the csi-spl-bkp SA for bkp, the env SA for env.
_spl_db_restore_gcloud() {
  if [[ "${SPL_RESTORE_WHO:-env}" == bkp ]]; then spl_bkp_gcloud "$@"; else gcloud "$@" --account="$GCP_ACCOUNT"; fi
}

# spl_db_restore_stage <bkp uri> -> prints the gs:// uri of a copy in the env's
# 045 bucket under restore/, where the instance's service agent can read it.
spl_db_restore_stage() {
  local work staged rc=0
  work="$(umask 077 && mktemp -d)" || return 1
  staged="gs://$(spl_db_backup_bucket)/restore/$(basename "$1")"
  _spl_db_restore_gcloud storage cp "$1" "$work/d.sql.gz" >/dev/null 2>&1 &&
    gcloud storage cp "$work/d.sql.gz" "$staged" --account="$GCP_ACCOUNT" >/dev/null 2>&1 || rc=1
  rm -rf "$work"
  (( rc == 0 )) || { do_log "FATAL $ENV: cannot stage $1 into $staged"; return 1; }
  do_log "INFO $ENV: staged $1 -> $staged for the import"
  printf '%s' "$staged"
}

# _spl_db_restore_dsn_for <db> -> SPL_PROXY_DSN with its database swapped.
_spl_db_restore_dsn_for() {
  python3 -c 'import sys,urllib.parse as u; p=u.urlsplit(sys.argv[1]); print(u.urlunsplit(p._replace(path="/"+sys.argv[2])))' \
    "$SPL_PROXY_DSN" "$1"
}

_spl_db_restore_table_count() {
  spl_psql_ro "$(_spl_db_restore_dsn_for "$1")" "SELECT count(*) FROM information_schema.tables
     WHERE table_type = 'BASE TABLE' AND table_schema = 'public';"
}

# _spl_db_restore_counts_in <db> -> "<table> <count>" per line, read-only, in
# the operator RLS scope, from the restored database.
_spl_db_restore_counts_in() {
  local dsn
  dsn="$(_spl_db_restore_dsn_for "$1")" || return 1
  SPL_PROXY_DSN="$dsn" _spl_db_backup_live_counts
}
