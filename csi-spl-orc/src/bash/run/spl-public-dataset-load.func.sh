#!/bin/bash
#------------------------------------------------------------------------------
# @description Load a public Spool Hub dataset seed into a FRESH hub database
# @description (spec 091 T010, §9.1 + §9.2). One command:
# @description   1. fetches the file and its manifest, checks the sha256 and
# @description      refuses a manifest without three PASS verdicts (agy, grok,
# @description      claude; distinct lane ids) bound to that sha256;
# @description   2. statement whitelist: only `COPY <table> (<cols>) FROM stdin;`
# @description      blocks, their data, blank lines and `--` comments. Each
# @description      target is a §4.1 table, each column one of its public
# @description      columns or a §4.4 constant. Anything else (DDL, SET, a
# @description      function body, a COPY into a credential table) refuses the
# @description      WHOLE file; a refusal names the line number and the class,
# @description      never the line's text (§5.6: CI logs are public);
# @description   3. refuses unless the database is at the manifest's migration
# @description      head (the error names the release to check out) and holds
# @description      no workspace and no human;
# @description   4. ONE transaction under the operator scope: the empty check
# @description      again, the file's rows into private staging tables, then the
# @description      loader's OWN statements copy them in with every withheld
# @description      column forced to its §4.4 constant whatever the file says
# @description      (msg rebuilt from the public columns, env / env_sig empty,
# @description      boxes 'seed', email NULL, display_name = human_id, role
# @description      member, admitted_by seed), humans_seq past the highest
# @description      loaded HUM-n, one workspace, counts equal to the manifest,
# @description      no credential, identity or key row. It refuses to COMMIT
# @description      while root_pubkey is still 32 zero bytes;
# @description   5. a NEW root keypair (spool root-keygen: the private key at
# @description      SEED_ROOT_KEY_OUT, mode 0600, never in the database) and the
# @description      first admin (spool hub-provision-member --password-stdin:
# @description      role owner, a native password credential), its generated
# @description      password printed ONCE on stdout with how to sign in.
# @description The schema comes from the repo's migrations (spool migrate),
# @description never from the file.
# @param SEED_FILE - required: path or https URL of spool-hub-public-*.sql.gz
# @param SEED_ADMIN_EMAIL - required, no default: the first admin's sign-in
# @param SPOOL_HUB_DB_DSN - required: the fresh database, migration owner login
# @param SEED_MANIFEST (optional) - path or URL; default <file minus .sql.gz>.manifest.json, then <file>.manifest.json
# @param SEED_ROOT_KEY_OUT (optional) - default $HOME/.spool/seed/<workspace>-root.key; must not exist
# @param SEED_ALLOW_UNVERIFIED (optional) - 1: skip the verdict check; refused unless CI=true (T011 round trip)
# @param SEED_DEBUG (optional) - 1: print the database's own error text (it may quote seed data; never in CI)
# @param SPOOL_BIN (optional) - spool CLI; otherwise built from csi-spl-api
# @example SEED_FILE=./spool-hub-public-2026-10-05-v1.4.0.sql.gz SEED_ADMIN_EMAIL=admin@example.com SPOOL_HUB_DB_DSN=postgres://... ./run -a do_spl_public_dataset_load
#------------------------------------------------------------------------------
do_spl_public_dataset_load() {
  do_require_bin psql jq sha256sum openssl || return 1
  local src="${SEED_FILE:-}" email="${SEED_ADMIN_EMAIL:-}" dsn="${SPOOL_HUB_DB_DSN:-}"
  spl_pdl_args "$src" "$email" "$dsn" || return 1
  email="${email,,}"

  local dir
  dir="$(mktemp -d)" || return 1
  chmod 700 "$dir" || { rm -rf "$dir"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'; trap - RETURN" RETURN

  _spl_pdl_fetch "$src" "$dir/seed.sql.gz" || return 1
  _spl_pdl_fetch_manifest "$src" "$dir/manifest.json" || return 1
  local sha
  sha="$(sha256sum "$dir/seed.sql.gz" | cut -d' ' -f1)"
  spl_pdl_manifest_check "$dir/manifest.json" "$sha" || return 1
  _spl_pdl_unpack "$dir/seed.sql.gz" "$dir/seed.sql" || return 1
  spl_pdl_whitelist "$dir/seed.sql" "$dir/body.sql" "$dir/tenant" || return 1

  local tid key_out
  tid="$(cat "$dir/tenant")"
  key_out="${SEED_ROOT_KEY_OUT:-$HOME/.spool/seed/${tid}-root.key}"
  [[ ! -e "$key_out" ]] || { do_log "FATAL $key_out exists: a seed never overwrites a key (set SEED_ROOT_KEY_OUT)"; return 1; }
  spl_pdl_db_precheck "$dsn" "$dir/manifest.json" || return 1

  local cli="${SPOOL_BIN:-}" pub
  _spl_tenant_create_cli || return 1
  pub="$("$cli" root-keygen --out "$dir/root.key")" || { do_log "FATAL root-keygen failed"; return 1; }
  spl_pdl_load_tx "$dsn" "$dir" "$pub" || return 1
  _spl_pdl_keep_key "$dir/root.key" "$key_out" || return 1
  spl_pdl_admin "$cli" "$dsn" "$tid" "$email" "$key_out"
}

# spl_pdl_args <src> <email> <dsn>: every refusal that needs nothing fetched.
spl_pdl_args() {
  [[ -n "$1" ]] || { do_log "FATAL SEED_FILE is required (path or https URL of the seed file)"; return 1; }
  [[ -n "$2" ]] || { do_log "FATAL SEED_ADMIN_EMAIL is required (no default): the first admin's sign-in"; return 1; }
  [[ "${2,,}" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$ ]] || { do_log "FATAL SEED_ADMIN_EMAIL is not an e-mail address"; return 1; }
  [[ -n "$3" ]] || { do_log "FATAL SPOOL_HUB_DB_DSN is required: the fresh database, migrated with spool migrate"; return 1; }
  if [[ "${SEED_ALLOW_UNVERIFIED:-0}" == 1 && "${CI:-}" != true ]]; then
    do_log "FATAL SEED_ALLOW_UNVERIFIED=1 is for the CI round trip only (CI=true); a real load needs three PASS verdicts"
    return 1
  fi
}

# _spl_pdl_fetch <path|https URL> <dst>: a local file is copied, an https URL
# is downloaded; any other scheme is refused.
_spl_pdl_fetch() {
  local src="$1" dst="$2"
  case "$src" in
    https://*) curl -fsSL --proto '=https' -o "$dst" "$src" || { do_log "FATAL cannot download $src"; return 1; } ;;
    *://*) do_log "FATAL only a local path or an https URL is accepted"; return 1 ;;
    *) [[ -f "$src" ]] || { do_log "FATAL no such file: $src"; return 1; }
       cp "$src" "$dst" || return 1 ;;
  esac
}

