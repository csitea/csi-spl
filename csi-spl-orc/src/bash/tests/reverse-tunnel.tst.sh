#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-1766 (owner t1 0bb05176 pick B) - the peer box reaches this box
#          through a reverse ssh tunnel, as a forced command only. Offline:
#          ssh is a stub (a long-lived tunnel, or the peer box in a temp home).
#   1. do_setup_reverse_tunnel refuses a bad command, box and port
#   2. DRY_RUN is the default: no ssh call, nothing recorded
#   3. DRY_RUN=0 start: recorded, one ssh -N -R 127.0.0.1:2222:127.0.0.1:22
#      <dest> to the satellite alias (BOX_SSH_SAT wins), detached and up
#   4. reconcile keeps a live tunnel (no second ssh); a dead one is restarted
#   5. a tunnel that exits at once is a FATAL, not an OK
#   6. stop: tunnel gone, record gone; status says none
#   7. do_box_peer_ssh_grant: one restricted forced-command line per peer,
#      other lines kept, a backup, idempotent; the peer gets its key + Host
#      block; no private key in any output
#   8. the gate runs ping and lease, refuses anything else (exit 3)
#   9. the cron row reverse-tunnel; its script is a no-op with nothing recorded
#  10. CONTROL: a tunnel started through the stub IS recorded in the stub log
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # n, PID2, AK, PUB, M, out and rc are read inside the check strings (eval)
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v ssh-keygen >/dev/null || { echo "SKIP: no ssh-keygen"; exit 0; }

ME="$(id -un)"
mkdir -p "$T/stub/remote-bin" "$T/rt" "$T/home/.ssh" "$T/peer" "$T/spool/dispatch"
printf 'SPOOL_BOX_TAG=hub1\nSPOOL_AGENT_USER=%s\n' "$ME" >"$T/spool/box.env"
echo "c-001 2026-10-14T00:00:00Z" >"$T/spool/dispatch/lease"
printf 'AGENT_USER=%s\nBOX_TAG=sat\n' "$ME" >"$T/peer.env"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHERKEYOTHERKEYOTHERKEYOTHERKEYOTHERK owner" >"$T/home/.ssh/authorized_keys"

# the tunnel: logs its args, then lives with its cmdline kept (no exec: the
# action proves a tunnel by its cmdline); FAKE_TUNNEL_DIE=1: exits at once
cat >"$T/stub/tunnel-ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >>"$STUB_LOG"
[[ "${FAKE_TUNNEL_DIE:-0}" == 1 ]] && { echo "remote port forwarding failed for listen port 2222"; exit 255; }
trap 'kill $! 2>/dev/null; exit 0' TERM
sleep 300 & wait
EOF
# ssh <-o x> <dest> <command>: plays the peer box, sudo stubbed to its temp home
cat >"$T/stub/ssh" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -o ]]; do shift 2; done
dest="$1" cmd="$2"
printf 'ssh %s %.40s\n' "$dest" "$cmd" >>"$STUB_LOG"
[[ "$cmd" == 'cat /etc/csi-spl-satellite.env' ]] && { cat "$FAKE_PEER_ENV"; exit 0; }
PATH="$FAKE_STUB_DIR/remote-bin:$PATH" eval "$cmd"
EOF
cat >"$T/stub/remote-bin/sudo" <<'EOF'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do case "$1" in -u) shift 2 ;; *) shift ;; esac; done
HOME="$FAKE_PEER_HOME" exec "$@"
EOF
chmod +x "$T/stub/tunnel-ssh" "$T/stub/ssh" "$T/stub/remote-bin/sudo"

rt() {
  SNIPPET=do_setup_reverse_tunnel in_orc REVERSE_TUNNEL_STATE_DIR="$T/rt" SSH_BIN="$T/stub/tunnel-ssh" \
    REVERSE_TUNNEL_START_WAIT=1 "$@" >"$T/o" 2>&1
}
calls() { grep -c '^ssh -N' "$T/calls.log" 2>/dev/null; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; sed 's/^/    /' "$T/o"; fi; }

# --- 1. refusals ------------------------------------------------------------------------------
: >"$T/calls.log"
for bad in "REVERSE_TUNNEL_CMD=up" "TO_BOX=../x" "REVERSE_TUNNEL_PORT=22" "REVERSE_TUNNEL_PORT=70000" "DRY_RUN=2"; do
  check "1. refused: $bad" '! rt "$bad" && grep -q FATAL "$T/o"'
