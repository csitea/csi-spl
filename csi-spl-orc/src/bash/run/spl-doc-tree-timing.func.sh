#!/bin/bash
# The dedicated timing run of spec 113 T002 (section 3.5, "Timing of the real
# ops"). wf 10 runs TestWorkspaceDocTiming inside the shared store suite (go
# test -race, every package's DB tests on one Postgres, a loaded runner) and
# only PRINTS it there: run 37928804138 measured the 11,111 delete at 92.8 ms
# in that suite against 13.6..24.1 ms on a quieter box. The ceilings are
# enforced HERE, where the test runs alone.

#------------------------------------------------------------------------------
# @description Run TestWorkspaceDocTiming alone with its ceilings ENFORCED
# @description (SPOOL_TEST_WSDOC_TIMING_GATE=1): no -race, no other test, no
# @description other package, on a throwaway postgres:16-alpine container
# @description (removed either way) unless TIMING_PG_DSN names a database.
# @description It prints the sha, the box, its load and CPU count first, then
# @description the test's table (median, max and ceiling per op), and exits
# @description with the test's exit code: 0 = every gated median is under
# @description its ceiling.
# @param WSDOC_TIMING_CEILINGS (optional) - "<case>=<ms>,..." over the defaults
# @param   (11111-fanout10=50; 1x1000 and 1x10000 printed only). The control:
# @param   a ceiling below its measured median must exit non-zero.
# @param WSDOC_TIMING_N (optional) - reps per op, default 5
# @param TIMING_PG_DSN (optional) - an existing test database (non-superuser
# @param   owner, so RLS binds); default: a throwaway container
# @param SPL_TIMING_IMAGE (optional) - default postgres:16-alpine
# @example ./run -a do_spl_doc_tree_timing
# @example WSDOC_TIMING_CEILINGS=11111-fanout10=1 ./run -a do_spl_doc_tree_timing
#------------------------------------------------------------------------------
do_spl_doc_tree_timing() {
  local mod="${APP_PATH:?APP_PATH must be set}/csi-spl-api/src/go/spool-hub-api"
  if ! command -v go >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$APP_PATH/csi-spl-api/src/bash/use-go-toolchain.sh"
    if ! spl_export_go_path; then
      do_log "FATAL no go toolchain on PATH or under /usr/local"
      return 1
    fi
  fi
  # go is found above (PATH, else the toolchain selector) and is not listed
  # below: it is a dev/CI tool, not one the box user's verify checks
  # (satellite-ansible.tst.sh case 8 reads the required-tool lists).
  do_require_bin docker || return 1
  # Sourced BEFORE the RETURN trap below: a finished `source` fires a RETURN
  # trap too, which removed the container before the go test ran.
  # The fleet's desk box id (specs/058), not hostname: hosts may share one.
  # shellcheck source=../../../lib/bash/funcs/spl-desk-box.func.sh
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"

  local dsn="${TIMING_PG_DSN:-}" con=""
  if [[ -z "$dsn" ]]; then
    con="spl-doc-timing-$$"
    # shellcheck disable=SC2064
    trap "docker rm -fv '$con' >/dev/null 2>&1 || true; trap - RETURN" RETURN
    dsn="$(spl_doc_timing_pg "$con")" || return 1
  fi

  local sha load box rc=0
  sha="$(git -C "$mod" rev-parse --short=9 HEAD 2>/dev/null || echo unknown)"
  box="$(spl_desk_box_default)"
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"
  do_log "INFO doc tree timing: sha=$sha box=$box load=$load cpus=$(nproc) n=${WSDOC_TIMING_N:-5} ceilings=${WSDOC_TIMING_CEILINGS:-default}"
  (cd "$mod" && SPOOL_TEST_PG_DSN="$dsn" SPOOL_TEST_WSDOC_TIMING_GATE=1 \
    SPOOL_TEST_WSDOC_TIMING_CEILINGS="${WSDOC_TIMING_CEILINGS:-}" \
    SPOOL_TEST_WSDOC_TIMING_N="${WSDOC_TIMING_N:-5}" \
    go test -count=1 -run '^TestWorkspaceDocTiming$' -v ./internal/store/) || rc=$?
  if ((rc == 0)); then
    do_log "INFO doc tree timing: sha=$sha every gated median under its ceiling, exit 0"
  else
    do_log "FATAL doc tree timing: sha=$sha exit $rc (a median over its ceiling, or the run failed)"
  fi
  return $rc
}

# spl_doc_timing_pg <container> -> the DSN of a fresh database on a throwaway
# postgres container, owned by a NOSUPERUSER NOBYPASSRLS login (so RLS binds,
# as in hub-pg.tst.sh). Readiness is a real query over TCP: the image's
# initdb server answers on the unix socket only (spl-db-backup-verify). It is
# called in $(...), so its log lines go to stderr, never into the DSN.
spl_doc_timing_pg() {
  local con="$1" img="${SPL_TIMING_IMAGE:-postgres:16-alpine}" pw i port
  pw="t$RANDOM$RANDOM$$"
  docker run -d --rm --pull never --name "$con" -e POSTGRES_PASSWORD="$pw" -p 127.0.0.1::5432 \
    "$img" >/dev/null 2>&1 || { do_log "FATAL cannot start $img for the timing run" >&2; return 1; }
  for i in {1..60}; do
    if docker exec "$con" psql -U postgres -h 127.0.0.1 -XAtc 'SELECT 1' >/dev/null 2>&1; then
      break
    fi
    ((i == 60)) && { do_log "FATAL the timing postgres was not ready after 60 s" >&2; return 1; }
    sleep 1
  done
  docker exec "$con" psql -U postgres -h 127.0.0.1 -v ON_ERROR_STOP=1 -q \
    -c "CREATE ROLE spool_app LOGIN PASSWORD '$pw' NOSUPERUSER NOBYPASSRLS CREATEROLE" \
    -c "CREATE DATABASE spool_hub_app OWNER spool_app" >/dev/null 2>&1 ||
    { do_log "FATAL cannot create the timing database" >&2; return 1; }
  port="$(docker port "$con" 5432 | sed -n 1p)"
  port="${port##*:}"
  [[ "$port" =~ ^[0-9]+$ ]] || { do_log "FATAL no published port for $con" >&2; return 1; }
  printf 'postgres://spool_app:%s@127.0.0.1:%s/spool_hub_app?sslmode=disable' "$pw" "$port"
}
