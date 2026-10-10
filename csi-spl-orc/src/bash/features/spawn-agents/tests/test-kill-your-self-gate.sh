#!/usr/bin/env bash
# test-kill-your-self-gate.sh — /exit-clean refuses without an ACCEPTED.
#   m-930 ran /exit-clean after c-928's REJECT b26ebbb9 (2026-10-10, attempts
#   `fail:F3 exit-clean`); the rule was prose only. kill-your-self-report.sh
#   --gate (and --reporter, which every exit skill's report send calls) exits
#   0 only on an ACCEPTED from the dispatch holder or the spawner that is newer
#   than every REJECT / SEND-BACK; else one line on stderr and exit 3. Ways out
#   with no ACCEPTED: a role seat (the rotation) and a human's logged override.
# Control: KSR_SCRIPT=<master's kill-your-self-report.sh> runs these checks on
# the old script; the REJECT-only --reporter case lets the report through.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
R="${KSR_SCRIPT:-$T_SCRIPTS/kill-your-self-report.sh}"
W="$T_TMP/wt"
mkdir -p "$W"

N=0
msg() {  # ID TS FROM KIND BODY [DIR]
  N=$((N + 1))
  local d="$SPOOL_ROOT/$1/${6:-archive}"
  mkdir -p "$d"
  jq -n --arg ts "$2" --arg from "$3" --arg kind "$4" --arg body "$5" --arg id "$(printf 'b%07d-0000-4000-8000-000000000000' "$N")" \
    '{v: 1, msg_id: $id, ts: $ts, from: $from, to: "x", kind: $kind, task_id: "dispatch-t", body: $body, files: []}' >"$d/$2--$N.json"
}
life() {  # ID SPAWNER
  mkdir -p "$SPOOL_ROOT/$1/lifetime"
  printf '# Brief\n\nSpawner: %s\n' "$2" >"$SPOOL_ROOT/$1/lifetime/brief.md"
}
gate() {  # ID -> "rc|stderr"
  local e rc
  e="$(SPOOL_AGENT_ID="$1" bash "$R" --gate "$W" 2>&1 >/dev/null)"; rc=$?
  printf '%s|%s' "$rc" "$e"
}