# _spl_pdl_fetch_manifest <seed src> <dst>: SEED_MANIFEST, else the seed's name
# with .sql.gz replaced by .manifest.json, else <seed name>.manifest.json.
_spl_pdl_fetch_manifest() {
  local src="$1" dst="$2" m
  if [[ -n "${SEED_MANIFEST:-}" ]]; then
    _spl_pdl_fetch "$SEED_MANIFEST" "$dst"
    return
  fi
  for m in "${src%.sql.gz}.manifest.json" "${src}.manifest.json"; do
    _spl_pdl_fetch "$m" "$dst" 2>/dev/null && return 0
  done
  do_log "FATAL no manifest next to $src (set SEED_MANIFEST)"
  return 1
}

_spl_pdl_unpack() {
  if gzip -t "$1" 2>/dev/null; then
    gzip -dc "$1" >"$2" || { do_log "FATAL cannot gunzip the seed file"; return 1; }
  else
    cp "$1" "$2"
  fi
}

# The §4.1 tables in FK order, the columns a COPY may name (public, §4.4
# constants, tenant_id), and the key column each COPY must name.
SPL_PDL_TABLES="tenants humans tenant_memberships channels messages"
declare -gA SPL_PDL_COLS=(
  [tenants]="tenant_id display_name created_at billing_status plan_id root_pubkey"
  [humans]="human_id display_name email disabled_at"
  [tenant_memberships]="tenant_id human_id role created_at admitted_by"
  [channels]="tenant_id channel_id name description created_by created_at"
  [messages]="tenant_id msg_id task_id parent_task_id channel ts from_id to_id kind body is_parent received_at expires_at msg env env_sig from_box to_box"
)
declare -gA SPL_PDL_KEY=([tenants]=tenant_id [humans]=human_id [tenant_memberships]=human_id [channels]=channel_id [messages]=msg_id)

