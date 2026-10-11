#!/usr/bin/env bash
# perf-agent-hook.sh — the speed budget of spool-agent-hook.sh (spec 093: 50 ms
# a run), on its own, out of the gating test-agent-hook.sh. Exit 1 when the
# hook's fastest run is over budget. run-ci-tests.sh runs every perf-*.sh after
# the pool and REPORTS its verdict: it never turns wf 10 red.
#
# Why it does not gate (c-954, 2026-10-11, the 29 wf 10 runs of the last 300
# that reached the orc feature tests): the unchanged hook's fastest of 200 read
# 14 .. 25 ms on the 4 hosted runs (load ~1), and 27 .. 101 ms on the 25 sat
# runs (6 runners on 16 cores, load 9 .. 58); 6 of those 25 read 41 .. 48 ms,
# within 9 ms of the budget, and run 38094820012 read 101 ms (load 33.36) with
# the bare interpreter's fastest at 14 ms. Two prior fixes (a 90 s resample,
# df659ca92; a loaded-floor ratio, a02292721) still left it red: what it
# measures on sat is the runner, not the hook.
#
# Env: PERF_HOOK (default: the real hook) — the red control plants a sleep in a
# copy; HOOK_BUDGET_MS (50); HOOK_RETRY_S (90): a fastest run over budget is
# sampled again, 20 runs a round 2 s apart, until one is under or time is up.
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
HOOK="${PERF_HOOK:-$T_SCRIPTS/spool-agent-hook.sh}"
ID=c-901
D="$SPOOL_ROOT/$ID"
mkdir -p "$D/inbox" "$D/archive"
export SPOOL_HARNESS=claude SPOOL_BOX_ID=box-t HOOK_PID=4242
BUDGET="${HOOK_BUDGET_MS:-50}"

ms() { local a b; a=$(date +%s%N); "$@" >/dev/null 2>&1; b=$(date +%s%N); echo $(( (b - a) / 1000000 )); }
pct() { sort -n "$1" | awk -v q="$2" '{a[NR]=$1} END{i=int(NR*q/100+0.999); print a[i<1?1:i]}'; }
over() { awk -v b="$2" '$1 >= b' "$1" | wc -l; }
fast() { awk -v h="$1" -v b="$2" 'BEGIN{exit !(h < b)}'; }
yn() { "$@" && echo y || echo n; }
resample() {  # SCRIPT MIN WINDOW_S -> "<min> <extra runs>"
  local s="$1" m="$2" end=$(( $(date +%s) + $3 )) n=0 t
  while ! fast "$m" "$BUDGET" && [ "$(date +%s)" -lt "$end" ]; do
    sleep 2
    for _ in $(seq 20); do
      t="$(ms bash "$s" PostToolUse <"$T_TMP/pay.json")"; n=$((n + 1))
      [ "$t" -lt "$m" ] && m="$t"
    done
  done
  echo "$m $n"
}

echo "# the controls of the judge itself"
eq "CONTROL: the budget fires at ${BUDGET} ms, not at $((BUDGET - 1))" "n y" "$(yn fast "$BUDGET" "$BUDGET") $(yn fast $((BUDGET - 1)) "$BUDGET")"
printf '%s\n' 10 20 30 40 50 60 70 80 90 100 > "$T_TMP/t.ctl"
eq "CONTROL: pct reads the 90th, the 50th and the 0th (min) percentile" "90 50 10" "$(pct "$T_TMP/t.ctl" 90) $(pct "$T_TMP/t.ctl" 50) $(pct "$T_TMP/t.ctl" 0)"
printf '%s\n' 10 20 61 > "$T_TMP/t.ctl"
eq "CONTROL: the over-budget counter fires on a 61 ms run" 1 "$(over "$T_TMP/t.ctl" "$BUDGET")"

echo "# the hook's fastest of 200 runs against ${BUDGET} ms"
pay='{"tool_name":"Bash","tool_input":{"command":"make"},"tool_response":"ok"}'
printf '%s\n' "$pay" > "$T_TMP/pay.json"
# The floor has the hook's shape (bash, then exec python3 -S) and does nothing:
# what the harness pays for any hook on this box at this load. Reported only.
printf '%s\n' 'exec python3 -S -c pass' > "$T_TMP/floor.sh"
: > "$T_TMP/t.hook"; : > "$T_TMP/t.floor"
export SPOOL_AGENT_ID="$ID"
# Warm-up, not measured: a cold page cache is not the hook's cost.
for _ in $(seq 5); do
  bash "$HOOK" PostToolUse <"$T_TMP/pay.json" >/dev/null 2>&1
  bash "$T_TMP/floor.sh" PostToolUse <"$T_TMP/pay.json" >/dev/null 2>&1
done
for _ in $(seq 200); do
  ms bash "$HOOK" PostToolUse <"$T_TMP/pay.json" >>"$T_TMP/t.hook"
  ms bash "$T_TMP/floor.sh" PostToolUse <"$T_TMP/pay.json" >>"$T_TMP/t.floor"
done
lh="$(pct "$T_TMP/t.hook" 0)"; lf="$(pct "$T_TMP/t.floor" 0)"
echo "  hook min/median/p90 ${lh}/$(pct "$T_TMP/t.hook" 50)/$(pct "$T_TMP/t.hook" 90) ms, bare python3 ${lf}/$(pct "$T_TMP/t.floor" 50)/$(pct "$T_TMP/t.floor" 90) ms, over ${BUDGET} ms: $(over "$T_TMP/t.hook" "$BUDGET")/200, load $(cut -d' ' -f1 /proc/loadavg), nproc $(nproc)"
read -r lh2 nx < <(resample "$HOOK" "$lh" "${HOOK_RETRY_S:-90}")
[ "$nx" -eq 0 ] || echo "  fastest of 200 was $lh ms: $nx more runs, fastest $lh2 ms, load $(cut -d' ' -f1 /proc/loadavg)"
if fast "$lh2" "$BUDGET"; then ok "the hook's fastest of $((200 + nx)) runs ($lh2 ms) is under ${BUDGET} ms"
else nok "the hook's fastest of $((200 + nx)) runs ($lh2 ms) is not under ${BUDGET} ms (bare interpreter: $lf ms, load $(cut -d' ' -f1 /proc/loadavg))"; fi
# The planted regression: the same hook behind a 100 ms sleep, through the
# same resample, from a start over budget (one round of 20, ~3 s).
printf 'sleep 0.1; exec bash %q "$@"\n' "$HOOK" > "$T_TMP/slow-hook.sh"
read -r ls nxs < <(resample "$T_TMP/slow-hook.sh" 99999 1)
eq "CONTROL: a 100 ms sleep in the hook stays over ${BUDGET} ms through the resample (fastest of $nxs: $ls ms)" "n" "$(yn fast "$ls" "$BUDGET")"
# The bound on EVERY run is opt-in: HOOK_BUDGET_MS=<ms> on a box known to be idle.
if [ -n "${HOOK_BUDGET_MS:-}" ]; then
  eq "200 runs, each under ${BUDGET} ms (HOOK_BUDGET_MS, load $(cut -d' ' -f1 /proc/loadavg))" 0 "$(over "$T_TMP/t.hook" "$BUDGET")"
fi
unset SPOOL_AGENT_ID
t_done
