#!/bin/bash
#------------------------------------------------------------------------------
# @description setup-app-inf: stand up the spool hub's LOCAL dev stack end to
# @description end and smoke it. LOCAL ONLY: no gcloud, no terraform apply, no
# @description cloud credential is read. Per git tree (see do_lde_cnf).
# @description
# @description   1. render compose.env + hub.env from cnf (do_gen_docker_env)
# @description   1b. make the box spool root (do_provision_spool_root)
# @description   2. build `spool` from csi-spl-api (static, for the image; and a
# @description      host build for the box-side CLI) and the hub image, which
# @description      bundles the csi-spl-rdb DDL at SPOOL_HUB_MIGRATIONS_DIR
# @description   3. compose up Postgres + the GCS emulator (fake-gcs-server)
# @description   4. smoke, each check PASS / FAIL / BLOCKED:
# @description        pg        pg_isready + `select 1`, in the container and
# @description                  over 127.0.0.1:<pg port>
# @description        gcs       the files bucket exists in the emulator
# @description        migrate   `spool migrate` twice (second is a no-op), rows
# @description                  in spool_schema_migrations
# @description        serve     `spool serve` up, GET /healthz -> 200 via the
# @description                  tenant host <tenant>.localhost
# @description        hello     a box `spool` CLI syncs over the local WS:
# @description                  tenant + pinned box seeded, `spool hub-sync` -> 0
# @description BLOCKED = the hub binary on this tree has no such verb yet (the
# @description 003 hub lane ships them); it is reported, never counted green.
# @description
# @description Exit: 0 all PASS; 3 no FAIL but something BLOCKED; 1 a FAIL.
# @description The stack stays up; do_teardown_app_inf stops it.
# @param LDE_PG_PORT / LDE_GCS_PORT / LDE_HUB_PORT (optional) - host port overrides (two trees at once)
# @param SPOOL_HUB_READY_TIMEOUT (optional) - seconds to wait for /healthz, default 30
# @example ./run -a do_setup_app_inf
# @example   measured 2026-09-18 on tree cle-1037 at 81121a0 + this change
# @example   (hub has `migrate`, not yet `serve`/`hub-*`), exit 3:
# @example     CHECK    STATUS   DETAIL
# @example     pg       PASS     select 1 = 1; 127.0.0.1:55432 accepts
# @example     gcs      PASS     bucket csi-spl-lde-files -> 200 (127.0.0.1:54443)
# @example     migrate  PASS     2/2 migrations recorded in spool_schema_migrations; re-run no-op
# @example     serve    BLOCKED  spool has no 'serve' verb on this tree
# @example     hello    BLOCKED  spool has no 'hub-tenant hub-pin hub-sync' verb(s) on this tree
# @example LDE_PG_PORT=55433 LDE_GCS_PORT=54444 LDE_HUB_PORT=58081 ./run -a do_setup_app_inf
#------------------------------------------------------------------------------
do_setup_app_inf() {
  do_require_bin docker curl yq || return 1
  docker compose version >/dev/null 2>&1 || { do_log "FATAL docker compose (v2) is required"; return 1; }
  do_gen_docker_env || return 1
  do_provision_spool_root || return 1

  _SAI_RESULTS=()
  _sai_build || return 1

  do_log "INFO compose up pg + gcs ($LDE_COMPOSE_PROJECT)"
  lde_compose up -d --wait pg gcs >/dev/null 2>&1 || {
    lde_compose ps; do_log "FATAL pg/gcs did not come up"; return 1; }

  _sai_check_pg
  _sai_check_gcs
  _sai_check_migrate
  _sai_check_serve
  _sai_check_hello
  _sai_report
}

# _sai_record <check> <PASS|FAIL|BLOCKED> <detail>
_sai_record() {
  _SAI_RESULTS+=("$1|$2|$3")
  case "$2" in
    PASS) do_log "OK $1: $3" ;;
    BLOCKED) do_log "WARN $1 BLOCKED: $3" ;;
    *) do_log "ERROR $1 FAILED: $3" ;;
  esac
}

