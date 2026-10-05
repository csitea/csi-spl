#!/usr/bin/env bash
# do_spl_public_dataset_load (spec 091 T010, §9.1 + §9.2). Synthetic fixtures
# only: a one-workspace seed file written here, with canaries planted in the
# withheld columns (msg, env, env_sig, the boxes, an e-mail) to prove the
# loader writes its own constants, never the file's values.
#
# Part 1 (hermetic): the argument guards, the manifest (sha256, three PASS
# verdicts) and the statement whitelist (a CREATE, a function body, a SET, a
# COPY into password_credentials, a column outside the allow-list), each
# refusing before any database is touched, and naming no line text.
# Part 2 (a REAL throwaway Postgres, migrated by the repo's migrations, as a
# NON-superuser owner so row-level security binds): a wrong migration head, a
# database with a workspace, a manifest count mismatch and a zero root key are
# refused and roll back; a clean load leaves exactly one workspace and one
# human who can sign in.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0; n=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { n=$((n + 1)); echo "PASS: $*"; }
fail() { n=$((n + 1)); echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-public-dataset-load.func.sh"
grep -qE 'set -x|pg_restore|psql[^\n]*-f "\$dir/seed.sql"' "$FUNC" \
  && fail "the loader runs the file itself or traces" || pass "the loader never runs the file as given and never traces (set -x)"

# --- the synthetic seed ------------------------------------------------------
TID=ws-seed
TS='2026-09-01 10:00:00+00'
EXP='2099-01-01 00:00:00+00'
ZERO="\\\\x$(printf '0%.0s' {1..64})"
# write_seed <out.sql> [extra line placed after the first COPY block]
write_seed() {
  local out="$1" extra="${2:-}"
  {
    echo "-- synthetic seed for public-dataset-load.tst.sh"
    echo "COPY tenants (tenant_id, display_name, created_at, billing_status, plan_id, root_pubkey) FROM stdin;"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$TID" "Seed Workspace" "$TS" internal default "$ZERO"
    echo '\.'
    [[ -n "$extra" ]] && printf '%s\n' "$extra"
    echo "COPY humans (human_id, display_name, email, disabled_at) FROM stdin;"
    printf 'HUM-3\tHUM-3\t\\N\t\\N\nHUM-7\tHUM-7\tcanary-mail@example.com\t\\N\n'
    echo '\.'
    echo "COPY tenant_memberships (tenant_id, human_id, role, created_at, admitted_by) FROM stdin;"
    printf '%s\tHUM-3\tmember\t%s\tseed\n%s\tHUM-7\towner\t%s\tCANARY-ADMIT\n' "$TID" "$TS" "$TID" "$TS"
    echo '\.'
    echo "COPY channels (tenant_id, channel_id, name, description, created_by, created_at) FROM stdin;"
    printf '%s\tlobby\tlobby\tThe lobby\tHUM-3\t%s\n%s\tdev-talk\tdev-talk\t\tHUM-7\t%s\n' "$TID" "$TS" "$TID" "$TS"
    echo '\.'
    echo "COPY messages (tenant_id, msg_id, task_id, parent_task_id, channel, ts, from_id, to_id, kind, body, is_parent, received_at, expires_at, msg, env, env_sig, from_box, to_box) FROM stdin;"
    local i
    for i in 1 2 3; do
      printf '%s\t00000000-0000-4000-8000-00000000000%s\t00000000-0000-4000-8000-0000000000a%s\t\\N\tdev-talk\t%s\tHUM-3\tc-001\tnote\tseed body %s\t1\t%s\t%s\t{"canary": "MSG-CANARY"}\t\\\\x43414e415259\tSIG-CANARY\tBOX-CANARY\tBOX-CANARY\n' \
        "$TID" "$i" "$i" "$TS" "$i" "$TS" "$EXP"
    done
    echo '\.'
  } >"$out"
}
# write_manifest <seed.sql.gz> <out> [jq edit]
write_manifest() {
  local sha
  sha="$(sha256sum "$1" | cut -d' ' -f1)"
  jq -n --arg sha "$sha" --arg head "${HEAD_FILE:-0001_init.sql}" '{
    sha256: $sha, version: "1.2.3", migration_head: $head,
    row_counts: {tenants: 1, humans: 2, tenant_memberships: 2, channels: 2, messages: 3},
    verdicts: [
      {lane_kind: "agy", lane_id: "a-101", verdict: "PASS", file_sha256: $sha},
      {lane_kind: "grok", lane_id: "g-102", verdict: "PASS", file_sha256: $sha},
      {lane_kind: "claude", lane_id: "c-103", verdict: "PASS", file_sha256: $sha}]}' | jq "${3:-.}" >"$2"
}
# make_case <name> [extra line] [jq edit]: <name>.sql.gz + its manifest
make_case() {
  write_seed "$T/$1.sql" "${2:-}"
  gzip -n -c "$T/$1.sql" >"$T/$1.sql.gz"
  write_manifest "$T/$1.sql.gz" "$T/$1.manifest.json" "${3:-.}"
}

