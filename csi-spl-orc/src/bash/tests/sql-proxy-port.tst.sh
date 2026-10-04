#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_sql_proxy_start never reports "up" through ANOTHER run's proxy.
#   1. RACE: the port is free at the check, then a decoy listener takes it and
#      our proxy dies on bind -> rc != 0 and a FATAL, never "proxy up" (the
#      2026-10-04 defect: the wait saw the other run's listener, and psql met
#      the other env's instance: password authentication failed). Binary path
#      and docker path.
#   2. SPL_PROXY_PORT unset -> a free port that is not the fixed 55499, and
#      the proxy is started on exactly that port.
#   3. an explicit SPL_PROXY_PORT already in use -> the existing FATAL, and no
#      proxy is started.
# No GCP, no docker, no network beyond 127.0.0.1: gcloud, cloud-sql-proxy and
# docker are stubs.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
trap 'for p in "$T"/*.pid; do [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null; done; rm -rf "$T"' EXIT

# listen.py <port> <pidfile>: a bare TCP listener on 127.0.0.1:<port> for 60 s
cat >"$T/listen.py" <<'PY'
import os, socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen()
open(sys.argv[2], "w").write(str(os.getpid()))
time.sleep(60)
PY
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
# wait_listen <pidfile> <port>: the stubs start the decoy asynchronously, so
# wait until it wrote its pidfile AND accepts on <port>; 0 within 5 s, else 1.
wait_listen() {
  for _ in $(seq 1 100); do
    [[ -f "$1" ]] && (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# Stubs. cloud-sql-proxy records its argv; FAKE_PROXY=race starts a decoy on
# --port a moment later (another run winning the port) and dies like a failed
# bind, FAKE_PROXY=listen is a healthy proxy listening on --port. docker run
# does the same race and inspect says the container is not running.
mkdir -p "$T/stub" "$T/dstub" "$T/state"
cat >"$T/stub/cloud-sql-proxy" <<'SH'
#!/usr/bin/env bash
echo "cloud-sql-proxy $*" >>"$STUB_LOG"
while [[ $# -gt 0 ]]; do [[ "$1" == --port ]] && port="$2"; shift; done
case "$FAKE_PROXY" in
  race) (sleep 0.3; exec python3 "$T/listen.py" "$port" "$T/decoy.pid") >/dev/null 2>&1 &
        echo "bind: address already in use"; exit 1 ;;
  listen) exec python3 "$T/listen.py" "$port" "$T/proxy.pid" ;;
esac
SH
cat >"$T/dstub/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >>"$STUB_LOG"
case "$1" in
  run) port=""; while [[ $# -gt 0 ]]; do [[ "$1" == --port ]] && port="$2"; shift; done
       (sleep 0.3; exec python3 "$T/listen.py" "$port" "$T/decoy.pid") >/dev/null 2>&1 &
       echo cafe; exit 0 ;;
  inspect) echo false; exit 0 ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\necho tok\n' >"$T/stub/gcloud"
cp "$T/stub/gcloud" "$T/dstub/gcloud"
chmod +x "$T/stub/"* "$T/dstub/"*

# start [VAR=value]... - spl-cloud-cnf sourced in a fresh bash, then
# spl_sql_proxy_start; prints its log and "RC=<rc> PORT=<port>".
start() {
  env T="$T" STUB_LOG="$T/calls.log" SPL_STATE_DIR="$T/state" PATH="$T/stub:$PATH" \
    GCP_ACCOUNT=sa@example.com SPL_SQL_CONN=p:r:i SPL_ORG_APP=csi-spl ENV=dev SPL_SQL_PROXY_IMAGE=img "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
    spl_sql_proxy_start; rc=$?
    echo "RC=$rc PORT=$SPL_PROXY_PORT"
    spl_sql_proxy_stop'
}
export PROJ_ROOT
reset() { for p in "$T"/*.pid; do [[ -f "$p" ]] && { kill "$(cat "$p")" 2>/dev/null; rm -f "$p"; }; done; : >"$T/calls.log"; sleep 0.2; }

# --- 1. race: our proxy died, someone else listens -> refused ---------------
reset; port=$(free_port)
out=$(start FAKE_PROXY=race SPL_PROXY_PORT="$port" 2>&1)
wait_listen "$T/decoy.pid" "$port" && pass "control: the decoy took 127.0.0.1:$port after the free check" || fail "control: no decoy listened on $port"
if grep -q "RC=0" <<<"$out" || grep -q "proxy up" <<<"$out"; then
  fail "race (binary): reported up through another run's listener: $(tr '\n' ' ' <<<"$out")"
else
  grep -q FATAL <<<"$out" && pass "race (binary): our proxy died -> FATAL, rc != 0" || fail "race (binary): no FATAL: $out"
fi
grep -q "address already in use" <<<"$out" && pass "race (binary): the FATAL carries the proxy log tail" || fail "race (binary): no proxy log tail in: $(tr '\n' ' ' <<<"$out")"

# the docker path: PATH without the host's cloud-sql-proxy, so docker runs it
reset; port=$(free_port)
out=$(start SPL_PROXY_PORT="$port" PATH="$T/dstub:/usr/bin:/bin" 2>&1)
grep -q "^docker run" "$T/calls.log" && pass "control: the docker path ran" || fail "control: docker path not taken: $(cat "$T/calls.log")"
if grep -q "RC=0" <<<"$out" || grep -q "proxy up" <<<"$out"; then
  fail "race (docker): reported up through another run's listener: $(tr '\n' ' ' <<<"$out")"
else
  grep -q FATAL <<<"$out" && pass "race (docker): our container is not running -> FATAL, rc != 0" || fail "race (docker): no FATAL: $out"
fi

# --- 2. unset port -> a free port, not 55499 ---------------------------------
reset
out=$(start FAKE_PROXY=listen 2>&1)
got=$(sed -n 's/^RC=0 PORT=\([0-9]*\)$/\1/p' <<<"$out")
if [[ -n "$got" && "$got" != 55499 ]]; then pass "unset SPL_PROXY_PORT: up on free port $got, not 55499"
else fail "unset SPL_PROXY_PORT: $(tr '\n' ' ' <<<"$out")"; fi
grep -q -- "--port $got " "$T/calls.log" && pass "the proxy was started on that port" || fail "proxy argv: $(cat "$T/calls.log")"

# --- 3. explicit port in use -> the existing FATAL ---------------------------
reset; port=$(free_port)
python3 "$T/listen.py" "$port" "$T/busy.pid" & for _ in $(seq 1 50); do [[ -f "$T/busy.pid" ]] && break; sleep 0.1; done
out=$(start FAKE_PROXY=listen SPL_PROXY_PORT="$port" 2>&1)
grep -q "FATAL 127.0.0.1:$port is already in use" <<<"$out" && grep -q "RC=1" <<<"$out" \
  && pass "explicit SPL_PROXY_PORT in use: the existing FATAL" || fail "explicit port in use: $(tr '\n' ' ' <<<"$out")"
grep -q cloud-sql-proxy "$T/calls.log" && fail "explicit port in use: a proxy was started anyway" || pass "explicit port in use: no proxy started"

reset
[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
