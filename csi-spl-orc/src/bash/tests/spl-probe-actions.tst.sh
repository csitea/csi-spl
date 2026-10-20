#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the two diagnostic probe actions, hermetic (test round 2 row 07).
#          No hub, no socket to a hub, no real spool binary: the probe script,
#          curl and spool are stubs on PATH, and the desk pin / sidecar are
#          stubbed functions.
#   do_spl_msg_edit_probe (spl-msg-edit-probe.func.sh)
#   1. the probe gets the env's API + auth hosts from the cnf, the tenant,
#      the email (PROBE_EMAIL > <state>/m3-e2e/<t>/human-email > default) and
#      the password FILE; its output is printed, the password never is
#   2. exit contract: the probe's exit 0 -> OK, exit 1 / 2 -> FATAL + exit 1
#   3. refusals before any probe call: a bad tenant, no password file
#   do_spl_wire_probe (spl-wire-probe.func.sh)
#   4. dry run (the default): no spool / curl call, the plan names n and hub
#   5. refusals before any call: DRY_RUN, WIRE_N, tenant, box, agent
#   6. DRY_RUN=0: n sends per leg, leg A with submit off, leg B over the
#      sidecar socket, mirror-local to itself; one summary JSON line with
#      the hub version, both legs and their p50 / p95 delta; sidecar killed
#   7. a corrupt or failed GET /version reads as an empty hub version
#   8. a failed send (leg A or B), a sidecar that never opens its socket and
#      a corrupt leg reading each fail the action with no summary line
#   9. CONTROL: the stubs record a call
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud docker psql
REAL_PY="$(command -v python3)"
umask 077
printf 'pw-secret-9\n' >"$T/pw"

# The msg-edit probe script stub: records what the action handed it, prints
# $T/probe.out and exits $T/probe.rc. Any other python3 call is the real one.
mkdir -p "$T/pystub"
cat >"$T/pystub/python3" <<EOF
#!/bin/bash
case "\${1:-}" in
  */msg-edit-probe.py)
    { echo "script=\$1"; for v in PROBE_API PROBE_AUTH PROBE_TENANT PROBE_EMAIL PROBE_PW_FILE; do echo "\$v=\${!v-}"; done; } >"$T/probe.env"
    echo "python3 \$1" >>"$T/calls.log"
    cat "$T/probe.out"; exit "\$(cat "$T/probe.rc")" ;;
esac
exec "$REAL_PY" "\$@"
EOF
# curl: GET /version prints $T/version.out, or fails when $T/curl-fail exists
cat >"$T/stub/curl" <<EOF
#!/bin/bash
echo "curl \$*" >>"$T/calls.log"
[[ -e "$T/curl-fail" ]] && exit 7
cat "$T/version.out"
EOF
# spool: one line per send with the env that picks the leg; the call whose
# 1-based number is in $T/spool-fail-at exits 1
cat >"$T/stub/spool" <<EOF
#!/bin/bash
n=\$(( \$(wc -l <"$T/sends.log" 2>/dev/null || echo 0) + 1 ))
echo "submit=\${SPOOL_SUBMIT_SOCKET-unset} mirror=\${SPOOL_MIRROR_LOCAL-} box=\${SPOOL_BOX_ID-} tenant=\${SPOOL_TENANT-} hub=\${SPOOL_HUB_URL-} \$*" >>"$T/sends.log"
echo "spool \$1" >>"$T/calls.log"
[[ -s "$T/spool-fail-at" && "\$(cat "$T/spool-fail-at")" == "\$n" ]] && { echo "refused by stub"; exit 1; }
exit 0
EOF
chmod +x "$T/pystub/python3" "$T/stub/curl" "$T/stub/spool"
reset() { : >"$T/calls.log"; rm -f "$T/sends.log" "$T/probe.env" "$T/spool-fail-at" "$T/curl-fail" "$T/no-sock" "$T/pin.log" "$T/sidecar.pid"; }

