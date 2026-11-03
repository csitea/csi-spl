#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the public dataset export, do_spl_public_dataset_export (spec 091
# T006; sections 4, 5.3, 5.4, 5.6, 5.7). Synthetic rows only.
#   Part 1 (hermetic: gcloud, curl, the proxy, the names step and the gate
#   stubbed; psql replaced by a fake that answers each projection's COPY):
#     1. the code: no SELECT *, no pg_dump, no set -x in the action and the
#        projection files; one projection per allow-list table, each opening
#        with its `-- columns:` line, each carrying WHERE tenant_id = :'ws'
#     2. the kill switch: cnf enabled false and no PUBLIC_DATASET_FORCE ->
#        exit 0, nothing called
#     3. DRY_RUN (default) with the force: no secret, no psql, no upload;
#        names the private staging prefix, the version and the head
#     4. a read returning a row of ANOTHER workspace: FATAL, the gate is not
#        called, nothing uploaded
#     5. the real path: one READ ONLY transaction per listed workspace with
#        SET LOCAL app.tenant_id and never app.rls_scope; the file holds only
#        COPY blocks in FK order; a non-member HUM-n drops its message
#        (counted); humans and memberships only for authors and addressees;
#        the manifest schema; both files go to private staging only, with
#        --account; the output names no row content
#   Part 2 (a REAL throwaway Postgres migrated by the repo's migrations, the
#   real spool_public_export login and its grants):
#     6. the projections run as that login and emit exactly the rows of the
#        section 4.1 row rules (private, deleted, archived, topic-channel and
#        DM channels out; archived and expired tasks out; a reply whose
#        thread root is out, out; another workspace out), and the real gate
#        passes the candidate they make
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in yq jq python3 gzip; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done

FUNC="$PROJ_ROOT/src/bash/run/spl-public-dataset-export.func.sh"
SQLD="$PROJ_ROOT/src/sql/public-dataset/v1"
ALLOW_YAML="$PROJ_ROOT/cnf/public-dataset/allow-list.v1.yaml"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
WS=$(yq -r '.env.public_dataset.workspace_ids | join(",")' "$CNF/dev.env.yaml")
STAGING=$(yq -r '.env.steps."053-gcs-public-dataset".staging_bucket_name' "$CNF/dev.env.yaml")
PUBLIC=$(yq -r '.env.steps."053-gcs-public-dataset".public_bucket_name' "$CNF/dev.env.yaml")
EXPORT_SLOT=$(yq -r '.env.public_dataset.export_password_secret' "$CNF/all.env.yaml")
OWNER_SLOT=$(yq -r '.env.hub.db_owner_dsn_secret' "$CNF/all.env.yaml")
HEAD_SHA=$(git -C "$APP_ROOT" rev-parse HEAD)
HEAD_MIG=$(git -C "$APP_ROOT" ls-tree --name-only HEAD csi-spl-rdb/src/sql/postgres/spool-hub/ | sed -n 's|.*/\([0-9]\{4\}_[a-z0-9_]*\.sql\)$|\1|p' | sort | tail -1)
CAND=2026-11-03-v1.5.0
EXPORT_PW="exportpw$RANDOM$RANDOM"
OWNER_DSN="postgres://spool_hub:ownerpw@/spool?host=/cloudsql/csi-spl-dev:europe-north1:csi-spl-dev-pg"

