#!/bin/bash
#------------------------------------------------------------------------------
# @description The hub DB's two logins (017 T029 / FR-SEC-014), shared by
# @description do_spl_db_owner_split and do_spl_db_bootstrap:
# @description   $SPL_DB_OWNER_USER  owns the schema, runs `spool migrate`; its
# @description                       DSN is in $SPL_OWNER_DSN_SECRET (040 slot,
# @description                       never injected into the hub)
# @description   $SPL_DB_USER        the hub's runtime login, created BY the
# @description                       owner in SQL with DML-only grants; its DSN
# @description                       is $SPL_DSN_SECRET, which 030 injects
# @description The SQL is csi-spl-rdb/src/sql/postgres/spool-hub-roles/, the
# @description same files hub-pg.tst.sh runs. Every gcloud call is pinned to
# @description $GCP_ACCOUNT (the caller ran do_gcp_pin_account). A password or
# @description DSN is never printed, never in argv: stdin and env only.
# @description Secret writes go through do_spl_cloud_dispatch (spec 076 T008):
# @description under gcp they are the Secret Manager calls below; under none
# @description they update the self-host .env (mode 600, the T009 seam) and
# @description never call gcloud.
#------------------------------------------------------------------------------

# spl_dsn_user <dsn> -> the login of a postgres:// DSN (the DSN travels in
# the environment of python, not its argv)
spl_dsn_user() {
  SPL_DSN_IN="$1" python3 -c 'import os, urllib.parse as u; print(u.unquote(u.urlsplit(os.environ["SPL_DSN_IN"]).username or ""))'
}

# spl_read_owner_dsn -> the owner DSN, or nothing: the db_dsn read seam
# (spl_read_dsn owner, spec 076 T008 follow-up); under gcp the latest version of
# $SPL_OWNER_DSN_SECRET, under none built from the self-host .env.
spl_read_owner_dsn() {
  spl_read_dsn owner
}

# spl_secret_add <secret id> <- value on stdin: a new version, nothing logged.
# Routed (spec 076 T008): do_db_secret_add_gcp is the Secret Manager write;
# do_db_secret_add_none stores it in the self-host .env.
spl_secret_add() {
  # shellcheck source=spl-cloud-dispatch.func.sh
  declare -F do_spl_cloud_dispatch >/dev/null || source "${BASH_SOURCE[0]%/*}/spl-cloud-dispatch.func.sh"
  do_spl_cloud_dispatch db_secret add "$1"
}

# do_db_secret_add_gcp <secret id> <- value on stdin. The gcloud argv is the
# one spl_secret_add used before the seam.
do_db_secret_add_gcp() {
  gcloud secrets versions add "$1" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1
}

