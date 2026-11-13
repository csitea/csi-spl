#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cmd_guard_mode and its per-home script
# spawn-agents/scripts/spl-cmd-guard-install.sh (SPL-5392), hermetic: fake
# homes, a STUB binary (no Rust toolchain needed):
#   1. dry run by default: the plan is printed, nothing is written
#   2. shadow: the binary goes in next to the hook and spl-cmd-guard.impl
#      says shadow; the installed hook then runs in shadow mode (a log line)
#   3. a second install keeps the old binary as spl-cmd-guard.bak
#   4. py: only the impl file changes, the binary stays (one-word rollback),
#      and the hook no longer runs it
#   5. refusals: a bad mode or DRY_RUN is rc 2; a home with no installed hook
#      is rc 3; a binary that fails --self-test is rc 4 and changes nothing
#      (RED control: the same call with a passing binary installs it)
#------------------------------------------------------------------------------
set -uo pipefail
ORC="$(cd "$(dirname "$0")/../../.." && pwd)"
SA="$ORC/src/bash/features/spawn-agents"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
do_log() { echo "$*"; }
export PROJ_PATH="$ORC"
# shellcheck source=../run/spl-cmd-guard-mode.func.sh
. "$ORC/src/bash/run/spl-cmd-guard-mode.func.sh"
unset SPL_CMD_GUARD_IMPL SPL_CMD_GUARD_BIN DRY_RUN

mkhome() {  # NAME: a home with the y13 install in it
  local d="$T/$1/.local/share/spool-agent/force-push-guard"
  mkdir -p "$d"
  cp "$SA/scripts/force-push-guard-hook.sh" "$SA/lib/"*-guard.inc.sh "$d/"
}
stub() {  # NAME VERSION SELFTEST_RC: a stand-in binary that allows everything
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "spl-cmd-guard %s";; --self-test) exit %s;;\nhook) cat >/dev/null; printf NONE;; esac\n' \
    "$2" "$3" >"$T/$1"
  chmod +x "$T/$1"
}
mkhome h1; mkhome h2; mkdir -p "$T/bare"
stub good1 v1 0; stub good2 v2 0; stub broken v0 1
G1="$T/h1/.local/share/spool-agent/force-push-guard" G2="$T/h2/.local/share/spool-agent/force-push-guard"
mode() { SPL_CMD_GUARD_HOMES="$T/h1 $T/h2" do_spl_cmd_guard_mode 2>&1; }

# 1. dry run
out="$(SPL_CMD_GUARD_IMPL=shadow SPL_CMD_GUARD_BIN="$T/good1" mode)"; rc=$?
if [ "$rc" = 0 ] && [[ "$out" == *"PLAN $G1/spl-cmd-guard <- $T/good1 (spl-cmd-guard v1)"* ]] && [[ "$out" == *"PLAN $G2/spl-cmd-guard.impl <- shadow"* ]] &&
  [ ! -e "$G1/spl-cmd-guard" ] && [ ! -e "$G1/spl-cmd-guard.impl" ]; then pass "dry run by default: plans both homes, writes nothing"
else fail "dry run: rc=$rc $out"; fi

# 2. shadow
out="$(SPL_CMD_GUARD_IMPL=shadow SPL_CMD_GUARD_BIN="$T/good1" DRY_RUN=0 mode)"; rc=$?
if [ "$rc" = 0 ] && cmp -s "$T/good1" "$G1/spl-cmd-guard" && cmp -s "$T/good1" "$G2/spl-cmd-guard" &&
  [ "$(cat "$G1/spl-cmd-guard.impl")" = shadow ] && [ "$(cat "$G2/spl-cmd-guard.impl")" = shadow ]; then
  pass "shadow: the binary and the impl file in both homes"
else fail "shadow: rc=$rc $out"; fi
L="$T/shadow.tsv"
printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' |
  env -u SPL_CMD_GUARD_IMPL SPL_CMD_GUARD_SHADOW_LOG="$L" bash "$G1/force-push-guard-hook.sh" claude; rc=$?
[ "$rc" = 0 ] && grep -q $'\tpy=allow\trust=none\t' "$L" && pass "the installed hook runs in shadow mode (the stub's NONE is logged)" ||
  fail "installed hook shadow: rc=$rc $(cat "$L" 2>/dev/null)"

# 3. a second install keeps the first as .bak
SPL_CMD_GUARD_IMPL=rust SPL_CMD_GUARD_BIN="$T/good2" DRY_RUN=0 mode >/dev/null; rc=$?
[ "$rc" = 0 ] && cmp -s "$T/good2" "$G1/spl-cmd-guard" && cmp -s "$T/good1" "$G1/spl-cmd-guard.bak" &&
  [ "$(cat "$G1/spl-cmd-guard.impl")" = rust ] && pass "rust: v2 in, v1 kept as .bak" || fail "second install rc=$rc"

# 4. py: the one-word rollback
SPL_CMD_GUARD_IMPL=py DRY_RUN=0 mode >/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$G2/spl-cmd-guard.impl")" = py ] && cmp -s "$T/good2" "$G2/spl-cmd-guard" &&
  pass "py: the impl file says py, the binary stays" || fail "py rc=$rc"
rm -f "$L"
printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' |
  env -u SPL_CMD_GUARD_IMPL SPL_CMD_GUARD_SHADOW_LOG="$L" bash "$G2/force-push-guard-hook.sh" claude; rc=$?
[ "$rc" = 0 ] && [ ! -e "$L" ] && pass "py: the installed hook no longer runs the binary" || fail "py hook rc=$rc"

# 5. refusals
SPL_CMD_GUARD_IMPL=fast mode >/dev/null; rc=$?
[ "$rc" = 2 ] && pass "a bad mode is rc 2" || fail "bad mode rc=$rc"
SPL_CMD_GUARD_IMPL=py DRY_RUN=yes mode >/dev/null; rc=$?
[ "$rc" = 2 ] && pass "a bad DRY_RUN is rc 2" || fail "bad dry rc=$rc"
bash "$SA/scripts/spl-cmd-guard-install.sh" "$T/bare" py - 0 2>/dev/null; rc=$?
[ "$rc" = 3 ] && pass "a home with no installed hook is rc 3" || fail "bare home rc=$rc"
before="$(cat "$G1/spl-cmd-guard.impl")"
bash "$SA/scripts/spl-cmd-guard-install.sh" "$T/h1" shadow "$T/broken" 0 2>/dev/null; rc=$?
[ "$rc" = 4 ] && cmp -s "$T/good2" "$G1/spl-cmd-guard" && [ "$(cat "$G1/spl-cmd-guard.impl")" = "$before" ] &&
  pass "a binary failing --self-test is rc 4 and changes nothing" || fail "broken binary rc=$rc"
bash "$SA/scripts/spl-cmd-guard-install.sh" "$T/h1" shadow "$T/good1" 0 >/dev/null; rc=$?
[ "$rc" = 0 ] && cmp -s "$T/good1" "$G1/spl-cmd-guard" && pass "RED control: the same call with a passing binary installs it" ||
  fail "control rc=$rc"
bash "$SA/scripts/spl-cmd-guard-install.sh" "$T/h1" shadow - 0 2>/dev/null; rc=$?
[ "$rc" = 4 ] && pass "shadow with no binary is rc 4" || fail "no binary rc=$rc"

echo "spl-cmd-guard-mode: $((n - fails))/$n passed"
[ "$fails" = 0 ]