# nothing at all
life m-901 c-928
g="$(gate m-901)"
eq "nothing: refused, exit 3" 3 "${g%%|*}"
has "nothing: the line names the missing ACCEPTED" "refused: no ACCEPTED" "$g"
eq "a refusal is one line" 1 "$(printf '%s\n' "${g#*|}" | wc -l)"

# REJECT only: m-930's shape
life m-930 c-928
msg m-930 2026-10-10T20:59:12Z c-928 msg "REJECT: not landed, the review is only on a branch"
g="$(gate m-930)"
eq "REJECT only: refused" 3 "${g%%|*}"
has "REJECT only: the line names the REJECT" "REJECT b0000001 from c-928 at 2026-10-10T20:59:12Z" "$g"
out="$(SPOOL_AGENT_ID=m-930 bash "$R" --reporter "$W" 2>/dev/null)"; rc=$?
eq "REJECT only: --reporter refuses (exit 3), so the report send has no recipient" "3|" "$rc|$out"

# ACCEPTED from the spawner
life m-902 c-928@box2
msg m-902 2026-10-10T21:00:00Z c-928@box2 result "ACCEPTED: on master at abc1234"
g="$(gate m-902)"
eq "ACCEPTED from the spawner: runs" 0 "${g%%|*}"
has "ACCEPTED: the line names it" "ACCEPTED b0000002 at 2026-10-10T21:00:00Z on task dispatch-t" "$g"
eq "ACCEPTED: --reporter prints the spawner" "c-928@box2" "$(SPOOL_AGENT_ID=m-902 bash "$R" --reporter "$W" 2>/dev/null)"

# REJECT after ACCEPTED
life m-903 c-928
msg m-903 2026-10-10T21:00:00Z c-001@sat note "ACCEPTED"
msg m-903 2026-10-10T21:05:00Z c-929 reject "the control is missing"
g="$(gate m-903)"
eq "REJECT after ACCEPTED: refused" 3 "${g%%|*}"
has "REJECT after ACCEPTED: names the newer REJECT" "REJECT b0000004 from c-929" "$g"

# a SEND-BACK body after an ACCEPTED, unread in the inbox
life m-904 c-928
msg m-904 2026-10-10T21:00:00Z c-002 note "**ACCEPTED** landed"
msg m-904 2026-10-10T21:06:00Z c-002 note "SEND-BACK: CI is red on your sha" inbox
eq "SEND-BACK in the inbox after ACCEPTED: refused" 3 "$(gate m-904 | cut -d'|' -f1)"

# REJECT, fixed, then ACCEPTED
life m-905 c-928
msg m-905 2026-10-10T21:00:00Z c-928 msg "REJECT: not landed"
msg m-905 2026-10-10T21:30:00Z c-928 msg "ACCEPTED: landed at def5678"
eq "ACCEPTED newer than the REJECT: runs" 0 "$(gate m-905 | cut -d'|' -f1)"

# an ACCEPTED from someone who is neither the dispatch holder nor the spawner
life m-906 c-928
msg m-906 2026-10-10T21:00:00Z c-777 msg "ACCEPTED, looks good to me"
eq "ACCEPTED from a peer lane: refused" 3 "$(gate m-906 | cut -d'|' -f1)"
mkdir -p "$SPOOL_ROOT/dispatch" && printf 'LEASE_MASTER=c-777\n' >"$SPOOL_ROOT/dispatch/lease.conf"
eq "the same id as the lease.conf dispatch holder: runs" 0 "$(gate m-906 | cut -d'|' -f1)"
rm -f "$SPOOL_ROOT/dispatch/lease.conf"

# a body that only mentions ACCEPTED
life m-907 c-928
msg m-907 2026-10-10T21:00:00Z c-928 msg "not ACCEPTED yet: rebase first"
eq "a body that does not start with ACCEPTED: refused" 3 "$(gate m-907 | cut -d'|' -f1)"

# the rotation: a role seat, REJECT or not
msg c-002 2026-10-10T21:00:00Z c-001 msg "REJECT: stale"
eq "the rotation retires a role seat: runs" 0 "$(gate c-002 | cut -d'|' -f1)"

# a human's override: logged, and needs a reason
eq "EXIT_CLEAN_BY=human with no reason: refused" 3 "$(EXIT_CLEAN_BY=human SPOOL_AGENT_ID=m-930 bash "$R" --gate "$W" >/dev/null 2>&1; echo $?)"
eq "EXIT_CLEAN_BY=human with a reason: runs" 0 "$(EXIT_CLEAN_BY=human EXIT_CLEAN_REASON='owner typed /exit-clean' SPOOL_AGENT_ID=m-930 bash "$R" --gate "$W" >/dev/null 2>&1; echo $?)"
has "the override is logged" "m-930	human	owner typed /exit-clean" "$(cat "$SPOOL_ROOT/exit-override.log" 2>/dev/null)"
hasnt "a refusal never names the override" "EXIT_CLEAN_BY" "$(gate m-930)"

# no id
eq "no agent id: refused" 3 "$(bash "$R" --gate "$W" >/dev/null 2>&1; echo $?)"

# --rebirth and report-only close and retire nothing: --no-gate
eq "--reporter --no-gate: the report still has a recipient" "c-928" "$(SPOOL_AGENT_ID=m-930 bash "$R" --reporter --no-gate "$W" 2>/dev/null)"

# Every vendor renders these two skills: the gate is the first command, and
# a refusal stops the flow before anything is landed, reported or closed.
for s in exit-clean kill-your-self; do
  f="$T_FEAT/assets/skills/$s/SKILL.md"
  gl="$(grep -nF 'kill-your-self-report.sh --gate' "$f" | sed -n 1p | cut -d: -f1)"
  fl="$(grep -nF 'tmux-close-window.sh --agent' "$f" | sed -n 1p | cut -d: -f1)"
  sl="$(grep -nF -- '--kind result' "$f" | sed -n 1p | cut -d: -f1)"
  order=no; [ -n "$gl" ] && [ "$gl" -lt "${sl:-0}" ] && [ "$gl" -lt "${fl:-0}" ] && order=yes
  eq "$s: the gate runs before the report and the close" yes "$order"
  has "$s: a refusal stops the flow" "exits 3: stop" "$(cat "$f")"
  has "$s: --rebirth reports with --no-gate" "--reporter --no-gate" "$(cat "$f")"
done
t_done
