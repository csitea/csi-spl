#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the public dataset names step, do_spl_public_dataset_names (spec 091
# T005, section 5.5 item 3 and 8.2). gcloud and psql are stubbed and record
# every call; the names are made up.
#   1. DRY_RUN (default) calls no cloud and no psql and names the staging prefix
#   2. a bad PD_CANDIDATE or a missing PD_NAMES_DIR is refused before any call
#   3. DRY_RUN=0: reads AS spool_public_names, read only, under the operator
#      scope, every workspace but the cnf one; writes names.tsv and
#      names.sha256 (lower-cased sha256 of each id and name), mode 0600; both
#      go to the PRIVATE staging bucket under candidates/<id>/names/ only,
#      with --account; the output names no workspace and no password
#   4. a read that holds the exported workspace is refused, nothing uploaded
#   5. an empty password slot is refused naming the seed, no psql
#   6. a staging bucket equal to the public bucket is refused before any call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v yq >/dev/null && command -v jq >/dev/null || { echo "SKIP: no yq / jq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
NAMES_SLOT=$(yq -r '.env.public_dataset.names_password_secret' "$CNF/all.env.yaml")
OWNER_SLOT=$(yq -r '.env.hub.db_owner_dsn_secret' "$CNF/all.env.yaml")
WS=$(yq -r '.env.public_dataset.workspace_id' "$CNF/dev.env.yaml")
STAGING=$(yq -r '.env.steps."053-gcs-public-dataset".staging_bucket_name' "$CNF/dev.env.yaml")
PUBLIC=$(yq -r '.env.steps."053-gcs-public-dataset".public_bucket_name' "$CNF/dev.env.yaml")
CAND=2026-10-25-v1.4.0
NAMES_PW="namespw$RANDOM$RANDOM"
OWNER_DSN="postgres://spool_hub:ownerpw@/spool?host=/cloudsql/csi-spl-dev:europe-north1:csi-spl-dev-pg"
GOOD_JSON='[["ws-other", "Zebracorp Holdings"], ["ws-quiet", "Quokka\tVille"]]'
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/names"
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
  "storage cp "*) cp "$3" "$UP/$(basename "$4")" ;;
esac
exit 0
EOF
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
in=$(cat); { echo "psql as=$PGUSER pw=$PGPASSWORD"; printf '%s\n' "$in"; } >>"$T_STDIN"
echo "PSQL as=$PGUSER" >>"$STUB_LOG"
printf '%s\n' "$NAMES_JSON"
EOF
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"; rm -rf "$T/up" "$T/names"; mkdir -p "$T/up" "$T/names"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    T_STDIN="$T/stdin" SEC="$T/sec" UP="$T/up" NAMES_JSON="${NAMES_JSON:-$GOOD_JSON}" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" ENV=dev PD_CANDIDATE="$CAND" PD_NAMES_DIR="$T/names" SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
seed() { rm -rf "$T/sec"; mkdir -p "$T/sec"; printf '%s' "$OWNER_DSN" >"$T/sec/$OWNER_SLOT"; printf '%s' "$NAMES_PW" >"$T/sec/$NAMES_SLOT"; }
cnt() { local n; n=$(grep -c -- "$1" "$T/calls.log" 2>/dev/null); echo "${n:-0}"; }
no_names() { ! grep -qiE 'zebracorp|quokka|ws-other|ws-quiet' "$T/out" && ! grep -qF -- "$NAMES_PW" "$T/out"; }

# --- 1. dry run ----------------------------------------------------------------
seed; in_orc do_spl_public_dataset_names; rc=$?
[[ $rc -eq 0 && $(cnt 'secrets ') -eq 0 && $(cnt 'storage ') -eq 0 && $(cnt PSQL) -eq 0 ]] &&
  grep -q "^OK DRY_RUN nothing was touched" "$T/out" && grep -qF "gs://$STAGING/candidates/$CAND/names/" "$T/out" &&
  [[ -z "$(ls "$T/names")" ]] \
  && pass "1. DRY_RUN: no secret, no psql, no upload, names the private staging prefix" || fail "1. dry: rc=$rc $(cat "$T/out")"

# --- 2. argument refusals ------------------------------------------------------------
seed; in_orc do_spl_public_dataset_names DRY_RUN=0 PD_CANDIDATE=../../public; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'PD_CANDIDATE must be' "$T/out" \
  && pass "2. a PD_CANDIDATE that is not <date>-v<X.Y.Z> is refused before any call" || fail "2. candidate: rc=$rc $(cat "$T/out")"
seed; in_orc do_spl_public_dataset_names DRY_RUN=0 PD_NAMES_DIR="$T/nowhere"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'PD_NAMES_DIR must be' "$T/out" \
  && pass "2. a missing PD_NAMES_DIR is refused before any call" || fail "2. dir: rc=$rc $(cat "$T/out")"

# --- 3. the real path ------------------------------------------------------------------
seed; in_orc do_spl_public_dataset_names DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK public dataset names (dev): 2 other workspace(s), 4 hash(es)" "$T/out" \
  && pass "3. DRY_RUN=0 succeeds: 2 other workspaces, 4 hashes" || fail "3. run: rc=$rc $(cat "$T/out")"
