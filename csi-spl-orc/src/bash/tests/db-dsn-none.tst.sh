#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 076 T008 follow-up, the db_dsn seam (SM-26) under provider none:
#          spl_read_dsn / spl_read_owner_dsn (do_spl_cloud_dispatch db_dsn
#          read) and spl_local_dsn (db_dsn local), the DSN readers of
#          spl_via_proxy and do_spl_db_bootstrap.
#          1. none, runtime: $SPOOL_HUB_DB_DSN; owner: the same server's host
#             and port as SPOOL_DB_OWNER with SPOOL_DB_OWNER_PASSWORD on
#             SPOOL_DB_NAME from the self-host .env (defaults spool_hub, the
#             password URL-encoded); no password or no SPOOL_HUB_DB_DSN ->
#             nothing printed, rc != 0, the FATAL names the key only.
#          2. none: spl_local_dsn passes the DSN through; spl_via_proxy runs
#             its command with SPL_PROXY_DSN = $SPOOL_HUB_DB_DSN.
#          3. env.cloud.provider: none in the cnf ($SPL_CNF) -> the same.
#          4. control: under gcp the gcloud stub IS reached, for the runtime
#             and the owner slot, and spl_local_dsn is spl_proxy_dsn.
#          gcloud, cloud-sql-proxy and docker are stubs that record every
#          call: 0 expected under none. DSNs are compared inside the run, so
#          no fixture password reaches any output (checked at the end).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/stub" "$T/sh" "$T/state"
for b in gcloud cloud-sql-proxy docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\necho "postgres://cu:cloud-fixture-pw@/cdb?host=/cloudsql/p:r:i"\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*
printf 'env:\n  cloud:\n    provider: none\n' >"$T/none.yaml"
ENVF="$T/sh/.env" ALL="$T/all.out"
RT_DSN='postgres://rt:rt-fixture-pw@db.internal:6432/spool?sslmode=disable'

# run [VAR=value]... - every orc lib + action sourced in a fresh bash, the
# stubs first on PATH, then eval "$SNIPPET"; output also appended to $ALL.
run() {
  env -u SPOOL_CLOUD_PROVIDER -u SPL_CNF PATH="$T/stub:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    HOME="$T/home" STUB_LOG="$T/calls.log" SPL_STATE_DIR="$T/state" SPOOL_SELF_HOST_DIR="$T/sh" \
    GCP_ACCOUNT=sa@example.com SPL_PROJECT=p SPL_DSN_SECRET=rt-slot SPL_OWNER_DSN_SECRET=owner-slot \
    SPOOL_HUB_DB_DSN="$RT_DSN" "$@" bash -c '
    set -uo pipefail
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_log() { echo "$*"; }
    eval "$SNIPPET"' 2>&1 | tee -a "$ALL"
}
# same <want> <got-cmd>: prints SAME or DIFF and the rc, never the values
SAME='same() { local g rc; g="$(eval "$2")"; rc=$?; [[ "$g" == "$1" ]] && echo "SAME rc=$rc" || echo "DIFF rc=$rc len=${#g}"; }'
no_calls() {  # <label>
  [[ ! -s "$T/calls.log" ]] && pass "$1: no gcloud, cloud-sql-proxy or docker call" ||
    fail "$1: a cloud call under none: $(tr '\n' ' ' <"$T/calls.log")"
}

# --- 1. none: runtime and owner ----------------------------------------------
printf "SPOOL_DB_OWNER='own'\nSPOOL_DB_OWNER_PASSWORD='o w/n@fixture'\nSPOOL_DB_NAME=hubdb\n" >"$ENVF"; chmod 600 "$ENVF"
: >"$T/calls.log"
out=$(SNIPPET="$SAME"'; same "$SPOOL_HUB_DB_DSN" spl_read_dsn' run SPOOL_CLOUD_PROVIDER=none)
[[ "$out" == "SAME rc=0" ]] && pass "none: spl_read_dsn is \$SPOOL_HUB_DB_DSN" || fail "none runtime: $out"
want='postgres://own:o%20w%2Fn%40fixture@db.internal:6432/hubdb?sslmode=disable'
out=$(SNIPPET="$SAME"'; same "'"$want"'" spl_read_owner_dsn' run SPOOL_CLOUD_PROVIDER=none)
[[ "$out" == "SAME rc=0" ]] && pass "none: spl_read_owner_dsn = .env owner + password (encoded) + db, on the runtime DSN's host:port" ||
  fail "none owner: $out"
no_calls "none read"

printf "SPOOL_DB_OWNER_PASSWORD=plainfixture\n" >"$ENVF"
want='postgres://spool_hub:plainfixture@db.internal:6432/spool_hub?sslmode=disable'
out=$(SNIPPET="$SAME"'; same "'"$want"'" spl_read_owner_dsn' run SPOOL_CLOUD_PROVIDER=none)
[[ "$out" == "SAME rc=0" ]] && pass "none: owner and db name default to spool_hub (the compose defaults)" || fail "none owner defaults: $out"

