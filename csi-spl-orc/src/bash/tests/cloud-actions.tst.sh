#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the owner-gated CLOUD actions read every name from the effective
#          cnf, and a DRY RUN (the default) touches no cloud.
#   1. do_spl_cloud_cnf (dev, prd): the image it pushes IS the image 030 runs
#      (rendered tfvars), the DSN secret IS 040's slot, the instance
#      connection name is <project>:<region>:<instance>
#   2. DRY_RUN other than 0/1 is refused
#   3. every cloud action's dry run, with gcloud / curl / docker push stubbed
#      to record calls, makes NO gcloud call, NO curl call and NO push/login.
#      CONTROL: the same stub records a call when one is made, so an empty
#      log means "not called", not "not recorded".
#   4. spl_proxy_dsn maps the /cloudsql socket DSN onto the local proxy
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# nokey_app <dir> -> an APP_PATH whose cnf has NO env.gcp.gcp_account_owner_email
# (every other dir symlinked to the real tree): the CONTROL for "no account
# resolves -> refused"; with the real cnf an empty GCP_ACCOUNT resolves from yaml
nokey_app() {
  local d="$1" e; mkdir -p "$d"
  for e in "$APP_ROOT"/*; do [[ "$e" == *-cnf ]] || ln -s "$e" "$d/"; done
  cp -r "$APP_ROOT"/*-cnf "$d/"
  for e in "$d"/*-cnf/*/*.env.yaml; do yq -i 'del(.env.gcp.gcp_account_owner_email)' "$e"; done
}
nokey_app "$T/nokey"

# Stubs: gcloud, curl and cloud-sql-proxy record and fail; docker records,
# refuses login/push, and passes the rest (build, inspect) to the real one.
mkdir -p "$T/stub"
for b in gcloud curl cloud-sql-proxy; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
real_docker=$(command -v docker || echo /bin/false)
printf '#!/bin/sh\ncase "$1" in login|push|run) echo "docker $*" >>"$STUB_LOG"; exit 1;; esac\nexec %s "$@"\n' "$real_docker" >"$T/stub/docker"
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. names come from cnf, one reference each -------------------------------
for ENV in dev prd; do
  export ENV
  out=$(SNIPPET='do_spl_cloud_cnf && printf "%s\n" "$SPL_IMAGE_REF" "$SPL_DSN_SECRET" "$SPL_SQL_CONN" "$SPL_PROJECT"' in_orc 2>&1) ||
    { fail "$ENV do_spl_cloud_cnf: $out"; continue; }
  mapfile -t got <<<"$out"
  tf="$APP_ROOT/csi-spl-cnf/csi-spl/$ENV/tf"
  want_img=$(sed -n 's/^image  *= "\(.*\)"$/\1/p' "$tf/030-cloud-run-hub.vars.tfvars")
  [[ -n "$want_img" && "${got[0]}" == "$want_img" ]] && pass "$ENV pushes the image 030 runs ($want_img)" || fail "$ENV image: action '${got[0]}' vs 030 '$want_img'"
  want_sec=$(sed -n 's/^dsn_secret_id = "\(.*\)"$/\1/p' "$tf/040-cloud-sql-postgres.vars.tfvars")
  [[ "${got[1]}" == "$want_sec" ]] && pass "$ENV DSN secret = 040 slot ($want_sec)" || fail "$ENV DSN secret '${got[1]}' vs 040 '$want_sec'"
  inst=$(sed -n 's/^instance_name = "\(.*\)"$/\1/p' "$tf/040-cloud-sql-postgres.vars.tfvars")
  [[ "${got[2]}" == "csi-spl-$ENV:europe-north1:$inst" ]] && pass "$ENV connection name ${got[2]}" || fail "$ENV connection name '${got[2]}'"
  [[ "${got[3]}" == "csi-spl-$ENV" ]] && pass "$ENV project csi-spl-$ENV" || fail "$ENV project '${got[3]}'"
done

# --- 2. DRY_RUN is 0 or 1 --------------------------------------------------------
export ENV=dev
SNIPPET='spl_dry_run' in_orc DRY_RUN=yes >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "DRY_RUN=yes is refused (rc 2)" || fail "DRY_RUN=yes gave rc $rc"

# DRY_RUN=0 reaches the real-run branch: with no GCP_ACCOUNT (and no cnf
# gcp_account_owner_email) it must stop on exactly that (the regression: `if ! spl_dry_run; then rc=$?` read the
# negated status and returned 1 silently, before any message)
out=$(SNIPPET='do_build_push_hub_image' in_orc DRY_RUN=0 GCP_ACCOUNT= APP_PATH="$T/nokey" 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q 'gcp_account_owner_email' <<<"$out" && ! grep -q 'INFO built' <<<"$out" && pass "DRY_RUN=0 without GCP_ACCOUNT stops on GCP_ACCOUNT" \
  || fail "DRY_RUN=0 without GCP_ACCOUNT: rc=$rc, $(tail -2 <<<"$out" | tr '\n' ' ')"

# --- 3. dry runs touch no cloud ---------------------------------------------------
: >"$T/calls.log"
SNIPPET='gcloud auth print-access-token; curl -s https://example.com; docker push x' in_orc >/dev/null 2>&1
[[ $(wc -l <"$T/calls.log") -eq 3 ]] && pass "control: the stubs record gcloud, curl and docker push" || fail "control: stubs recorded $(wc -l <"$T/calls.log") of 3 calls"

check_dry() { # <label> <snippet> [env...]
  local label="$1" snip="$2"; shift 2
  : >"$T/calls.log"
  out=$(SNIPPET="$snip" in_orc "$@" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then fail "$label dry run exited $rc: $(tail -3 <<<"$out" | tr '\n' ' ')"
  elif [[ -s "$T/calls.log" ]]; then fail "$label dry run made cloud calls: $(tr '\n' ';' <"$T/calls.log")"
  else pass "$label dry run: exit 0, no gcloud / curl / push"; fi
}
if [[ -x "$real_docker" ]] && docker info >/dev/null 2>&1; then
  check_dry "do_build_push_hub_image" 'do_build_push_hub_image'
else
  echo "SKIP: no docker: do_build_push_hub_image"
fi
check_dry "do_export_all_dns_settings" 'do_export_all_dns_settings' ENV=dev
check_dry "do_flush_dns" 'do_flush_dns' TEST_DOMAIN=example.test
for ENV in dev prd; do check_dry "$ENV do_spl_db_bootstrap" 'do_spl_db_bootstrap' ENV=$ENV; done
export ENV=dev

# --- 4. the cloud DSN (040 comment, 030 socket) maps onto the local proxy -------
out=$(SNIPPET='spl_proxy_dsn "postgres://u:p0@/spool?host=/cloudsql/p:r:i" 55499' in_orc 2>&1)
[[ "$out" == "postgres://u:p0@127.0.0.1:55499/spool?sslmode=disable" ]] && pass "spl_proxy_dsn rewrites the socket DSN to 127.0.0.1" \
  || fail "spl_proxy_dsn gave '$out'"
SNIPPET='spl_proxy_dsn "postgres://u:p0@db.example.com/spool" 55499' in_orc >/dev/null 2>&1 \
  && fail "spl_proxy_dsn accepted a non-socket DSN" || pass "spl_proxy_dsn refuses a DSN that is not the /cloudsql socket form"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