# The env's hosts, read the way the actions read them (no literal domain here)
CNF_HOSTS='do_spl_cloud_cnf >/dev/null && echo "$(yq -r .env.dns.api_fqdn "$SPL_CNF") $(yq -r .env.dns.fqdn "$SPL_CNF")"'
read -r API FQDN < <(SNIPPET="$CNF_HOSTS" in_orc 2>/dev/null | tail -n 1)
[[ -n "${API:-}" && -n "${FQDN:-}" && "$API" != null ]] || { echo "FAIL: cannot read the dev cnf hosts"; exit 1; }

# --- 1. msg-edit: what the probe gets, what is printed ------------------------------------
edit() { SNIPPET=do_spl_msg_edit_probe in_orc PATH="$T/pystub:$T/stub:$PATH" PROBE_PW_FILE="$T/pw" "$@" 2>&1; }
reset
echo '{"rc": 0, "steps": [{"step": "edit", "result": "PASS"}]}' >"$T/probe.out"; echo 0 >"$T/probe.rc"
mkdir -p "$T/state/dev/m3-e2e/t1"; printf '  probe-human@example.com \n' >"$T/state/dev/m3-e2e/t1/human-email"
out=$(edit TENANT_ID=t1); rc=$?
script=$(sed -n 's/^script=//p' "$T/probe.env" 2>/dev/null)
[[ $rc -eq 0 && -f "$script" && "$script" == */src/bash/scripts/msg-edit-probe.py ]] &&
  grep -qx "PROBE_API=https://$API" "$T/probe.env" && grep -qx "PROBE_AUTH=https://$FQDN" "$T/probe.env" &&
  grep -qx "PROBE_TENANT=t1" "$T/probe.env" && grep -qx "PROBE_PW_FILE=$T/pw" "$T/probe.env" &&
  pass "msg-edit: the probe script exists and gets the cnf API + auth hosts, the tenant and the password file" ||
  fail "msg-edit env: rc=$rc env=$(cat "$T/probe.env" 2>/dev/null) out=$out"
grep -qx "PROBE_EMAIL=probe-human@example.com" "$T/probe.env" &&
  pass "msg-edit: the email comes from the human-email state file, whitespace stripped" || fail "email from file: $(cat "$T/probe.env")"
grep -qF '"result": "PASS"' <<<"$out" && grep -q "^OK msg-edit probe on dev/t1" <<<"$out" &&
  pass "msg-edit: the probe's verdict is printed, then OK" || fail "msg-edit output: $out"
grep -q "pw-secret-9" <<<"$out" && fail "the password was printed" || pass "msg-edit: the password is never printed"

reset; edit TENANT_ID=t1 PROBE_EMAIL=over@example.com >/dev/null
grep -qx "PROBE_EMAIL=over@example.com" "$T/probe.env" && pass "msg-edit: PROBE_EMAIL beats the state file" || fail "PROBE_EMAIL: $(cat "$T/probe.env")"
reset; rm -f "$T/state/dev/m3-e2e/t1/human-email"; edit TENANT_ID=t1 >/dev/null
grep -qx "PROBE_EMAIL=m3-e2e-human@example.com" "$T/probe.env" && pass "msg-edit: no state file -> the m3-e2e default address" || fail "default email: $(cat "$T/probe.env")"
reset; edit TENANT_ID=t1 PROBE_API=http://127.0.0.1:9 PROBE_AUTH=http://127.0.0.1:8 >/dev/null
grep -qx "PROBE_API=http://127.0.0.1:9" "$T/probe.env" && grep -qx "PROBE_AUTH=http://127.0.0.1:8" "$T/probe.env" &&
  pass "msg-edit: PROBE_API / PROBE_AUTH override the cnf hosts" || fail "host override: $(cat "$T/probe.env")"