# do_db_secret_add_none <secret id> <- a postgres DSN on stdin. The owner slot
# becomes SPOOL_DB_OWNER / SPOOL_DB_OWNER_PASSWORD / SPOOL_DB_NAME; the runtime
# slot becomes $SPOOL_HUB_DB_DSN (exported, so a later spl_read_dsn sees it)
# plus the runtime user and password. Mode 600. The value is never logged.
do_db_secret_add_none() {
  local secret="$1" dsn user pw db
  local -a fields=()
  dsn="$(cat)"
  [[ -n "$dsn" ]] || return 1
  mapfile -t fields < <(SPL_DSN_IN="$dsn" python3 -c '
import os, urllib.parse as u
p = u.urlsplit(os.environ["SPL_DSN_IN"])
print(u.unquote(p.username or ""))
print(u.unquote(p.password or ""))
print(u.unquote(p.path.lstrip("/")))
')
  user="${fields[0]:-}" pw="${fields[1]:-}" db="${fields[2]:-}"
  if [[ "$secret" == "${SPL_OWNER_DSN_SECRET:-}" ]]; then
    [[ -n "$user" ]] && { spl_secrets_none_put SPOOL_DB_OWNER "$user" || return 1; }
    spl_secrets_none_put SPOOL_DB_OWNER_PASSWORD "$pw" || return 1
    [[ -z "$db" ]] || { spl_secrets_none_put SPOOL_DB_NAME "$db" || return 1; }
  elif [[ "$secret" == "${SPL_DSN_SECRET:-}" ]]; then
    export SPOOL_HUB_DB_DSN="$dsn"
    spl_secrets_none_put SPOOL_HUB_DB_DSN "$dsn" || return 1
    [[ -z "$user" ]] || { spl_secrets_none_put SPOOL_DB_RUNTIME "$user" || return 1; }
    [[ -z "$pw" ]] || { spl_secrets_none_put SPOOL_DB_RUNTIME_PASSWORD "$pw" || return 1; }
  else
    do_log "FATAL provider none has no .env key for secret $secret"
    return 1
  fi
}

# spl_secret_disable_older <secret id> -> disables every ENABLED version but
# the newest, so a reader of the slot (the hub's SA, for the runtime slot)
# cannot fetch an older login by version number. Prints the count. Under none
# the .env holds one value, so the count is 0 and nothing is called.
spl_secret_disable_older() {
  # shellcheck source=spl-cloud-dispatch.func.sh
  declare -F do_spl_cloud_dispatch >/dev/null || source "${BASH_SOURCE[0]%/*}/spl-cloud-dispatch.func.sh"
  do_spl_cloud_dispatch db_secret disable_older "$1"
}

do_db_secret_disable_older_gcp() {
  local v n=0 first=1
  while read -r v; do
    [[ -n "$v" ]] || continue
    if (( first )); then first=0; continue; fi
    gcloud secrets versions disable "$v" --secret="$1" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
      >/dev/null 2>&1 || { do_log "FATAL could not disable version $v of $1"; return 1; }
    n=$((n + 1))
  done < <(gcloud secrets versions list "$1" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
             --filter='state=ENABLED' --sort-by='~createTime' --format='value(name.basename())' 2>/dev/null)
  echo "$n"
}

do_db_secret_disable_older_none() { echo 0; }

# spl_scram_verifier <- password on stdin -> a SCRAM-SHA-256 verifier
# (RFC 5802 / 7677, Postgres' stored form). The server stores it as given, so
# the clear-text password never reaches Postgres or its logs.
spl_scram_verifier() {
  python3 -c '
import base64, hashlib, hmac, os, sys
pw = sys.stdin.buffer.read(); salt = os.urandom(16); it = 4096
salted = hashlib.pbkdf2_hmac("sha256", pw, salt, it)
ck = hmac.new(salted, b"Client Key", "sha256").digest()
sk = hmac.new(salted, b"Server Key", "sha256").digest()
b = lambda x: base64.b64encode(x).decode()
print("SCRAM-SHA-256$%d:%s$%s:%s" % (it, b(salt), b(hashlib.sha256(ck).digest()), b(sk)))'
}

# spl_db_roles_psql <proxy dsn> <roles sql file> [<psql preamble>] -> runs a
# spool-hub-roles file as the DSN's login with :runtime_role = $SPL_DB_USER.
# The preamble (a \set carrying the verifier) goes on stdin, never argv.
spl_db_roles_psql() {
  local f="$SPL_DB_ROLES_SQL/$2"
  [[ -r "$f" ]] || { do_log "FATAL no roles SQL $f"; return 1; }
  { [[ -n "${3:-}" ]] && printf '%s\n' "$3"; cat "$f"; } |
    spl_pg_env "$1" psql -X -q -v ON_ERROR_STOP=1 -v runtime_role="$SPL_DB_USER" -f - >/dev/null
}

# spl_db_runtime_ensure <owner proxy dsn> <mint 0|1> -> as the OWNER: with
# mint=1 creates (or re-passwords) the runtime role and, only after its grants
# are in place, adds its DSN as the newest version of $SPL_DSN_SECRET; with
# mint=0 re-applies the grants only (idempotent, after a migrate).
spl_db_runtime_ensure() {
  local odsn="$1" mint="$2" pw ver
  if [[ "$mint" == 1 ]]; then
    pw="$(openssl rand -hex 24)" || return 1
    ver="$(printf '%s' "$pw" | spl_scram_verifier)" || { do_log "FATAL cannot compute the SCRAM verifier"; return 1; }
    spl_db_roles_psql "$odsn" runtime-role.sql "\\set runtime_verifier '$ver'" ||
      { do_log "FATAL runtime-role.sql as $SPL_DB_OWNER_USER failed"; return 1; }
    do_log "INFO runtime role $SPL_DB_USER ensured by $SPL_DB_OWNER_USER (password set as a SCRAM verifier)"
  fi
  spl_db_roles_psql "$odsn" runtime-grants.sql ||
    { do_log "FATAL runtime-grants.sql as $SPL_DB_OWNER_USER failed"; return 1; }
  do_log "INFO DML-only grants + default privileges for $SPL_DB_USER applied by $SPL_DB_OWNER_USER"
  [[ "$mint" == 1 ]] || return 0
  # shellcheck source=spl-cloud-dispatch.func.sh
  declare -F do_spl_cloud_dispatch >/dev/null || source "${BASH_SOURCE[0]%/*}/spl-cloud-dispatch.func.sh"
  do_spl_cloud_dispatch db_secret publish_runtime "$pw" ||
    { do_log "FATAL could not add a version to $SPL_DSN_SECRET (the role has a password nobody holds: re-run to reset it)"; return 1; }
  do_log "INFO secret $SPL_DSN_SECRET: new version with the runtime login $SPL_DB_USER (value not logged)"
}

# do_db_secret_publish_runtime_gcp <password> -> the runtime DSN as a new
# version of $SPL_DSN_SECRET. The password rides on gcloud's stdin, never argv.
do_db_secret_publish_runtime_gcp() {
  printf 'postgres://%s:%s@/%s?host=/cloudsql/%s' "$SPL_DB_USER" "$1" "$SPL_DB_NAME" "$SPL_SQL_CONN" |
    gcloud secrets versions add "$SPL_DSN_SECRET" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --data-file=- >/dev/null 2>&1
}

# do_db_secret_publish_runtime_none <password> -> the same login as a TCP DSN
# in the self-host .env (SPOOL_HUB_DB_DSN, SPOOL_DB_RUNTIME, the password),
# and exported so spl_read_dsn in this shell reads it back. Host and port come
# from the current $SPOOL_HUB_DB_DSN, else 127.0.0.1:5432. Nothing is logged.
do_db_secret_publish_runtime_none() {
  local dsn
  dsn="$(SPL_PW_IN="$1" SPL_USER_IN="$SPL_DB_USER" SPL_DB_IN="${SPL_DB_NAME:-spool_hub}" \
    SPL_DSN_IN="${SPOOL_HUB_DB_DSN:-}" python3 -c '
import os, urllib.parse as u
base = os.environ.get("SPL_DSN_IN") or ""
p = u.urlsplit(base) if base else None
host = (p.hostname if p else "") or "127.0.0.1"
port = (p.port if p and p.port else None) or 5432
q = lambda s: u.quote(s, safe="")
hostp = "[%s]" % host if ":" in host else host
print("postgres://%s:%s@%s:%s/%s?sslmode=disable" % (
    q(os.environ["SPL_USER_IN"]), q(os.environ["SPL_PW_IN"]), hostp, port,
    q(os.environ["SPL_DB_IN"] or "spool_hub")), end="")
')" || return 1
  export SPOOL_HUB_DB_DSN="$dsn"
  spl_secrets_none_put SPOOL_HUB_DB_DSN "$dsn" || return 1
  spl_secrets_none_put SPOOL_DB_RUNTIME "$SPL_DB_USER" || return 1
  spl_secrets_none_put SPOOL_DB_RUNTIME_PASSWORD "$1" || return 1
}

# spl_db_runtime_facts_sql -> one JSON line about the CURRENT login: its
# flags, memberships, anything it owns or can act as the owner of, CREATE on
# the schema, and that it can read rows (operator scope, count only).
spl_db_runtime_facts_sql() {
  cat <<'EOF_SQL'
SELECT json_build_object(
  'role', r.rolname, 'superuser', r.rolsuper, 'bypassrls', r.rolbypassrls,
  'createrole', r.rolcreaterole, 'createdb', r.rolcreatedb,
  'member_of', (SELECT count(*) FROM pg_auth_members m WHERE m.member = r.oid),
  'owns', (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = current_schema() AND pg_has_role(current_user, c.relowner, 'MEMBER')),
  'schema_create', has_schema_privilege(current_schema(), 'CREATE'),
  'tenants', (SELECT count(*) FROM tenants))
FROM pg_roles r WHERE r.rolname = current_user;
EOF_SQL
}

# spl_db_runtime_verdict <facts json> -> exit 0 when the runtime login is
# the split shape (no attribute, membership, ownership or schema CREATE) and
# reads rows; one log line either way.
spl_db_runtime_verdict() {
  local v
  v="$(SPL_FACTS="$1" python3 -c '
import json, os
d = json.loads(os.environ["SPL_FACTS"])
bad = [k for k in ("superuser", "bypassrls", "createrole", "createdb", "schema_create") if d.get(k)]
bad += ["%s=%s" % (k, d.get(k)) for k in ("member_of", "owns") if d.get(k)]
if not isinstance(d.get("tenants"), int): bad.append("cannot read tenants")
print(("1 runtime %s is NOT split: %s" % (d.get("role"), ", ".join(bad))) if bad else
      ("0 runtime %s: no superuser/bypassrls/createrole/createdb, 0 memberships, owns 0, no schema CREATE, reads %d tenant row(s)" % (d.get("role"), d["tenants"])))
')" || { do_log "FATAL cannot parse the runtime facts: $1"; return 1; }
  if [[ "${v%% *}" == 0 ]]; then do_log "OK ${v#* }"; return 0; fi
  do_log "FAIL ${v#* }"; return 1
}

# spl_db_runtime_verify <runtime proxy dsn> -> the facts above, then two
# write attempts AS THE RUNTIME LOGIN, each inside BEGIN .. ROLLBACK, that
# must be REFUSED: switching FORCE RLS off on messages, and granting itself
# the owner role. A success would be rolled back and is reported as FAIL.
spl_db_runtime_verify() {
  local rdsn="$1" facts out rc
  facts="$(printf 'BEGIN READ ONLY;\nSET LOCAL app.rls_scope = '\''operator'\'';\n%s\nROLLBACK;\n' "$(spl_db_runtime_facts_sql)" |
    spl_pg_env "$rdsn" psql -X -q -At -v ON_ERROR_STOP=1 -f - 2>&1)" ||
    { do_log "FATAL the runtime login $SPL_DB_USER cannot connect / read: $facts"; return 1; }
  printf '%s\n' "$facts"
  spl_db_runtime_verdict "$facts" || return 1
  local probe want
  while IFS='|' read -r probe want; do
    rc=0
    out="$(printf 'BEGIN;\nSET LOCAL lock_timeout = '\''2s'\'';\n%s;\nROLLBACK;\n' "$probe" |
      spl_pg_env "$rdsn" psql -X -q -v ON_ERROR_STOP=1 -f - 2>&1)" || rc=$?
    if (( rc == 0 )); then do_log "FAIL the runtime login ran: $probe (rolled back)"; return 1; fi
    grep -qiE "$want" <<<"$out" || { do_log "FAIL '$probe' failed for another reason: $out"; return 1; }
    do_log "OK refused as $SPL_DB_USER: $probe"
  done <<EOF_PROBES
