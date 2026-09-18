#!/usr/bin/env bash
# The three launchers, rendered with SPAWN_DRY_RUN=1: spool root, spool
# protocol in the seed prompt, id guards, worktree plan, and parity (the three
# kinds say the same thing once their own declarations are normalised).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
WD="$T_TMP/plain"; mkdir -p "$WD"
echo brief > "$T_TMP/brief.md"

for k in claude grok agy; do
  p="$(printf '%s' "$k" | sed 's/claude/CLE/;s/grok/GRK/;s/agy/AGY/')"
  mkdir -p "$T_TMP/plan-$k"
  out="$(SPAWN_PLAN_DIR="$T_TMP/plan-$k" bash "$T_SCRIPTS/spawn-$k.sh" "$p-77" "$WD" "$T_TMP/brief.md" "do the thing" 2>&1)"; rc=$?
  eq "$k: dry run exits 0" 0 "$rc"
  has "$k: spool dir planned under SPOOL_ROOT" "PLAN spooldir   ${SPOOL_ROOT}/${p}-77/{inbox,outbox,archive}" "$out"
  check "$k: dry run created nothing" test ! -e "$SPOOL_ROOT/$p-77"
  has "$k: non-git WORKDIR runs in place" "PLAN worktree   none: ${WD}" "$out"
  prompt="$(cat "$T_TMP/plan-$k/prompt.txt")"
  has "$k: prompt names the spool id" "Your spool agent id is ${p}-77" "$prompt"
  has "$k: prompt teaches spool recv" "SPOOL_ROOT=${SPOOL_ROOT} /opt/x/spool recv --as ${p}-77" "$prompt"
  has "$k: prompt teaches spool-send.sh" "spool-send.sh --from ${p}-77 --to <PEER-ID>" "$prompt"
  has "$k: prompt says local mode is unsigned" "UNSIGNED" "$prompt"
  has "$k: prompt names the orchestrator" "orchestrator CLE-00" "$prompt"
  hasnt "$k: no markdown-inbox root" "/var/tmp/claude/msgs" "$prompt"
  hasnt "$k: no inbox-send.sh" "inbox-send" "$prompt"
  hasnt "$k: no git closing steps outside a repo" "INTEGRATION / CLOSING STEPS" "$prompt"
  launch="$(cat "$T_TMP/plan-$k/launch.cmd")"
  has "$k: launch exports SPOOL_ROOT" "SPOOL_ROOT='${SPOOL_ROOT}'" "$launch"
  has "$k: launch exports SPOOL_AGENT_ID" "SPOOL_AGENT_ID='${p}-77'" "$launch"
  # Normalise the kind-specific parts for the parity check below.
  printf '%s' "$prompt" | sed -E "s/^As your VERY FIRST action, .*\. Then read your full task brief/Then read your full task brief/; s/${p}-77/ID/g" > "$T_TMP/norm-$k"
done
check "parity: claude and grok prompts match after normalisation" cmp -s "$T_TMP/norm-claude" "$T_TMP/norm-grok"
check "parity: claude and agy prompts match after normalisation" cmp -s "$T_TMP/norm-claude" "$T_TMP/norm-agy"

has "agy: prompt goes after --prompt-interactive" '--prompt-interactive "' "$(cat "$T_TMP/plan-agy/launch.cmd")"
has "claude: session named after the id" "--name 'CLE-77'" "$(cat "$T_TMP/plan-claude/launch.cmd")"
has "grok: retitles through riname --agent" "riname.sh --agent GRK-77 \\\"do the thing\\\"" "$(cat "$T_TMP/plan-grok/launch.cmd")"

# ---- the prompt survives shell-live bytes -----------------------------------
out="$(bash "$T_SCRIPTS/spawn-grok.sh" GRK-78 "$WD" "$T_TMP/brief.md" 'x $(touch '"$T_TMP"'/pwned) `id` "q"' 2>&1)"
check "a hostile slug is not executed at render time" test ! -e "$T_TMP/pwned"

# ---- id guards ---------------------------------------------------------------
bash "$T_SCRIPTS/spawn-claude.sh" GRK-77 "$WD" >/dev/null 2>&1; eq "claude refuses a GRK id" 1 "$?"
bash "$T_SCRIPTS/spawn-claude.sh" BOX-1 "$WD" >/dev/null 2>&1;  eq "BOX- id refused" 1 "$?"
bash "$T_SCRIPTS/spawn-claude.sh" "" "$WD" >/dev/null 2>&1;     eq "empty id refused" 1 "$?"
bash "$T_SCRIPTS/spawn-claude.sh" CLE-7 >/dev/null 2>&1;        eq "missing WORKDIR refused" 1 "$?"

# ---- a git repo with an origin: own worktree + closing steps -----------------
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null
mkdir -p "$T_TMP/plan-git"
out="$(SPAWN_PLAN_DIR="$T_TMP/plan-git" SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' bash "$T_SCRIPTS/spawn-claude.sh" CLE-79 "$T_TMP/repo" "$T_TMP/brief.md" "fix it" 2>&1)"
has "git: worktree planned beside the repo" "PLAN worktree   add ${T_TMP}/repo-wt/CLE-79 -b CLE-79-fix-it origin/master" "$out"
check "git: dry run added no worktree" test ! -e "$T_TMP/repo-wt"
prompt="$(cat "$T_TMP/plan-git/prompt.txt")"
has "git: closing steps present" "INTEGRATION / CLOSING STEPS" "$prompt"
has "git: scope control present" "SCOPE + COLLISION CONTROL" "$prompt"
has "git: leak gate quotes the identity" "dev@example.com dev@example.com" "$prompt"
has "git: red-run owners are told via spool-send" "tell them with spool-send.sh" "$prompt"

t_done
