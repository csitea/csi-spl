#!/bin/bash
#------------------------------------------------------------------------------
# @description setup-app-inf: stand up the spool hub's LOCAL dev stack end to
# @description end and smoke it. LOCAL ONLY: no gcloud, no terraform apply, no
# @description cloud credential is read. Per git tree (see do_lde_cnf).
# @description
# @description   1. render compose.env + hub.env from cnf (do_gen_docker_env)
# @description   1b. only with LDE_SPOOL_ROOT=1: make the box's agent spool root
# @description      (do_provision_spool_root; needs its group and sudo). The
# @description      stack itself never uses it (spec 072 A46).
# @description   2. build the hub image IN DOCKER from csi-spl-api's
# @description      hub.Dockerfile (A21), so the host needs no Go and no module
# @description      cache; it bundles the csi-spl-rdb DDL at
# @description      SPOOL_HUB_MIGRATIONS_DIR. The box-side CLI is
# @description      <state>/bin/spool, a wrapper that runs that binary in the
# @description      hub image on the host network (do_lde_cli_wrapper)
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
# @description                  tenant + root-pinned box seeded, `spool
# @description                  hub-sync` -> 0; control: an unpinned box -> 78
# @description BLOCKED = the hub binary on this tree has no such verb yet (the
# @description 003 hub lane ships them); it is reported, never counted green.
# @description
# @description Exit: 0 all PASS; 3 no FAIL but something BLOCKED; 1 a FAIL.
# @description The stack stays up; do_teardown_app_inf stops it.
# @param LDE_PG_PORT / LDE_GCS_PORT / LDE_HUB_PORT (optional) - host port overrides (two trees at once)
# @param SPOOL_HUB_READY_TIMEOUT (optional) - seconds to wait for /healthz, default 30
# @param LDE_SPOOL_ROOT (optional) - 1: also provision the box spool root (agent harness)
# @example ./run -a do_setup_app_inf
# @example   measured 2026-09-18 on tree cle-1037 at 3531034 (hub verbs from
# @example   7905e35), exit 0; n=3: first run, re-run on kept volumes, and after
# @example   LDE_PURGE=1 ./run -a do_teardown_app_inf:
# @example     CHECK    STATUS   DETAIL
# @example     pg       PASS     select 1 = 1; 127.0.0.1:55432 accepts
# @example     gcs      PASS     bucket csi-spl-lde-files -> 200 (127.0.0.1:54443)
# @example     migrate  PASS     2/2 migrations recorded in spool_schema_migrations; re-run no-op
# @example     serve    PASS     GET http://t1.localhost:58080/healthz -> 200
# @example     hello    PASS     hub-sync box-smoke@http://t1.localhost:58080 -> 0 {"delivered":0,"flushed":0,"pending":0,"refused":0}; control: unpinned box -> 78
# @example LDE_PG_PORT=55433 LDE_GCS_PORT=54444 LDE_HUB_PORT=58081 ./run -a do_setup_app_inf
#------------------------------------------------------------------------------
do_setup_app_inf() {
  do_require_bin docker curl yq || return 1
  docker compose version >/dev/null 2>&1 || { do_log "FATAL docker compose (v2) is required"; return 1; }
  do_gen_docker_env || return 1
  if [[ "${LDE_SPOOL_ROOT:-0}" == 1 ]]; then do_provision_spool_root || return 1; fi

  _SAI_RESULTS=() _SAI_SERVE=""
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

# _sai_build -- THE hub image (specs/072 A21), as compose and Cloud Run run it:
# built in Docker from the repo root (hub.Dockerfile: golang build stage, `go
# mod download` inside it), the DDL bundled at SPOOL_HUB_MIGRATIONS_DIR. No
# host Go (A46): the box-side CLI is that image's binary (do_lde_cli_wrapper).
_sai_build() {
  local dockerfile="$APP_PATH/$LDE_ORG_APP-api/src/docker/hub.Dockerfile"
  [[ -f "$dockerfile" ]] || { do_log "FATAL no $dockerfile"; return 1; }
  mkdir -p "$LDE_STATE_DIR/bin" || return 1
  SPL_IMAGE_SQL_SRC="$LDE_SQL_SRC" SPL_MIGRATIONS_DIR="$LDE_MIGRATIONS_DIR" spl_hub_image_matches_cnf "$dockerfile" || return 1
  do_log "INFO building $LDE_HUB_IMAGE in docker from $dockerfile"
  docker build -q --build-arg "SPOOL_COMMIT=$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)" -t "$LDE_HUB_IMAGE" \
    -f "$dockerfile" "$APP_PATH" >/dev/null || { do_log "FATAL hub image build failed"; return 1; }
  _SAI_CLI="$LDE_STATE_DIR/bin/spool"
  do_lde_cli_wrapper "$_SAI_CLI" || return 1
  do_log "INFO built $LDE_HUB_IMAGE ($("$_SAI_CLI" version 2>/dev/null | sed -n 1p))"
}

# do_lde_cli_wrapper <path> -- write the box-side `spool` CLI: it runs the
# static `spool` of the lde hub image (its entrypoint bypassed) on the host
# network, as the caller, with the state dir mounted at the same path and every SPOOL_* variable passed in.
# Go's own resolver (the binary is static) does not map <tenant>.localhost to
# loopback, so the smoke tenant's host and a *.localhost SPOOL_HUB_URL host go
# into the container's /etc/hosts.
do_lde_cli_wrapper() {
  local out="$1"
  cat >"$out" <<WRAP || return 1
#!/usr/bin/env bash
# generated by do_setup_app_inf: the lde spool CLI, run from $LDE_HUB_IMAGE
args=(run --rm -i --network host -u "\$(id -u):\$(id -g)" -e HOME=/tmp -v "$LDE_STATE_DIR:$LDE_STATE_DIR")
hosts=("$LDE_SMOKE_TENANT.localhost")
url_host="\${SPOOL_HUB_URL:-}"; url_host="\${url_host#*://}"; url_host="\${url_host%%[:/]*}"
[[ "\$url_host" == *.localhost ]] && hosts+=("\$url_host")
for h in "\${hosts[@]}"; do args+=(--add-host "\$h:127.0.0.1"); done
while IFS= read -r v; do args+=(-e "\$v"); done < <(compgen -e | grep '^SPOOL_')
exec docker "\${args[@]}" --entrypoint /usr/local/bin/spool "$LDE_HUB_IMAGE" "\$@"
WRAP
  chmod 755 "$out"
}

_sai_check_pg() {
  local in_con host
  in_con=$(lde_compose exec -T pg psql -U "$LDE_PG_USER" -d "$LDE_PG_DB" -Atc 'select 1' 2>&1)
  if [[ "$in_con" != 1 ]]; then _sai_record pg FAIL "select 1 in the container: $in_con"; return; fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$LDE_PG_PORT") 2>/dev/null; then host=open; else host=closed; fi
  [[ "$host" == open ]] && _sai_record pg PASS "select 1 = 1; 127.0.0.1:$LDE_PG_PORT accepts" \
    || _sai_record pg FAIL "127.0.0.1:$LDE_PG_PORT is not reachable"
}

# _sai_check_gcs -> the emulator answers. Polls ~10 s (20 x 0.5 s). Each
# probe is bounded so a stalled handshake cannot hang the loop.
_sai_check_gcs() {
  local base="http://127.0.0.1:$LDE_GCS_PORT/storage/v1" code
  for _ in $(seq 1 20); do
    code=$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "$base/b?project=lde") && [[ "$code" == 200 ]] && break
    sleep 0.5
  done
  [[ "$code" == 200 ]] || { _sai_record gcs FAIL "emulator list buckets -> $code"; return; }
  code=$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"$LDE_FILES_BUCKET\"}" "$base/b?project=lde")
  [[ "$code" == 200 || "$code" == 409 ]] || { _sai_record gcs FAIL "create $LDE_FILES_BUCKET -> $code"; return; }
  code=$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "$base/b/$LDE_FILES_BUCKET")
  [[ "$code" == 200 ]] && _sai_record gcs PASS "bucket $LDE_FILES_BUCKET -> 200 (127.0.0.1:$LDE_GCS_PORT)" \
    || _sai_record gcs FAIL "get $LDE_FILES_BUCKET -> $code"
}

