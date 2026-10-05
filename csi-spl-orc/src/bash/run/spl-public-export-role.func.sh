#!/bin/bash
#------------------------------------------------------------------------------
# @description Fence 1 of the public dataset export (spec 091 T004, spec 5.1 and
# @description 5.5 item 3): as the schema OWNER (cnf hub.db_owner_user, its DSN
# @description from hub.db_owner_dsn_secret, through the Cloud SQL proxy) apply
# @description csi-spl-rdb spool-hub-roles/
# @description   public-export-role.sql   the export login spool_public_export
# @description   public-export-grants.sql column SELECT on the allow-list only
# @description                            (generated: refused when stale)
# @description   public-names-role.sql    the names login spool_public_names,
# @description                            SELECT (tenant_id, display_name) ON tenants
# @description each password set as a SCRAM verifier computed here from the
# @description Secret Manager slots do_spl_public_export_secret_seed fills, then
# @description write the one public_export_workspace row (rdb 0126) from cnf
# @description public_dataset.workspace_id. Then read EVERY flag back as the
# @description owner (the do_spl_db_owner_split verify pattern): login, no
# @description superuser / bypassrls / createrole / createdb, noinherit, 0
# @description memberships, owns 0, the exact column and table privileges, the
# @description workspace row; and log in AS each login: the allowed read works,
# @description a withheld column (messages.msg, humans.email, tenants.root_pubkey)
# @description and a never-exported table are refused. One OK or FAIL line each.
# @description Passwords and verifiers travel on stdin, in 0600 scratch files and
# @description in the environment (spl_pg_env): never a psql or gcloud argv,
# @description stdout or a log. Idempotent.
# @description Also FAILs when PUBLIC holds any privilege on a table or column
# @description of the schema (every login would inherit it).
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): check the files and cnf, no cloud. 0: apply + verify.
# @param VERIFY_ONLY (optional) - 1: read back and probe, apply nothing
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account (the per-env project SA from its key otherwise; never the owner account)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_public_export_role
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_public_export_role
# @example ENV=prd DRY_RUN=0 VERIFY_ONLY=1 ./run -a do_spl_public_export_role
#------------------------------------------------------------------------------
do_spl_public_export_role() {
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "${VERIFY_ONLY:-0}" =~ ^[01]$ ]] || { do_log "FATAL VERIFY_ONLY must be 0 or 1"; return 1; }

  local -a slots=()
  spl_public_export_slots slots || return 1
  [[ "${slots[0]%%:*}" == spool_public_export && "${slots[1]%%:*}" == spool_public_names ]] ||
    { do_log "FATAL cnf public_dataset export_login / names_login must be spool_public_export / spool_public_names (the names rdb 0126 and the roles SQL use)"; return 1; }
  local ws f
  ws="$(yq -r '.env.public_dataset.workspace_id // ""' "$SPL_CNF")"
  spl_require_tenant_slug "$ws" || { do_log "FATAL cnf public_dataset.workspace_id is unset for $ENV"; return 1; }
  for f in public-export-role.sql public-export-grants.sql public-names-role.sql; do
    [[ -r "$SPL_DB_ROLES_SQL/$f" ]] || { do_log "FATAL no roles SQL $SPL_DB_ROLES_SQL/$f"; return 1; }
  done
  CHECK=1 OUT='' do_spl_public_export_grants_gen || return 1

  if (( dry )); then
    do_log "INFO DRY_RUN would: as $SPL_DB_OWNER_USER on $SPL_SQL_CONN/$SPL_DB_NAME apply public-export-role.sql, public-export-grants.sql, public-names-role.sql with the passwords in ${slots[0]#*:} / ${slots[1]#*:}"
    do_log "INFO DRY_RUN would: set public_export_workspace to $ws, read every flag back, probe as both logins"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to apply."
    return 0
  fi
  [[ "$(do_spl_cloud_provider)" == gcp ]] || { do_log "FATAL do_spl_public_export_role needs Secret Manager (provider gcp)"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_require_bin gcloud || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local h
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "shred -u '$h'/* 2>/dev/null; rm -rf '$h'; trap - RETURN" RETURN
  local s
  for s in "${slots[@]}"; do
    (umask 077 && gcloud secrets versions access latest --secret="${s#*:}" --project="$SPL_PROJECT" \
      --account="$GCP_ACCOUNT" >"$h/${s%%:*}" 2>/dev/null) && [[ -s "$h/${s%%:*}" ]] ||
      { do_log "FATAL ${s#*:} has no readable version: run ENV=$ENV DRY_RUN=0 ./run -a do_spl_public_export_secret_seed first"; return 1; }
  done
  local owner_dsn
  owner_dsn="$(spl_read_owner_dsn)"
  [[ -n "$owner_dsn" && "$(spl_dsn_user "$owner_dsn")" == "$SPL_DB_OWNER_USER" ]] ||
    { do_log "FATAL $SPL_OWNER_DSN_SECRET has no $SPL_DB_OWNER_USER DSN"; return 1; }

  local odsn rc=0
  spl_sql_proxy_start || return 1
  odsn="$(spl_local_dsn "$owner_dsn" "$SPL_PROXY_PORT")" ||
    { spl_sql_proxy_stop; do_log "FATAL the DSN in $SPL_OWNER_DSN_SECRET is not the /cloudsql socket form"; return 1; }
  if [[ "${VERIFY_ONLY:-0}" != 1 ]]; then
    spl_public_export_role_apply "$odsn" "$h" "$ws" || rc=1
  fi
  (( rc == 0 )) && { spl_public_export_role_verify "$odsn" "$ws" || rc=1; }
  (( rc == 0 )) && { spl_public_export_login_probes "$owner_dsn" "$h" || rc=1; }
  spl_sql_proxy_stop
  (( rc == 0 )) || { do_log "FAIL public dataset logins on $SPL_DB_NAME ($ENV): see above"; return 1; }
  do_log "OK public dataset logins on $SPL_DB_NAME ($ENV): spool_public_export reads the allow-list columns of workspace $ws only, spool_public_names reads tenants (tenant_id, display_name) only"
}