grep -q '^psql as=spool_public_names pw='"$NAMES_PW"'$' "$T/stdin" && ! grep -q 'as=spool_hub' "$T/stdin" \
  && pass "3. the read runs AS spool_public_names with its own password (never the owner)" || fail "3. login: $(head -1 "$T/stdin")"
grep -q '^BEGIN READ ONLY;$' "$T/stdin" && grep -q "^SET LOCAL app.rls_scope = 'operator';$" "$T/stdin" &&
  grep -qF "\\set ws '$WS'" "$T/stdin" && grep -qF "FROM tenants WHERE tenant_id <> :'ws'" "$T/stdin" &&
  grep -q 'SELECT coalesce(json_agg(json_build_array(tenant_id, display_name)' "$T/stdin" \
  && pass "3. read only, operator scope, (tenant_id, display_name) only, every workspace but $WS" || fail "3. sql: $(cat "$T/stdin")"
printf 'ws-other\tZebracorp Holdings\nws-quiet\tQuokka Ville\n' >"$T/want.tsv"
want_sha=$(for w in ws-other 'zebracorp holdings' ws-quiet 'quokka ville'; do printf '%s' "$w" | sha256sum | cut -d' ' -f1; done | sort)
cmp -s "$T/names/names.tsv" "$T/want.tsv" && [[ "$(cat "$T/names/names.sha256")" == "$want_sha" ]] \
  && pass "3. names.tsv holds id TAB name (a tab inside a name becomes a space); names.sha256 the lower-cased hashes" \
  || fail "3. files: $(cat -A "$T/names/names.tsv") / $(cat "$T/names/names.sha256")"
[[ "$(stat -c %a "$T/names/names.tsv") $(stat -c %a "$T/names/names.sha256")" == "600 600" ]] \
  && pass "3. both files are mode 0600" || fail "3. modes: $(stat -c %a "$T/names/"*)"
[[ $(cnt "storage cp $T/names/names.tsv gs://$STAGING/candidates/$CAND/names/names.tsv --account=$DEV_SA") -eq 1 &&
   $(cnt "storage cp $T/names/names.sha256 gs://$STAGING/candidates/$CAND/names/names.sha256 --account=$DEV_SA") -eq 1 &&
   $(cnt 'storage ') -eq 2 && $(cnt "gs://$PUBLIC/") -eq 0 ]] && cmp -s "$T/up/names.tsv" "$T/names/names.tsv" \
  && pass "3. both lists go to private staging under candidates/$CAND/names/ only, as the per-env SA" || fail "3. uploads: $(grep storage "$T/calls.log")"
[[ $(cnt "secrets versions access latest --secret=$NAMES_SLOT") -eq 1 ]] && ! grep -q 'secrets' <(grep -v -- "--account=$DEV_SA" "$T/calls.log") \
  && pass "3. the password comes from $NAMES_SLOT; every secrets call carries --account" || fail "3. secrets: $(grep secrets "$T/calls.log")"
no_names && pass "3. the output names no workspace and no password" || fail "3. leak: $(cat "$T/out")"

# --- 4. the exported workspace in the read ----------------------------------------------
seed; NAMES_JSON="[[\"$WS\", \"Our Own\"], [\"ws-other\", \"Zebracorp Holdings\"]]" in_orc do_spl_public_dataset_names DRY_RUN=0; rc=$?
[[ $rc -ne 0 && $(cnt 'storage ') -eq 0 ]] && grep -q 'holds the exported workspace' "$T/out" && no_names \
  && pass "4. a read holding the exported workspace is refused; nothing uploaded" || fail "4. own ws: rc=$rc $(cat "$T/out")"

# --- 5. no password ------------------------------------------------------------------------
seed; : >"$T/sec/$NAMES_SLOT"; in_orc do_spl_public_dataset_names DRY_RUN=0; rc=$?
[[ $rc -ne 0 && $(cnt PSQL) -eq 0 && $(cnt 'storage ') -eq 0 ]] && grep -q "$NAMES_SLOT has no readable version: run ENV=dev DRY_RUN=0 ./run -a do_spl_public_export_secret_seed" "$T/out" \
  && pass "5. an empty password slot is refused naming the seed action; no psql" || fail "5. no pw: rc=$rc $(cat "$T/out")"

# --- 6. staging = public ---------------------------------------------------------------------
seed; in_orc 'eval "_real_cnf() $(declare -f do_spl_cloud_cnf | tail -n +2)"
do_spl_cloud_cnf() { _real_cnf || return 1
  yq -i ".env.steps.\"053-gcs-public-dataset\".public_bucket_name = \"$STAGING\"" "$SPL_CNF"; }
do_spl_public_dataset_names' DRY_RUN=0 STAGING="$STAGING"; rc=$?
[[ $rc -ne 0 && $(cnt 'secrets ') -eq 0 && $(cnt 'storage ') -eq 0 ]] && grep -q 'the staging bucket is the public bucket' "$T/out" \
  && pass "6. a staging bucket equal to the public one is refused before any call" || fail "6. same bucket: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