# spl_pdl_manifest_check <manifest> <sha256 of the file>: the manifest carries
# that sha256, a migration head, all five row counts and (unless the CI switch
# is on) exactly three PASS verdicts, one per lane kind, each lane id of its
# kind's prefix, all bound to that sha256.
spl_pdl_manifest_check() {
  local m="$1" sha="$2" t
  jq -e . "$m" >/dev/null 2>&1 || { do_log "FATAL the manifest is not JSON"; return 1; }
  [[ "$(jq -r '.sha256 // ""' "$m")" == "$sha" ]] || { do_log "FATAL sha256 mismatch: the file is $sha, the manifest names another"; return 1; }
  [[ "$(jq -r '.migration_head // ""' "$m")" =~ ^[0-9]{4}_[a-z0-9_]+\.sql$ ]] || { do_log "FATAL the manifest has no migration_head"; return 1; }
  for t in $SPL_PDL_TABLES; do
    jq -e --arg t "$t" '.row_counts[$t] | type == "number" and . >= 0' "$m" >/dev/null 2>&1 \
      || { do_log "FATAL the manifest has no row_counts.$t"; return 1; }
  done
  if [[ "${SEED_ALLOW_UNVERIFIED:-0}" == 1 ]]; then
    do_log "WARN SEED_ALLOW_UNVERIFIED=1 under CI: the three verdicts are NOT checked"
    return 0
  fi
  jq -e --arg sha "$sha" '{"agy": "a-", "grok": "g-", "claude": "c-"} as $pre
    | (.verdicts // []) as $v
    | ($v | type) == "array" and ($v | length) == 3
    and ([$v[].lane_kind] | sort) == ["agy", "claude", "grok"]
    and ([$v[].lane_id] | unique | length) == 3
    and all($v[]; .lane_kind as $k | .verdict == "PASS" and .file_sha256 == $sha
        and (.lane_id | type == "string" and test("^" + ($pre[$k] // "x-") + "[0-9]{3}(@[a-z0-9-]+)?$")))' \
    "$m" >/dev/null 2>&1 && return 0
  do_log "FATAL the manifest lacks three PASS verdicts (agy, grok, claude; distinct lane ids; bound to sha256 $sha): nothing loaded"
  return 1
}

# spl_pdl_whitelist <seed.sql> <body out> <tenant out>: refuses the whole file
# on any line that is not a blank, a `--` comment, an allowed COPY header or
# that COPY's data; writes the COPY blocks retargeted at the seed_* staging
# tables, and the workspace id from the tenants block's first row.
spl_pdl_whitelist() {
  local in="$1" out="$2" tout="$3" spec="" t err
  for t in $SPL_PDL_TABLES; do spec+="$t:${SPL_PDL_KEY[$t]}:${SPL_PDL_COLS[$t]// /,};"; done
  : >"$out"
  : >"$tout"
  err="$(LC_ALL=C awk -v spec="$spec" -v out="$out" -v tout="$tout" "$(_spl_pdl_whitelist_awk)" "$in")" || {
    do_log "FATAL the seed file is refused, nothing loaded: ${err:-unreadable}"
    return 1
  }
  [[ "$(cat "$tout")" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || {
    do_log "FATAL the seed file is refused, nothing loaded: the tenants block has no workspace slug in its first row"
    return 1
  }
}

_spl_pdl_whitelist_awk() {
  cat <<'AWK'
function refuse(class) { print "line " NR ": " class; bad = 1; exit 1 }
BEGIN {
  FS = "\t"
  n = split(spec, rows, ";")
  for (i = 1; i <= n; i++) {
    if (rows[i] == "") continue
    split(rows[i], p, ":"); key[p[1]] = p[2]
    m = split(p[3], cs, ","); for (j = 1; j <= m; j++) allow[p[1], cs[j]] = 1
  }
}
incopy {
  if ($0 == "\\.") { incopy = 0; print > out; next }
  if (tbl == "tenants" && tid == "") tid = $tcol
  print > out; next
}
/^[ \t]*$/ { next }
/^--/ { next }
{
  if ($0 !~ /^COPY [a-z_.]+ \([a-z_, ]+\) FROM stdin;$/) refuse("not a COPY ... FROM stdin statement")
  tbl = $0; sub(/^COPY /, "", tbl); sub(/ .*/, "", tbl); sub(/^public\./, "", tbl)
  if (!(tbl in key)) refuse("a COPY into a table outside the allow-list")
  if (tbl in seen) refuse("a second COPY into " tbl)
  seen[tbl] = 1
  cols = $0; sub(/^[^(]*\(/, "", cols); sub(/\).*/, "", cols); gsub(/ /, "", cols)
  k = split(cols, c, ","); haskey = 0; tcol = 0; split("", dup)
  for (j = 1; j <= k; j++) {
    if (!((tbl, c[j]) in allow)) refuse("a column outside the allow-list of " tbl)
    if (c[j] in dup) refuse("a column named twice in " tbl)
    dup[c[j]] = 1
    if (c[j] == key[tbl]) haskey = 1
    if (c[j] == "tenant_id") tcol = j
  }
  if (!haskey) refuse("a COPY into " tbl " without its key column")
  if (tbl == "tenants" && !tcol) refuse("a COPY into tenants without tenant_id")
  print "COPY seed_" tbl " (" cols ") FROM stdin;" > out
  incopy = 1
}
END {
  if (bad) exit 1
  if (incopy) { print "line " NR ": a COPY block without its \\. terminator"; exit 1 }
  if (!("tenants" in seen)) { print "no COPY into tenants"; exit 1 }
  printf "%s", tid > tout
}
AWK
}

# _spl_pdl_psql <dsn> <psql args...>: quiet, stops at the first error.
_spl_pdl_psql() {
  local dsn="$1"; shift
  psql -X -q -At -v ON_ERROR_STOP=1 "$@" "$dsn"
}

# spl_pdl_db_precheck <dsn> <manifest>: at the manifest's migration head, and
# no workspace and no human (checked again inside the load transaction).
spl_pdl_db_precheck() {
  local dsn="$1" m="$2" want have ver n
  want="$(jq -r '.migration_head' "$m")"
  ver="$(jq -r '.version // "unknown"' "$m")"
  have="$(_spl_pdl_psql "$dsn" -c 'SELECT coalesce(max(filename), '"''"') FROM spool_schema_migrations' 2>/dev/null)" || {
    do_log "FATAL the database is not migrated (no spool_schema_migrations): run spool migrate from release $ver first"
    return 1
  }
  [[ "$have" == "$want" ]] || {
    do_log "FATAL the database is at migration '${have:-none}', the seed needs '$want': check out release $ver (git checkout v${ver#v}), run spool migrate, then load"
    return 1
  }
  n="$(_spl_pdl_psql "$dsn" -c 'BEGIN' -c "SET LOCAL app.rls_scope = 'operator'" \
      -c 'SELECT (SELECT count(*) FROM tenants) + (SELECT count(*) FROM humans)' -c 'ROLLBACK')" || {
    do_log "FATAL cannot read the database"
    return 1
  }
  [[ "$n" == 0 ]] || { do_log "FATAL the database already holds a workspace or a human: the seed loads into a fresh database only, never a merge"; return 1; }
}

# spl_pdl_load_tx <dsn> <work dir> <root pubkey b64>: the one transaction.
# The database's own error text can quote seed data, so it is printed only
# with SEED_DEBUG=1; otherwise only the loader's own 'seed:' refusals are.
spl_pdl_load_tx() {
  local dsn="$1" dir="$2" pub="$3" t args=()
  for t in $SPL_PDL_TABLES; do args+=(-v "n_$t=$(jq -r --arg t "$t" '.row_counts[$t]' "$dir/manifest.json")"); done
  { _spl_pdl_sql_head; cat "$dir/body.sql"; _spl_pdl_sql_tail; } >"$dir/load.sql"
  if _spl_pdl_psql "$dsn" -v VERBOSITY=terse -v "pub=$pub" "${args[@]}" -f "$dir/load.sql" >/dev/null 2>"$dir/load.err"; then
    do_log "OK seed loaded in one transaction: one workspace, counts equal the manifest"
    return 0
  fi
  local why
  why="$(grep -o -m1 'seed: .*' "$dir/load.err")"
  [[ "${SEED_DEBUG:-0}" == 1 ]] && why="$(cat "$dir/load.err")"
  do_log "FATAL the load was rolled back, nothing kept: ${why:-a database error (SEED_DEBUG=1 prints it; it may quote seed data)}"
  return 1
}

_spl_pdl_sql_head() {
  cat <<'SQL'
BEGIN;
SET LOCAL app.rls_scope = 'operator';
LOCK TABLE tenants, humans IN SHARE ROW EXCLUSIVE MODE;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM tenants) OR EXISTS (SELECT 1 FROM humans) THEN
    RAISE EXCEPTION 'seed: the database already holds a workspace or a human; a seed loads into a fresh database only';
  END IF;
END $$;
CREATE TEMP TABLE seed_tenants ON COMMIT DROP AS
  SELECT tenant_id, display_name, created_at, billing_status, plan_id, root_pubkey FROM tenants WITH NO DATA;
CREATE TEMP TABLE seed_humans ON COMMIT DROP AS
  SELECT human_id, display_name, email, disabled_at FROM humans WITH NO DATA;
CREATE TEMP TABLE seed_tenant_memberships ON COMMIT DROP AS
  SELECT tenant_id, human_id, role, created_at, admitted_by FROM tenant_memberships WITH NO DATA;
CREATE TEMP TABLE seed_channels ON COMMIT DROP AS
  SELECT tenant_id, channel_id, name, description, created_by, created_at FROM channels WITH NO DATA;
CREATE TEMP TABLE seed_messages ON COMMIT DROP AS
  SELECT tenant_id, msg_id, task_id, parent_task_id, channel, ts, from_id, to_id, kind, body, is_parent,
         received_at, expires_at, msg, env, env_sig, from_box, to_box FROM messages WITH NO DATA;
SQL
}

# The tail: checks on the staged rows, the loader's own INSERTs (every
# withheld column a constant, never the file's value), the post-load checks,
# the new root key, and the zero-key refusal right before COMMIT.
_spl_pdl_sql_tail() {
  cat <<'SQL'
CREATE TEMP TABLE seed_expect (tbl text, n bigint) ON COMMIT DROP;
INSERT INTO seed_expect VALUES ('tenants', :n_tenants), ('humans', :n_humans),
  ('tenant_memberships', :n_tenant_memberships), ('channels', :n_channels), ('messages', :n_messages);
DO $$
DECLARE r record; got bigint; tid text;
BEGIN
  FOR r IN SELECT * FROM seed_expect LOOP
    EXECUTE format('SELECT count(*) FROM %I', 'seed_' || r.tbl) INTO got;
    IF got <> r.n THEN RAISE EXCEPTION 'seed: % has % rows, the manifest says %', r.tbl, got, r.n; END IF;
  END LOOP;
  IF (SELECT count(*) FROM seed_tenants) <> 1 THEN RAISE EXCEPTION 'seed: the file must hold exactly one workspace'; END IF;
  SELECT tenant_id INTO tid FROM seed_tenants;
  IF EXISTS (SELECT 1 FROM seed_tenant_memberships WHERE tenant_id IS DISTINCT FROM tid AND tenant_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM seed_channels WHERE tenant_id IS DISTINCT FROM tid AND tenant_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM seed_messages WHERE tenant_id IS DISTINCT FROM tid AND tenant_id IS NOT NULL) THEN
    RAISE EXCEPTION 'seed: a row of another workspace';
  END IF;
END $$;
SELECT tenant_id AS seed_tid FROM seed_tenants \gset
INSERT INTO tenants (tenant_id, display_name, created_at, billing_status, plan_id, root_pubkey)
  SELECT tenant_id, display_name, coalesce(created_at, now()), 'internal', 'default', decode(repeat('00', 32), 'hex')
  FROM seed_tenants;
INSERT INTO humans (human_id, display_name, email, disabled_at)
  SELECT human_id, human_id, NULL, NULL FROM seed_humans;
INSERT INTO tenant_memberships (tenant_id, human_id, role, created_at, admitted_by)
  SELECT :'seed_tid', human_id, 'member', coalesce(created_at, now()), 'seed' FROM seed_tenant_memberships;
INSERT INTO channels (tenant_id, channel_id, name, description, created_by, created_at)
  SELECT :'seed_tid', channel_id, name, coalesce(description, ''), created_by, coalesce(created_at, now()) FROM seed_channels
  ON CONFLICT (tenant_id, channel_id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description,
    created_by = EXCLUDED.created_by, created_at = EXCLUDED.created_at;
INSERT INTO messages (tenant_id, msg_id, task_id, parent_task_id, channel, ts, from_box, from_id, to_box, to_id,
                      kind, body, is_parent, received_at, expires_at, msg, env, env_sig)
  SELECT :'seed_tid', msg_id, task_id, parent_task_id, channel, ts, 'seed', from_id, 'seed', to_id,
         kind, body, coalesce(is_parent, 1), coalesce(received_at, now()), expires_at,
         jsonb_build_object('v', 1, 'msg_id', msg_id::text, 'task_id', task_id::text,
           'ts', to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'from', from_id, 'to', to_id,
           'kind', kind, 'body', body, 'files', '[]'::jsonb),
         '\x'::bytea, ''
  FROM seed_messages;
SELECT setval('humans_seq', max(substr(human_id, 5)::bigint)) FROM humans HAVING count(*) > 0;
DO $$ BEGIN
  IF (SELECT count(*) FROM tenants) <> 1 THEN RAISE EXCEPTION 'seed: the load must leave exactly one workspace'; END IF;
  IF (SELECT count(*) FROM humans) <> (SELECT count(*) FROM seed_humans)
     OR (SELECT count(*) FROM tenant_memberships) <> (SELECT count(*) FROM seed_tenant_memberships)
     OR (SELECT count(*) FROM messages) <> (SELECT count(*) FROM seed_messages)
     OR EXISTS (SELECT channel_id FROM seed_channels EXCEPT SELECT channel_id FROM channels) THEN
    RAISE EXCEPTION 'seed: the loaded counts differ from the file';
  END IF;
  IF EXISTS (SELECT 1 FROM humans WHERE email IS NOT NULL OR display_name IS DISTINCT FROM human_id)
     OR EXISTS (SELECT 1 FROM password_credentials) OR EXISTS (SELECT 1 FROM human_identities)
     OR EXISTS (SELECT 1 FROM human_keys) THEN
    RAISE EXCEPTION 'seed: a loaded member carries an e-mail, a credential, an identity or a key';
  END IF;
END $$;
UPDATE tenants SET root_pubkey = decode(:'pub', 'base64') WHERE tenant_id = :'seed_tid';
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM tenants WHERE root_pubkey = decode(repeat('00', 32), 'hex')) THEN
    RAISE EXCEPTION 'seed: root_pubkey is still 32 zero bytes; refusing to commit';
  END IF;
END $$;
COMMIT;
SQL
}

# _spl_pdl_keep_key <tmp key> <operator path>: the private key leaves the
# private work dir for the operator's path, still mode 0600.
_spl_pdl_keep_key() {
  local from="$1" to="$2"
  ( umask 077 && mkdir -p "$(dirname "$to")" ) || { do_log "FATAL cannot create $(dirname "$to")"; return 1; }
  mv "$from" "$to" && chmod 600 "$to" || { do_log "FATAL cannot write the root key to $to"; return 1; }
}

# spl_pdl_admin <cli> <dsn> <workspace> <email> <key path>: the first admin
# through the same helper an operator seat uses (hub-provision-member), its
# generated password on stdin and printed once, then how to sign in.
spl_pdl_admin() {
  local cli="$1" dsn="$2" tid="$3" email="$4" key="$5" pw out hum
  pw="$(openssl rand -base64 24 | tr -d '\n/+=')"
  out="$(printf '%s\n' "$pw" | "$cli" hub-provision-member --tenant "$tid" --email "$email" --name "Seed admin" \
      --role owner --password-stdin --db "$dsn" 2>&1)" || {
    do_log "FATAL the workspace $tid is loaded but the first admin was not created: ${out:-no detail}"
    do_log "INFO finish it: printf '%s\\n' '<a new password>' | spool hub-provision-member --tenant $tid --email $email --role owner --password-stdin --db \"\$SPOOL_HUB_DB_DSN\""
    return 1
  }
  hum="$(jq -r '.human_id // ""' <<<"$out")"
  do_log "OK first admin $hum ($email) is the owner of $tid"
  cat <<EOF
Seed loaded: workspace $tid
Root private key: $key (mode 0600, not in the database; keep it, it signs this workspace's box pins)
First admin: $email ($hum, role owner)
Password (shown once, never stored in clear): $pw
Sign in: start the hub on this database (SPOOL_HUB_DB_DSN=<this database> spool serve), open its web app with
  ?tenant=$tid and sign in with the e-mail and password above. No loaded member can sign in (spec 091 §9.2).
EOF
}
