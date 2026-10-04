#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the contributor dev stack needs Docker only (spec 072 A46).
#   1. do_setup_app_inf leaves the box spool root alone by default: a group
#      that does not exist and an absent root do not stop it, and the root is
#      not made; control: LDE_SPOOL_ROOT=1 still provisions it
#   2. _sai_build builds the hub image in docker from hub.Dockerfile (A21),
#      with no `go` on PATH, and writes an executable CLI wrapper
#   3. the CLI wrapper runs the lde hub image's `spool` (not its entrypoint)
#      on the host network as the caller, maps the smoke tenant's and SPOOL_HUB_URL's *.localhost host to
#      127.0.0.1 and passes every SPOOL_* variable in
#   4. do_lde_up = setup + WUI with sign-in and the one-shot install on by
#      default (the caller's value wins); a failed setup stops it before the
#      WUI; BLOCKED (3) still brings the WUI up. do_lde_down = teardown
#   5. root docker-compose.yml: SPOOL_PUBLIC_URL follows SPOOL_HTTP_PORT
#      (SKIP without docker compose)
#   6. LIVE, only with LDE_UP_LIVE=1 (docker, minutes): the 072 A46 check --
#      `env -i HOME=<empty> PATH=<no go> ./run -a do_setup_app_inf` -> 0, then
#      do_lde_up -> GET hub /healthz and WUI / both 200, torn down after.
#      LDE_PG_PORT / LDE_GCS_PORT / LDE_HUB_PORT / LDE_WUI_PORT pass through
#      (the cnf defaults 58080 / 3000 when unset), for a box whose main tree
#      already holds them
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" LDE_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. no spool root by default ------------------------------------------------
STUB1='do_require_bin() { :; }; do_gen_docker_env() { :; }; _sai_build() { echo BUILD-REACHED; return 1; }; do_setup_app_inf'
SNIPPET="$STUB1" in_orc SPOOL_ROOT_GROUP=lde-no-such-group-$$ SPOOL_ROOT_DIR="$T/no-root" >"$T/s1.out" 2>&1
grep -q BUILD-REACHED "$T/s1.out" && pass "a missing spool group does not stop do_setup_app_inf" || fail "setup stopped before the build: $(tail -2 "$T/s1.out")"
[[ ! -e "$T/no-root" ]] && pass "the spool root is not created" || fail "the spool root was created"
STUB1C='do_require_bin() { :; }; do_gen_docker_env() { :; }; do_provision_spool_root() { echo PROVISIONED; }; _sai_build() { return 1; }; do_setup_app_inf'
SNIPPET="$STUB1C" in_orc LDE_SPOOL_ROOT=1 >"$T/s1c.out" 2>&1
grep -q PROVISIONED "$T/s1c.out" && pass "control: LDE_SPOOL_ROOT=1 provisions the spool root" || fail "control: LDE_SPOOL_ROOT=1 did not provision"

# --- 2. the hub image is built in docker, no host go -----------------------------
mkdir -p "$T/nogo"
for b in bash env cat cp mkdir rm find wc sed chmod grep tail tr dirname basename yq stat id git dirname; do
  p=$(command -v "$b") && ln -sf "$p" "$T/nogo/$b"
done
printf '#!/bin/sh\necho "$@" >>"%s/docker.args"\n' "$T" >"$T/nogo/docker"
chmod +x "$T/nogo/docker"
SNIPPET='do_lde_cnf >/dev/null && _sai_build && echo BUILT' in_orc PATH="$T/nogo" >"$T/s2.out" 2>&1
if [[ -x "$T/nogo/yq" ]]; then
  grep -q BUILT "$T/s2.out" && pass "_sai_build succeeds with no go on PATH" || fail "_sai_build: $(tail -3 "$T/s2.out")"
  grep -qE "^build -q --build-arg SPOOL_COMMIT=\S* -t \S+ -f $APP_ROOT/csi-spl-api/src/docker/hub.Dockerfile $APP_ROOT\$" "$T/docker.args" \
    && pass "the hub image is built from hub.Dockerfile, context = the checkout" || fail "docker build args: $(head -1 "$T/docker.args" 2>&1)"
  [[ -x "$T/state/bin/spool" ]] && pass "the CLI wrapper is executable" || fail "no executable $T/state/bin/spool"