# spl_public_export_role_psql <owner proxy dsn> <roles sql file> [<preamble>]
# -> runs one spool-hub-roles file as the owner; the preamble (a \set holding
# a verifier) goes on stdin, never argv.
spl_public_export_role_psql() {
  { [[ -n "${3:-}" ]] && printf '%s\n' "$3"; cat "$SPL_DB_ROLES_SQL/$2"; } |
    spl_pg_env "$1" psql -X -q -v ON_ERROR_STOP=1 -f - >/dev/null
}

# spl_public_export_role_apply <owner proxy dsn> <scratch dir> <workspace>
spl_public_export_role_apply() {
  local odsn="$1" h="$2" ws="$3" ev nv out
  ev="$(spl_scram_verifier <"$h/spool_public_export")" && nv="$(spl_scram_verifier <"$h/spool_public_names")" ||
    { do_log "FATAL cannot compute the SCRAM verifiers"; return 1; }
  spl_public_export_role_psql "$odsn" public-export-role.sql "\\set export_verifier '$ev'" ||
    { do_log "FAIL public-export-role.sql as $SPL_DB_OWNER_USER"; return 1; }
  spl_public_export_role_psql "$odsn" public-export-grants.sql ||
    { do_log "FAIL public-export-grants.sql as $SPL_DB_OWNER_USER"; return 1; }
  spl_public_export_role_psql "$odsn" public-names-role.sql "\\set names_verifier '$nv'" ||
    { do_log "FAIL public-names-role.sql as $SPL_DB_OWNER_USER"; return 1; }
  do_log "INFO applied public-export-role.sql, public-export-grants.sql, public-names-role.sql as $SPL_DB_OWNER_USER (passwords set as SCRAM verifiers)"
  out="$(printf "\\\\set ws '%s'\nINSERT INTO public_export_workspace (workspace_id) VALUES (:'ws')\n  ON CONFLICT (one_row) DO UPDATE SET workspace_id = EXCLUDED.workspace_id;\n" "$ws" |
    spl_pg_env "$odsn" psql -X -q -v ON_ERROR_STOP=1 -f - 2>&1)" ||
    { do_log "FAIL could not write public_export_workspace = $ws: $out"; return 1; }
  do_log "INFO public_export_workspace = $ws"
}