# --- 1. the code ---------------------------------------------------------------------
[[ -s "$FUNC" ]] && pass "1. the action file exists" || fail "1. no $FUNC"
grep -nE 'set -x|SELECT \*|pg_dump' "$FUNC" "$SQLD"/*.sql | grep -vE '^\S+:[0-9]+:\s*(#|--)' >/dev/null \
  && fail "1. the action or a projection traces (set -x), selects * or dumps" || pass "1. no set -x, SELECT * or pg_dump in the action and the projections"
bad=0
for t in $(yq -r '.tables | keys | .[]' "$ALLOW_YAML"); do
  f=$(ls "$SQLD"/[0-9][0-9]-"$t".sql 2>/dev/null)
  [[ -n "$f" ]] || { fail "1. no projection for $t"; bad=1; continue; }
  [[ "$(head -1 "$f")" =~ ^--\ columns:\ [a-z_]+(,\ [a-z_]+)*$ ]] || { fail "1. $t: no -- columns: line"; bad=1; }
  grep -qE "\.tenant_id = :'ws'" "$f" || { fail "1. $t: no WHERE ... tenant_id = :'ws' (fence 3)"; bad=1; }
  cols=$(head -1 "$f" | sed 's/^-- columns: //; s/, /\n/g')
  ok=$(yq -r ".tables.$t | (.public + ((.constants // {}) | keys)) | .[]" "$ALLOW_YAML"; echo tenant_id)
  for c in $cols; do grep -qx "$c" <<<"$ok" || { fail "1. $t emits $c: not public, not a constant, not tenant_id"; bad=1; }; done
  for c in $(yq -r ".tables.$t.public[]" "$ALLOW_YAML"); do grep -qx "$c" <<<"$cols" || { fail "1. $t does not emit public $c"; bad=1; }; done
done
[[ "$(ls "$SQLD"/*.sql | wc -l)" == "$(yq -r '.tables | length' "$ALLOW_YAML")" ]] || { fail "1. a projection file for a table outside the allow-list"; bad=1; }
(( bad == 0 )) && pass "1. one projection per allow-list table, columns line = public + constants (+ tenant_id), each filtered on :'ws'"

# --- the stubs -------------------------------------------------------------------------
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/fix"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud|$*" >>"$STUB_LOG"
case "$*" in
  "auth activate-service-account"*) for a; do [[ "$a" == --key-file=* ]] && jq -r .client_email "${a#*=}" >"$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo ya29.stub_token_value_long_enough ;;
  "secrets versions access latest"*) for a; do [[ "$a" == --secret=* ]] && s="${a#--secret=}"; done
    [[ -s "$SEC/$s" ]] && cat "$SEC/$s" || exit 1 ;;
  "storage cp "*) cp "$3" "$UP/$(basename "$4")"; echo "$4" >>"$UP/dests" ;;
esac
exit 0
EOF
cat >"$T/stub/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl|$*" >>"$STUB_LOG"
printf '{"version":"1.5.0","commit":"%s","built_at":"x"}\n' "$HEAD_SHA"
EOF
# fakepg.py: psql. Records the script; answers the whoami line, then each
# `\o <dir>/<ws>/<table>.tsv` with $FIX/<ws>/<table>.tsv.
cat >"$T/fakepg.py" <<'EOF'
import os, re, sys
script = sys.stdin.read()
open(os.environ["T_STDIN"], "a").write(script)
print("spool_public_export|f|f")
for m in re.finditer(r"^\\o (\S+)/([^/\s]+)/([a-z_]+)\.tsv$", script, re.M):
    src = os.path.join(os.environ["FIXD"], m.group(2), m.group(3) + ".tsv")
    open(os.path.join(m.group(1), m.group(2), m.group(3) + ".tsv"), "w").write(open(src).read() if os.path.exists(src) else "")
EOF
chmod +x "$T/stub/"*

# fixture rows per listed workspace: HUM-3 / HUM-7 author, HUM-5 a member who
# writes nothing, HUM-9 no member (its message is dropped)
mkfix() { # <dir> [<ws> <table> <tenant_id override>]
  python3 - "$1" "$WS" "${2:-}" "${3:-}" "${4:-}" <<'PY'
import os, sys
d, ws, ow, ot, ov = sys.argv[1], sys.argv[2].split(","), sys.argv[3], sys.argv[4], sys.argv[5]
at = "2026-11-01 10:00:00+00"
for i, w in enumerate(ws):
    rows = {
      "tenants": [[w, "Space %d" % i, at, "internal", "default", "\\\\x" + "00" * 32]],
      "humans": [[h, h, "\\N", "\\N"] for h in ("HUM-3", "HUM-5", "HUM-7")],
      "tenant_memberships": [[w, h, "member", at, "seed"] for h in ("HUM-3", "HUM-5", "HUM-7")],
      "channels": [[w, "dev-talk", "dev-talk", "\\N", "HUM-3", at]],
      "messages": [],
    }
    for n, (f, to) in enumerate((("HUM-3", "c-001"), ("c-001", "HUM-7"), ("HUM-9", "c-001")), 1):
        mid = "00000000-0000-4000-8000-%012d" % (i * 10 + n)
        body = "message %d" % n
        rows["messages"].append([w, mid, "00000000-0000-4000-9000-%012d" % i, "\\N", "dev-talk", at, f, to, "note", body,
            "0", at, "2026-12-01 10:00:00+00",
            '{"v": 1, "to": "%s", "ts": "%s", "body": "%s", "from": "%s", "kind": "note", "files": [], "msg_id": "%s", "task_id": "00000000-0000-4000-9000-%012d"}' % (to, at, body, f, mid, i),
            "\\\\x", "", "seed", "seed"])
    if w == ow:
        rows[ot][0][0] = ov
    os.makedirs(os.path.join(d, w), exist_ok=True)
    for t, rs in rows.items():
        open(os.path.join(d, w, t + ".tsv"), "w").write("".join("\t".join(r) + "\n" for r in rs))
PY
}

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"; rm -rf "$T/up" "$T/keep"; mkdir -p "$T/up" "$T/keep"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u PUBLIC_DATASET_FORCE HOME="$T/home" PATH="$T/stub:$PATH" \
    STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" SEC="$T/sec" UP="$T/up" FIXD="${FIXD:-$T/fix}" HEAD_SHA="$HEAD_SHA" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" ENV=dev PD_DATE=2026-11-03 \
    PD_HUB_VERSION_URL=https://hub.example.com/version FAKEPG="$T/fakepg.py" SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    spl_pg_env() { echo "PSQL" >>"$STUB_LOG"; shift; python3 "$FAKEPG"; }
    do_release_note_link() { echo "${SHA:0:8} v1.5.0 https://site.example.com/releases/$SHA"; }
    do_spl_public_dataset_names() { echo "NAMES $PD_CANDIDATE $DRY_RUN" >>"$STUB_LOG"; printf "ws-other\tZebracorp Holdings\n" >"$PD_NAMES_DIR/names.tsv"; }
    do_spl_public_dataset_gate() { echo "GATE $PD_EXPORT_DSN" >>"$STUB_LOG"; cp "$PD_GATE_FILE" "$PD_GATE_OUT"; cp "$PD_GATE_FILE" "$UP/../gated.sql"
      printf "{\"result\":\"PASS\",\"row_counts\":{\"tenants\":3},\"removed_by_class\":{\"email\":0}}\n" >"$PD_GATE_REPORT"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
seed() { rm -rf "$T/sec"; mkdir -p "$T/sec"; printf '%s' "$OWNER_DSN" >"$T/sec/$OWNER_SLOT"; printf '%s' "$EXPORT_PW" >"$T/sec/$EXPORT_SLOT"; }
cnt() { local n; n=$(grep -c -- "$1" "$T/calls.log" 2>/dev/null); echo "${n:-0}"; }
no_content() { ! grep -qE 'message [0-9]|Zebracorp|ws-other|Space [0-9]' "$T/out" && ! grep -qF -- "$EXPORT_PW" "$T/out"; }

# --- 2. the kill switch ------------------------------------------------------------------
seed; in_orc do_spl_public_dataset_export DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'is off: cnf public_dataset.enabled is false and PUBLIC_DATASET_FORCE is unset; nothing exported' "$T/out" \
  && pass "2. enabled false, no PUBLIC_DATASET_FORCE: exit 0, nothing called" || fail "2. switch: rc=$rc $(cat "$T/out") $(cat "$T/calls.log")"

# --- 3. dry run -------------------------------------------------------------------------------
seed; in_orc do_spl_public_dataset_export PUBLIC_DATASET_FORCE=1; rc=$?
[[ $rc -eq 0 && $(cnt 'secrets ') -eq 0 && $(cnt 'storage ') -eq 0 && $(cnt PSQL) -eq 0 && $(cnt NAMES) -eq 0 ]] &&
  grep -q '^OK DRY_RUN nothing was touched' "$T/out" && grep -qF "gs://$STAGING/candidates/$CAND/" "$T/out" &&
  grep -qF "version v1.5.0 commit ${HEAD_SHA:0:8}, migration head $HEAD_MIG, allow-list v1" "$T/out" \
  && pass "3. DRY_RUN: no secret, psql, names or upload; names the staging prefix, version and head ($HEAD_MIG)" || fail "3. dry: rc=$rc $(cat "$T/out")"

# --- 4. a row of another workspace --------------------------------------------------------------
for tb in channels messages tenant_memberships tenants; do
  rm -rf "$T/fix4"; mkfix "$T/fix4" "${WS##*,}" "$tb" ws-other
  seed; FIXD="$T/fix4" in_orc do_spl_public_dataset_export PUBLIC_DATASET_FORCE=1 DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && $(cnt GATE) -eq 0 && $(cnt 'storage ') -eq 0 && $(cnt proxy-stop) -eq 1 ]] &&
    grep -q "FATAL C1 export $tb row 1: a row of another workspace, nothing written" "$T/out" && no_content \
    && pass "4. a $tb row of another workspace is FATAL: no gate, nothing uploaded, the proxy stopped" || fail "4. $tb foreign: rc=$rc $(cat "$T/out")"
done

# --- 5. the real path ---------------------------------------------------------------------------
rm -rf "$T/fix"; mkfix "$T/fix"
seed; in_orc do_spl_public_dataset_export PUBLIC_DATASET_FORCE=1 DRY_RUN=0 PD_OUT_DIR="$T/keep"; rc=$?
GZ="spool-hub-public-$CAND.sql.gz" MAN="spool-hub-public-$CAND.manifest.json"
[[ $rc -eq 0 ]] && grep -qF "OK public dataset candidate (dev) staged: gs://$STAGING/candidates/$CAND/$GZ sha256 " "$T/out" \
  && pass "5. DRY_RUN=0 stages $GZ" || fail "5. run: rc=$rc $(cat "$T/out")"
nws=$(tr ',' '\n' <<<"$WS" | wc -l)
[[ "$(grep -c '^BEGIN READ ONLY;$' "$T/stdin")" == "$nws" && "$(grep -c "^SET LOCAL app.tenant_id = :'ws';$" "$T/stdin")" == "$nws" ]] &&
  ! grep -q 'rls_scope' "$T/stdin" && [[ "$(grep -c '^ROLLBACK;$' "$T/stdin")" == "$nws" ]] &&
  for w in ${WS//,/ }; do grep -qF "\\set ws '$w'" "$T/stdin" || exit 1; done \
  && pass "5. one READ ONLY transaction per listed workspace ($WS), SET LOCAL app.tenant_id, never app.rls_scope" || fail "5. sql: $(head -20 "$T/stdin")"
[[ "$(grep -c '^COPY (' "$T/stdin")" == "$((nws * 5))" ]] && ! grep -qiE 'pg_dump|SELECT \*' "$T/stdin" \
  && pass "5. five projections per workspace, no SELECT *" || fail "5. copies: $(grep -c '^COPY (' "$T/stdin")"
[[ $(cnt "NAMES $CAND 0") -eq 1 && $(cnt GATE) -eq 1 && $(cnt proxy-stop) -eq 1 ]] && grep -q 'GATE postgres://spool_public_export:' "$T/calls.log" \
  && pass "5. the names step runs (DRY_RUN=0), then the gate as spool_public_export; the proxy is stopped" || fail "5. steps: $(cat "$T/calls.log")"
G="$T/gated.sql"
awk 'BEGIN{b=0} /^COPY [a-z_]+ \([a-z_, ]+\) FROM stdin;$/{if(b)exit 1; b=1; next} /^\\\.$/{if(!b)exit 1; b=0; next} {if(!b)exit 1} END{if(b)exit 1}' "$G" &&
  [[ "$(grep -o '^COPY [a-z_]*' "$G" | cut -d' ' -f2 | tr '\n' ' ')" == "tenants humans tenant_memberships channels messages " ]] \
  && pass "5. the file holds only COPY blocks, in FK order" || fail "5. shape: $(grep -n '^COPY' "$G")"
blk() { awk -v t="$1" '$0 ~ "^COPY "t" \\(" {b=1; next} /^\\\.$/ {b=0} b' "$G"; }
[[ "$(blk messages | wc -l)" == "$((nws * 2))" ]] && ! grep -q 'HUM-9' <<<"$(blk messages)" &&
  [[ "$(blk humans | cut -f1 | tr '\n' ' ')" == "HUM-3 HUM-7 " ]] && [[ "$(blk tenant_memberships | wc -l)" == "$((nws * 2))" ]] &&
  ! grep -q 'HUM-5' <<<"$(blk tenant_memberships)" && [[ "$(blk tenants | wc -l)" == "$nws" ]] \
  && pass "5. HUM-9 (no member) drops its message; humans HUM-3, HUM-7 only (HUM-5 wrote nothing)" || fail "5. rows: $(cat "$G")"
M="$T/up/$MAN"
gz_sha=$(sha256sum "$T/up/$GZ" | cut -d' ' -f1)
jq -e --arg sha "$gz_sha" --arg c "$HEAD_SHA" --arg h "$HEAD_MIG" --arg ws "$WS" --arg f "$GZ" '
  .v == 1 and .file == $f and .sha256 == $sha and .version == "1.5.0" and .commit == $c and .migration_head == $h
  and .allow_list_version == 1 and (.allow_list_sha256 | test("^[0-9a-f]{64}$")) and .workspace_ids == ($ws | split(","))
  and .row_counts.tenants == 3 and .removed_by_class["non-member"] == '"$nws"' and .removed_by_class.email == 0
  and (.release_note | endswith("/releases/" + $c)) and .source_env == "dev" and (.exported_at | test("Z$"))' "$M" >/dev/null &&
  gzip -t "$T/up/$GZ" && cmp -s <(gzip -dc "$T/up/$GZ") "$G" && cmp -s "$T/keep/$GZ" "$T/up/$GZ" && cmp -s "$T/keep/$MAN" "$M" \
  && pass "5. the manifest: sha256 of the .sql.gz, version, commit, head, allow-list v + sha256, counts, removed by class (export + gate), release note" \
  || fail "5. manifest: $(cat "$M")"
[[ "$(sort "$T/up/dests" | tr '\n' ' ')" == "gs://$STAGING/candidates/$CAND/$MAN gs://$STAGING/candidates/$CAND/$GZ " &&
   $(cnt 'storage ') -eq 2 && $(cnt "gs://$PUBLIC/") -eq 0 && $(cnt "storage cp .* --account=$DEV_SA") -eq 2 ]] \
  && pass "5. the file and the manifest go to private staging under candidates/$CAND/ only, as the per-env SA" || fail "5. uploads: $(grep storage "$T/calls.log")"
[[ $(cnt "secrets versions access latest --secret=$EXPORT_SLOT") -eq 1 ]] && ! grep -v -- "--account=$DEV_SA" <<<"$(grep 'secrets' "$T/calls.log")" >/dev/null \
  && pass "5. the password comes from $EXPORT_SLOT; every secrets call carries --account" || fail "5. secrets: $(grep secrets "$T/calls.log")"
no_content && pass "5. the output names no row content and no password" || fail "5. leak: $(cat "$T/out")"

# --- part 2: a real Postgres -----------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP: no cached $PG_IMAGE image or no psql; the database part is not run"
  [[ "$fails" -eq 0 ]] && { echo "PASS: $(basename "$0") hermetic part"; exit 0; }
  echo "FAIL: $fails assertion(s)"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
BIN="${SPOOL_BIN:-}"
if [[ -z "$BIN" || ! -x "$BIN" ]]; then
  # shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
  source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
  spl_export_go_path || { fail "no go toolchain"; exit 1; }
  BIN="$T/spool"
  (cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
fi
PG_CTR="spl-pde-pg-$$"
trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$TEST_DIR/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
sleep 1
SUPER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
DB_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/pde?sslmode=disable"
OWNER_DSN="postgres://pde_owner:owner@127.0.0.1:$PGPORT/pde?sslmode=disable"
EXPORT_DSN="postgres://spool_public_export:export-pw@127.0.0.1:$PGPORT/pde?sslmode=disable"
psql -X -q -v ON_ERROR_STOP=1 "$SUPER_DSN" \
  -c "CREATE ROLE pde_owner LOGIN NOSUPERUSER NOBYPASSRLS CREATEDB CREATEROLE PASSWORD 'owner'" \
  -c "CREATE DATABASE pde OWNER pde_owner" >/dev/null || { fail "create the owner role"; exit 1; }
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null \
  || { fail "spool migrate as the non-superuser owner"; exit 1; }
# Listed: ws-pub and ws-two. Not listed: ws-other. The ops channel is the
# dataset topic's channel. Each message id's last digits name its case;
# the KEEP ones are 01, 02, 15 (ws-pub) and 21 (ws-two).
psql -X -q -v ON_ERROR_STOP=1 "$DB_DSN" >/dev/null <<'SQL' || { fail "load the synthetic rows"; exit 1; }
INSERT INTO tenants (tenant_id, root_pubkey, display_name) VALUES
  ('ws-pub', decode(repeat('00', 32), 'hex'), 'Public Space'), ('ws-two', decode(repeat('00', 32), 'hex'), 'Second Space'),
  ('ws-other', decode(repeat('00', 32), 'hex'), 'Zebracorp Holdings') ON CONFLICT (tenant_id) DO NOTHING;
INSERT INTO humans (human_id) VALUES ('HUM-3'), ('HUM-5'), ('HUM-7'), ('HUM-9') ON CONFLICT DO NOTHING;
INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
  ('ws-pub', 'HUM-3', 'developer', 'seed'), ('ws-pub', 'HUM-5', 'developer', 'seed'), ('ws-pub', 'HUM-7', 'developer', 'seed'),
  ('ws-two', 'HUM-3', 'developer', 'seed'), ('ws-other', 'HUM-9', 'developer', 'seed') ON CONFLICT DO NOTHING;
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES
  ('ws-pub', 'dev-talk', 'dev-talk', 'HUM-3'), ('ws-pub', 'secret', 'secret', 'HUM-3'), ('ws-pub', 'gone', 'gone', 'HUM-3'),
  ('ws-pub', 'old', 'old', 'HUM-3'), ('ws-pub', 'ops', 'ops', 'HUM-3'),
  ('ws-two', 'dev-talk', 'dev-talk', 'HUM-3'), ('ws-other', 'dev-talk', 'dev-talk', 'HUM-9') ON CONFLICT DO NOTHING;
UPDATE channels SET is_private = true WHERE tenant_id = 'ws-pub' AND channel_id = 'secret';
UPDATE channels SET deleted_at = now() WHERE tenant_id = 'ws-pub' AND channel_id = 'gone';
UPDATE channels SET archived_at = now() WHERE tenant_id = 'ws-pub' AND channel_id = 'old';
CREATE TEMP TABLE plan (ws text, n int, task int, parent int, ch text, fr text, too text, mins int, exp_days int);
INSERT INTO plan VALUES
  ('ws-pub', 1, 1, NULL, 'dev-talk', 'HUM-3', 'c-001', 0, 1), ('ws-pub', 2, 1, NULL, 'dev-talk', 'c-001', 'HUM-7', 1, 1),
  ('ws-pub', 3, 2, NULL, 'secret', 'HUM-3', 'c-001', 0, 1), ('ws-pub', 4, 3, NULL, 'gone', 'HUM-3', 'c-001', 0, 1),
  ('ws-pub', 5, 4, NULL, 'old', 'HUM-3', 'c-001', 0, 1), ('ws-pub', 6, 5, NULL, 'ops', 'HUM-3', 'c-001', 0, 1),
  ('ws-pub', 7, 6, NULL, NULL, 'HUM-3', 'HUM-7', 0, 1), ('ws-pub', 8, 7, NULL, 'dev-talk', 'HUM-3', 'c-001', 0, 1),
  ('ws-pub', 9, 7, NULL, 'dev-talk', 'c-001', 'HUM-3', 1, 1), ('ws-pub', 10, 8, NULL, 'dev-talk', 'HUM-3', 'c-001', 0, -1),
  ('ws-pub', 11, 9, NULL, 'dev-talk', 'HUM-9', 'c-001', 0, 1), ('ws-pub', 12, 10, NULL, 'secret', 'HUM-3', 'c-001', 0, 1),
  ('ws-pub', 13, 10, NULL, 'dev-talk', 'c-001', 'HUM-3', 1, 1), ('ws-pub', 14, 11, 2, 'dev-talk', 'HUM-3', 'c-001', 0, 1),
  ('ws-pub', 15, 12, 1, 'dev-talk', 'HUM-3', 'c-001', 2, 1),
  ('ws-two', 21, 21, NULL, 'dev-talk', 'HUM-3', 'c-001', 0, 1), ('ws-other', 31, 31, NULL, 'dev-talk', 'HUM-9', 'c-001', 0, 1);
INSERT INTO messages (tenant_id, msg_id, task_id, parent_task_id, channel, ts, from_id, to_id, kind, body, expires_at, msg, env, env_sig, from_box, to_box)
SELECT ws, ('00000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, ('00000000-0000-4000-9000-' || lpad(task::text, 12, '0'))::uuid,
       CASE WHEN parent IS NULL THEN NULL ELSE ('00000000-0000-4000-9000-' || lpad(parent::text, 12, '0'))::uuid END,
       ch, now() - interval '1 hour' + make_interval(mins => mins), fr, too, 'note', 'case ' || n, now() + make_interval(days => exp_days),
       '{"planted": "msg-canary"}', '\x01', 'sig-canary', 'box-canary', 'box-canary'
  FROM plan;
UPDATE messages SET archived_at = now() WHERE msg_id = '00000000-0000-4000-8000-000000000008';
SQL
ROLES="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles"
{ psql -X -q -v ON_ERROR_STOP=1 -v export_verifier=export-pw -f "$ROLES/public-export-role.sql" "$OWNER_DSN" &&
  psql -X -q -v ON_ERROR_STOP=1 -f "$ROLES/public-export-grants.sql" "$OWNER_DSN" &&
  psql -X -q -v ON_ERROR_STOP=1 -c "INSERT INTO public_export_workspace (workspace_id) VALUES ('ws-pub'), ('ws-two')" "$OWNER_DSN"; } >/dev/null ||
  { fail "apply the T004 roles files"; exit 1; }
# a PROJ_PATH whose allow-list v1 also lists, as withheld, the live columns
# migrations added after it (the gate test's pattern: this proves the export,
# not the list's age)
mkdir -p "$T/proj/cnf/public-dataset" && ln -s "$PROJ_ROOT/lib" "$T/proj/lib" && ln -s "$PROJ_ROOT/src" "$T/proj/src"
yq -o=json . "$ALLOW_YAML" >"$T/allow.json"
live="$(psql -X -At "$OWNER_DSN" -c "SELECT json_object_agg(relname, cols) FROM (SELECT c.relname, json_agg(a.attname::text) cols
  FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
    AND c.relname IN ('tenants', 'channels', 'messages', 'humans', 'tenant_memberships') GROUP BY c.relname) t")"
LIVE="$live" python3 -c 'import json, os, sys
a, live = json.load(open(sys.argv[1])), json.loads(os.environ["LIVE"])
n = 0
for t, s in a["tables"].items():
    extra = [c for c in live[t] if c not in s["public"] + s["withheld"]]
    n += len(extra); s["withheld"] += extra
print(json.dumps(a)); print("INFO: %d live column(s) the allow-list v1 does not classify (spec 4.5: a v2 list)" % n, file=sys.stderr)' \
  "$T/allow.json" >"$T/proj/cnf/public-dataset/allow-list.v1.yaml" || { fail "write the test allow-list"; exit 1; }
printf 'env:\n  public_dataset:\n    workspace_ids: [ws-pub, ws-two]\n    body_drop_cap_pct: 1\n    size_tolerance_pct: 50\n    allow_list_version: 1\n' >"$T/cnf.yaml"
printf 'ws-other\tZebracorp Holdings\n' >"$T/names.tsv"
GL="$(command -v gitleaks || true)"
if [[ -z "$GL" ]]; then
  printf '#!/bin/sh\nfor a; do p="$r"; r="$a"; [ "$p" = --report-path ] && echo "[]" >"$a"; done\nexit 0\n' >"$T/stub/gitleaks"
  chmod +x "$T/stub/gitleaks"; echo "INFO: no gitleaks on this runner: a stub stands in for the gate's gitleaks scan"
fi
mkdir -m 700 "$T/pg" "$T/pg/raw"
env PROJ_PATH="$T/proj" APP_PATH="$APP_ROOT" PATH="$T/stub:$PATH" ENV=dev SPL_CNF_STUB="$T/cnf.yaml" H="$T/pg" \
  PD_GATE_FILE="$T/pg/candidate.sql" PD_GATE_OUT="$T/pg/clean.sql" PD_GATE_REPORT="$T/pg/gate.json" PD_NAMES_FILE="$T/names.tsv" \
  PD_EXPORT_DSN="$EXPORT_DSN" bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf() { SPL_CNF="$SPL_CNF_STUB"; }
  declare -A X=([ws]=ws-pub,ws-two [topic]=ops [sql]="$PROJ_PATH/src/sql/public-dataset/v1")
  spl_pd_export_read "$PD_EXPORT_DSN" X "$H/raw" && spl_pd_export_assemble X "$H" && do_spl_public_dataset_gate' >"$T/pg.log" 2>&1 </dev/null
prc=$?
C="$T/pg/candidate.sql"
pblk() { awk -v t="$1" '$0 ~ "^COPY "t" \\(" {b=1; next} /^\\\.$/ {b=0} b' "$C"; }
got=$(pblk messages | cut -f2 | sed 's/.*-0*//' | sort -n | tr '\n' ' ')
[[ $prc -eq 0 ]] && grep -q '^OK public dataset gate (dev)' "$T/pg.log" \
  && pass "6. the projections run as the real spool_public_export login and the real gate passes their candidate" || fail "6. read + gate: rc=$prc $(cat "$T/pg.log")"
