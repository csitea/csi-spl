#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL_CMD_GUARD_IMPL=py|shadow|rust in force-push-guard-hook.sh
# (SPL-5392, the Rust pilot; spec 011 rust-candidates-analysis.md 6.2, 6.3
# row 3), with STUB binaries so it needs no Rust toolchain. The real binary's
# parity: csi-spl-orc/src/rust/spl-cmd-guard/tests/parity.sh (CI rust-suite).
#   1. the mode: unset and no impl file = py (the stub is never run); an
#      unknown value = py; the impl file next to the hook is read; the env
#      wins over the file
#   2. rust: the stub decides (a stub that refuses `git status` refuses it;
#      one that allows a force push lets the force-push part pass), rc 3 is
#      the fail-closed payload refusal, NONE allows, agy keeps its contract,
#      and the kill-target part still runs after a Rust allow
#   3. rust falls back to Python, never to allow (6.3 row 3): no binary, a
#      non-executable one, exit 101, a timeout, an rc 0 answer that is neither
#      NONE nor CMD: - each still refuses `git push --force` and allows
#      `git status`
#   4. shadow: Python decides alone (a stub that allows everything changes
#      no verdict); one log line per call, mode 600, match=1 on agreement,
#      match=0 plus the command on a planted mismatch (the RED control), and
#      rust=error when the binary is missing; an unreadable payload is still
#      refused after its line is written
#------------------------------------------------------------------------------
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/../features/spawn-agents/scripts" && pwd)/force-push-guard-hook.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
unset SPL_CMD_GUARD_IMPL SPL_CMD_GUARD_BIN SPL_CMD_GUARD_TIMEOUT
export SPL_CMD_GUARD_SHADOW_LOG="$T/shadow.tsv"

# stub NAME BODY: an executable stand-in for spl-cmd-guard; it records each run.
stub() {
  printf '#!/usr/bin/env bash\necho run >>"%s/%s.runs"\n%s\n' "$T" "$1" "$2" >"$T/$1"
  chmod +x "$T/$1"
}
payload() { python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))' "$1"; }
# run HARNESS COMMAND [VAR=VAL...]: "rc|stdout|stderr" of one hook call
run() {
  local h="$1" c="$2" out err rc; shift 2
  out="$(payload "$c" | env "$@" bash "$HOOK" "$h" 2>"$T/err")"; rc=$?
  err="$(cat "$T/err")"
  printf '%s|%s|%s' "$rc" "$out" "$err"
}
runs() { [ -f "$T/$1.runs" ] && wc -l <"$T/$1.runs" | tr -d ' ' || echo 0; }

stub deny-all 'cat >/dev/null; printf "stub says no"; exit 2'
stub allow-all 'p="$(cat)"; c="$(printf "%s" "$p" | python3 -c "import json,sys; print(\"CMD:\" + json.load(sys.stdin)[\"tool_input\"][\"command\"], end=\"\")")"; printf "%s" "$c"; exit 0'
stub crash 'cat >/dev/null; exit 101'
stub slow 'cat >/dev/null; sleep 5; printf "CMD:git status"'
stub junk 'cat >/dev/null; printf "hello"; exit 0'
stub unreadable 'cat >/dev/null; exit 3'
stub none 'cat >/dev/null; printf NONE; exit 0'
cp "$T/deny-all" "$T/noexec" && chmod -x "$T/noexec"

# 1. the mode
r="$(run claude 'git status' SPL_CMD_GUARD_BIN="$T/deny-all")"
[ "${r%%|*}" = 0 ] && [ "$(runs deny-all)" = 0 ] && pass "unset: py, the binary never runs" || fail "unset: $r runs=$(runs deny-all)"
r="$(run claude 'git status' SPL_CMD_GUARD_IMPL=rustt SPL_CMD_GUARD_BIN="$T/deny-all")"
[ "${r%%|*}" = 0 ] && [ "$(runs deny-all)" = 0 ] && pass "an unknown value is py" || fail "unknown: $r"
HC="$T/hookcopy"; mkdir -p "$HC"
cp "$HOOK" "$(dirname "$HOOK")/../lib/"*-guard.inc.sh "$HC/"
cp "$T/deny-all" "$HC/spl-cmd-guard"
echo rust >"$HC/spl-cmd-guard.impl"
out="$(payload 'git status' | bash "$HC/force-push-guard-hook.sh" claude 2>&1)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"stub says no"* ]] && pass "the impl file next to the hook is read (rust)" || fail "impl file: rc=$rc $out"
out="$(payload 'git status' | SPL_CMD_GUARD_IMPL=py bash "$HC/force-push-guard-hook.sh" claude 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "SPL_CMD_GUARD_IMPL wins over the file" || fail "env over file: rc=$rc $out"