printf "SPOOL_DB_OWNER='own'\nSPOOL_DB_OWNER_PASSWORD='<choose-one>'\n" >"$ENVF"
out=$(SNIPPET='v="$(spl_read_owner_dsn)"; echo "RC=$? LEN=${#v}"' run SPOOL_CLOUD_PROVIDER=none)
grep -qx 'RC=1 LEN=0' <<<"$out" && grep -q 'FATAL no SPOOL_DB_OWNER_PASSWORD' <<<"$out" &&
  pass "none: an empty owner password -> nothing printed, rc 1, the key named" || fail "none owner empty: $out"
printf "SPOOL_DB_OWNER_PASSWORD=plainfixture\n" >"$ENVF"
out=$(SNIPPET='v="$(spl_read_owner_dsn)"; echo "RC=$? LEN=${#v}"' run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN=)
grep -qx 'RC=1 LEN=0' <<<"$out" && grep -q 'FATAL SPOOL_HUB_DB_DSN is not set' <<<"$out" &&
  pass "none: no SPOOL_HUB_DB_DSN -> no owner DSN, rc 1" || fail "none owner no host: $out"
out=$(SNIPPET='v="$(spl_read_dsn)"; echo "RC=$? LEN=${#v}"' run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN=)
grep -qx 'RC=1 LEN=0' <<<"$out" && pass "none: no SPOOL_HUB_DB_DSN -> no runtime DSN, rc 1" || fail "none runtime unset: $out"
no_calls "none failures"

# --- 2. none: the local DSN and spl_via_proxy --------------------------------
out=$(SNIPPET="$SAME"'; same "$SPOOL_HUB_DB_DSN" "spl_local_dsn \"\$SPOOL_HUB_DB_DSN\" 5432"' run SPOOL_CLOUD_PROVIDER=none)
[[ "$out" == "SAME rc=0" ]] && pass "none: spl_local_dsn passes a TCP DSN through" || fail "none local: $out"
out=$(SNIPPET='chk() { [[ "$SPL_PROXY_DSN" == "$SPOOL_HUB_DB_DSN" ]] && echo CMD-SAME || echo CMD-DIFF; }; spl_via_proxy chk; echo "RC=$? JOBS=$(jobs -p | wc -l)"' \
  run SPOOL_CLOUD_PROVIDER=none)
grep -qx CMD-SAME <<<"$out" && grep -qx 'RC=0 JOBS=0' <<<"$out" &&
  pass "none: spl_via_proxy runs the command with SPL_PROXY_DSN = \$SPOOL_HUB_DB_DSN, rc 0, no background job" ||
  fail "none via_proxy: $out"
no_calls "none spl_via_proxy"

# --- 3. env.cloud.provider: none in the cnf ----------------------------------
printf "SPOOL_DB_OWNER_PASSWORD=plainfixture\n" >"$ENVF"
want='postgres://spool_hub:plainfixture@db.internal:6432/spool_hub?sslmode=disable'
out=$(SNIPPET="$SAME"'; same "$SPOOL_HUB_DB_DSN" spl_read_dsn; same "'"$want"'" spl_read_owner_dsn' run SPL_CNF="$T/none.yaml")
[[ "$out" == $'SAME rc=0\nSAME rc=0' ]] && pass "cnf env.cloud.provider none: runtime and owner read without a cloud" || fail "cnf none: $out"
no_calls "cnf none"

# --- 4. control: gcp reaches the gcloud stub ---------------------------------
: >"$T/calls.log"
out=$(SNIPPET='a="$(spl_read_dsn)"; b="$(spl_read_owner_dsn)"; echo "LENS=${#a},${#b}"' run SPOOL_CLOUD_PROVIDER=gcp)
grep -q '^gcloud secrets versions access latest --secret=rt-slot --project=p --account=sa@example.com$' "$T/calls.log" &&
  grep -q '^gcloud secrets versions access latest --secret=owner-slot --project=p --account=sa@example.com$' "$T/calls.log" &&
  [[ $(wc -l <"$T/calls.log") -eq 2 ]] && grep -qx 'LENS=[1-9][0-9]*,[1-9][0-9]*' <<<"$out" &&
  pass "control: under gcp both reads are one gcloud secrets access each, on \$SPL_DSN_SECRET and \$SPL_OWNER_DSN_SECRET" ||
  fail "control gcp: $(tr '\n' ' ' <"$T/calls.log") / $out"
out=$(SNIPPET='spl_local_dsn "postgres://u:p@/d?host=/cloudsql/p:r:i" 7777; echo; spl_local_dsn "$SPOOL_HUB_DB_DSN" 7777; echo "RC=$?"' run SPOOL_CLOUD_PROVIDER=gcp)
grep -qx 'postgres://u:p@127.0.0.1:7777/d?sslmode=disable' <<<"$out" && grep -qx 'RC=1' <<<"$out" &&
  pass "control: under gcp spl_local_dsn is spl_proxy_dsn (the /cloudsql form only)" || fail "control gcp local: $out"

# --- no fixture secret in any output -----------------------------------------
grep -qE 'fixture|rt-fixture-pw' "$ALL" && fail "a fixture password reached the output: $(grep -m 3 -E 'fixture' "$ALL")" ||
  pass "no fixture password in any output"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