ALTER TABLE messages NO FORCE ROW LEVEL SECURITY|must be (the )?owner
GRANT "$SPL_DB_OWNER_USER" TO CURRENT_USER|permission denied to grant role
EOF_PROBES
}

# spl_db_api_user_set <user> <secret id> -> mint a password, create (POST) or
# reset (PUT) the Cloud SQL API user, then add its DSN as a new version of
# <secret>. HTTP: one curl to the Cloud SQL Admin users collection, POST
# {name,password} to create, or PUT ?name=<user> when the user already
# exists. That call is bounded (--connect-timeout 10 --max-time 60); a stall
# is curl exit 28. Token and password travel in files (mode 600, removed on
# return) and on stdin only. Used for the OWNER (bootstrap, ROTATE_OWNER=1);
# the runtime login is SQL-created by the owner instead (spl_db_runtime_ensure).
spl_db_api_user_set() {
  local user="$1" secret="$2"
  local api="https://sqladmin.googleapis.com/v1/projects/$SPL_PROJECT/instances/$SPL_SQL_INSTANCE/users"
  local tmp pw method=POST url resp op
  tmp="$(umask 077 && mktemp -d)" || return 1
  pw="$(openssl rand -hex 24)" || { rm -rf "$tmp"; return 1; }
  printf 'Authorization: Bearer %s\n' "$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)" >"$tmp/h"
  printf '{"name":"%s","password":"%s"}' "$user" "$pw" >"$tmp/body"
  url="$api"
  if gcloud sql users list --instance="$SPL_SQL_INSTANCE" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
       --format='value(name)' 2>/dev/null | grep -x "$user" >/dev/null; then
    method=PUT url="$api?name=$user"
    do_log "INFO user $user exists: resetting its password"
  fi
  resp="$(curl -sS -X "$method" --connect-timeout 10 --max-time 60 -H @"$tmp/h" -H 'Content-Type: application/json' --data-binary @"$tmp/body" "$url")" ||
    { rm -rf "$tmp"; do_log "FATAL $method $SPL_SQL_INSTANCE/users failed"; return 1; }
  op="$(yq -r '.name // ""' <<<"$resp")"
  [[ -n "$op" && "$(yq -r '.error // ""' <<<"$resp")" == "" ]] ||
    { rm -rf "$tmp"; do_log "FATAL Cloud SQL users $method: $(yq -r '.error.message // "no operation"' <<<"$resp")"; return 1; }
  gcloud sql operations wait "$op" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --timeout=300 >/dev/null 2>&1 ||
    { rm -rf "$tmp"; do_log "FATAL operation $op did not finish"; return 1; }
  do_log "INFO Postgres user $user on $SPL_SQL_INSTANCE: $method done"
  printf 'postgres://%s:%s@/%s?host=/cloudsql/%s' "$user" "$pw" "$SPL_DB_NAME" "$SPL_SQL_CONN" |
    spl_secret_add "$secret" ||
    { rm -rf "$tmp"; do_log "FATAL could not add a version to $secret (the user now has a password nobody holds: re-run to reset it)"; return 1; }
  rm -rf "$tmp"
  do_log "INFO secret $secret: new version added (value not logged)"
}

