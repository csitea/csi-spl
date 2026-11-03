#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spl-agent-log-pipe.tst.sh - do_spl_agent_log_pipe (spec 160 section 3.9,
# SPL-4718) on a stub tmux that keeps its panes in a file:
#   1. a pane with pane_pipe=0 gets the pipe: through the repo's ANSI filter,
#      appended (>>) to the cnf path, never truncating it
#   2. idempotent: a piped pane is left alone, no second pipe-pane call
#   3. a rotation: the newest registry row's live pane is piped; an old row
#      whose pane id now sits in another window, and a c-1410 window, are not
#   3b. a registry row whose pane id is now the agent's pokes side pane
#      (spool-notice-pane) is never piped
#   4. no live pane = SKIP, exit 0, no call; only <id>.log allow paths count
#   5. the cron wrapper runs it before the steps log, so one tick re-pipes
#   6. RED control: with the action disabled the pane stays at pane_pipe=0
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v yq >/dev/null && command -v perl >/dev/null || { echo "FAIL: yq and perl are required"; exit 1; }

FUNC="$PROJ_ROOT/src/bash/run/spl-agent-log-pipe.func.sh"
CRON="$PROJ_ROOT/src/bash/scripts/agent-steps-log-cron.sh"
[[ -f "$FUNC" ]] || { echo "FAIL: no action at $FUNC"; echo "FAIL spl-agent-log-pipe: 1 failed"; exit 1; }

# the stub tmux: panes "<id> <pipe> <window>" in $TMUX_STUB_PANES, each
# pipe-pane call logged to $TMUX_STUB_CALLS; an attach runs the pipe command
# once on a line with escapes, as the pane's output would.
mkdir -p "$T/bin"
cat >"$T/bin/tmux" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = -S ] && shift 2
P="$TMUX_STUB_PANES"
case "$1" in
  list-panes) cat "$P" ;;
  display-message) awk -v p="$4" '$1 == p { print $2 }' "$P" ;;
  pipe-pane)
    shift; o=0; [ "$1" = -o ] && { o=1; shift; }; p="$2"; cmd="$3"
    echo "$p $cmd" >>"$TMUX_STUB_CALLS"
    [ "$o" = 1 ] && [ "$(awk -v p="$p" '$1 == p { print $2 }' "$P")" = 1 ] && exit 0
    awk -v p="$p" '$1 == p { $2 = 1 } 1' "$P" >"$P.new" && mv "$P.new" "$P"
    printf 'hello \033[31mred\033[0m\r\n' | bash -c "$cmd" ;;
esac
STUB
chmod +x "$T/bin/tmux"

L="$T/logs"; mkdir -p "$L" "$T/spool"
cat >"$T/cnf.yaml" <<EOF
env:
  box:
    file_streams:
      allow:
        - {id: token-burn-cron, path: $T/token.log}
        - {id: agent-c-141, path: $L/c-141.log}
        - {id: agent-c-141-steps, path: $L/c-141.steps.log}
        - {id: agent-c-142, path: $L/c-142.log}
EOF
REG="$T/spool/registry.tsv"
printf 'c-141\tclaude\t%%10\t/w/c-141\t20261103T122928Z\t-\n' >"$REG"
printf 'c-142\tclaude\t%%30\t/w/c-142\t20261103T122928Z\t-\n' >>"$REG"
export TMUX_STUB_PANES="$T/panes" TMUX_STUB_CALLS="$T/calls"
printf '%%10 0 main c-141@box >\n%%11 0 side c-141@box >\n%%12 0 main c-1410@box\n' >"$TMUX_STUB_PANES"
: >"$TMUX_STUB_CALLS"
echo 'earlier screen' >"$L/c-141.log"

act() {
  env PATH="$T/bin:$PATH" SPOOL_ROOT="$T/spool" SPOOL_TMUX_SOCKET="$T/sock" AGENT_LOG_PIPE_CNF="$T/cnf.yaml" "$@" \
    bash -c 'source "$1"; do_spl_agent_log_pipe' _ "$FUNC"
}
pipe_of() { awk -v p="$1" '$1 == p { print $2 }' "$TMUX_STUB_PANES"; }

# --- 1. attach -----------------------------------------------------------------
out="$(act 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(pipe_of %10)" == 1 && "$(pipe_of %11)" == 0 ]] && pass "1. the registry pane with pane_pipe=0 is piped, its pokes side pane %11 is not (rc 0)" ||
  fail "1. attach (rc $rc: $out; %10=$(pipe_of %10))"
[[ "$(cat "$L/c-141.log")" == $'earlier screen\nhello red' ]] && pass "1. ...appended through the ANSI filter, nothing truncated" ||
  fail "1. log: $(cat -v "$L/c-141.log")"