# load <name> [VAR=value...]: the action, sourced like the other orc tests.
load() {
  local name="$1"; shift
  env -u SEED_ALLOW_UNVERIFIED -u CI -u SEED_MANIFEST -u SEED_ROOT_KEY_OUT -u SPOOL_HUB_DB_DSN \
    HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    SEED_FILE="$T/$name.sql.gz" SEED_ADMIN_EMAIL=Admin@Example.com SPOOL_HUB_DB_DSN="${DSN:-postgres://none@127.0.0.1:1/none}" \
    SPOOL_BIN="${BIN:-$T/no-spool}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_public_dataset_load' >"$T/out" 2>&1 </dev/null
}
# refused <label> <needle> <case> [VAR=value...]
refused() {
  local label="$1" needle="$2" name="$3"; shift 3
  load "$name" "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q -- "$needle" "$T/out" && ! grep -q 'Seed loaded' "$T/out" \
    && pass "$label" || fail "$label: rc=$rc $(cat "$T/out")"
}

# --- part 1: hermetic refusals -------------------------------------------------
make_case good
refused "SEED_ADMIN_EMAIL is required, no default" "SEED_ADMIN_EMAIL is required" good SEED_ADMIN_EMAIL=
refused "SEED_ADMIN_EMAIL must be an address" "not an e-mail address" good SEED_ADMIN_EMAIL=nobody
refused "SEED_ALLOW_UNVERIFIED=1 outside CI" "CI round trip only" good SEED_ALLOW_UNVERIFIED=1
refused "a URL of another scheme" "only a local path or an https URL" good SEED_FILE=gs://bucket/x.sql.gz
make_case badsha "" '.sha256 = "0000"'
refused "a sha256 that does not match the file" "sha256 mismatch" badsha
make_case two "" '.verdicts |= .[0:2]'
refused "a manifest with two verdicts" "lacks three PASS verdicts" two
make_case onefail "" '.verdicts[1].verdict = "FAIL"'
refused "one FAIL verdict" "lacks three PASS verdicts" onefail
make_case samekind "" '.verdicts[1].lane_kind = "claude" | .verdicts[1].lane_id = "c-104"'
refused "two verdicts of one kind" "lacks three PASS verdicts" samekind
make_case wrongprefix "" '.verdicts[0].lane_id = "g-109"'
refused "a lane id outside its kind's prefix" "lacks three PASS verdicts" wrongprefix
make_case othersha "" '.verdicts[2].file_sha256 = "ffff"'
refused "a verdict bound to another file" "lacks three PASS verdicts" othersha
make_case nocount "" 'del(.row_counts.messages)'
refused "a manifest without a row count" "no row_counts.messages" nocount

wl() { # <label> <class needle> <planted line> <secret word that must not be echoed>
  make_case wl "$3"
  load wl; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "the seed file is refused" "$T/out" && grep -q -- "$2" "$T/out" && ! grep -q -- "$4" "$T/out" \
    && pass "whitelist: $1 refuses the whole file, naming the class not the text" || fail "whitelist $1: rc=$rc $(cat "$T/out")"
}
wl "a CREATE TABLE"           "line 5: not a COPY" "CREATE TABLE plantedx (a int);" plantedx
wl "a function body"          "line 5: not a COPY" 'CREATE FUNCTION plantedf() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql;' plantedf
wl "a SET"                    "line 5: not a COPY" "SET search_path = plantedschema;" plantedschema
wl "a COPY into password_credentials" "table outside the allow-list" \
  "COPY password_credentials (subject, password_hash) FROM stdin;" password_hash
