#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the local stack is wired from cnf and only from cnf, and its smoke
#          cannot report a missing verb as present.
#   1. do_gen_docker_env renders hub.env whose KEYS are exactly the hub env
#      names published in all.env.yaml env.hub.env (+ the lde-only ones) --
#      it renames and invents nothing -- with lde values (pg/gcs services,
#      {tenant}.localhost)
#   2. docker compose accepts the three files with the rendered env, and
#      every published port binds 127.0.0.1 only (SKIP without docker)
#   4. _sai_has_verb: a spool that says `unknown command` is NOT a verb, under
#      pipefail (the regression that reported a missing `serve` as present);
#      control: a known verb is one
#   5. do_provision_spool_root on a scratch dir: sticky cleared, setgid on,
#      default ACL rwx, a subdir made later inherits it (SKIP without sudo -n)
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

# --- 1. hub.env = the published names, lde values ------------------------------
SNIPPET='do_gen_docker_env' in_orc >"$T/gen.out" 2>&1 || { fail "do_gen_docker_env: $(tail -3 "$T/gen.out")"; }
H="$T/state/hub.env"
if [[ -f "$H" ]]; then
  want=$( (yq -r '.env.hub.env | keys | .[]' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
           yq -r '.env.hub.env | keys | .[]' "$APP_ROOT/csi-spl-cnf/csi-spl/lde.env.yaml") | sort -u)
  got=$(cut -d= -f1 "$H" | sort -u)
  [[ "$want" == "$got" ]] && pass "hub.env keys = all.env.yaml + lde.env.yaml hub.env keys ($(wc -l <<<"$got"))" \
    || fail "hub.env keys differ from cnf: $(diff <(echo "$want") <(echo "$got") | grep '^[<>]' | tr '\n' ' ')"
  grep -qx 'SPOOL_HUB_ENV=lde' "$H" && pass "SPOOL_HUB_ENV=lde" || fail "SPOOL_HUB_ENV is not lde"
  grep -q '^SPOOL_HUB_DB_DSN=postgres://[^@]*@pg:5432/' "$H" && pass "DSN points at the pg service" || fail "DSN does not point at pg:5432"
  grep -qx 'STORAGE_EMULATOR_HOST=gcs:4443' "$H" && pass "GCS emulator host is the gcs service" || fail "STORAGE_EMULATOR_HOST"
  grep -qx 'SPOOL_HUB_TENANT_HOST_PATTERN={tenant}.localhost' "$H" && pass "tenant host pattern {tenant}.localhost" || fail "tenant host pattern"
  [[ "$(stat -c %a "$H")" == 600 ]] && pass "hub.env is 0600" || fail "hub.env mode $(stat -c %a "$H")"
else
  fail "no hub.env rendered"
fi

# --- 2+3. compose accepts the files; every published port is loopback -------------
if docker compose version >/dev/null 2>&1 && [[ -f "$T/state/compose.env" ]]; then
  if docker compose -p lde-test --env-file "$T/state/compose.env" -f "$PROJ_ROOT/src/docker/docker-compose-infra.yaml" \
      -f "$PROJ_ROOT/src/docker/docker-compose-rdb.yaml" -f "$PROJ_ROOT/src/docker/docker-compose-api.yaml" \
      config --format json >"$T/cfg.json" 2>"$T/cfg.err"; then
    pass "docker compose config accepts the 3 files"
    ips=$(yq -p json -r '.services[].ports[]?.host_ip' "$T/cfg.json" | sort | uniq -c | xargs)
    [[ "$ips" == "3 127.0.0.1" ]] && pass "all 3 published ports bind 127.0.0.1" || fail "published host_ip: $ips"
  else
    fail "compose config: $(head -3 "$T/cfg.err")"
  fi
else
  skip "no docker compose"
fi

# --- 4. verb detection under pipefail ------------------------------------------------
printf '#!/bin/sh\n[ "$1" = migrate ] && { echo "Usage of migrate:"; exit 0; }\necho "unknown command \\"$1\\""; exit 1\n' >"$T/spool"
chmod +x "$T/spool"
SNIPPET='_SAI_CLI='"$T/spool"'; _sai_has_verb serve && echo HAS-serve; _sai_has_verb migrate && echo HAS-migrate' in_orc >"$T/verb.out" 2>&1
grep -q HAS-serve "$T/verb.out" && fail "an unknown verb (serve) was detected as present" || pass "an 'unknown command' verb is not present (pipefail on)"
grep -q HAS-migrate "$T/verb.out" && pass "control: a known verb (migrate) is present" || fail "control: migrate not detected"

# --- 5. spool root permissions model ---------------------------------------------------
if sudo -n true 2>/dev/null && command -v setfacl >/dev/null; then
  d="$T/spool-root"; mkdir -p "$d"; chmod 1777 "$d"
  SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$d" >"$T/prov.out" 2>&1; rc=$?
  if [[ $rc -eq 0 && ! -k "$d" && -g "$d" ]]; then pass "sticky cleared, setgid set"; else fail "provision rc=$rc sticky=$([[ -k $d ]] && echo y) $(tail -2 "$T/prov.out")"; fi
  (umask 077; mkdir "$d/inbox"; echo x >"$d/inbox/m")
  getfacl -p "$d/inbox/m" 2>/dev/null | grep -q '^other::rw' && pass "a file made later under umask 077 is still other-rw (default ACL)" \
    || fail "default ACL not inherited: $(getfacl -p "$d/inbox/m" 2>/dev/null | grep other)"
  sudo -n rm -rf "$d"
else
  skip "no passwordless sudo / setfacl"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