# 2. rust decides
r="$(run claude 'git status' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/deny-all")"
[ "${r%%|*}" = 2 ] && [[ "$r" == *"force-push-guard: refused: stub says no"* ]] && pass "rust: the binary's refusal is the verdict" || fail "rust deny: $r"
r="$(run claude 'git push --force origin master' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/allow-all")"
[ "${r%%|*}" = 0 ] && pass "rust: the binary's allow is the verdict (Python not asked)" || fail "rust allow: $r"
r="$(run claude 'kill 1' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/allow-all")"
[ "${r%%|*}" = 2 ] && [[ "$r" == *kill-guard* ]] && pass "rust: the kill-target part still runs after a Rust allow" || fail "rust kill: $r"
r="$(run claude 'git status' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/unreadable")"
[ "${r%%|*}" = 2 ] && [[ "$r" == *"cannot read the claude hook payload (fail closed)"* ]] && pass "rust: rc 3 refuses (fail closed)" || fail "rust rc3: $r"
r="$(run agy 'git status' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/none")"
[ "$r" = '0|{"decision":"allow"}|' ] && pass "rust: NONE allows, agy's allow JSON" || fail "rust none agy: $r"
r="$(run agy 'git status' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/deny-all")"
[ "${r%%|*}" = 0 ] && [[ "$r" == *'"decision": "deny"'*'stub says no'* ]] && pass "rust: agy deny JSON on exit 0" || fail "rust agy deny: $r"

# 3. rust falls back to Python, never to allow
for b in missing noexec crash slow junk; do
  r1="$(run claude 'git push --force origin master' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/$b" SPL_CMD_GUARD_TIMEOUT=1)"
  r2="$(run claude 'git status' SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/$b" SPL_CMD_GUARD_TIMEOUT=1)"
  if [ "${r1%%|*}" = 2 ] && [[ "$r1" == *"rewrites remote history"* ]] && [ "${r2%%|*}" = 0 ]; then
    pass "rust, binary $b: Python decides (force push refused, git status allowed)"
  else fail "rust fallback $b: $r1 / $r2"; fi
done

# 4. shadow
rm -f "$SPL_CMD_GUARD_SHADOW_LOG"
r="$(run claude 'git push --force origin master' SPL_CMD_GUARD_IMPL=shadow SPL_CMD_GUARD_BIN="$T/allow-all")"
[ "${r%%|*}" = 2 ] && [[ "$r" == *"rewrites remote history"* ]] && pass "shadow: Python's refusal stands over a Rust allow" || fail "shadow py decides: $r"
r="$(run claude 'git status' SPL_CMD_GUARD_IMPL=shadow SPL_CMD_GUARD_BIN="$T/deny-all")"
[ "${r%%|*}" = 0 ] && pass "shadow: Python's allow stands over a Rust refusal" || fail "shadow py allows: $r"
r="$(run claude 'ls -l' SPL_CMD_GUARD_IMPL=shadow SPL_CMD_GUARD_BIN="$T/allow-all")"
r="$(run claude 'ls' SPL_CMD_GUARD_IMPL=shadow SPL_CMD_GUARD_BIN="$T/missing")"
[ "${r%%|*}" = 0 ] && pass "shadow: a missing binary blocks nothing" || fail "shadow missing: $r"
out="$(printf 'not json' | SPL_CMD_GUARD_IMPL=shadow SPL_CMD_GUARD_BIN="$T/unreadable" bash "$HOOK" claude 2>&1)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"cannot read the claude hook payload"* ]] && pass "shadow: an unreadable payload is still refused" || fail "shadow unreadable: rc=$rc $out"
L="$SPL_CMD_GUARD_SHADOW_LOG"
mapfile -t lines <"$L"
[ "${#lines[@]}" = 5 ] && pass "shadow: one log line per call (5)" || fail "shadow lines: ${#lines[@]}: $(cat "$L")"
[ "$(stat -c %a "$L")" = 600 ] && pass "shadow: the log is mode 600" || fail "shadow log mode $(stat -c %a "$L")"
[[ "${lines[0]}" == *$'\tclaude\tmatch=0\tpy=refuse:git push --force rewrites remote history'*$'\trust=allow\tpy_ms='*'rust_ms='*$'\tgit\\ push\\ --force\\ origin\\ master' ]] &&
  pass "shadow RED control: a planted Rust allow is logged match=0 with the command" || fail "shadow mismatch line: ${lines[0]}"
[[ "${lines[1]}" == *$'\tmatch=0\tpy=allow\trust=refuse:stub says no\t'* ]] && pass "shadow: a planted Rust refusal is logged match=0" || fail "shadow line 2: ${lines[1]}"
[[ "${lines[2]}" == *$'\tmatch=1\tpy=allow\trust=allow\tpy_ms='*'rust_ms='* ]] && [[ "${lines[2]}" != *ls* ]] &&
  pass "shadow: agreement is match=1 and logs no command" || fail "shadow match line: ${lines[2]}"
[[ "${lines[3]}" == *$'\tmatch=0\tpy=allow\trust=error\t'* ]] && pass "shadow: a missing binary is rust=error" || fail "shadow error line: ${lines[3]}"
[[ "${lines[4]}" == *$'\tmatch=1\tpy=unreadable\trust=unreadable\t'* ]] && pass "shadow: unreadable on both sides matches" || fail "shadow unreadable line: ${lines[4]}"

echo "force-push-guard-hook-impl: $((n - fails))/$n passed"
[ "$fails" = 0 ]
