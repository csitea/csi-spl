#!/usr/bin/env bash
# The truth rule is the FIRST sentence of every agent's seed (SPL-2097; owner
# HUM-10, t1 04d9c246 msg 3e1eb819: "a special mention at the very beginning
# of the instruction to the agents ... Verify their statements empirically").
# Its one home is assets/seed-truth-rule.txt, read by spool_truth_rule. The
# four seed builders, each rendered for real:
#   1. spawn-core       every vendor's lane seed (SPAWN_DRY_RUN, SPAWN_PLAN_DIR)
#   2. spawn-chain-core chain and task prompts (CHAIN_PRINT=1)
#   3. lane rotation    spl_lane_rotate_prompt_head, and spawn-core with it as head
#   4. role rotation    spl_rotate_prompt_head
# Control: the same builders with the rule's uses removed (the source before
# SPL-2097) -> no output starts with the rule.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe SPOOL_MISTRAL_MAX_PRICE=1
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
RULE_FILE="$T_FEAT/assets/seed-truth-rule.txt"
RULE="$(cat "$RULE_FILE")"
T_RUN="$(cd "$T_FEAT/../../run" && pwd)"
copies() { grep -oF -- "$RULE" <<<"$1" | wc -l; }

check "the rule's one home exists" test -s "$RULE_FILE"
check "the rule opens with TRUTH FIRST" [ "${RULE#TRUTH FIRST (owner order): }" != "$RULE" ]
check "the rule is at most 300 bytes (got $(printf '%s' "$RULE" | wc -c))" [ "$(printf '%s' "$RULE" | wc -c)" -le 300 ]
eq "the rule is one line" 1 "$(wc -l <"$RULE_FILE")"

echo brief >"$T_TMP/brief.md"
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

