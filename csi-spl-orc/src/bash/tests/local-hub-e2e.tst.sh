#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Hermetic test of do_spl_local_hub_e2e (spl-local-hub-e2e.func.sh, swarm lane
# L9): the e2e of the local private spool-hub, driven against STUBBED lane
# actions, so the cheap gate checks the flow in seconds; the live run is
# DRY_RUN=0 ./run -a do_spl_local_hub_e2e. It names every lane action
# (do_spl_local_hub_unlock, do_spl_local_hub_up, do_spl_local_hub_owner_add,
# do_spl_local_hub_ports_gate, do_spl_local_hub_backup,
# do_spl_local_hub_restore, do_spl_local_hub_down), so changed-tests.sh picks
# this test whenever one of them changes, or the drivers local-hub-e2e-post.py
# (on m3-e2e.py) and local-hub-e2e-tty.py. Temp roots only: no docker, no
# network, no live home or spool root.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

ACTION="$PROJ_ROOT/src/bash/run/spl-local-hub-e2e.func.sh"
POST_PY="$PROJ_ROOT/src/bash/scripts/local-hub-e2e-post.py"

# the stubs: each lane action logs "<name> <facts>" and exits ${FAIL_<step>:-0}
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$STUB_LOG"
exit "${FAIL_HEALTH:-0}"
EOF
cat >"$T/bin/post" <<'EOF'
#!/bin/sh
echo "post $LHE2E_API $LHE2E_TENANT $LHE2E_EMAIL pwfile=$(stat -c %a "$LHE2E_PW_FILE")" >>"$STUB_LOG"
echo '{"step": "read-back", "ok": true}'
exit "${FAIL_POST:-0}"
EOF
# the pty seat: logs which action it seated, the secret's length and whether
# its own stdin was closed: the e2e is fed a pipe, which must never reach a
# secret action (it gets the secret from the pty only)
cat >"$T/bin/tty" <<'EOF'
#!/bin/sh
case "$4" in do_spl_local_hub_unlock) n=unlock f="${FAIL_UNLOCK:-0}" ;; *) n=owner_add f="${FAIL_OWNER:-0}" ;; esac
[ "$(head -c1 | wc -c)" -eq 0 ] && in=closed || in=open
echo "$n len=$(tr -d '\n' <"$1" | wc -c) mode=$(stat -c %a "$1") run=$2 $3 dry=$DRY_RUN stdin=$in" >>"$STUB_LOG"
exit "$f"
EOF
chmod +x "$T/bin/curl" "$T/bin/post" "$T/bin/tty"
STUBS='
do_spl_local_hub_unlock() { echo "unlock called in-process" >>"$STUB_LOG"; return 1; }
do_spl_local_hub_up() {
  echo "up user=$LOCAL_HUB_USER project=$LOCAL_HUB_PROJECT ports=$LOCAL_HUB_PG_PORT,$LOCAL_HUB_GCS_PORT,$LOCAL_HUB_HUB_PORT,$LOCAL_HUB_WUI_PORT cnf=$(stat -c %a "$LOCAL_HUB_HOME/.config/csi-spl/local-hub.env") home=$(stat -c %a "$LOCAL_HUB_HOME") $(cat "$LOCAL_HUB_HOME/.config/csi-spl/local-hub.env" | tr "\n" " ")" >>"$STUB_LOG"
  echo "$LOCAL_HUB_HOME" >"$T/home.seen"; return "${FAIL_UP:-0}"; }
do_spl_local_hub_owner_add() { echo "owner_add called in-process" >>"$STUB_LOG"; return 1; }
do_spl_local_hub_ports_gate() { echo "ports_gate"; echo "ports_gate" >>"$STUB_LOG"; [ -z "${FAIL_PORTS:-}" ] || { echo "FAIL 0.0.0.0:58282 public"; return 1; }; }
do_spl_local_hub_backup() { echo "backup dry=$DRY_RUN" >>"$STUB_LOG"; return "${FAIL_BACKUP:-0}"; }
do_spl_local_hub_restore() { echo "restore dry=$DRY_RUN" >>"$STUB_LOG"; return "${FAIL_RESTORE:-0}"; }
do_spl_local_hub_down() { echo "down purge=${LOCAL_HUB_PURGE:-} dry=$DRY_RUN project=$LOCAL_HUB_PROJECT" >>"$STUB_LOG"; return "${FAIL_DOWN:-0}"; }
'