done
check "1. no ssh call on a refusal" '[[ $(calls) == 0 ]]'

# --- 2. dry run -------------------------------------------------------------------------------
rt
check "2. dry run by default: nothing recorded, no ssh" 'grep -q "DRY_RUN would" "$T/o" && [[ ! -e $T/rt/sat.conf && $(calls) == 0 ]]'

# --- 3. start ---------------------------------------------------------------------------------
rt DRY_RUN=0
check "3. start: OK started" 'grep -q "OK tunnel to sat started" "$T/o"'
check "3. one ssh -N -R 127.0.0.1:2222:127.0.0.1:22 satellite" '[[ $(calls) == 1 ]] && grep -q -- "-R 127.0.0.1:2222:127.0.0.1:22 satellite\$" "$T/calls.log"'
check "3. ExitOnForwardFailure + keepalive" 'grep -q "ExitOnForwardFailure=yes" "$T/calls.log" && grep -q "ServerAliveInterval=30" "$T/calls.log"'
check "3. its own connection, never a shared ControlMaster" 'grep -q "ControlMaster=no -o ControlPath=none" "$T/calls.log"'
PID1="$(cat "$T/rt/sat.pid" 2>/dev/null)"
check "3. the tunnel pid is alive" 'kill -0 "$PID1" 2>/dev/null'
rt REVERSE_TUNNEL_CMD=stop DRY_RUN=0
rt DRY_RUN=0 BOX_SSH_SAT=sat-alt
check "3. BOX_SSH_SAT wins over the alias" 'grep -q -- "-R 127.0.0.1:2222:127.0.0.1:22 sat-alt\$" "$T/calls.log" && grep -qx "dest=sat-alt" "$T/rt/sat.conf"'
PID1="$(cat "$T/rt/sat.pid")"

# --- 4. reconcile -----------------------------------------------------------------------------
n="$(calls)"
rt REVERSE_TUNNEL_CMD=reconcile DRY_RUN=0
check "4. reconcile keeps a live tunnel: no new ssh" 'grep -q "is up (pid $PID1)" "$T/o" && [[ $(calls) == "$n" ]]'
kill "$PID1"; sleep 0.3
rt REVERSE_TUNNEL_CMD=reconcile DRY_RUN=0
PID2="$(cat "$T/rt/sat.pid" 2>/dev/null)"
check "4. reconcile restarts a dead tunnel" 'grep -q started "$T/o" && [[ $(calls) == $((n + 1)) && "$PID2" != "$PID1" ]] && kill -0 "$PID2"'
rt REVERSE_TUNNEL_CMD=status
check "4. status: up" 'grep -q "reverse-tunnel: sat up (sat-alt -R 127.0.0.1:2222:127.0.0.1:22)" "$T/o"'

# --- 6. stop (before 5: 5 needs no live tunnel) -----------------------------------------------
rt REVERSE_TUNNEL_CMD=stop DRY_RUN=0; sleep 0.3
check "6. stop: tunnel and record gone" '! kill -0 "$PID2" 2>/dev/null && [[ ! -e $T/rt/sat.conf ]]'
rt REVERSE_TUNNEL_CMD=status
check "6. status: none recorded" 'grep -q "none recorded" "$T/o"'

# --- 5. a tunnel that dies at once ------------------------------------------------------------
check "5. exits at once = FATAL" '! rt DRY_RUN=0 FAKE_TUNNEL_DIE=1 && grep -q "FATAL tunnel to sat exited at once: remote port forwarding failed" "$T/o"'
rt REVERSE_TUNNEL_CMD=stop DRY_RUN=0

