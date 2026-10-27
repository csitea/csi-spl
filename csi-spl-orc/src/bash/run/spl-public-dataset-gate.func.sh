#!/bin/bash
#------------------------------------------------------------------------------
# @description The public dataset gate (spec 091 T005, sections 5.5 and 5.6),
# @description run by the export (T006) on a candidate seed file BEFORE it is
# @description staged. Fail closed: any FATAL = exit 1, no cleaned file.
# @description   C3     every table and column of the file is a public one of
# @description          the allow-list (cnf/public-dataset/allow-list.v<N>.yaml),
# @description          every constant holds its fixed value, and every LIVE
# @description          column of a listed table (pg_attribute, not a grep)
# @description          is classified public or withheld
# @description   C1     no tenant_id but the cnf workspaces (workspace_ids);
# @description          exactly one tenants row per listed workspace
# @description   C2     every row is found again on a SECOND connection as the
# @description          export login, pinned by RLS alone (no filter), one
# @description          transaction per listed workspace
# @description   MEMBER members are HUM-n ids only (Q1b): display_name =
# @description          human_id, no e-mail, every HUM-n a message names is an
# @description          exported member
# @description   C4     e-mail, IPv4/IPv6, JWT, PEM, cloud / Slack / GitHub
# @description          tokens, iam.gserviceaccount.com, gitleaks with the
# @description          repo's .gitleaks.toml, every other workspace's id and
# @description          display name (the names step's list) as whole words.
# @description          A hit in a message body drops that message and counts
# @description          it by class (Q3), then the scan runs again and must be
# @description          clean; above public_dataset.body_drop_cap_pct dropped,
# @description          or a hit anywhere else, the day fails
# @description   SIZE   row counts within public_dataset.size_tolerance_pct of
# @description          the previous manifest (skipped for the first file or a
# @description          new allow-list version)
# @description Output names the class, the table and the row key, never the
# @description matched text (CI logs are public). The core is
# @description src/bash/scripts/public-dataset-gate.py; this action reads the
# @description database facts it needs and writes nothing to any bucket.
# @param ENV - required: dev or prd (the cnf: workspaces, caps, allow-list version)
# @param PD_GATE_FILE - required: the candidate seed file (.sql or .sql.gz)
# @param PD_GATE_OUT - required: where the cleaned file goes (must not exist)
# @param PD_GATE_REPORT - required: the gate report JSON (counts, removed by class)
# @param PD_NAMES_FILE - required: the names step's list (do_spl_public_dataset_names)
# @param PD_EXPORT_DSN - required: the export login (spool_public_export) DSN, e.g. through the proxy
# @param PD_PREV_MANIFEST (optional) - the previous published manifest (size check)
# @example ENV=dev PD_GATE_FILE=cand.sql.gz PD_GATE_OUT=clean.sql PD_GATE_REPORT=gate.json PD_NAMES_FILE=names.tsv PD_EXPORT_DSN=postgres://... ./run -a do_spl_public_dataset_gate
#------------------------------------------------------------------------------
do_spl_public_dataset_gate() {
  do_require_bin python3 yq psql || return 1
  # gitleaks is checked here, not in the require line above: the gate runs on the CI
  # runner (spec 091 5.4), never as the box user, so the box verify list
  # (satellite-ansible.tst.sh section 8) does not provision it
  command -v gitleaks >/dev/null || { do_log "FATAL gitleaks is not on PATH: the gate's C4 scan needs it (fail closed)"; return 1; }
  spl_pd_gate_args || return 1
  do_spl_cloud_cnf || return 1
  local ws cap tol ver allow
  IFS=$'\t' read -r cap tol ver < <(yq -r '[.env.public_dataset.body_drop_cap_pct // "",
      .env.public_dataset.size_tolerance_pct // "", .env.public_dataset.allow_list_version // ""] | @tsv' "$SPL_CNF")
  ws="$(spl_pd_workspaces)" || return 1
  [[ "$cap" =~ ^[0-9]+(\.[0-9]+)?$ && "$tol" =~ ^[0-9]+(\.[0-9]+)?$ && "$ver" =~ ^[0-9]+$ ]] ||
    { do_log "FATAL cnf public_dataset body_drop_cap_pct / size_tolerance_pct / allow_list_version unset or malformed for $ENV"; return 1; }
  allow="$PROJ_PATH/cnf/public-dataset/allow-list.v$ver.yaml"
  [[ -r "$allow" && "$(yq -r '.["version"]' "$allow")" == "$ver" ]] ||
    { do_log "FATAL no allow-list v$ver ($allow) or its version field disagrees"; return 1; }

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$h'; trap - RETURN" RETURN
  yq -o=json '.' "$allow" >"$h/allow.json" || { do_log "FATAL cannot read $allow"; return 1; }
  spl_pd_gate_unpack "$PD_GATE_FILE" "$h/candidate.sql" || return 1
  spl_pd_gate_catalog "$PD_EXPORT_DSN" "$h/allow.json" "$h/catalog.json" || return 1
  spl_pd_gate_reread "$PD_EXPORT_DSN" "$ws" "$h/reread.json" || return 1

  local rc=0 line
  python3 "$PROJ_PATH/src/bash/scripts/public-dataset-gate.py" --file "$h/candidate.sql" \
    --allow-list "$h/allow.json" --catalog "$h/catalog.json" --reread "$h/reread.json" \
    --names "$PD_NAMES_FILE" --workspace "$ws" --out "$PD_GATE_OUT" --report "$PD_GATE_REPORT" \
    --prev-manifest "${PD_PREV_MANIFEST:-}" --drop-cap-pct "$cap" --size-tol-pct "$tol" \
    --gitleaks "$(command -v gitleaks)" --gitleaks-config "$APP_PATH/.gitleaks.toml" >"$h/gate.log" 2>&1 || rc=$?
  while IFS= read -r line; do do_log "$line"; done <"$h/gate.log"
  if (( rc != 0 )); then
    rm -f "$PD_GATE_OUT"
    do_log "FAIL public dataset gate ($ENV): the candidate is NOT fit to stage (exit $rc); classes above, report $PD_GATE_REPORT"
    return 1
  fi
  do_log "OK public dataset gate ($ENV): cleaned candidate $PD_GATE_OUT, report $PD_GATE_REPORT"
}

# spl_pd_workspaces -> the cnf public_dataset.workspace_ids of $SPL_CNF as one
# comma-joined line (a,b,c), the form the gate, the names step and the role
# action pass on. Each a workspace slug, none twice, at least one; else FATAL.
spl_pd_workspaces() {
  local ids w
  ids="$(yq -r '.env.public_dataset.workspace_ids // [] | .[]' "$SPL_CNF" 2>/dev/null)" ||
    { do_log "FATAL cnf public_dataset.workspace_ids of $ENV is not a list"; return 1; }
  [[ -n "$ids" ]] || { do_log "FATAL cnf public_dataset.workspace_ids is unset or empty for $ENV"; return 1; }
  while IFS= read -r w; do
    spl_require_tenant_slug "$w" || { do_log "FATAL cnf public_dataset.workspace_ids of $ENV holds a value that is not a workspace slug"; return 1; }
  done <<<"$ids"
  [[ "$(sort -u <<<"$ids" | wc -l)" == "$(wc -l <<<"$ids")" ]] ||
    { do_log "FATAL cnf public_dataset.workspace_ids of $ENV names a workspace twice"; return 1; }
  paste -sd, <<<"$ids"
}

# spl_pd_gate_args: every refusal that needs no cnf and no database.
spl_pd_gate_args() {
  local v
  for v in PD_GATE_FILE PD_GATE_OUT PD_GATE_REPORT PD_NAMES_FILE PD_EXPORT_DSN; do
    [[ -n "${!v:-}" ]] || { do_log "FATAL $v is required (no default)"; return 1; }
  done
  [[ -r "$PD_GATE_FILE" ]] || { do_log "FATAL no candidate file $PD_GATE_FILE"; return 1; }
  [[ -r "$PD_NAMES_FILE" ]] || { do_log "FATAL no names list $PD_NAMES_FILE: run do_spl_public_dataset_names first (a gate without it fails closed)"; return 1; }
  [[ ! -e "$PD_GATE_OUT" ]] || { do_log "FATAL $PD_GATE_OUT exists: the gate never overwrites a cleaned file"; return 1; }
  [[ -z "${PD_PREV_MANIFEST:-}" || -r "$PD_PREV_MANIFEST" ]] || { do_log "FATAL no previous manifest $PD_PREV_MANIFEST"; return 1; }
  [[ -r "$APP_PATH/.gitleaks.toml" ]] || { do_log "FATAL no $APP_PATH/.gitleaks.toml (the repo's gitleaks config)"; return 1; }
}

spl_pd_gate_unpack() {
  if gzip -t "$1" 2>/dev/null; then
    gzip -dc "$1" >"$2" || { do_log "FATAL cannot gunzip the candidate"; return 1; }
  else
    cp "$1" "$2" || return 1
  fi
}

# spl_pd_gate_catalog <export dsn> <allow json> <out>: the LIVE columns of
# every allow-list table, read from pg_attribute (readable by any login,
# unlike information_schema.columns, which hides the columns a role cannot
# read). Refuses unless the login is spool_public_export with no superuser and
# no bypassrls: a re-read by any other role would not be "RLS alone".
spl_pd_gate_catalog() {
  local dsn="$1" tables out
  tables="$(python3 -c 'import json, sys; print(",".join(sorted(json.load(open(sys.argv[1]))["tables"])))' "$2")" || return 1
  out="$(printf "\\\\set tables '%s'\n%s\n" "$tables" "$(spl_pd_gate_catalog_sql)" |
    spl_pg_env "$dsn" psql -X -q -At -v ON_ERROR_STOP=1 -f - 2>&1)" ||
    { do_log "FATAL cannot read the live catalog as the export login (the database's message is not shown)"; return 1; }
  [[ "$(sed -n 1p <<<"$out")" == "spool_public_export|f|f" ]] ||
    { do_log "FATAL the gate must read as spool_public_export (no superuser, no bypassrls), got another login"; return 1; }
  sed -n '2,$p' <<<"$out" >"$3"
  python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$3" 2>/dev/null ||
    { do_log "FATAL the live catalog read is not JSON"; return 1; }
}