# _sai_has_verb <verb> -- the host-built spool knows the verb. The output is
# captured first: under pipefail `spool x --help | grep` carries spool's own
# exit status, which inverted this test.
_sai_has_verb() {
  local out
  out=$("$_SAI_CLI" "$1" --help 2>&1)
  [[ "$out" != "unknown command"* ]]
}

_sai_build() {
  local build="$APP_PATH/$LDE_ORG_APP-api/src/bash/build.sh" ctx="$LDE_STATE_DIR/hub-ctx"
  [[ -f "$build" ]] || { do_log "FATAL no $build"; return 1; }
  rm -rf "$ctx" && mkdir -p "$ctx/sql" "$LDE_STATE_DIR/bin" || return 1
  # static for the distroless image; the host CLI keeps cgo, so Go resolves
  # <tenant>.localhost through nss (the pure-Go resolver asks DNS and fails)
  CGO_ENABLED=0 bash "$build" "$ctx/spool" >/dev/null || { do_log "FATAL static spool build failed"; return 1; }
  bash "$build" "$LDE_STATE_DIR/bin/spool" >/dev/null || { do_log "FATAL host spool build failed"; return 1; }
  _SAI_CLI="$LDE_STATE_DIR/bin/spool"
  if [[ -d "$LDE_SQL_SRC" ]]; then
    cp -p "$LDE_SQL_SRC"/*.sql "$ctx/sql/" 2>/dev/null || true
  fi
  do_log "INFO bundling $(find "$ctx/sql" -name '*.sql' | wc -l) sql file(s) from $LDE_SQL_SRC"
  docker build -q --build-arg "MIGRATIONS_DIR=$LDE_MIGRATIONS_DIR" -t "$LDE_HUB_IMAGE" \
    -f "$LDE_DOCKER_DIR/spool-hub-api/Dockerfile" "$ctx" >/dev/null || { do_log "FATAL hub image build failed"; return 1; }
  do_log "INFO built $LDE_HUB_IMAGE ($("$_SAI_CLI" version 2>/dev/null | head -1))"
}

_sai_check_pg() {
  local in_con host
  in_con=$(lde_compose exec -T pg psql -U "$LDE_PG_USER" -d "$LDE_PG_DB" -Atc 'select 1' 2>&1)
  if [[ "$in_con" != 1 ]]; then _sai_record pg FAIL "select 1 in the container: $in_con"; return; fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$LDE_PG_PORT") 2>/dev/null; then host=open; else host=closed; fi
  [[ "$host" == open ]] && _sai_record pg PASS "select 1 = 1; 127.0.0.1:$LDE_PG_PORT accepts" \
    || _sai_record pg FAIL "127.0.0.1:$LDE_PG_PORT is not reachable"
}

_sai_check_gcs() {
  local base="http://127.0.0.1:$LDE_GCS_PORT/storage/v1" code i
  for i in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$base/b?project=lde") && [[ "$code" == 200 ]] && break
    sleep 0.5
  done
  [[ "$code" == 200 ]] || { _sai_record gcs FAIL "emulator list buckets -> $code"; return; }
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"$LDE_FILES_BUCKET\"}" "$base/b?project=lde")
  [[ "$code" == 200 || "$code" == 409 ]] || { _sai_record gcs FAIL "create $LDE_FILES_BUCKET -> $code"; return; }
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/b/$LDE_FILES_BUCKET")
  [[ "$code" == 200 ]] && _sai_record gcs PASS "bucket $LDE_FILES_BUCKET -> 200 (127.0.0.1:$LDE_GCS_PORT)" \
    || _sai_record gcs FAIL "get $LDE_FILES_BUCKET -> $code"
}

_sai_check_migrate() {
  _sai_has_verb migrate || { _sai_record migrate BLOCKED "spool has no 'migrate' verb on this tree"; return; }
  local out n files
  out=$(lde_compose run --rm --no-deps -T hub migrate 2>&1) || { _sai_record migrate FAIL "first run: $(tail -3 <<<"$out" | tr '\n' ' ')"; return; }
  out=$(lde_compose run --rm --no-deps -T hub migrate 2>&1) || { _sai_record migrate FAIL "re-run is not a no-op: $(tail -3 <<<"$out" | tr '\n' ' ')"; return; }
  files=$(find "$LDE_STATE_DIR/hub-ctx/sql" -name '*.sql' | wc -l)
  n=$(lde_compose exec -T pg psql -U "$LDE_PG_USER" -d "$LDE_PG_DB" -Atc 'select count(*) from spool_schema_migrations' 2>&1)
  [[ "$n" =~ ^[0-9]+$ && "$n" -eq "$files" && "$files" -gt 0 ]] \
    && _sai_record migrate PASS "$n/$files migrations recorded in spool_schema_migrations; re-run no-op" \
    || _sai_record migrate FAIL "spool_schema_migrations holds '$n', $files sql file(s) bundled"
}

_sai_check_serve() {
  _sai_has_verb serve || { _sai_record serve BLOCKED "spool has no 'serve' verb on this tree"; return; }
  lde_compose up -d --no-deps hub >/dev/null 2>&1 || { _sai_record serve FAIL "compose up hub failed"; return; }
  local url="http://$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT/healthz" code="" t
  for t in $(seq 1 $(( ${SPOOL_HUB_READY_TIMEOUT:-30} * 2 ))); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT:127.0.0.1" "$url")
    [[ "$code" == 200 ]] && break
    sleep 0.5
  done
  [[ "$code" == 200 ]] && _sai_record serve PASS "GET $url -> 200" \
    || _sai_record serve FAIL "GET $url -> ${code:-none}; $(lde_compose logs --tail 5 hub 2>&1 | tr '\n' ' ')"
}

# The box side of M1 over the local WS: a tenant with a root key, one box
# pinned under it by the root, then `spool hub-sync` (challenge + hello +
# pin sync + drain + flush) exits 0. Verbs per the 003 hub lane (CLE-1036).
_sai_check_hello() {
  local v missing=()
  for v in hub-tenant hub-pin hub-sync; do _sai_has_verb "$v" || missing+=("$v"); done
  if (( ${#missing[@]} )); then _sai_record hello BLOCKED "spool has no '${missing[*]}' verb(s) on this tree"; return; fi
  _sai_hello_flow
}

# Filled in against the 003 verbs' final flags once they are on master; until
# then a tree that has the verbs but not this flow reports BLOCKED, not PASS.
_sai_hello_flow() {
  _sai_record hello BLOCKED "hub-tenant/hub-pin/hub-sync exist; the orc hello flow for them is not written yet"
}

_sai_report() {
  local r name st detail fails=0 blocked=0
  printf '\n  %-8s %-8s %s\n' CHECK STATUS DETAIL
  for r in "${_SAI_RESULTS[@]}"; do
    IFS='|' read -r name st detail <<<"$r"
    printf '  %-8s %-8s %s\n' "$name" "$st" "$detail"
    [[ "$st" == FAIL ]] && fails=$((fails + 1))
    [[ "$st" == BLOCKED ]] && blocked=$((blocked + 1))
  done
  printf '\n  hub     http://%s.localhost:%s   pg 127.0.0.1:%s   gcs http://127.0.0.1:%s   (project %s)\n\n' \
    "$LDE_SMOKE_TENANT" "$LDE_HUB_PORT" "$LDE_PG_PORT" "$LDE_GCS_PORT" "$LDE_COMPOSE_PROJECT"
  (( fails )) && { do_log "ERROR setup-app-inf: $fails FAIL, $blocked BLOCKED"; return 1; }
  (( blocked )) && { do_log "WARN setup-app-inf: all runnable checks PASS, $blocked BLOCKED (not green)"; return 3; }
  do_log "OK setup-app-inf: all ${#_SAI_RESULTS[@]} checks PASS"
}