# spl_public_export_role_facts_sql -> one JSON line, read by the OWNER: per
# login its flags, memberships, owned objects, table and column privileges,
# and the public_export_workspace row.
spl_public_export_role_facts_sql() {
  cat <<'EOF_SQL'
SELECT json_build_object(
  'workspace', (SELECT json_agg(workspace_id) FROM public_export_workspace),
  'public_grants', (SELECT coalesce(json_agg(g ORDER BY g), '[]') FROM (
      SELECT c.relname || ':' || x.privilege_type AS g
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) x
       WHERE n.nspname = 'public' AND x.grantee = 0 AND c.relkind IN ('r', 'v', 'm', 'p', 'S')
      UNION
      SELECT c.relname || '.' || a.attname || ':' || x.privilege_type
        FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(a.attacl) x
       WHERE n.nspname = 'public' AND x.grantee = 0) pg),
  'roles', (SELECT json_object_agg(r.rolname, json_build_object(
    'login', r.rolcanlogin, 'superuser', r.rolsuper, 'bypassrls', r.rolbypassrls,
    'createrole', r.rolcreaterole, 'createdb', r.rolcreatedb, 'inherit', r.rolinherit,
    'replication', r.rolreplication,
    'member_of', (SELECT count(*) FROM pg_auth_members m WHERE m.member = r.oid),
    'owns', (SELECT count(*) FROM pg_class c WHERE c.relowner = r.oid)
          + (SELECT count(*) FROM pg_namespace n WHERE n.nspowner = r.oid)
          + (SELECT count(*) FROM pg_proc p WHERE p.proowner = r.oid),
    'tables', (SELECT coalesce(json_agg(c.relname || ':' || x.privilege_type ORDER BY 1), '[]')
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) x
               WHERE n.nspname = 'public' AND x.grantee = r.oid),
    'columns', (SELECT coalesce(json_agg(c.relname || '.' || a.attname || ':' || x.privilege_type ORDER BY 1), '[]')
                FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(a.attacl) x
                WHERE n.nspname = 'public' AND x.grantee = r.oid AND NOT a.attisdropped)))
    FROM pg_roles r WHERE r.rolname IN ('spool_public_export', 'spool_public_names')));
EOF_SQL
}

# spl_public_export_role_verify <owner proxy dsn> <workspace> -> reads the
# facts as the owner and compares them with the grants file and the names
# rule; one OK / FAIL line per login and one for the workspace row.
spl_public_export_role_verify() {
  local odsn="$1" ws="$2" facts v
  facts="$(spl_public_export_role_facts_sql | spl_pg_env "$odsn" psql -X -q -At -v ON_ERROR_STOP=1 -f - 2>&1)" ||
    { do_log "FAIL cannot read the public dataset logins back as $SPL_DB_OWNER_USER: $facts"; return 1; }
  v="$(spl_public_export_role_verdict "$facts" "$ws" "$SPL_DB_ROLES_SQL/public-export-grants.sql")" ||
    { do_log "FAIL cannot parse the public dataset login facts"; return 1; }
  local line bad=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    do_log "$line"
    [[ "$line" == OK* ]] || bad=1
  done <<<"$v"
  return "$bad"
}