# a column outside the allow-list goes in the messages header, not an extra line
write_seed "$T/wl.sql"
python3 - "$T/wl.sql" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("from_box, to_box) FROM stdin;", "from_box, to_box, files) FROM stdin;")
open(p, "w").write(s)
PY
gzip -n -c "$T/wl.sql" >"$T/wl.sql.gz"; write_manifest "$T/wl.sql.gz" "$T/wl.manifest.json"
load wl; rc=$?
[[ $rc -ne 0 ]] && grep -q "column outside the allow-list of messages" "$T/out" \
  && pass "whitelist: a COPY naming messages.files is refused" || fail "files column: rc=$rc $(cat "$T/out")"
wl "a second COPY into tenants" "a second COPY into tenants" \
  "COPY tenants (tenant_id) FROM stdin;" "nothing-to-hide"

# --- part 2: a real Postgres ---------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the database part is not run"
  [[ "$fails" -eq 0 ]] && { echo "PASS: all $n $(basename "$0") hermetic assertions (database part skipped)"; exit 0; }
  echo "FAIL: $fails of $n assertion(s)"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-pdl-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
sleep 1
SUPER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
psql -X -q -v ON_ERROR_STOP=1 "$SUPER_DSN" \
  -c "CREATE ROLE seed_owner LOGIN NOSUPERUSER NOBYPASSRLS CREATEDB PASSWORD 'owner'" \
  -c "CREATE DATABASE seed_tpl OWNER seed_owner" >/dev/null || { fail "create the owner role"; exit 1; }
dsn_of() { echo "postgres://seed_owner:owner@127.0.0.1:$PGPORT/$1?sslmode=disable"; }
"$BIN" migrate --db "$(dsn_of seed_tpl)" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null \
  || { fail "spool migrate as the non-superuser owner"; exit 1; }
HEAD_FILE="$(psql -X -At "$(dsn_of seed_tpl)" -c 'SELECT max(filename) FROM spool_schema_migrations')"
fresh() { psql -X -q "$SUPER_DSN" -c "CREATE DATABASE $1 TEMPLATE seed_tpl OWNER seed_owner" >/dev/null; DSN="$(dsn_of "$1")"; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 "$DSN" -c 'BEGIN' -c "SET LOCAL app.rls_scope = 'operator'" -c "$1" -c 'COMMIT' | sed -n 1p; }

make_case good
fresh db_head
make_case oldhead "" '.migration_head = "0001_init.sql"'
refused "a database at another migration head names the release" "check out release 1.2.3" oldhead
[[ "$(q 'SELECT count(*) FROM tenants')" == 0 ]] && pass "  ... and nothing was loaded" || fail "head refusal loaded rows"

fresh db_count
make_case badcount "" '.row_counts.messages = 4'
refused "a manifest count that differs from the file rolls back" "seed: messages has 3 rows, the manifest says 4" badcount
[[ "$(q 'SELECT count(*) FROM tenants') $(q 'SELECT count(*) FROM humans')" == "0 0" ]] \
  && pass "  ... the transaction rolled back: no workspace, no human" || fail "count refusal kept rows"
compgen -G "$T/home/.spool/seed/*" >/dev/null && fail "  ... a root key was kept for a refused load" || pass "  ... and no root key was kept"

fresh db_zero
cat >"$T/zero-spool" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == root-keygen ]]; then "$BIN" "\$@" >/dev/null || exit 1; printf '%s\n' "$(head -c 32 /dev/zero | base64)"; exit 0; fi
exec "$BIN" "\$@"
EOF
chmod +x "$T/zero-spool"
BIN_SAVE="$BIN"; BIN="$T/zero-spool"
refused "a root_pubkey still 32 zero bytes refuses to commit" "root_pubkey is still 32 zero bytes" good
BIN="$BIN_SAVE"
[[ "$(q 'SELECT count(*) FROM tenants')" == 0 ]] && pass "  ... and the zero-key load rolled back" || fail "zero key committed"