# --- 7. grant ---------------------------------------------------------------------------------
grant() {
  SNIPPET=do_box_peer_ssh_grant in_orc SPOOL_ROOT="$T/spool" HOME="$T/home" PEER_SSH_ALLOW_WORKTREE=1 \
    FAKE_PEER_ENV="$T/peer.env" FAKE_STUB_DIR="$T/stub" FAKE_PEER_HOME="$T/peer" "$@" >"$T/o" 2>&1
}
AK="$T/home/.ssh/authorized_keys"
: >"$T/calls.log"
grant
check "7. grant dry run: no ssh, keys untouched" 'grep -q "DRY_RUN would" "$T/o" && [[ ! -s $T/calls.log ]] && ! grep -q spl-peer "$AK"'
grant DRY_RUN=0
check "7. grant: OK" 'grep -q "^OK .*may run the gate verbs" "$T/o"'
check "7. one forced-command line for sat" '[[ $(grep -c " spl-peer:sat\$" "$AK") == 1 ]] && grep -q "^from=\"127.0.0.1,::1\",restrict,command=\"bash $PROJ_ROOT/src/bash/scripts/peer-ssh-gate.sh sat\" ssh-ed25519 " "$AK"'
PUB="$(cut -d" " -f2 "$T/peer/.ssh/id_ed25519_spl_peer_hub1.pub" 2>/dev/null)"
check "7. the key is the peer's own" '[[ -n "$PUB" ]] && grep -qF " $PUB spl-peer:sat" "$AK"'
check "7. the other line kept" 'grep -q "OTHERKEY.* owner\$" "$AK"'
check "7. a backup written" 'ls "$T/home/.ssh/"authorized_keys.bak-spl-peer-* >/dev/null 2>&1'
check "7. peer Host hub1-tunnel block" 'grep -q "^Host hub1-tunnel\$" "$T/peer/.ssh/config" && grep -q "^  Port 2222\$" "$T/peer/.ssh/config"'
check "7. no private key in output" '! grep -q "PRIVATE KEY" "$T/o" "$T/calls.log"'
grant DRY_RUN=0
check "7. idempotent: still one line, one Host block" '[[ $(grep -c " spl-peer:sat\$" "$AK") == 1 && $(grep -c "^Host hub1-tunnel" "$T/peer/.ssh/config") == 1 ]]'
printf 'BOX_TAG=other\nAGENT_USER=%s\n' "$ME" >"$T/peer.env"
check "7. a peer answering as another box is refused" '! grant DRY_RUN=0 && grep -q "answers as box .other." "$T/o"'
check "7. the grant from a worktree is refused" '! grant DRY_RUN=0 PEER_SSH_ALLOW_WORKTREE=0 || ! git -C "$PROJ_ROOT" rev-parse --git-dir | grep -q worktrees'

# --- 8. the gate ------------------------------------------------------------------------------
GATE="$PROJ_ROOT/src/bash/scripts/peer-ssh-gate.sh"
gate() { env SPOOL_ROOT="$T/spool" SSH_ORIGINAL_COMMAND="$1" bash "$GATE" sat >"$T/o" 2>&1; }
check "8. ping -> pong <user>@hub1 from sat" 'gate ping && grep -qx "pong $ME@hub1 from sat" "$T/o"'
check "8. lease -> the lease line" 'gate lease && grep -qx "c-001 2026-10-14T00:00:00Z" "$T/o"'
for bad in "" "bash" "ping; id" "cat /etc/shadow" "lease && rm -rf /"; do
  gate "$bad"; rc=$?
  check "8. refused (exit 3): '$bad'" '[[ $rc == 3 ]] && grep -q refused "$T/o"'
done

# --- 9. cron ----------------------------------------------------------------------------------
M="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
check "9. manifest row reverse-tunnel every minute" 'grep -qE "^reverse-tunnel +\| \* \* \* \* \* +\| src/bash/scripts/reverse-tunnel-cron.sh +\| reverse-tunnel/cron.log" "$M"'
out="$(REVERSE_TUNNEL_ALLOW_WORKTREE=1 REVERSE_TUNNEL_STATE_DIR="$T/rt-empty" bash "$PROJ_ROOT/src/bash/scripts/reverse-tunnel-cron.sh" 2>&1)"; rc=$?
check "9. cron with nothing recorded: exit 0, silent" '[[ $rc == 0 && -z "$out" ]]'

# --- 10. control ------------------------------------------------------------------------------
: >"$T/calls.log"
rt DRY_RUN=0
check "10. CONTROL: a started tunnel is in the stub log" '[[ $(calls) == 1 ]]'
rt REVERSE_TUNNEL_CMD=stop DRY_RUN=0

[[ $fails -eq 0 ]] && echo "reverse-tunnel: ALL PASS" || echo "reverse-tunnel: $fails FAIL"
exit "$fails"