# The control tree: this feature and the rotation files, every
# spool_truth_rule use removed, as before SPL-2097. spl-rotate-lib reaches
# lib/bash/funcs three dirs up from run/: the control keeps that depth.
CTL="$T_TMP/x/ctl"; mkdir -p "$CTL/features/spawn-agents" "$CTL/run" "$T_TMP/lib/bash"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$T_FEAT/assets" "$CTL/features/spawn-agents/"
cp "$T_RUN"/spl-lane-rotate.func.sh "$T_RUN"/spl-rotate-lib.func.sh "$T_RUN"/spl-dispatch-lease.func.sh "$CTL/run/"
ln -s "$(cd "$T_RUN/../../../lib/bash/funcs" && pwd)" "$T_TMP/lib/bash/funcs"
sed -i 's/\$(spool_truth_rule) //; s/"\$(spool_truth_rule)" //; s/%s\\n\\nROTATION/ROTATION/; /PROMPT="\${rule}"/d' \
  "$CTL"/features/spawn-agents/scripts/spawn-core.inc.sh "$CTL"/features/spawn-agents/scripts/spawn-chain-core.inc.sh "$CTL"/run/*.func.sh
check "control: the old source renders no rule" sh -c "! grep -n 'spool_truth_rule) \|PROMPT=\"\${rule}\"' '$CTL'/features/spawn-agents/scripts/*.sh '$CTL'/run/*.sh"

# --- 1. spawn-core: every vendor --------------------------------------------
seed() {  # FEAT_DIR KIND ID WORKDIR PLAN -> the rendered seed
  mkdir -p "$5"
  SPAWN_PLAN_DIR="$5" bash "$1/scripts/spawn-$2.sh" "$3" "$4" "$T_TMP/brief.md" "truth" >"$5/out" 2>&1
  cat "$5/prompt.txt" 2>/dev/null
}
for k in claude grok agy qwen mistral; do
  id='c-079'; [ "$k" = grok ] && id='g-079'; [ "$k" = agy ] && id='a-079'
  [ "$k" = qwen ] && id='q-079'; [ "$k" = mistral ] && id='m-079'
  s="$(seed "$T_FEAT" "$k" "$id" "$T_TMP/repo" "$T_TMP/plan-$k")"
  check "1. $k: the seed starts with the truth rule, then the rename line" [ "${s#"$RULE As your VERY FIRST action"}" != "$s" ]
  eq "1. $k: ... once" 1 "$(copies "$s")"
  c="$(seed "$CTL/features/spawn-agents" "$k" "$id" "$T_TMP/repo" "$T_TMP/ctl-$k")"
  has "1. $k: control renders a seed" "Your spool agent id is ${id}" "$c"
  check "1. $k: control (old source): the seed does not start with the rule -> FAIL" [ "${c#"$RULE"}" = "$c" ]
done

# --- 2. spawn-chain-core: chain and task, claude and grok -------------------
chain() {  # FEAT_DIR SCRIPT ARGS... -> the printed command
  CHAIN_PRINT=1 CLAUDE_BIN=claude GROK_BIN=grok SPOOL_ORCHESTRATOR_ID=c-001 bash "$1/scripts/spawn-$2.sh" "${@:3}" 2>&1
}
for v in claude-chain grok-chain claude-task grok-task; do
  case "$v" in *chain) a=(- "$T_TMP/repo" /b/one.md) ;; claude-task) a=(c-007 "$T_TMP/repo" /b/t.md) ;; *) a=(g-008 "$T_TMP/repo" /b/t.md) ;; esac
  out="$(chain "$T_FEAT" "$v" "${a[@]}")"
  has "2. $v: the prompt starts with the truth rule" "\"$RULE " "$out"
  out="$(chain "$CTL/features/spawn-agents" "$v" "${a[@]}")"
  hasnt "2. $v: control (old source): no rule -> FAIL" "\"$RULE " "$out"
done

# --- 3 + 4. the rotation heads ----------------------------------------------
heads() {  # RUN_DIR -> the lane head, a ===== line, the role head
  ( export SPOOL_ROOT="$T_TMP/spool" PROJ_PATH=/opt/x ROTATE_RID=20261016T000000Z-x SPOOL_BOX_USER=box
    # shellcheck disable=SC1091
    source "$1/spl-lane-rotate.func.sh" >/dev/null 2>&1 || exit 1
    spl_lane_rotate_prompt_head c-951 /x/seed.md; printf '\n=====\n'
    spl_rotate_prompt_head c-001 ack-cmd /x/role.seed.md )
}
h="$(heads "$T_RUN")"
eq "3. lane rotation: the head's first line is the truth rule" "$RULE" "$(printf '%s\n' "$h" | sed -n 1p)"
eq "3. ... the ROTATION line follows" ROTATION "$(printf '%s\n' "$h" | sed -n 3p | cut -c1-8)"
eq "4. role rotation: the head's first line is the truth rule" "$RULE" "$(printf '%s\n' "$h" | sed -n '/^=====$/{n;p;q}')"
h="$(heads "$CTL/run")"
has "3+4. control renders both heads" "you are the new c-001 session" "$h"
hasnt "3+4. control (old source): no rule -> FAIL" "$RULE" "$h"

# spawn-core with the lane rotation's head: the rule leads, exactly once
( export SPOOL_ROOT="$T_TMP/spool" PROJ_PATH=/opt/x ROTATE_RID=r
  source "$T_RUN/spl-lane-rotate.func.sh" >/dev/null 2>&1; spl_lane_rotate_prompt_head c-952 /x/seed.md ) >"$T_TMP/head.md"
mkdir -p "$T_TMP/plan-rot"
SPAWN_PROMPT_HEAD_FILE="$T_TMP/head.md" SPAWN_PLAN_DIR="$T_TMP/plan-rot" \
  bash "$T_SCRIPTS/spawn-claude.sh" c-952 "$T_TMP/repo" "$T_TMP/brief.md" rotate >/dev/null 2>&1
s="$(cat "$T_TMP/plan-rot/prompt.txt" 2>/dev/null)"
eq "3. rotation seed: the rule is its first line" "$RULE" "$(printf '%s\n' "$s" | sed -n 1p)"
eq "3. rotation seed: ... once, not a second copy from the lane seed" 1 "$(copies "$s")"
has "3. rotation seed: the ACK-COMMAND follows" "ACK-COMMAND: " "$s"
has "3. rotation seed: the lane seed follows" "As your VERY FIRST action" "$s"

t_done