_sai_check_migrate() {
  _sai_has_verb migrate || { _sai_record migrate BLOCKED "spool has no 'migrate' verb on this tree"; return; }
  local out n files
  out=$(lde_compose run --rm --no-deps -T hub migrate 2>&1) || { _sai_record migrate FAIL "first run: $(tail -3 <<<"$out" | tr '\n' ' ')"; return; }
  out=$(lde_compose run --rm --no-deps -T hub migrate 2>&1) || { _sai_record migrate FAIL "re-run is not a no-op: $(tail -3 <<<"$out" | tr '\n' ' ')"; return; }
  # what hub.Dockerfile bundles (spl_hub_image_matches_cnf holds it to cnf sql_src)
  files=$(find "$LDE_SQL_SRC" -maxdepth 1 -name '*.sql' | wc -l)
  n=$(lde_compose exec -T pg psql -U "$LDE_PG_USER" -d "$LDE_PG_DB" -Atc 'select count(*) from spool_schema_migrations' 2>&1)
  [[ "$n" =~ ^[0-9]+$ && "$n" -eq "$files" && "$files" -gt 0 ]] \
    && _sai_record migrate PASS "$n/$files migrations recorded in spool_schema_migrations; re-run no-op" \
    || _sai_record migrate FAIL "spool_schema_migrations holds '$n', $files sql file(s) bundled"
}