# e2e [VAR=value]... - source the action + the stubs, run it; out in $T/out, rc in $rc
e2e() {
  : >"$T/calls.log"
  env STUB_LOG="$T/calls.log" T="$T" PROJ_PATH="$PROJ_ROOT" TMPDIR="$T" STUBS="$STUBS" ACTION="$ACTION" \
    LOCAL_HUB_E2E_CURL="$T/bin/curl" LOCAL_HUB_E2E_POST_CMD="$T/bin/post" LOCAL_HUB_E2E_TTY_CMD="$T/bin/tty" LOCAL_HUB_E2E_WAIT=4 "$@" \
    bash -c 'source "$ACTION"; eval "$STUBS"; [ -z "${UNSET_FN:-}" ] || unset -f "$UNSET_FN"; do_spl_local_hub_e2e' \
    <<<"piped-not-a-terminal" >"$T/out" 2>&1
  rc=$?
}
steps() { awk '{print $1}' "$T/calls.log" | tr '\n' ' '; }
has() { grep -qF -- "$2" "$1"; }

# 1. the whole flow, every lane green
e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz
want="unlock up curl owner_add post ports_gate backup restore down "
[[ $rc -eq 0 && "$(steps)" == "$want" ]] && pass "green flow runs every step in order" \
  || fail "green flow: rc=$rc steps='$(steps)' want '$want' :: $(cat "$T/out")"
has "$T/out" "OK local-hub e2e green on e2e-abc123xyz" && pass "green flow says OK" || fail "no OK line: $(cat "$T/out")"
for s in unlock up health owner post ports backup restore down; do
  grep -q "^PASS $s " "$T/out" || fail "no PASS line for $s: $(cat "$T/out")"
done
has "$T/calls.log" "unlock len=32 mode=600 run=./run -a dry=0 stdin=closed" \
  && pass "unlock runs as ./run -a under the pty seat with a 0600 throwaway passphrase, stdin closed" || fail "unlock seat: $(cat "$T/calls.log")"
has "$T/calls.log" "up user=$(id -un) project=spl-lhe2e-abc123xyz ports=58280,58281,58282,58283 cnf=600 home=700 LOCAL_HUB_TENANT=e2e-abc123xyz LOCAL_HUB_OWNER_EMAIL=owner-abc123xyz@example.com" \
  && pass "up sees its own project, off ports, a 0600 private config naming only the throwaway tenant" || fail "up env: $(cat "$T/calls.log")"
has "$T/calls.log" "curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:58282/healthz" && pass "health asks the hub on 127.0.0.1" || fail "health: $(cat "$T/calls.log")"
has "$T/calls.log" "owner_add len=24 mode=600 run=./run -a dry=0 stdin=closed" \
  && pass "owner_add runs under the pty seat with a 0600 throwaway password" || fail "owner_add seat: $(cat "$T/calls.log")"
has "$T/calls.log" "called in-process" && fail "a secret action ran in-process (no tty)" || pass "no secret action runs off the pty"
grep -qE "PASSWORD_FILE|PASSPHRASE=" "$ACTION" && fail "the action hands a secret by env" || pass "no secret is handed by env"
has "$T/calls.log" "post http://127.0.0.1:58282 e2e-abc123xyz owner-abc123xyz@example.com pwfile=600" && pass "post signs in as the throwaway owner" || fail "post: $(cat "$T/calls.log")"
has "$T/calls.log" "down purge=1 dry=0 project=spl-lhe2e-abc123xyz" && pass "down purges the throwaway project" || fail "down: $(cat "$T/calls.log")"
home=$(cat "$T/home.seen" 2>/dev/null)
[[ -n "$home" && ! -e "$home" ]] && pass "the temp home is removed after" || fail "temp home left: '$home'"
pw_leak=0
for f in "$T"/spl-lhe2e.*/.e2e/pw; do [[ -f "$f" ]] && grep -qF "$(cat "$f")" "$T/out" && pw_leak=1; done
(( pw_leak == 0 )) && pass "no password in the output" || fail "a password reached the output"