[[ "$got" == "1 2 15 21 " ]] \
  && pass "6. messages exactly 01 02 15 (ws-pub) 21 (ws-two): private, deleted, archived, topic and DM channels, archived and expired tasks, a root outside, a non-member, another workspace all out" \
  || fail "6. messages kept: [$got], want [1 2 15 21 ]"
chs=" $(pblk channels | cut -f1,2 | tr '\t\n' ': ')"
[[ "$chs" == *" ws-pub:dev-talk "* && "$chs" == *" ws-two:dev-talk "* && "$chs" != *ws-other* ]] &&
  ! grep -qE ' ws-pub:(secret|gone|old|ops) ' <<<"$chs " && [[ "$(pblk humans | cut -f1 | tr '\n' ' ')" == "HUM-3 HUM-7 " &&
   "$(pblk tenant_memberships | cut -f1,2 | tr '\t\n' ': ')" == "ws-pub:HUM-3 ws-pub:HUM-7 ws-two:HUM-3 " &&
   "$(pblk tenants | cut -f1 | tr '\n' ' ')" == "ws-pub ws-two " ]] \
  && pass "6. channels (dev-talk in both, the migrations' default ones; never secret, gone, old, ops), humans (HUM-5 wrote nothing, HUM-9 is no member), memberships and tenants as the row rules say" \
  || fail "6. other rows: $(grep -v '^[0-9a-f]\{8\}-' "$C" | sed -n 1,30p)"
[[ "$(jq -r '.removed_by_class["non-member"]' "$T/pg/export.json")" == 1 ]] && ! grep -qE 'canary|Zebracorp|ws-other' "$C" "$T/pg.log" \
  && pass "6. one non-member drop counted; no msg / env / env_sig / box canary and no other workspace in the file or the log" \
  || fail "6. removed $(cat "$T/pg/export.json"); leak: $(grep -nE 'canary|Zebracorp|ws-other' "$C" "$T/pg.log" | sed -n 1,3p)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