else
  skip "no yq: _sai_build needs the lde cnf"
fi

# --- 3. the CLI wrapper -------------------------------------------------------------
W="$T/state/bin/spool"
if [[ -x "$W" ]]; then
  : >"$T/docker.args"
  env PATH="$T/nogo" SPOOL_HUB_URL=http://acme.localhost:58080 SPOOL_BOX_ID=box-x "$W" hub-sync --x 1 >/dev/null 2>&1
  a=$(cat "$T/docker.args")
  [[ "$a" == "run --rm -i --network host -u $(id -u):$(id -g) "* ]] && pass "wrapper: host network, as the caller" || fail "wrapper args: $a"
  [[ "$a" == *"--add-host t1.localhost:127.0.0.1"* && "$a" == *"--add-host acme.localhost:127.0.0.1"* ]] \
    && pass "wrapper: the smoke tenant and the SPOOL_HUB_URL host resolve to 127.0.0.1" || fail "wrapper hosts: $a"
  [[ "$a" == *"-e SPOOL_HUB_URL"* && "$a" == *"-e SPOOL_BOX_ID"* && "$a" == *"-v $T/state:$T/state"* ]] \
    && pass "wrapper: SPOOL_* passed in, the state dir mounted at its own path" || fail "wrapper env/mount: $a"
  [[ "$a" == *" --entrypoint /usr/local/bin/spool csi-spl-hub-lde:"*" hub-sync --x 1" ]] && pass "wrapper: the lde hub image's spool runs the verb and its args" || fail "wrapper tail: $a"
else
  skip "no wrapper written (section 2 skipped)"
fi

# --- 4. do_lde_up / do_lde_down -----------------------------------------------------
STUB4='do_setup_app_inf() { echo "SETUP native=$LDE_AUTH_NATIVE install=$LDE_WUI_INSTALL"; return "${SETUP_RC:-0}"; }
  do_wui_up() { echo WUI-UP; }; LDE_WUI_PORT=3000 LDE_SMOKE_TENANT=t1 LDE_HUB_PORT=58080 LDE_COMPOSE_PROJECT=p; do_lde_up'
SNIPPET="$STUB4" in_orc >"$T/s4.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'SETUP native=1 install=1' "$T/s4.out" && grep -q WUI-UP "$T/s4.out" \
  && pass "do_lde_up: setup with sign-in + install on, then the WUI" || fail "do_lde_up rc=$rc: $(tr '\n' ' ' <"$T/s4.out")"
grep -q 'http://localhost:3000/' "$T/s4.out" && grep -q 'sign-in  on' "$T/s4.out" && pass "do_lde_up prints the WUI URL and sign-in on" || fail "do_lde_up summary"
SNIPPET="$STUB4" in_orc LDE_AUTH_NATIVE=0 LDE_WUI_INSTALL=0 >"$T/s4b.out" 2>&1
grep -q 'SETUP native=0 install=0' "$T/s4b.out" && grep -q 'sign-in  off' "$T/s4b.out" && pass "the caller's LDE_AUTH_NATIVE=0 / LDE_WUI_INSTALL=0 win" || fail "override: $(head -1 "$T/s4b.out")"
SNIPPET="$STUB4" in_orc SETUP_RC=1 >"$T/s4c.out" 2>&1 && fail "a failed setup returned 0" \
  || { grep -q WUI-UP "$T/s4c.out" && fail "the WUI came up after a failed setup" || pass "a failed setup stops do_lde_up before the WUI"; }
SNIPPET="$STUB4" in_orc SETUP_RC=3 >"$T/s4d.out" 2>&1 && grep -q WUI-UP "$T/s4d.out" && grep -q BLOCKED "$T/s4d.out" \
  && pass "setup BLOCKED (3): WARN, the WUI still comes up" || fail "BLOCKED: $(tr '\n' ' ' <"$T/s4d.out")"