# spl_public_export_role_verdict <facts json> <workspace> <grants file> ->
# "OK ..." / "FAIL ..." lines. The export login's expected column set is
# parsed from the grants file (which CHECK=1 pinned to the allow-list).
spl_public_export_role_verdict() {
  SPL_FACTS="$1" SPL_WS="$2" python3 - "$3" <<'EOF_PY'
import json, os, re, sys
d = json.loads(os.environ["SPL_FACTS"])
want_cols = set()
for t_cols, t in re.findall(r"^GRANT SELECT \(([^)]*)\) ON (\w+) TO spool_public_export;$", open(sys.argv[1]).read(), re.M):
    want_cols |= {"%s.%s:SELECT" % (t, c.strip()) for c in t_cols.split(",")}
want = {
    "spool_public_export": (want_cols, {"public_export_workspace:SELECT"}),
    "spool_public_names": ({"tenants.tenant_id:SELECT", "tenants.display_name:SELECT"}, set()),
}
roles = d.get("roles") or {}
for name, (cols, tables) in want.items():
    r = roles.get(name)
    if r is None:
        print("FAIL %s does not exist" % name); continue
    bad = [k for k in ("superuser", "bypassrls", "createrole", "createdb", "inherit", "replication") if r.get(k)]
    bad += [] if r.get("login") else ["no LOGIN"]
    bad += ["%s=%s" % (k, r.get(k)) for k in ("member_of", "owns") if r.get(k)]
    have_c, have_t = set(r.get("columns") or []), set(r.get("tables") or [])
    bad += ["extra column grant %s" % x for x in sorted(have_c - cols)]
    bad += ["missing column grant %s" % x for x in sorted(cols - have_c)]
    bad += ["extra table grant %s" % x for x in sorted(have_t - tables)]
    bad += ["missing table grant %s" % x for x in sorted(tables - have_t)]
    if bad:
        print("FAIL %s: %s" % (name, ", ".join(bad)))
    else:
        print("OK %s: login, noinherit, no superuser/bypassrls/createrole/createdb/replication, 0 memberships, owns 0, exactly %d column grant(s) and %d table grant(s)" % (name, len(cols), len(tables)))
pub = d.get("public_grants") or []
print(("FAIL PUBLIC holds %d privilege(s) every login inherits: %s" % (len(pub), ", ".join(pub[:10]))) if pub else
      "OK PUBLIC holds no table or column privilege in schema public")
ws = d.get("workspace") or []
print(("OK public_export_workspace = %s" % ws[0]) if ws == [os.environ["SPL_WS"]] else
      ("FAIL public_export_workspace holds %s, cnf says %s" % (ws, os.environ["SPL_WS"])))
EOF_PY
}

# spl_public_export_login_probes <owner cloud dsn> <scratch dir> -> logs in
# AS each login through the running proxy: its one allowed read must work,
# each refused read must fail with a permission error.
spl_public_export_login_probes() {
  local owner_dsn="$1" h="$2" login cloud ldsn probe want out rc bad=0
  while IFS='|' read -r login probe want; do
    cloud="$(SPL_DSN_IN="$owner_dsn" SPL_USER_IN="$login" SPL_PW_IN="$(cat "$h/$login")" python3 -c '
import os, urllib.parse as u
p = u.urlsplit(os.environ["SPL_DSN_IN"])
print(u.urlunsplit((p.scheme, "%s:%s@" % (os.environ["SPL_USER_IN"], u.quote(os.environ["SPL_PW_IN"], safe="")), p.path, p.query, "")), end="")')" &&
      ldsn="$(spl_local_dsn "$cloud" "$SPL_PROXY_PORT")" || { do_log "FAIL cannot build the $login DSN"; return 1; }
    rc=0
    out="$(printf 'BEGIN READ ONLY;\n%s;\nROLLBACK;\n' "$probe" | spl_pg_env "$ldsn" psql -X -q -At -v ON_ERROR_STOP=1 -f - 2>&1)" || rc=$?
    if [[ "$want" == ok ]]; then
      if (( rc == 0 )); then do_log "OK $login reads: $probe"; else do_log "FAIL $login cannot run: $probe: $out"; bad=1; fi
    elif (( rc == 0 )); then
      do_log "FAIL $login ran what it must not: $probe"; bad=1
    elif grep -qi 'permission denied' <<<"$out"; then
      do_log "OK refused as $login: $probe"
    else
      do_log "FAIL '$probe' as $login failed for another reason: $out"; bad=1
    fi
  done <<'EOF_PROBES'
spool_public_export|SELECT count(*) FROM (SELECT tenant_id, display_name FROM tenants) t|ok
spool_public_export|SELECT msg FROM messages LIMIT 1|denied
spool_public_export|SELECT email FROM humans LIMIT 1|denied
spool_public_export|SELECT root_pubkey FROM tenants LIMIT 1|denied
spool_public_export|SELECT count(*) FROM password_credentials|denied
spool_public_names|SELECT set_config('app.rls_scope', 'operator', true); SELECT count(*) FROM (SELECT tenant_id, display_name FROM tenants) t|ok
spool_public_names|SELECT root_pubkey FROM tenants LIMIT 1|denied
spool_public_names|SELECT count(*) FROM channels|denied
spool_public_names|SELECT count(*) FROM public_export_workspace|denied
EOF_PROBES
  return "$bad"
}
