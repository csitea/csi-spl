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
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

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

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