# --- 2. msg-edit: the exit contract -------------------------------------------------------
for prc in 1 2; do
  reset; echo '{"rc": 1, "steps": [{"step": "edit", "result": "FAIL"}]}' >"$T/probe.out"; echo "$prc" >"$T/probe.rc"
  out=$(edit TENANT_ID=t1); rc=$?
  [[ $rc -eq 1 ]] && grep -q "FATAL msg-edit probe on dev/t1 (exit $prc)" <<<"$out" && ! grep -q "^OK " <<<"$out" &&
    grep -qF '"result": "FAIL"' <<<"$out" &&
    pass "msg-edit: probe exit $prc -> FATAL, exit 1, its verdict still printed" || fail "probe exit $prc: rc=$rc out=$out"
done

# --- 3. msg-edit: refusals before any probe call ------------------------------------------
echo 0 >"$T/probe.rc"
for bad in "TENANT_ID=" "TENANT_ID=T1" "TENANT_ID=../x"; do
  reset
  if out=$(edit "$bad"); then fail "msg-edit accepts $bad"
  else [[ ! -s "$T/calls.log" ]] && grep -q "FATAL TENANT_ID" <<<"$out" && pass "msg-edit refuses $bad before any call" ||
    fail "msg-edit $bad: calls=$(cat "$T/calls.log") out=$out"; fi
done
reset
if out=$(edit TENANT_ID=t1 PROBE_PW_FILE="$T/none"); then fail "msg-edit runs with no password file"
else [[ ! -s "$T/calls.log" ]] && grep -q "FATAL no readable password file $T/none" <<<"$out" &&
  pass "msg-edit: no password file -> FATAL before any call" || fail "no pw: calls=$(cat "$T/calls.log") out=$out"; fi