# do_db_login_ensure_gcp -> spl_db_api_user_set for the owner (Cloud SQL Admin
# API + a Secret Manager version). The gcp body of a fresh do_spl_db_bootstrap.
do_db_login_ensure_gcp() {
  spl_db_api_user_set "$SPL_DB_OWNER_USER" "$SPL_OWNER_DSN_SECRET"
}

# do_db_login_ensure_none -> a fresh env under provider none. No Cloud SQL
# Admin API and no Secret Manager: the T009 seam fills the self-host .env
# (mode 600). $SPOOL_HUB_DB_DSN is left unset so the caller can still tell a
# fresh env from one that already has a runtime login.
do_db_login_ensure_none() {
  DRY_RUN=0 do_secrets_seed_none
}

# do_db_login_rotate_gcp -> the owner-password rotation (ROTATE_OWNER=1).
do_db_login_rotate_gcp() {
  spl_db_api_user_set "$SPL_DB_OWNER_USER" "$SPL_OWNER_DSN_SECRET"
}

# do_db_login_rotate_none -> a new owner password in the self-host .env only.
# The value is never logged.
do_db_login_rotate_none() {
  local pw
  pw="$(openssl rand -hex 24)" || return 1
  spl_secrets_none_put SPOOL_DB_OWNER "${SPL_DB_OWNER_USER:-spool_hub}" || return 1
  spl_secrets_none_put SPOOL_DB_OWNER_PASSWORD "$pw" || return 1
  do_log "INFO owner password rotated in the self-host .env (value not logged)"
}

