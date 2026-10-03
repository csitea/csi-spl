#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: render-yield.sh, hermetic, on a fake claude-config render.
#   1. refusals: no --render, a render without the role's manifest
#   2. every engine row install.sh writes is dropped (skills, commands, qwen),
#      with its file; the header and every other row stay, in order
#   3. the other role's manifest is untouched
#   4. a re-run drops nothing and changes nothing
#   5. the real spawn-agents assets: exit-clean, kill-your-self, agent-msg and
#      the spawn commands are harness-owned; graft and tmux-color are not
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
Y="$TEST_DIR/../render-yield.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# --- fixtures ---------------------------------------------------------------
A="$T/assets"
mkdir -p "$A/skills/exit-clean" "$A/skills/agent-msg" "$A/commands"
: >"$A/skills/exit-clean/SKILL.md"; : >"$A/skills/agent-msg/SKILL.md"
: >"$A/commands/claude-spawn.md"
R="$T/render"; mkdir -p "$R"
rows=".bashrc
.claude/skills/exit-clean/SKILL.md
.claude/skills/graft/SKILL.md
.claude/skills/agent-msg/SKILL.md
.claude/commands/claude-spawn.md
.claude/commands/signed-prompt.md
.qwen/skills/claude-spawn/SKILL.md"
for role in agent owner; do
  printf 'path\tmode\tblob\tbytes\tkind\tname\tlayer\tsource\n' >"$R/$role.manifest.tsv"
  while IFS= read -r p; do
    mkdir -p "$(dirname "$R/$role/$p")" && echo x >"$R/$role/$p"
    printf '%s\t644\tb\t2\tk\tn\tengine\tsrc\n' "$p" >>"$R/$role.manifest.tsv"
  done <<<"$rows"
done
cp "$R/owner.manifest.tsv" "$T/owner.before"

# --- 1. refusals ------------------------------------------------------------
bash "$Y" --assets "$A" >/dev/null 2>&1; [ $? = 2 ] && pass "no --render: exit 2" || fail "no --render did not exit 2"
bash "$Y" --render "$T/none" --assets "$A" >/dev/null 2>&1; [ $? = 2 ] && pass "no manifest: exit 2" || fail "no manifest did not exit 2"

# --- 2. the agent role ------------------------------------------------------
out=$(bash "$Y" --render "$R" --assets "$A"); rc=$?
[ $rc = 0 ] && pass "a yield exits 0" || fail "a yield exited $rc"
[ "$(grep -c '^yield ' <<<"$out")" = 4 ] && pass "4 harness rows yielded" || fail "yielded: $(grep -c '^yield ' <<<"$out") (want 4)"
grep -qx 'render-yield: role=agent yielded=4 kept=3' <<<"$out" && pass "summary line" || fail "summary: $(tail -n1 <<<"$out")"
got=$(cut -f1 "$R/agent.manifest.tsv" | tr '\n' ' ')
[ "$got" = "path .bashrc .claude/skills/graft/SKILL.md .claude/commands/signed-prompt.md " ] \
  && pass "header + the other rows kept, in order" || fail "agent manifest now: $got"
for p in .claude/skills/exit-clean/SKILL.md .claude/skills/agent-msg/SKILL.md .claude/commands/claude-spawn.md .qwen/skills/claude-spawn/SKILL.md; do
  [ -e "$R/agent/$p" ] && fail "file kept: $p" || pass "file dropped: $p"
done
[ -e "$R/agent/.claude/skills/graft/SKILL.md" ] && pass "a non-harness file kept" || fail "graft was dropped"

# --- 3. the other role ------------------------------------------------------
cmp -s "$R/owner.manifest.tsv" "$T/owner.before" && [ -e "$R/owner/.claude/skills/exit-clean/SKILL.md" ] \
  && pass "the owner role is untouched" || fail "the owner role changed"

# --- 4. a re-run ------------------------------------------------------------
cp "$R/agent.manifest.tsv" "$T/agent.before"
out=$(bash "$Y" --render "$R" --assets "$A")
grep -qx 'render-yield: role=agent yielded=0 kept=3' <<<"$out" && cmp -s "$R/agent.manifest.tsv" "$T/agent.before" \
  && pass "a re-run changes nothing" || fail "a re-run: $out"

# --- 5. the real assets -----------------------------------------------------
R2="$T/real"; mkdir -p "$R2"
printf 'path\n.claude/skills/exit-clean/SKILL.md\n.claude/skills/kill-your-self/SKILL.md\n.claude/skills/agent-msg/SKILL.md\n.claude/commands/claude-spawn.md\n.claude/commands/tmux-close-window.md\n.claude/skills/graft/SKILL.md\n.claude/skills/tmux-color/SKILL.md\n' >"$R2/agent.manifest.tsv"
out=$(bash "$Y" --render "$R2")
grep -qx 'render-yield: role=agent yielded=5 kept=2' <<<"$out" && pass "real assets: 5 harness names yielded, graft + tmux-color kept" \
  || fail "real assets: $out"

[ "$fails" -eq 0 ] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