# --- 4. wire: dry run ---------------------------------------------------------------------
wire() { SNIPPET="$WIRE_STUBS do_spl_wire_probe" in_orc "$@" 2>&1; }
# spl_host_spool -> the spool stub; the pin is recorded; the sidecar opens a
# real unix socket (unless $T/no-sock) and a sleep stands in for its pid
WIRE_STUBS='spl_host_spool() { SPL_SPOOL="$STUB_DIR/spool"; }
spl_desk_pin() { echo "pin $*" >>"$T_DIR/pin.log"; echo pubkey; }
spl_desk_sidecar() { sleep 30 </dev/null >/dev/null 2>&1 & SPL_DESK_PID=$!; echo "$SPL_DESK_PID" >"$T_DIR/sidecar.pid"
  [[ -e "$T_DIR/no-sock" ]] || python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$1/spool/.hub/submit.sock"; }
'
export STUB_DIR="$T/stub" T_DIR="$T"
reset
out=$(wire TENANT_ID=e2e WIRE_N=4); rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" && ! -e "$T/pin.log" ]] && grep -q "OK DRY_RUN nothing was sent" <<<"$out" &&
  grep -q "send 4 messages with the submit path OFF" <<<"$out" && grep -q "hub-pin box-wire-probe under e2e at https://$API" <<<"$out" &&
  pass "wire dry run: no spool / curl / pin call; the plan names n, the box and the hub" || fail "wire dry run: rc=$rc calls=$(cat "$T/calls.log") out=$out"

# --- 5. wire: refusals before any call ----------------------------------------------------
for bad in "DRY_RUN=2" "WIRE_N=0" "WIRE_N=ten" "TENANT_ID=E2E" "WIRE_BOX=box-wui" "WIRE_BOX=Bad_Box" "WIRE_AGENT=nobody"; do
  reset
  if wire TENANT_ID=e2e DRY_RUN=0 "$bad" >"$T/o"; then fail "wire accepts $bad"
  else [[ ! -s "$T/calls.log" && ! -e "$T/pin.log" ]] && pass "wire refuses $bad before any call" ||
    fail "wire $bad: calls=$(cat "$T/calls.log") out=$(cat "$T/o")"; fi
done

# --- 6. wire: a measured run --------------------------------------------------------------
summary() { grep '^{' <<<"$1" | tail -n 1; }
jget() { "$REAL_PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
reset; echo '{"version": "9.8.7", "commit": "abc1234"}' >"$T/version.out"
out=$(wire TENANT_ID=e2e DRY_RUN=0 WIRE_N=3); rc=$?
s=$(summary "$out")
[[ $rc -eq 0 && "$(jget "$s" '" ".join(map(str, (d["n"], d["hub_version"], d["hub_commit"], d["hub"])))')" == "3 9.8.7 abc1234 https://$API" ]] &&
  grep -q "^OK do_spl_wire_probe measured 3 sends per leg" <<<"$out" &&
  pass "wire: one summary JSON line with n, the hub and its version + commit, then OK" || fail "wire summary: rc=$rc s=$s out=$out"
[[ "$(jget "$s" 'sorted(d["dial_ms"]) == sorted(d["submit_ms"]) == ["max", "min", "p50", "p95"]')" == True &&
   "$(jget "$s" 'all(l["min"] <= l["p50"] <= l["p95"] <= l["max"] for l in (d["dial_ms"], d["submit_ms"]))')" == True &&
   "$(jget "$s" 'd["delta_p50_ms"] == round(d["dial_ms"]["p50"] - d["submit_ms"]["p50"], 1) and d["delta_p95_ms"] == round(d["dial_ms"]["p95"] - d["submit_ms"]["p95"], 1)')" == True ]] &&
  pass "wire: both legs carry p50/p95/min/max in order, the deltas are leg A - leg B" || fail "wire legs: $s"
[[ "$(grep -c '^submit=off ' "$T/sends.log")" -eq 3 && "$(grep -c '^submit= ' "$T/sends.log")" -eq 3 && "$(wc -l <"$T/sends.log")" -eq 6 ]] &&
  [[ "$(head -n 3 "$T/sends.log" | grep -c '^submit=off ')" -eq 3 ]] &&
  pass "wire: 3 sends with the submit socket off (leg A), then 3 over the sidecar (leg B)" || fail "wire legs: $(cat "$T/sends.log")"
[[ "$(grep -cF "mirror=1 box=box-wire-probe tenant=e2e hub=https://$API send --from WIR-1 --to WIR-1 --to-box box-wire-probe --kind note --body [wire-probe] " "$T/sends.log")" -eq 6 ]] &&
  pass "wire: every send is mirror-local, from the probe agent to itself on its own box" || fail "wire send shape: $(cat "$T/sends.log")"
grep -qF "curl -fsS -m 10 https://$API/version" "$T/calls.log" && grep -qF "pin $T/state/dev/wire-probe/e2e/box-wire-probe box-wire-probe e2e https://$API" "$T/pin.log" &&
  pass "wire: GET /version on the cnf hub; the box pinned from its own state dir" || fail "wire calls: $(cat "$T/calls.log") pin=$(cat "$T/pin.log" 2>/dev/null)"
pid=$(cat "$T/sidecar.pid"); sleep 0.2
! kill -0 "$pid" 2>/dev/null && [[ "$(stat -c %a "$T/state/dev/wire-probe/e2e/box-wire-probe")" == 700 ]] &&
  pass "wire: the sidecar is killed after leg B; the probe state is 0700" || { kill "$pid" 2>/dev/null; fail "wire sidecar $pid alive or state mode wrong"; }

# --- 7. wire: corrupt or failed /version --------------------------------------------------
sock="$T/state/dev/wire-probe/e2e/box-wire-probe/spool/.hub/submit.sock"
for how in corrupt failed; do
  reset; rm -f "$sock"
  echo 'not json {' >"$T/version.out"; [[ $how == failed ]] && touch "$T/curl-fail"
  out=$(wire TENANT_ID=e2e DRY_RUN=0 WIRE_N=1); rc=$?
  [[ $rc -eq 0 && "$(jget "$(summary "$out")" 'repr(d["hub_version"]) + " " + repr(d["hub_commit"])')" == "'' ''" ]] &&
    pass "wire: a $how /version reads as an empty hub version, the measurement stands" || fail "wire $how /version: rc=$rc out=$out"
done

# --- 8. wire: failures end the action, with no summary line -------------------------------
echo '{"version": "9.8.7"}' >"$T/version.out"
for at in 2 5; do
  reset; rm -f "$sock"; echo "$at" >"$T/spool-fail-at"
  out=$(wire TENANT_ID=e2e DRY_RUN=0 WIRE_N=3); rc=$?
  leg=$( ((at <= 3)) && echo A || echo B); k=$(( at <= 3 ? at : at - 3 ))
  [[ $rc -eq 1 && -z "$(summary "$out")" && "$(wc -l <"$T/sends.log")" -eq $at ]] && grep -q "FATAL wire-probe send $k/3 failed: refused by stub" <<<"$out" &&
    ! grep -q "^OK " <<<"$out" && pass "wire: a failed send in leg $leg stops the leg there, FATAL, exit 1, no summary" ||
    fail "wire send fail at $at: rc=$rc sends=$(wc -l <"$T/sends.log") out=$out"
  if [[ $leg == A ]]; then
    [[ ! -e "$T/sidecar.pid" ]] && pass "wire: leg A failed -> no sidecar was started" || fail "wire: a sidecar started after leg A failed"
  else
    pid=$(cat "$T/sidecar.pid"); sleep 0.2
    ! kill -0 "$pid" 2>/dev/null && pass "wire: leg B failed -> the sidecar is killed" ||
      { kill "$pid" 2>/dev/null; fail "wire: sidecar $pid left running after leg B failed"; }
  fi
done
reset; rm -f "$sock"; touch "$T/no-sock"
out=$(wire TENANT_ID=e2e DRY_RUN=0 WIRE_N=1); rc=$?
pid=$(cat "$T/sidecar.pid"); sleep 0.2
[[ $rc -eq 1 && -z "$(summary "$out")" ]] && grep -q "FATAL the sidecar never opened .*/submit.sock" <<<"$out" && ! kill -0 "$pid" 2>/dev/null &&
  [[ "$(grep -c '^submit= ' "$T/sends.log")" -eq 0 ]] &&
  pass "wire: a sidecar that never opens its socket -> FATAL, exit 1, killed, no leg B send" || { kill "$pid" 2>/dev/null; fail "wire no socket: rc=$rc out=$out"; }
reset; rm -f "$sock"
out=$(SNIPPET="$WIRE_STUBS"' spl_wire_leg() { echo "{\"p50\": 1"; }; do_spl_wire_probe' in_orc TENANT_ID=e2e DRY_RUN=0 WIRE_N=1 2>&1); rc=$?
[[ -e "$T/sidecar.pid" ]] && kill "$(cat "$T/sidecar.pid")" 2>/dev/null
[[ $rc -eq 1 && -z "$(summary "$out")" ]] && grep -q "FATAL do_spl_wire_probe could not read" <<<"$out" && ! grep -q "^OK " <<<"$out" &&
  pass "wire: a corrupt leg reading -> FATAL, exit 1, no OK" || fail "wire corrupt leg: rc=$rc out=$out"

# --- 9. CONTROL: the stubs record a call --------------------------------------------------
reset
SNIPPET='spool keygen; curl -s x' in_orc >/dev/null 2>&1
grep -q "^spool keygen" "$T/calls.log" && grep -q "^curl -s x" "$T/calls.log" && pass "CONTROL: a spool and a curl call are recorded" ||
  fail "CONTROL: stub log $(cat "$T/calls.log")"

echo "=== $([[ $fails -eq 0 ]] && echo 'all spl-probe-actions.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