# 2. a failing step stops the run, down still runs
for case in "FAIL_UNLOCK=1:unlock down " "FAIL_UP=1:unlock up down " "FAIL_HEALTH=1:unlock up curl down " \
  "FAIL_OWNER=1:unlock up curl owner_add down " "FAIL_POST=2:unlock up curl owner_add post down " \
  "FAIL_PORTS=1:unlock up curl owner_add post ports_gate down " \
  "FAIL_BACKUP=1:unlock up curl owner_add post ports_gate backup down " \
  "FAIL_RESTORE=1:unlock up curl owner_add post ports_gate backup restore down "; do
  var="${case%%:*}" want="${case#*:}"
  e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz LOCAL_HUB_E2E_WAIT=2 "$var"
  # curl is retried until the wait runs out: collapse repeats
  got=$(awk '{print $1}' "$T/calls.log" | uniq | tr '\n' ' ')
  [[ $rc -eq 1 && "$got" == "$want" ]] && has "$T/out" "FAIL local-hub e2e on e2e-abc123xyz" \
    && pass "$var stops at its step and still runs down" || fail "$var: rc=$rc steps='$got' want '$want' :: $(cat "$T/out")"
done
e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz FAIL_PORTS=1
has "$T/out" "FAIL ports rc=1 ports_gate FAIL 0.0.0.0:58282 public" && pass "a public listener is shown in the FAIL line" || fail "ports evidence: $(cat "$T/out")"
e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz FAIL_DOWN=1
[[ $rc -eq 1 ]] && has "$T/out" "FAIL down rc=1" && pass "a failing down fails the run" || fail "down failure: rc=$rc $(cat "$T/out")"

# 3. a lane action not landed yet is a named FAIL, then down
e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz UNSET_FN=do_spl_local_hub_restore
[[ $rc -eq 1 ]] && has "$T/out" "FAIL restore missing action do_spl_local_hub_restore (lane L4)" && has "$T/calls.log" "down purge=1" \
  && pass "a missing lane action is named, down still runs" || fail "missing action: rc=$rc $(cat "$T/out")"
e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz UNSET_FN=do_spl_local_hub_down
[[ $rc -eq 1 ]] && has "$T/out" "FAIL down missing action do_spl_local_hub_down (lane L1)" \
  && pass "a missing down is named" || fail "missing down: rc=$rc $(cat "$T/out")"

# 4. only a throwaway tenant: anything else is refused before any call
for bad in acme e2e-abc e2e-ABC123 e2e-abc123/x "e2e-abc123 x" t1; do
  e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT="$bad"
  [[ $rc -eq 2 && ! -s "$T/calls.log" ]] && has "$T/out" "is not a throwaway name" \
    && pass "tenant '$bad' refused, nothing called" || fail "tenant '$bad': rc=$rc calls=$(steps) $(cat "$T/out")"
done
e2e DRY_RUN=0
tn=$(grep -oE 'OK local-hub e2e green on e2e-[a-z0-9]+' "$T/out" | awk '{print $NF}')
[[ $rc -eq 0 && "$tn" =~ ^e2e-[a-z0-9]{10}$ ]] && pass "default tenant is a fresh e2e-<random>" || fail "default tenant: rc=$rc '$tn'"

