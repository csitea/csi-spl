#!/usr/bin/env bash
# test-live-ack-shown.sh — scripts/spool-live-ack.sh, the agent hook's shown
# ack sender (spec 053 S1, SPL-6517, latency action 7). Throwaway SPOOL_ROOT,
# a stub spool binary that records its argv; no hub, no sidecar. The hub side
# (one row per shown message, none new on a second surfacing, no sidecar =
# dropped at once) is internal/hub/live_ack_shown_test.go.
#   1. one run = one `spool live-ack --as <id> <ids...>`; a qualified
#      <id>@<box> is acked as <id>; the log line names rc (control: the stub
#      saw exactly those args)
#   2. no ids, or no agent: the binary is never started (control: 1 starts it)
#   3. a failing or hanging spool still exits 0, bounded by
#      SPOOL_LIVE_ACK_TIMEOUT (control: the log line carries rc=124 / rc=3)
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
SENDER="$T_SCRIPTS/spool-live-ack.sh"
STUB="$T_TMP/spool-stub"
ARGS="$T_TMP/args"
cat > "$STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGS"
case "${STUB_MODE:-ok}" in
  ok) echo '{"acked":'"$(($# - 3))"'}' ;;
  fail) echo "spool: live-ack: sidecar: no hub session" >&2; exit 3 ;;
  hang) exec sleep 30 ;;
esac
STUB
chmod +x "$STUB"
export SPOOL_BIN="$STUB" STUB_ARGS="$ARGS"
M1=11111111-2222-4333-8444-555555555555
M2=66666666-7777-4888-9999-aaaaaaaaaaaa
mkdir -p "$SPOOL_ROOT/c-901/lifetime" "$SPOOL_ROOT/c-902@box-t/lifetime"

echo "# 1. one run, one live-ack call"
bash "$SENDER" c-901 "$M1" "$M2"; rc=$?
eq "exit 0" 0 "$rc"
eq "the verb's argv" "live-ack --as c-901 $M1 $M2" "$(cat "$ARGS")"
has "the log line" "c-901 rc=0 {\"acked\":2}" "$(cat "$SPOOL_ROOT/c-901/lifetime/live-ack.log")"
: > "$ARGS"
bash "$SENDER" "c-902@box-t" "$M1"
eq "a qualified dir is acked as its id" "live-ack --as c-902 $M1" "$(cat "$ARGS")"
check "its log is in the qualified dir" test -s "$SPOOL_ROOT/c-902@box-t/lifetime/live-ack.log"

echo "# 2. nothing to ack: no start"
: > "$ARGS"
bash "$SENDER" c-901; rc=$?
eq "no ids: exit 0" 0 "$rc"
bash "$SENDER" "" "$M1"
eq "no ids / no agent: spool never started" "" "$(cat "$ARGS")"

echo "# 3. a failing or hanging spool"
STUB_MODE=fail bash "$SENDER" c-901 "$M1"; rc=$?
eq "a failing verb: exit 0" 0 "$rc"
has "its rc is logged" "rc=3 spool: live-ack: sidecar: no hub session" "$(tail -n1 "$SPOOL_ROOT/c-901/lifetime/live-ack.log")"
start=$(date +%s)
STUB_MODE=hang SPOOL_LIVE_ACK_TIMEOUT=1 bash "$SENDER" c-901 "$M1"; rc=$?
took=$(( $(date +%s) - start ))
eq "a hanging verb: exit 0" 0 "$rc"
check "bounded by the timeout (took ${took}s, cap 5)" test "$took" -le 5
has "the timeout is logged" "rc=124" "$(tail -n1 "$SPOOL_ROOT/c-901/lifetime/live-ack.log")"

t_done