fresh db_good
load good; rc=$?
[[ $rc -eq 0 ]] && grep -q "Seed loaded: workspace $TID" "$T/out" && pass "a clean load succeeds" || fail "clean load: rc=$rc $(cat "$T/out")"
pw="$(sed -n 's/^Password (shown once, never stored in clear): //p' "$T/out")"
[[ ${#pw} -ge 20 && "$(grep -c -- "$pw" "$T/out")" == 1 ]] && pass "the generated password is printed exactly once" || fail "password line: '$pw'"
[[ "$(q 'SELECT count(*) FROM tenants')" == 1 && "$(q 'SELECT tenant_id FROM tenants')" == "$TID" ]] \
  && pass "exactly one workspace, the file's" || fail "workspaces: $(q 'SELECT string_agg(tenant_id, ",") FROM tenants')"
[[ "$(q "SELECT count(*) FROM tenants WHERE billing_status = 'internal' AND plan_id = 'default'")" == 1 ]] \
  && pass "billing_status internal, plan default" || fail "tenant constants"
admin="$(q "SELECT human_id FROM human_identities WHERE provider = 'password' AND subject = 'admin@example.com'")"
[[ "$admin" == HUM-8 ]] && pass "the first admin is a new human past the highest loaded HUM-n (HUM-8)" || fail "admin id '$admin'"
[[ "$(q "SELECT role FROM tenant_memberships WHERE human_id = '$admin'")" == biz_owner ]] \
  && pass "the admin's membership is owner (biz_owner)" || fail "admin role"
[[ "$(q "SELECT count(*) FROM password_credentials WHERE subject = 'admin@example.com' AND password_hash LIKE '\$argon2id\$%'")" == 1 ]] \
  && pass "the admin has a native argon2id password credential" || fail "admin credential"
[[ "$(q "SELECT count(DISTINCT human_id) FROM human_identities WHERE provider = 'password'")" == 1 \
   && "$(q 'SELECT count(*) FROM password_credentials')" == 1 ]] \
  && pass "exactly one human can sign in" || fail "sign-in principals"
[[ "$(q "SELECT count(*) FROM humans h WHERE h.human_id <> '$admin' AND (h.email IS NOT NULL OR h.display_name <> h.human_id
      OR EXISTS (SELECT 1 FROM human_identities i WHERE i.human_id = h.human_id)
      OR EXISTS (SELECT 1 FROM human_keys k WHERE k.human_id = h.human_id))")" == 0 ]] \
  && pass "no loaded human has a credential, identity, key or e-mail (the planted e-mail was dropped)" || fail "a loaded human carries data"
[[ "$(q "SELECT count(*) FROM tenant_memberships WHERE human_id <> '$admin' AND (role <> 'developer' OR admitted_by <> 'seed')")" == 0 ]] \
  && pass "loaded memberships are member (developer) admitted by seed, whatever the file says" || fail "membership constants"
[[ "$(q "SELECT count(*) FROM messages WHERE msg::text LIKE '%CANARY%' OR env_sig <> '' OR octet_length(env) <> 0 OR from_box <> 'seed' OR to_box <> 'seed'")" == 0 \
   && "$(q 'SELECT count(*) FROM messages')" == 3 ]] \
  && pass "3 messages, msg/env/env_sig/boxes are the loader's constants (no canary survived)" || fail "message constants"
[[ "$(q "SELECT msg->>'body' || '|' || (msg->>'v') || '|' || (msg->'files')::text FROM messages ORDER BY msg_id LIMIT 1")" == "seed body 1|1|[]" ]] \
  && pass "msg is the v:1 object rebuilt from the public columns" || fail "msg rebuild: $(q 'SELECT msg::text FROM messages LIMIT 1')"
[[ "$(q "SELECT description FROM channels WHERE channel_id = 'lobby'")" == "The lobby" ]] \
  && pass "a loaded channel replaces the default the tenant trigger seeds" || fail "lobby upsert"
key="$T/home/.spool/seed/$TID-root.key"
[[ -f "$key" && "$(stat -c %a "$key")" == 600 ]] && pass "the root private key is at the operator path, mode 0600" || fail "key file"
pub="$(q "SELECT encode(root_pubkey, 'base64') FROM tenants")"
[[ "$pub" != "$(head -c 32 /dev/zero | base64)" ]] && ! grep -rq -- "$(cat "$key")" "$T/out" \
  && pass "root_pubkey is the new key, and the private key is not printed" || fail "root key"
[[ "$(base64 -d "$key" | tail -c 32 | base64)" == "$pub" ]] \
  && pass "the database holds only the public half of the new keypair (the private key stays in the file)" || fail "key pair mismatch"

refused "a second load into a database with a workspace" "already holds a workspace" good SEED_ROOT_KEY_OUT="$T/other.key"
[[ "$(q 'SELECT count(*) FROM tenants')" == 1 ]] && pass "  ... the first load is untouched" || fail "second load changed tenants"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $n $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails of $n assertion(s)"; exit 1