# 5. a given home must be empty; a used one is refused
mkdir -p "$T/used"; touch "$T/used/x"
e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz LOCAL_HUB_E2E_HOME="$T/used"
[[ $rc -eq 2 && ! -s "$T/calls.log" ]] && pass "a non-empty home is refused" || fail "used home: rc=$rc $(cat "$T/out")"
e2e DRY_RUN=0 LOCAL_HUB_E2E_TENANT=e2e-abc123xyz LOCAL_HUB_E2E_HOME="$T/given"
[[ $rc -eq 0 && -d "$T/given/state" ]] && pass "a given empty home is used and kept" || fail "given home: rc=$rc $(cat "$T/out")"

# 6. dry run (the default): the plan only, nothing called, nothing created
before=$(ls "$T" | wc -l)
e2e LOCAL_HUB_E2E_TENANT=e2e-abc123xyz
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && has "$T/out" "DRY RUN local-hub e2e: tenant e2e-abc123xyz, project spl-lhe2e-abc123xyz" \
  && has "$T/out" "restore  do_spl_local_hub_restore (L4)" && [[ "$(ls "$T" | wc -l)" == "$before" ]] \
  && pass "dry run prints the plan and touches nothing" || fail "dry run: rc=$rc calls=$(steps) $(cat "$T/out")"

# 7. the pty seat itself: it types the secret into a tty-only prompt, and the
# same prompt refuses plain stdin (the owner rule every secret action keeps)
cat >"$T/ask.sh" <<'EOF'
#!/bin/bash
[[ -t 0 ]] || { echo "refused: not a terminal"; exit 9; }
read -rs -p "type the passphrase here: " a </dev/tty; echo
read -rs -p "again: " b </dev/tty; echo
[[ "$a" == "$b" ]] && echo "got ${#a}" || { echo mismatch; exit 1; }
EOF
chmod +x "$T/ask.sh"; printf 'thr0waway-secret\n' >"$T/sec"
TTY_PY="$PROJ_ROOT/src/bash/scripts/local-hub-e2e-tty.py"
out=$(LHE2E_TTY_TIMEOUT=20 python3 "$TTY_PY" "$T/sec" "$T/ask.sh" </dev/null 2>&1); r=$?
[[ $r -eq 0 && "$out" == *"got 16"* && "$out" != *thr0waway* ]] && pass "pty seat answers both prompts, never shows the secret" || fail "pty seat: rc=$r $out"
out=$("$T/ask.sh" </dev/null 2>&1); r=$?
[[ $r -eq 9 && "$out" == *refused* ]] && pass "the tty-only prompt refuses /dev/null" || fail "control /dev/null: rc=$r $out"
out=$(echo thr0waway-secret | "$T/ask.sh" 2>&1); r=$?
[[ $r -eq 9 && "$out" == *refused* ]] && pass "the tty-only prompt refuses a pipe" || fail "control pipe: rc=$r $out"
printf '#!/bin/sh\nexit 7\n' >"$T/x7.sh"; chmod +x "$T/x7.sh"
LHE2E_TTY_TIMEOUT=20 python3 "$TTY_PY" "$T/sec" "$T/x7.sh" </dev/null >/dev/null 2>&1; r=$?
[[ $r -eq 7 ]] && pass "pty seat returns the child's exit code" || fail "pty exit code: $r"
printf '#!/bin/sh\nsleep 30\n' >"$T/hang.sh"; chmod +x "$T/hang.sh"
LHE2E_TTY_TIMEOUT=1 python3 "$TTY_PY" "$T/sec" "$T/hang.sh" </dev/null >/dev/null 2>&1; r=$?
[[ $r -eq 124 ]] && pass "pty seat kills a hung child (124)" || fail "pty timeout: $r"

# 8. the post driver compiles and sends no password on argv or stdout
python3 -m py_compile "$POST_PY" "$TTY_PY" 2>"$T/pyc.err" && pass "local-hub-e2e-post.py and -tty.py compile" || fail "py_compile: $(cat "$T/pyc.err")"
grep -q 'print(.*pw' "$POST_PY" && fail "post driver prints the password" || pass "post driver never prints the password"

echo "local-hub-e2e: $fails failure(s)"
(( fails == 0 ))