# spl_secrets_none_put <KEY> <value> -> set KEY in the self-host .env, rewriting
# the file mode 600 (the T009 store). The value is never logged and never put
# on a command argv: it travels in the environment of python.
spl_secrets_none_put() {
  # shellcheck disable=SC2034 # statef is set by spl_secrets_none_paths and unused here
  local key="$1" val="$2" envf statef tmp
  # shellcheck source=../../../src/bash/run/spl-secrets-check.func.sh
  declare -F spl_secrets_none_paths >/dev/null ||
    source "${BASH_SOURCE[0]%/*}/../../../src/bash/run/spl-secrets-check.func.sh"
  spl_secrets_none_paths >&2 || return 1
  tmp="$envf.tmp.$$"
  (
    umask 077
    SPL_KEY="$key" SPL_VAL="$val" SPL_ENVF="$envf" python3 - "$tmp" <<'PY'
import os, sys
key = os.environ["SPL_KEY"]
val = os.environ["SPL_VAL"]
src = os.environ["SPL_ENVF"]
dst = sys.argv[1]
kept = []
if os.path.isfile(src):
    with open(src) as fh:
        for line in fh:
            body = line[:-1] if line.endswith("\n") else line
            if body.startswith(key + "="):
                continue
            kept.append(body)
quoted = "'" + val.replace("'", "'\\''") + "'"
kept.append("%s=%s" % (key, quoted))
with open(dst, "w") as fh:
    fh.write("\n".join(kept) + "\n")
PY
  ) || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f "$tmp" "$envf" || { rm -f "$tmp"; return 1; }
}
