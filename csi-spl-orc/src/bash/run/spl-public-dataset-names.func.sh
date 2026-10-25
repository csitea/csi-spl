#!/bin/bash
#------------------------------------------------------------------------------
# @description The public dataset NAMES step (spec 091 T005, section 5.5 item
# @description 3 and 8.2): as the names login spool_public_names (its one
# @description grant: SELECT (tenant_id, display_name) ON tenants), under the
# @description operator scope, read every workspace OTHER than the exported
# @description one (cnf public_dataset.workspace_id) and write, mode 0600:
# @description   names.tsv     <tenant_id> TAB <display_name>, the gate's C4 list
# @description   names.sha256  the sha256 of each lower-cased id and display
# @description                 name, one per line: the grok verifier's list
# @description into PD_NAMES_DIR and into the PRIVATE staging bucket under
# @description candidates/<PD_CANDIDATE>/names/ only. Neither list is ever
# @description published (short names are guessable, so the hashes are
# @description reversible); the publish step (T008) deletes both. The output
# @description gives counts, never a name. Refused when the staging bucket is
# @description unset or is the public bucket.
# @param ENV - required: dev or prd
# @param PD_CANDIDATE - required: the candidate's id, e.g. 2026-10-25-v1.4.0 (the staging prefix)
# @param PD_NAMES_DIR - required: an existing local directory for the two files
# @param DRY_RUN (optional) - 1 (default): check the cnf and the arguments, no cloud. 0: read and write.
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev PD_CANDIDATE=2026-10-25-v1.4.0 PD_NAMES_DIR=/var/tmp/pd ./run -a do_spl_public_dataset_names
# @example ENV=dev DRY_RUN=0 PD_CANDIDATE=2026-10-25-v1.4.0 PD_NAMES_DIR=/var/tmp/pd ./run -a do_spl_public_dataset_names
#------------------------------------------------------------------------------
do_spl_public_dataset_names() {
  do_require_bin yq psql python3 || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "${PD_CANDIDATE:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { do_log "FATAL PD_CANDIDATE must be <YYYY-MM-DD>-v<X.Y.Z> (the candidate's staging prefix)"; return 1; }
  [[ -n "${PD_NAMES_DIR:-}" && -d "$PD_NAMES_DIR" && -w "$PD_NAMES_DIR" ]] ||
    { do_log "FATAL PD_NAMES_DIR must be an existing writable local directory"; return 1; }
  do_spl_cloud_cnf || return 1
  local ws staging public slot
  IFS=$'\t' read -r ws staging public < <(yq -r '[.env.public_dataset.workspace_id // "",
      .env.steps."053-gcs-public-dataset".staging_bucket_name // "",
      .env.steps."053-gcs-public-dataset".public_bucket_name // ""] | @tsv' "$SPL_CNF")
  spl_require_tenant_slug "$ws" || { do_log "FATAL cnf public_dataset.workspace_id is unset for $ENV"; return 1; }
  [[ "$staging" =~ ^[a-z0-9][a-z0-9._-]{2,62}$ ]] || { do_log "FATAL cnf staging_bucket_name of step 053 is unset for $ENV"; return 1; }
  [[ "$staging" != "$public" ]] || { do_log "FATAL the staging bucket is the public bucket: the names lists never go public"; return 1; }
  local -a slots=()
  spl_public_export_slots slots || return 1
  [[ "${slots[1]%%:*}" == spool_public_names ]] || { do_log "FATAL cnf public_dataset.names_login must be spool_public_names"; return 1; }
  slot="${slots[1]#*:}"
  local dest="gs://$staging/candidates/$PD_CANDIDATE/names"
  if (( dry )); then
    do_log "INFO DRY_RUN would: as spool_public_names (password in $slot) under the operator scope read every workspace but $ws"
    do_log "INFO DRY_RUN would: write names.tsv and names.sha256 (0600) to $PD_NAMES_DIR and $dest/"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to read and write."
    return 0
  fi
  [[ "$(do_spl_cloud_provider)" == gcp ]] || { do_log "FATAL do_spl_public_dataset_names needs Secret Manager and GCS (provider gcp)"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_require_bin gcloud || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  spl_pd_names_read "$slot" "$ws" "$h" || return 1
  spl_pd_names_write "$h/names.json" "$ws" "$PD_NAMES_DIR" || return 1
  spl_pd_names_upload "$PD_NAMES_DIR" "$dest" || return 1
  do_log "OK public dataset names ($ENV): $(wc -l <"$PD_NAMES_DIR/names.tsv") other workspace(s), $(wc -l <"$PD_NAMES_DIR/names.sha256") hash(es) in $PD_NAMES_DIR and $dest/ (private staging only)"
}

# spl_pd_names_read <password slot> <workspace> <scratch dir>: the names login
# through the proxy, the operator scope, every OTHER workspace -> names.json
# ([[id, display_name], ...]). The database's own message is never printed: it
# may quote a name.
spl_pd_names_read() {
  local slot="$1" ws="$2" h="$3" owner_dsn ldsn rc=0
  (umask 077 && gcloud secrets versions access latest --secret="$slot" --project="$SPL_PROJECT" \
    --account="$GCP_ACCOUNT" >"$h/pw" 2>/dev/null) && [[ -s "$h/pw" ]] ||
    { do_log "FATAL $slot has no readable version: run ENV=$ENV DRY_RUN=0 ./run -a do_spl_public_export_secret_seed first"; return 1; }
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" ]] || { do_log "FATAL $SPL_OWNER_DSN_SECRET has no DSN (it names the database and its socket)"; return 1; }
  spl_sql_proxy_start || return 1
  ldsn="$(spl_pd_names_dsn "$owner_dsn" "$h/pw")" || { spl_sql_proxy_stop; do_log "FATAL cannot build the spool_public_names DSN"; return 1; }
  printf "\\\\set ws '%s'\nBEGIN READ ONLY;\nSET LOCAL app.rls_scope = 'operator';\n%s\nROLLBACK;\n" "$ws" \
    "SELECT coalesce(json_agg(json_build_array(tenant_id, display_name) ORDER BY tenant_id), '[]') FROM tenants WHERE tenant_id <> :'ws';" |
    spl_pg_env "$ldsn" psql -X -q -At -v ON_ERROR_STOP=1 -f - >"$h/names.json" 2>/dev/null || rc=$?
  spl_sql_proxy_stop
  (( rc == 0 )) || { do_log "FATAL the names read as spool_public_names failed (exit $rc; the database's message is not shown)"; return 1; }
}

# spl_pd_names_dsn <owner cloud dsn> <password file> -> the local proxy DSN of
# spool_public_names (the owner DSN's database and socket, another login).
spl_pd_names_dsn() {
  local cloud
  cloud="$(SPL_DSN_IN="$1" SPL_PW_IN="$(cat "$2")" python3 -c '
import os, urllib.parse as u
p = u.urlsplit(os.environ["SPL_DSN_IN"])
print(u.urlunsplit((p.scheme, "spool_public_names:%s@" % u.quote(os.environ["SPL_PW_IN"], safe=""), p.path, p.query, "")), end="")')" &&
    spl_local_dsn "$cloud" "$SPL_PROXY_PORT"
}

# spl_pd_names_write <names.json> <exported workspace> <dir>: names.tsv and
# names.sha256, mode 0600. A tab or a line break inside a name becomes a
# space. Refuses when the exported workspace is in the list.
spl_pd_names_write() {
  (umask 077 && python3 - "$1" "$2" "$3" <<'EOF_PY'
import hashlib, json, os, re, sys
rows = json.load(open(sys.argv[1]))
if not isinstance(rows, list) or any(not isinstance(r, list) or len(r) != 2 for r in rows):
    sys.exit("the names read is not a list of [id, display_name]")
if any(r[0] == sys.argv[2] for r in rows):
    sys.exit("the names read holds the exported workspace")
clean = lambda s: re.sub(r"[\t\r\n]+", " ", s or "").strip()
tsv = ["%s\t%s\n" % (clean(i), clean(n)) for i, n in rows if clean(i)]
words = sorted({w.lower() for i, n in rows for w in (clean(i), clean(n)) if w})
sha = ["%s\n" % hashlib.sha256(w.encode("utf-8")).hexdigest() for w in words]
for name, lines in (("names.tsv", tsv), ("names.sha256", sorted(set(sha)))):
    p = os.path.join(sys.argv[3], name)
    with open(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    os.chmod(p, 0o600)
EOF_PY
  ) 2>/dev/null || { do_log "FATAL cannot write the names lists (a malformed read, or it holds the exported workspace)"; return 1; }
}

# spl_pd_names_upload <dir> <gs://staging/candidates/<id>/names>: both files to
# private staging, as the pinned per-env SA.
spl_pd_names_upload() {
  local f
  for f in names.tsv names.sha256; do
    gcloud storage cp "$1/$f" "$2/$f" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
      { do_log "FATAL cannot write $2/$f"; return 1; }
  done
}
