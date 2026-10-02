#!/usr/bin/env bash
# The SPOOL_TEST guard (CLE-77923): under SPOOL_TEST=1 the send/notify path
# refuses the LIVE spool root, and its tmux and hub-relay legs stay off unless
# the test names its own. responder-run.tst.sh once reached the real root on
# every run and flooded the orchestrator's inbox and pane.
#
# The real root is never touched here (nor the real box.env): SPOOL_LIVE_ROOT points the guard at a
# throwaway "live" root, so the CONTROL (no SPOOL_TEST) can show a send landing
# there, which is exactly what the guard then refuses.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
LIVE="$T_TMP/live-root"
mkdir -p "$LIVE/CLE-91" "$SPOOL_ROOT/CLE-91"
# Its own refusals are deliberate: they go to its own log, never to a runner's.
GLOG="$T_TMP/guard.log"; : >"$GLOG"; export SPOOL_TEST_GUARD_LOG="$GLOG"
RELAYLOG="$T_TMP/relay.log"; : >"$RELAYLOG"
inbox_n() { find "$1/CLE-91/inbox" -name '*.json' 2>/dev/null | wc -l; }

# ---- control: no guard, the send reaches the "live" root --------------------
env -u SPOOL_TEST SPOOL_LIVE_ROOT="$LIVE" SPOOL_ROOT="$LIVE" \
  bash "$SS" --from CLE-90 --to CLE-91 --kind note --body control --no-poke >/dev/null 2>&1
eq "CONTROL: without SPOOL_TEST the send lands in the live root" 1 "$(inbox_n "$LIVE")"
rm -rf "$LIVE/CLE-91/inbox" "$LIVE/CLE-90"

# ---- guarded: the live root is refused, nothing written ---------------------
out="$(SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" SPOOL_ROOT="$LIVE" \
  bash "$SS" --from CLE-90 --to CLE-91 --kind note --body leak 2>&1)"; rc=$?
eq "SPOOL_TEST=1 + live root: spool-send exits 96" 96 "$rc"
has "the refusal names the live root" "REFUSED: SPOOL_TEST=1 and SPOOL_ROOT is the live root" "$out"
eq "nothing landed in the live root" 0 "$(inbox_n "$LIVE")"
check "no sender outbox was made in the live root" test ! -e "$LIVE/CLE-90"
has "the refusal is in SPOOL_TEST_GUARD_LOG" "spool-send.sh" "$(cat "$GLOG")"

# an UNSET root defaults to the live one: refused too. CLE-91 has no dir in
# the real root and the relay is off, so even a broken guard writes nothing.
SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" SPOOL_FLEET_RELAY=0 env -u SPOOL_ROOT \
  bash "$SS" --from CLE-90 --to CLE-91 --kind note --body leak >/dev/null 2>&1; rc=$?
eq "SPOOL_TEST=1 + no SPOOL_ROOT (defaults live): refused" 96 "$rc"

# a symlink to the live root is the live root
ln -s "$LIVE" "$T_TMP/alias"
SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" SPOOL_ROOT="$T_TMP/alias/" \
  bash "$SS" --from CLE-90 --to CLE-91 --kind note --body leak >/dev/null 2>&1; rc=$?
eq "SPOOL_TEST=1 + a symlink to the live root: refused" 96 "$rc"
eq "still nothing in the live root" 0 "$(inbox_n "$LIVE")"

# the other entry points share the resolver
SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" SPOOL_ROOT="$LIVE" \
  bash "$T_SCRIPTS/agent-send.sh" CLE-91 hello >/dev/null 2>&1; rc=$?
eq "agent-send.sh refuses the live root too" 96 "$rc"
SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" SPOOL_ROOT="$LIVE" \
  bash "$T_SCRIPTS/spool-notify.sh" </dev/null >/dev/null 2>&1; rc=$?
eq "spool-notify.sh refuses the live root too" 96 "$rc"

# ---- guarded sandbox: delivered; no real tmux, no hub relay -----------------
out="$(SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" env -u SPOOL_TMUX_SOCKET bash "$SS" --from CLE-90 --to CLE-91 --kind note --body ok 2>&1)"; rc=$?
eq "SPOOL_TEST=1 + sandbox root: delivered (exit 5, no window)" 5 "$rc"
eq "the sandbox inbox holds it" 1 "$(inbox_n "$SPOOL_ROOT")"
has "the poke socket defaulted into the sandbox, not the box tmux" "$SPOOL_ROOT" \
  "$(SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" env -u SPOOL_TMUX_SOCKET bash -c ". '$T_FEAT/lib/spool-env.inc.sh'; spool_env_resolve; echo \"\$SPOOL_TMUX_SOCKET\"")"

# an id this root does not know would be relayed through the hub: refused
SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" SPOOL_FLEET_ENV=dev SPOOL_FLEET_TENANT=t1 \
  bash "$SS" --from CLE-90 --to CLE-77 --kind note --body away >/dev/null 2>&1; rc=$?
eq "SPOOL_TEST=1: an off-machine id is refused, not relayed (exit 13)" 13 "$rc"
printf '#!/usr/bin/env bash\necho "$*" >>%s\necho %s\n' "$RELAYLOG" "'{\"delivery\":\"queued\",\"msg_id\":\"m1\",\"task_id\":\"t1\"}'" >"$T_TMP/relay.sh"
SPOOL_TEST=1 SPOOL_LIVE_ROOT="$LIVE" SPOOL_FLEET_RELAY_CMD="bash $T_TMP/relay.sh" \
  bash "$SS" --from CLE-90 --to CLE-77 --kind note --body away >/dev/null 2>&1; rc=$?
eq "SPOOL_TEST=1 + a stub SPOOL_FLEET_RELAY_CMD: the stub relays" 0 "$rc"
has "the stub saw the send" "--to CLE-77" "$(cat "$RELAYLOG")"

# ---- the box config: a test never reads the live box.env --------------------
DB="$T_REPO/csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh"
echo 'SPOOL_DESK_BOX=box-live' >"$LIVE/box.env"
dbox() { env -u SPOOL_DESK_BOX -u SPOOL_BOX_ENV SPOOL_LIVE_ROOT="$LIVE" "$@" bash -c '. "$1"; spl_desk_box_default' _ "$DB"; }
eq "CONTROL: without SPOOL_TEST the desk box comes from the live box.env" box-live "$(dbox env -u SPOOL_TEST)"
eq "SPOOL_TEST=1: the live box.env is not read (one-machine default)" box-desk "$(dbox SPOOL_TEST=1)"
echo 'SPOOL_DESK_BOX=box-own' >"$T_TMP/own.env"
eq "SPOOL_TEST=1: a box.env the test names is still read" box-own "$(dbox SPOOL_TEST=1 SPOOL_BOX_ENV="$T_TMP/own.env")"

t_done