_sai_check_serve() {
  _sai_has_verb serve || { _sai_record serve BLOCKED "spool has no 'serve' verb on this tree"; return; }
  lde_compose up -d --no-deps hub >/dev/null 2>&1 || { _sai_record serve FAIL "compose up hub failed"; return; }
  local url="http://$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT/healthz" code=""
  for _ in $(seq 1 $(( ${SPOOL_HUB_READY_TIMEOUT:-30} * 2 ))); do
    code=$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' --resolve "$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT:127.0.0.1" "$url")
    [[ "$code" == 200 ]] && break
    sleep 0.5
  done
  [[ "$code" == 200 ]] && _SAI_SERVE=PASS
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

# The M1 box path over the local WS, with the 003 verbs (CLE-1036, 7905e35):
# the tenant root key and the box key persist in the state dir (so re-runs are
# idempotent against the kept Postgres volume), the tenant row is seeded, the
# box is pinned by the root, and `spool hub-sync` (challenge + hello + pin
# sync + drain + flush) must exit 0. CONTROL: a second box that was never
# pinned must be refused with 78, or the check proves nothing.
_sai_hello_flow() {
  if [[ "$_SAI_SERVE" != PASS ]]; then _sai_record hello BLOCKED "serve is not up"; return; fi
  local h="$LDE_STATE_DIR/hello" box=box-smoke stranger=box-unpinned out rc
  local url="http://$LDE_SMOKE_TENANT.localhost:$LDE_HUB_PORT"
  local dsn="postgres://$LDE_PG_USER:$LDE_PG_PASSWORD@127.0.0.1:$LDE_PG_PORT/$LDE_PG_DB?sslmode=disable"
  mkdir -p "$h" && chmod 700 "$h" || return
  _sai_box() { SPOOL_HUB_URL="$url" SPOOL_BOX_ID="$1" SPOOL_ROOT="$h/spool-$1" SPOOL_KEYS_DIR="$h/keys" "$_SAI_CLI" "${@:2}"; }
  if [[ ! -s "$h/root.pub" ]]; then
    "$_SAI_CLI" root-keygen --out "$h/root.key" >"$h/root.pub" 2>"$h/err" || { _sai_record hello FAIL "root-keygen: $(cat "$h/err")"; return; }
  fi
  local b
  for b in "$box" "$stranger"; do
    [[ -s "$h/$b.pub" ]] || _sai_box "$b" keygen >"$h/$b.pub" 2>"$h/err" || { _sai_record hello FAIL "keygen $b: $(cat "$h/err")"; return; }
  done
  out=$("$_SAI_CLI" hub-tenant --tenant "$LDE_SMOKE_TENANT" --root-pubkey "$(tail -1 "$h/root.pub")" --db "$dsn" 2>&1) ||
    { _sai_record hello FAIL "hub-tenant: $out (a kept pg volume with another root key: LDE_PURGE=1 ./run -a do_teardown_app_inf)"; return; }
  out=$(_sai_box "$box" hub-pin --box "$box" --pubkey "$(tail -1 "$h/$box.pub")" --root-key "$h/root.key" --force 2>&1) ||
    { _sai_record hello FAIL "hub-pin $box: $out"; return; }
  out=$(_sai_box "$stranger" hub-sync 2>&1); rc=$?
  [[ $rc -eq 78 ]] || { _sai_record hello FAIL "control: unpinned $stranger got exit $rc, not 78: $out"; return; }
  out=$(_sai_box "$box" hub-sync 2>&1); rc=$?
  [[ $rc -eq 0 ]] && _sai_record hello PASS "hub-sync $box@$url -> 0 $(tail -1 <<<"$out"); control: unpinned box -> 78" \
    || _sai_record hello FAIL "hub-sync $box -> $rc: $out"
  unset -f _sai_box
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