SNIPPET='do_teardown_app_inf() { echo "TEARDOWN purge=${LDE_PURGE:-0}"; }; do_lde_down' in_orc LDE_PURGE=1 >"$T/s4e.out" 2>&1
grep -qx 'TEARDOWN purge=1' "$T/s4e.out" && pass "do_lde_down = do_teardown_app_inf (LDE_PURGE passes through)" || fail "do_lde_down: $(cat "$T/s4e.out")"

# --- 5. root compose: the public URL follows the port --------------------------------
if docker compose version >/dev/null 2>&1; then
  cfg=$(cd "$APP_ROOT" && SPOOL_HTTP_PORT=18580 SPOOL_PUBLIC_URL='' docker compose --env-file /dev/null -f docker-compose.yml config 2>&1)
  n=$(grep -c 'localhost:18580' <<<"$cfg"); o=$(grep -c 'localhost:8080' <<<"$cfg")
  (( n >= 5 && o == 0 )) && pass "SPOOL_HTTP_PORT=18580: $n x localhost:18580, 0 x localhost:8080" || fail "SPOOL_HTTP_PORT=18580: $n x 18580, $o x 8080"
  cfg=$(cd "$APP_ROOT" && SPOOL_HTTP_PORT='' SPOOL_PUBLIC_URL='' docker compose --env-file /dev/null -f docker-compose.yml config 2>&1)
  (( $(grep -c 'localhost:8080' <<<"$cfg") >= 5 )) && pass "control: no SPOOL_HTTP_PORT keeps localhost:8080" || fail "control: default port lost"
else
  skip "no docker compose"
fi

# --- 6. LIVE: the 072 A46 acceptance check ---------------------------------------------
if [[ "${LDE_UP_LIVE:-0}" == 1 ]]; then
  H=$(mktemp -d) P=/usr/local/bin:/usr/bin:/bin ports=()
  for v in LDE_PG_PORT LDE_GCS_PORT LDE_HUB_PORT LDE_WUI_PORT; do [[ -n "${!v:-}" ]] && ports+=("$v=${!v}"); done
  hp=${LDE_HUB_PORT:-58080} wp=${LDE_WUI_PORT:-3000}
  [[ -z "$(PATH=$P command -v go)" ]] || { mkdir -p "$T/p"; for d in ${P//:/ }; do for f in "$d"/*; do [[ "$(basename "$f")" == go ]] || ln -sf "$f" "$T/p/" 2>/dev/null; done; done; P="$T/p"; }
  (cd "$PROJ_ROOT" && env -i HOME="$H" PATH="$P" "${ports[@]}" ./run -a do_setup_app_inf) >"$T/live1.out" 2>&1; rc=$?
  [[ $rc -eq 0 ]] && pass "LIVE: env -i HOME=<empty> PATH=<no go> do_setup_app_inf -> 0" || fail "LIVE setup rc=$rc: $(tail -8 "$T/live1.out")"
  (cd "$PROJ_ROOT" && env -i HOME="$H" PATH="$P" "${ports[@]}" ./run -a do_lde_up) >"$T/live2.out" 2>&1; rc=$?
  hub=$(curl -s -o /dev/null -w '%{http_code}' --resolve "t1.localhost:$hp:127.0.0.1" "http://t1.localhost:$hp/healthz")
  wui=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$wp/")
  [[ $rc -eq 0 && $hub == 200 && $wui == 200 ]] && pass "LIVE: do_lde_up -> :$hp/healthz $hub, :$wp/ $wui" || fail "LIVE lde_up rc=$rc hub=$hub wui=$wui: $(tail -8 "$T/live2.out")"
  (cd "$PROJ_ROOT" && env -i HOME="$H" PATH="$P" "${ports[@]}" LDE_PURGE=1 ./run -a do_lde_down) >/dev/null 2>&1
  rm -rf "$H"
else
  # INFO, not SKIP: CI fails any SKIP outside the two root-only lines, and
  # this opt-in block is minutes of docker the hermetic job does not run.
  echo "INFO: LIVE acceptance not run (set LDE_UP_LIVE=1)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