grep -q "^%10 exec perl '$PROJ_ROOT/src/bash/scripts/agent-log-strip-ansi.pl' >> '$L/c-141.log'$" "$TMUX_STUB_CALLS" &&
  pass "1. ...with the repo's filter, never a hand-made one" || fail "1. call: $(cat "$TMUX_STUB_CALLS")"
grep -q "OK agent-log-pipe: c-141 pane %10 piped" <<<"$out" && pass "1. ...and says so" || fail "1. out: $out"

# --- 2. idempotent ---------------------------------------------------------------
: >"$TMUX_STUB_CALLS"
out="$(act 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -s "$TMUX_STUB_CALLS" && "$out" != *OK* ]] && pass "2. a piped pane is left alone: no second pipe-pane" ||
  fail "2. idempotent (rc $rc: $out; calls $(cat "$TMUX_STUB_CALLS"))"

# --- 3. a rotation -----------------------------------------------------------------
# the agent rotated to %20; its old pane %10 is gone and its id %10 now
# belongs to another agent's window
printf 'c-141\tclaude\t%%20\t/w/c-141\t20261103T133107Z\t-\n' >>"$REG"
printf '%%10 0 main c-999@box\n%%20 0 main c-141@box >\n%%21 0 side c-141@box >\n%%12 0 main c-1410@box\n' >"$TMUX_STUB_PANES"
: >"$TMUX_STUB_CALLS"
out="$(act 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(pipe_of %20)" == 1 && "$(pipe_of %10)" == 0 && "$(pipe_of %12)" == 0 ]] &&
  pass "3. after a rotation the new pane is piped; the reused id and c-1410 are not" ||
  fail "3. rotation (rc $rc: $out; %20=$(pipe_of %20) %10=$(pipe_of %10) %12=$(pipe_of %12))"
printf '%%10 0 main c-999@box\n%%12 0 main c-1410@box\n%%30 0 side c-142@box\n' >"$TMUX_STUB_PANES"
: >"$TMUX_STUB_CALLS"
out="$(act 2>&1)"; rc=$?
[[ "$rc" == 0 && ! -s "$TMUX_STUB_CALLS" && "$(pipe_of %10)" == 0 ]] && pass "3. ...an old row whose pane id is another window's is never piped" ||
  fail "3. reused id (rc $rc: $out; calls $(cat "$TMUX_STUB_CALLS"))"

# --- 4. no live pane, the allow filter ---------------------------------------------
grep -q "SKIP agent-log-pipe: c-142 has no live pane" <<<"$out" && [[ "$(pipe_of %30)" == 0 ]] && pass "3b/4. a row on a side pane is no live pane: skipped, side pane unpiped (rc 0)" || fail "4. skip: $out"
[[ ! -e "$T/token.log" && ! -e "$L/c-141.steps.log" && "$out" != *steps* && "$out" != *token* ]] &&
  pass "4. ...and only the <id>.log allow paths are logs to pipe" || fail "4. filter: $out"
out="$(act AGENT_LOG_PIPE_CNF="$T/none.yaml" 2>&1)"; rc=$?
[[ "$rc" == 1 && "$out" == *"FATAL agent-log-pipe: no cnf"* ]] && pass "4. no cnf = exit 1" || fail "4. no cnf (rc $rc: $out)"

# --- 5. the cron wrapper ------------------------------------------------------------
printf '%%20 0 main c-141@box >\n' >"$TMUX_STUB_PANES"
out="$(env PATH="$T/bin:$PATH" SPOOL_ROOT="$T/spool" SPOOL_TMUX_SOCKET="$T/sock" AGENT_LOG_PIPE_CNF="$T/cnf.yaml" \
  AGENT_LOG_PIPE_TMUX="$T/bin/tmux" AGENT_STEPS_LOG_ALLOW_WORKTREE=1 bash "$CRON" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(pipe_of %20)" == 1 && "$out" == *"c-141 pane %20 piped"* ]] && pass "5. one cron tick re-pipes the rotated pane" ||
  fail "5. cron (rc $rc: $out; %20=$(pipe_of %20))"

# --- 6. RED control ------------------------------------------------------------------
printf '%%20 0 main c-141@box >\n' >"$TMUX_STUB_PANES"
env PATH="$T/bin:$PATH" SPOOL_ROOT="$T/spool" SPOOL_TMUX_SOCKET="$T/sock" AGENT_LOG_PIPE_CNF="$T/cnf.yaml" \
  bash -c 'source "$1"; do_spl_agent_log_pipe() { :; }; do_spl_agent_log_pipe' _ "$FUNC" >/dev/null 2>&1
[[ "$(pipe_of %20)" == 0 ]] && pass "6. RED control: with the action disabled the pane stays at pane_pipe=0" ||
  fail "6. red control: %20=$(pipe_of %20)"

[[ "$fails" == 0 ]] && echo "PASS spl-agent-log-pipe: all passed" || { echo "FAIL spl-agent-log-pipe: $fails failed"; exit 1; }
