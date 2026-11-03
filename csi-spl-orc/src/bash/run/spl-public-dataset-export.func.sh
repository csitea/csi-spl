#!/bin/bash
#------------------------------------------------------------------------------
# @description The public dataset EXPORT (spec 091 T006; sections 4, 5.3, 5.4,
# @description 5.7). Kill switch first: with cnf public_dataset.enabled false
# @description and PUBLIC_DATASET_FORCE unset it exits 0 and touches nothing
# @description (the dev and CI paths set the switch). Then, as the export
# @description login spool_public_export through the Cloud SQL proxy (the env
# @description SA key opens the proxy only):
# @description   1. the names step (do_spl_public_dataset_names), to private staging
# @description   2. one READ ONLY transaction per listed workspace
# @description      (cnf public_dataset.workspace_ids) starting
# @description      SET LOCAL app.tenant_id = <it>; app.rls_scope is never set.
# @description      Each table is ONE named projection query,
# @description      src/sql/public-dataset/v<N>/<nn>-<table>.sql, listing its
# @description      columns and carrying WHERE tenant_id = :'ws' (fence 3)
# @description   3. every emitted row's tenant_id must be that workspace: one
# @description      mismatch = FATAL, nothing written. A message naming a HUM-n
# @description      that is not a member is dropped and counted (non-member);
# @description      humans and memberships are kept for authors and
# @description      addressees of the exported messages only
# @description   4. the gate (do_spl_public_dataset_gate) on the candidate
# @description   5. spool-hub-public-<YYYY-MM-DD>-v<X.Y.Z>.sql.gz (COPY blocks
# @description      only, FK order) and its .manifest.json to the PRIVATE
# @description      staging bucket under candidates/<YYYY-MM-DD>-v<X.Y.Z>/,
# @description      never the public one (T008 publishes)
# @description <X.Y.Z> and the commit come from prd's hub /version; the
# @description migration head is the newest migration file at that commit.
# @description Output names classes, tables and counts, never row content (CI
# @description logs are public, section 5.6).
# @param ENV - required: dev or prd (the database read and the staging bucket)
# @param DRY_RUN (optional) - 1 (default): resolve the cnf, version and names, no database, no upload. 0: export.
# @param PUBLIC_DATASET_FORCE (optional) - 1: run although cnf public_dataset.enabled is false (dev, CI)
# @param PD_DATE (optional) - the file's date YYYY-MM-DD, default today (UTC)
# @param PD_HUB_VERSION_URL (optional) - default https://<prd env.dns.api_fqdn>/version
# @param PD_PREV_MANIFEST (optional) - the previous published manifest, for the gate's size check
# @param PD_OUT_DIR (optional) - also keep the file and the manifest in this existing local directory
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @example ENV=dev PUBLIC_DATASET_FORCE=1 ./run -a do_spl_public_dataset_export
# @example ENV=dev PUBLIC_DATASET_FORCE=1 DRY_RUN=0 ./run -a do_spl_public_dataset_export
#------------------------------------------------------------------------------
do_spl_public_dataset_export() {
  do_require_bin yq jq psql python3 sha256sum curl git || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_spl_cloud_cnf || return 1
  spl_pd_export_switch || return 0
  local -A X=()
  spl_pd_export_cnf X || return 1
  spl_pd_export_release X || return 1
  if (( dry )); then
    do_log "INFO DRY_RUN would: names step, then read workspaces ${X[ws]} as ${X[login]} (password in ${X[slot]}) with $(ls "${X[sql]}"/*.sql | wc -l) projection(s) from ${X[sql]#"$PROJ_PATH"/}"
    do_log "INFO DRY_RUN would: gate the candidate, then write ${X[name]}.sql.gz and its manifest to gs://${X[staging]}/candidates/${X[cand]}/"
    do_log "INFO DRY_RUN version v${X[ver]} commit ${X[commit]:0:8}, migration head ${X[head]}, allow-list v${X[alv]}"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to export."
    return 0
  fi
  [[ "$(do_spl_cloud_provider)" == gcp ]] || { do_log "FATAL do_spl_public_dataset_export needs Secret Manager, Cloud SQL and GCS (provider gcp)"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_require_bin gcloud || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local h
  h="$(mktemp -d)" && chmod 700 "$h" && mkdir -m 700 "$h/names" "$h/raw" "$h/out" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$h'; trap - RETURN" RETURN
  PD_CANDIDATE="${X[cand]}" PD_NAMES_DIR="$h/names" DRY_RUN=0 do_spl_public_dataset_names || return 1
  spl_pd_export_run X "$h" || return 1
  spl_pd_export_stage X "$h" || return 1
}

# spl_pd_export_switch: 0 = go on; 1 = the kill switch is off (logged, the
# caller exits 0 and touches nothing).
spl_pd_export_switch() {
  local on
  on="$(yq -r '.env.public_dataset.enabled // false' "$SPL_CNF")"
  [[ "$on" == true || "${PUBLIC_DATASET_FORCE:-}" == 1 ]] && return 0
  do_log "OK public dataset export ($ENV) is off: cnf public_dataset.enabled is $on and PUBLIC_DATASET_FORCE is unset; nothing exported"
  return 1
}

# spl_pd_export_cnf <assoc name>: workspaces, buckets, topic channel, the
# allow-list and its projection dir, the export login and its password slot.
spl_pd_export_cnf() {
  local -n _x="$1"
  local staging public topic alv
  IFS=$'\t' read -r staging public topic alv < <(yq -r '[.env.steps."053-gcs-public-dataset".staging_bucket_name // "",
      .env.steps."053-gcs-public-dataset".public_bucket_name // "", .env.public_dataset.topic_channel // "",
      .env.public_dataset.allow_list_version // ""] | @tsv' "$SPL_CNF")
  _x[ws]="$(spl_pd_workspaces)" || return 1
  [[ "$staging" =~ ^[a-z0-9][a-z0-9._-]{2,62}$ ]] || { do_log "FATAL cnf staging_bucket_name of step 053 is unset for $ENV"; return 1; }
  [[ "$staging" != "$public" ]] || { do_log "FATAL the staging bucket is the public bucket: the export writes to private staging only"; return 1; }
  [[ "$topic" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL cnf public_dataset.topic_channel is unset or not a channel id for $ENV (its channel is never exported)"; return 1; }
  [[ "$alv" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL cnf public_dataset.allow_list_version is unset for $ENV"; return 1; }
  _x["allow"]="$PROJ_PATH/cnf/public-dataset/allow-list.v$alv.yaml"
  _x[sql]="$PROJ_PATH/src/sql/public-dataset/v$alv"
  [[ -r "${_x["allow"]}" && "$(yq -r '.["version"]' "${_x["allow"]}")" == "$alv" ]] ||
    { do_log "FATAL no allow-list v$alv or its version field disagrees"; return 1; }
  spl_pd_export_projections "${_x[sql]}" "${_x["allow"]}" || return 1
  local -a slots=()
  spl_public_export_slots slots || return 1
  [[ "${slots[0]%%:*}" == spool_public_export ]] || { do_log "FATAL cnf public_dataset.export_login must be spool_public_export"; return 1; }
  _x[login]="${slots[0]%%:*}" _x[slot]="${slots[0]#*:}"
  _x[staging]="$staging" _x[topic]="$topic" _x[alv]="$alv"
  _x["alsha"]="$(sha256sum <"${_x["allow"]}" | cut -d' ' -f1)"
}

# spl_pd_export_projections <dir> <allow-list>: one <nn>-<table>.sql per
# allow-list table, each opening with its `-- columns:` line.
spl_pd_export_projections() {
  local t f n=0
  for t in $(yq -r '.tables | keys | .[]' "$2"); do
    f="$(ls "$1"/[0-9][0-9]-"$t".sql 2>/dev/null)"
    [[ -n "$f" && "$(wc -l <<<"$f")" == 1 ]] || { do_log "FATAL no single projection file for $t in $1"; return 1; }
    [[ "$(head -1 "$f")" =~ ^--\ columns:\ [a-z_]+(,\ [a-z_]+)*$ ]] || { do_log "FATAL $(basename "$f") does not open with its -- columns: line"; return 1; }
    n=$((n + 1))
  done
  [[ "$(ls "$1"/*.sql | wc -l)" == "$n" ]] || { do_log "FATAL $1 holds a projection file for a table outside the allow-list"; return 1; }
}

# spl_pd_export_release <assoc name>: prd's hub version and commit, the
# migration head at that commit, the date, the candidate and file names and
# the version's release-note line.
spl_pd_export_release() {
  local -n _r="$1"
  local url body note
  url="${PD_HUB_VERSION_URL:-}"
  [[ -n "$url" ]] || url="https://$( (ENV=prd; do_spl_cloud_cnf >/dev/null 2>&1 && yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF") )/version"
  [[ "$url" =~ ^https://[a-z0-9.-]+\.[a-z]{2,}/version$ ]] || { do_log "FATAL cannot resolve prd's hub /version URL (cnf env.dns.api_fqdn of prd)"; return 1; }
  body="$(curl -sS --max-time 15 -H 'Cache-Control: no-cache' "$url" 2>/dev/null)" || { do_log "FATAL GET $url failed"; return 1; }
  _r[ver]="$(jq -r '.version // ""' <<<"$body" 2>/dev/null)" _r[commit]="$(jq -r '.commit // ""' <<<"$body" 2>/dev/null)"
  _r[ver]="${_r[ver]#v}"
  [[ "${_r[ver]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "${_r[commit]}" =~ ^[0-9a-f]{40}$ ]] ||
    { do_log "FATAL prd /version has no X.Y.Z version and 40-hex commit"; return 1; }
  _r[head]="$(git -C "$APP_PATH" ls-tree --name-only "${_r[commit]}" csi-spl-rdb/src/sql/postgres/spool-hub/ 2>/dev/null |
    sed -n 's|.*/\([0-9]\{4\}_[a-z0-9_]*\.sql\)$|\1|p' | sort | tail -1)"
  [[ -n "${_r[head]}" ]] || { do_log "FATAL prd's commit ${_r[commit]:0:8} is not in $APP_PATH (git fetch first): no migration head"; return 1; }
  local d="${PD_DATE:-$(date -u +%F)}"
  [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { do_log "FATAL PD_DATE must be YYYY-MM-DD"; return 1; }
  _r[cand]="$d-v${_r[ver]}" _r[name]="spool-hub-public-$d-v${_r[ver]}"
  note="$( (SHA="${_r[commit]}" ENV=prd do_release_note_link) 2>/dev/null)" || note=""
  _r[note]="$(awk '{print $3}' <<<"$note")"
  [[ "${_r[note]}" =~ ^https:// ]] || { do_log "FATAL no release-note link for ${_r[commit]:0:8} (do_release_note_link)"; return 1; }
}

# spl_pd_export_run <assoc name> <scratch>: the password, the proxy, the
# read, the assembly and the gate, the proxy stopped on every path.
spl_pd_export_run() {
  local -n _e="$1"
  local h="$2" owner_dsn ldsn rc=0
  (umask 077 && gcloud secrets versions access latest --secret="${_e[slot]}" --project="$SPL_PROJECT" \
    --account="$GCP_ACCOUNT" >"$h/pw" 2>/dev/null) && [[ -s "$h/pw" ]] ||
    { do_log "FATAL ${_e[slot]} has no readable version: run ENV=$ENV DRY_RUN=0 ./run -a do_spl_public_export_secret_seed first"; return 1; }
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" ]] || { do_log "FATAL $SPL_OWNER_DSN_SECRET has no DSN (it names the database and its socket)"; return 1; }
  spl_sql_proxy_start || return 1
  ldsn="$(spl_pd_export_dsn "$owner_dsn" "$h/pw")" || { spl_sql_proxy_stop; do_log "FATAL cannot build the spool_public_export DSN"; return 1; }
  rm -f "$h/pw"
  spl_pd_export_read "$ldsn" _e "$h/raw" && spl_pd_export_assemble _e "$h" &&
    PD_GATE_FILE="$h/candidate.sql" PD_GATE_OUT="$h/clean.sql" PD_GATE_REPORT="$h/gate.json" \
    PD_NAMES_FILE="$h/names/names.tsv" PD_EXPORT_DSN="$ldsn" do_spl_public_dataset_gate || rc=1
  spl_sql_proxy_stop
  (( rc == 0 )) || { do_log "FAIL public dataset export ($ENV): no candidate staged (classes above)"; return 1; }
}

# spl_pd_export_dsn <owner cloud dsn> <password file> -> the local proxy DSN
# of spool_public_export (the owner DSN's database and socket, another login).
spl_pd_export_dsn() {
  local cloud
  cloud="$(SPL_DSN_IN="$1" SPL_PW_IN="$(cat "$2")" python3 -c '
import os, urllib.parse as u
p = u.urlsplit(os.environ["SPL_DSN_IN"])
print(u.urlunsplit((p.scheme, "spool_public_export:%s@" % u.quote(os.environ["SPL_PW_IN"], safe=""), p.path, p.query, "")), end="")')" &&
    spl_local_dsn "$cloud" "$SPL_PROXY_PORT"
}

# spl_pd_export_read <export dsn> <assoc name> <raw dir>: one READ ONLY
# transaction per workspace, its projections each COPY'd to
# <raw>/<ws>/<table>.tsv. It asserts its own login first; the database's
# message is never printed (it may quote a row).
spl_pd_export_read() {
  local dsn="$1" raw="$3" w f t script out
  local -n _d="$2"
  script="$(spl_pd_gate_whoami_sql)"$'\n'
  for w in ${_d[ws]//,/ }; do
    mkdir -m 700 "$raw/$w" || return 1
    script+="$(printf "\\\\set ws '%s'\n\\\\set topic_channel '%s'\nBEGIN READ ONLY;\nSET LOCAL app.tenant_id = :'ws';" "$w" "${_d[topic]}")"$'\n'
    for f in "${_d[sql]}"/[0-9][0-9]-*.sql; do
      t="$(basename "$f" .sql)"; t="${t#[0-9][0-9]-}"
      script+="\\o $raw/$w/$t.tsv"$'\n'"COPY ("$'\n'"$(cat "$f")"$'\n'") TO STDOUT;"$'\n'
    done
    script+='\o'$'\n'"ROLLBACK;"$'\n'
  done
  out="$(printf '%s' "$script" | spl_pg_env "$dsn" psql -X -q -At -v ON_ERROR_STOP=1 -f - 2>/dev/null)" ||
    { do_log "FATAL the projection read as spool_public_export failed (the database's message is not shown)"; return 1; }
  [[ "$(head -1 <<<"$out")" == "spool_public_export|f|f" ]] ||
    { do_log "FATAL the export must read as spool_public_export (no superuser, no bypassrls), got another login"; return 1; }
}

# spl_pd_export_assemble <assoc name> <scratch>: <raw>/<ws>/<table>.tsv ->
# candidate.sql (COPY blocks in the projections' file order, which is FK
# order) and export.json (rows removed by class). FATAL, nothing written,
# when a row's tenant_id is not the workspace it was read under (fence 3's
# check after the read). Output names the table and the row number only.
spl_pd_export_assemble() {
  local -n _a="$1"
  (umask 077 && python3 - "${_a[sql]}" "$2/raw" "${_a[ws]}" "$2/candidate.sql" "$2/export.json" <<'EOF_PY'
import json, os, re, sys
sqldir, raw, ws, out, rep = sys.argv[1], sys.argv[2], sys.argv[3].split(","), sys.argv[4], sys.argv[5]
HUM = re.compile(r"^HUM-[0-9]+$")
order = []
for f in sorted(x for x in os.listdir(sqldir) if re.match(r"^[0-9]{2}-[a-z_]+\.sql$", x)):
    head = open(os.path.join(sqldir, f), encoding="utf-8").readline()
    order.append((f[3:-4], [c.strip() for c in head[len("-- columns:"):].split(",")]))
def read(w, t, cols):
    lines = open(os.path.join(raw, w, t + ".tsv"), encoding="utf-8").read().split("\n")
    rows = [dict(zip(cols, l.split("\t"))) for l in lines if l != ""]
    if any(len(r) != len(cols) for r in rows):
        sys.exit("FATAL C3 export %s: a row with the wrong number of columns" % t)
    if "tenant_id" in cols:
        for n, r in enumerate(rows, 1):
            if r["tenant_id"] != w:
                sys.exit("FATAL C1 export %s row %d: a row of another workspace, nothing written" % (t, n))
    return rows
removed, keep, humans = {}, {t: [] for t, _ in order}, {}
cols_of = dict(order)
for w in ws:
    got = {t: read(w, t, cols) for t, cols in order}
    members = {r["human_id"] for r in got["tenant_memberships"]}
    msgs = []
    for r in got["messages"]:
        if any(HUM.match(r[c]) and r[c] not in members for c in ("from_id", "to_id")):
            removed["non-member"] = removed.get("non-member", 0) + 1
        else:
            msgs.append(r)
    used = {r[c] for r in msgs for c in ("from_id", "to_id") if HUM.match(r[c])}
    keep["messages"] += msgs
    keep["tenant_memberships"] += [r for r in got["tenant_memberships"] if r["human_id"] in used]
    for r in got["humans"]:
        if r["human_id"] in used:
            humans[r["human_id"]] = r
    for t in ("tenants", "channels"):
        keep[t] += got[t]
keep["humans"] = [humans[k] for k in sorted(humans)]
with open(out, "w", encoding="utf-8") as fh:
    for t, cols in order:
        fh.write("COPY %s (%s) FROM stdin;\n" % (t, ", ".join(cols)))
        fh.writelines("\t".join(r[c] for c in cols) + "\n" for r in keep[t])
        fh.write("\\.\n")
json.dump({"removed_by_class": removed, "rows": {t: len(keep[t]) for t, _ in order}}, open(rep, "w"), sort_keys=True)
print("INFO export read: %s; removed %s" % (", ".join("%s %d" % (t, len(keep[t])) for t, _ in order),
      ", ".join("%s %d" % kv for kv in sorted(removed.items())) or "none"))
EOF_PY
  ) >"$2/assemble.log" 2>&1
  local rc=$? line
  while IFS= read -r line; do do_log "$line"; done <"$2/assemble.log"
  (( rc == 0 )) || { do_log "FATAL the export's read did not assemble (above): nothing written"; return 1; }
}

# spl_pd_export_stage <assoc name> <scratch>: gzip the gated file, write its
# manifest, put both in PRIVATE staging under candidates/<cand>/ (and
# PD_OUT_DIR when set). The output gives the sha256 and counts, no content.
spl_pd_export_stage() {
  local -n _s="$1"
  local h="$2" gz man sha dest
  gz="$h/out/${_s[name]}.sql.gz" man="$h/out/${_s[name]}.manifest.json"
  gzip -n -9 -c "$h/clean.sql" >"$gz" || { do_log "FATAL cannot gzip the candidate"; return 1; }
  sha="$(sha256sum "$gz" | cut -d' ' -f1)"
  jq -n --slurpfile g "$h/gate.json" --slurpfile e "$h/export.json" --arg file "$(basename "$gz")" --arg sha "$sha" \
    --arg ver "${_s[ver]}" --arg commit "${_s[commit]}" --arg head "${_s[head]}" --argjson alv "${_s[alv]}" \
    --arg alsha "${_s["alsha"]}" --arg note "${_s[note]}" --arg ws "${_s[ws]}" --arg env "$ENV" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{v: 1, file: $file, sha256: $sha, version: $ver, commit: $commit,
      migration_head: $head, allow_list_version: $alv, allow_list_sha256: $alsha, workspace_ids: ($ws | split(",")),
      row_counts: $g[0].row_counts, removed_by_class: ($e[0].removed_by_class + $g[0].removed_by_class),
      release_note: $note, source_env: $env, exported_at: $at}' >"$man" ||
    { do_log "FATAL cannot write the manifest"; return 1; }
  dest="gs://${_s[staging]}/candidates/${_s[cand]}"
  local f
  for f in "$gz" "$man"; do
    gcloud storage cp "$f" "$dest/$(basename "$f")" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
      { do_log "FATAL cannot write $dest/$(basename "$f")"; return 1; }
  done
  [[ -z "${PD_OUT_DIR:-}" ]] || { [[ -d "$PD_OUT_DIR" ]] && cp "$gz" "$man" "$PD_OUT_DIR/"; } ||
    { do_log "FATAL PD_OUT_DIR $PD_OUT_DIR is not a writable directory (the candidate IS staged)"; return 1; }
  do_log "OK public dataset candidate ($ENV) staged: $dest/$(basename "$gz") sha256 $sha"
  do_log "INFO rows $(jq -r '.row_counts | to_entries | map("\(.key) \(.value)") | join(", ")' "$man"); removed $(jq -r '.removed_by_class | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end' "$man")"
}