spl_pd_gate_catalog_sql() {
  cat <<'EOF_SQL'
SELECT current_user, r.rolsuper, r.rolbypassrls FROM pg_roles r WHERE r.rolname = current_user;
SELECT coalesce(json_object_agg(t.relname, t.cols), '{}') FROM (
  SELECT c.relname, json_agg(a.attname::text ORDER BY a.attnum) AS cols
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
     AND c.relname = ANY (string_to_array(:'tables', ','))
   GROUP BY c.relname) t;
EOF_SQL
}

# spl_pd_gate_reread <export dsn> <workspaces a,b,..> <out>: a SECOND
# connection, the export login and NO filter, one transaction per listed
# workspace with app.tenant_id set to it: the keys RLS lets it see, merged
# into one JSON object of [workspace, key] pairs per table. humans has no RLS; its rows are checked
# against the memberships re-read. It asserts its own login too, so "RLS
# alone" holds for this connection.
spl_pd_gate_reread() {
  local out w sql=""
  for w in ${2//,/ }; do
    sql+="$(printf "\\\\set ws '%s'\nBEGIN READ ONLY;\nSET LOCAL app.tenant_id = :'ws';\n%s\nROLLBACK;" "$w" "$(spl_pd_gate_reread_sql)")"$'\n'
  done
  out="$(printf '%s%s' "$(spl_pd_gate_whoami_sql)"$'\n' "$sql" | spl_pg_env "$1" psql -X -q -At -v ON_ERROR_STOP=1 -f - 2>&1)" ||
    { do_log "FATAL the RLS re-read failed as the export login (the database's message is not shown)"; return 1; }
  [[ "$(sed -n 1p <<<"$out")" == "spool_public_export|f|f" ]] ||
    { do_log "FATAL the RLS re-read must run as spool_public_export (no superuser, no bypassrls), got another login"; return 1; }
  sed -n '2,$p' <<<"$out" | python3 -c '
import json, sys
m, ws = {}, sys.argv[2].split(",")
lines = [json.loads(x) for x in sys.stdin if x.strip()]
assert len(lines) == len(ws)
for w, d in zip(ws, lines):
    for k, v in d.items():
        m.setdefault(k, []).extend([w, x] for x in v)
json.dump(m, open(sys.argv[1], "w"))' "$3" "$2" 2>/dev/null ||
    { do_log "FATAL the RLS re-read is not JSON"; return 1; }
}

spl_pd_gate_whoami_sql() {
  echo 'SELECT current_user, r.rolsuper, r.rolbypassrls FROM pg_roles r WHERE r.rolname = current_user;'
}

spl_pd_gate_reread_sql() {
  cat <<'EOF_SQL'
SELECT json_build_object(
  'tenants', (SELECT coalesce(json_agg(tenant_id), '[]') FROM tenants),
  'tenant_memberships', (SELECT coalesce(json_agg(human_id), '[]') FROM tenant_memberships),
  'channels', (SELECT coalesce(json_agg(channel_id), '[]') FROM channels),
  'messages', (SELECT coalesce(json_agg(msg_id), '[]') FROM messages));
EOF_SQL
}
