#!/usr/bin/env bash
# The four launchers, rendered with SPAWN_DRY_RUN=1: spool root, spool
# protocol in the seed prompt, id guards, worktree plan, and parity (the four
# kinds say the same thing once their own declarations are normalised).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
WD="$T_TMP/plain"; mkdir -p "$WD"
echo brief > "$T_TMP/brief.md"

for k in claude grok agy qwen; do
  p="$(printf '%s' "$k" | sed 's/claude/CLE/;s/grok/GRK/;s/agy/AGY/;s/qwen/QWN/')"
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
  has "$k: prompt names the orchestrator" "today CLE-00 here" "$prompt"
  has "$k: reports go to the lease holder (specs/058 N1)" "--to orchestrator" "$prompt"
  # CLE-77896: three lanes once greeted one new member; no lane posts social messages.
  has "$k: prompt forbids greetings and social posts" "Never post greetings, welcomes or social messages; only post what your brief asks for." "$prompt"
  # CLE-77938 (owner 2026-10-02): one agent does one small task, then exits.
  has "$k: prompt limits the lane to one small task" "You do ONE small task. If someone sends you a different task, refuse it and tell CLE-00 so it spawns a new lane. When your task is verified done: report and /exit-clean." "$prompt"
  hasnt "$k: no markdown-inbox root" "/var/tmp/claude/msgs" "$prompt"
  hasnt "$k: no inbox-send.sh" "inbox-send" "$prompt"
  hasnt "$k: no git closing steps outside a repo" "INTEGRATION / CLOSING STEPS" "$prompt"
  launch="$(cat "$T_TMP/plan-$k/launch.cmd")"
  has "$k: launch exports SPOOL_ROOT" "SPOOL_ROOT='${SPOOL_ROOT}'" "$launch"
  has "$k: launch exports SPOOL_AGENT_ID" "SPOOL_AGENT_ID='${p}-77'" "$launch"
  has "$k: the CLI starts through spool-harness --as (spec 012 T013), mirrored (specs/036)" "spool-harness.sh' --as '${p}-77' --mirror -- '" "$launch"
  [ "$k" = grok ] && printf '%s\n' "$out" > "$T_TMP/grok.out"
  # Normalise the kind-specific parts for the parity check below.
  printf '%s' "$prompt" | sed -E "s/^As your VERY FIRST action, .*\. Then read your full task brief/Then read your full task brief/; s/${p}-77([^0-9]|$)/ID\1/g" > "$T_TMP/norm-$k"
done
# GUARD: inside the test sandbox a spawn WITHOUT SPAWN_DRY_RUN=1 is refused
# before any side effect (no spool dir, no plan, no launch).
GR="$T_TMP/guard"; mkdir -p "$GR"
( unset SPAWN_DRY_RUN; CLAUDE_BIN=/bin/false timeout 20 bash "$T_SCRIPTS/spawn-claude.sh" CLE-99 "$WD" "$T_TMP/brief.md" guard >"$GR/out" 2>&1 ); grc=$?
check "guard: a non-dry-run spawn in the test sandbox is refused (rc 3)" [ "$grc" -eq 3 ]
check "guard: ... and it created no spool dir" [ ! -e "$SPOOL_ROOT/CLE-99" ]
check "guard: ... and says why" grep -q 'SPAWN_TEST_SANDBOX=1 without SPAWN_DRY_RUN=1' "$GR/out"

check "parity: claude and grok prompts match after normalisation" cmp -s "$T_TMP/norm-claude" "$T_TMP/norm-grok"
check "parity: claude and agy prompts match after normalisation" cmp -s "$T_TMP/norm-claude" "$T_TMP/norm-agy"
check "parity: claude and qwen prompts match after normalisation" cmp -s "$T_TMP/norm-claude" "$T_TMP/norm-qwen"

has "agy: prompt goes after --prompt-interactive" '--prompt-interactive "' "$(cat "$T_TMP/plan-agy/launch.cmd")"
has "qwen: prompt goes after --prompt-interactive" '--prompt-interactive "' "$(cat "$T_TMP/plan-qwen/launch.cmd")"
has "qwen: --yolo approves tool calls" "--yolo" "$(cat "$T_TMP/plan-qwen/launch.cmd")"
has "qwen: retitles through riname --agent" "riname.sh --agent QWN-77" "$(cat "$T_TMP/plan-qwen/launch.cmd")"
has "claude: session named after the id" "--name 'CLE-77'" "$(cat "$T_TMP/plan-claude/launch.cmd")"
has "grok: retitles through riname --agent" "riname.sh --agent GRK-77 \\\"do the thing\\\"" "$(cat "$T_TMP/plan-grok/launch.cmd")"
has "grok: claude permission flag, which this grok build accepts" "--dangerously-skip-permissions" "$(cat "$T_TMP/plan-grok/launch.cmd")"
has "grok: permission mode does not depend on config.toml" "--permission-mode bypassPermissions" "$(cat "$T_TMP/plan-grok/launch.cmd")"
has "grok: resume stub repeats the permission flags" "--permission-mode bypassPermissions --resume" "$(cat "$T_TMP/grok.out")"

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
# CLE-77920 (specs/058 N2): the scope check reads the FLEET-WIDE lane map,
# and the spawn writes this agent's row (dry run: planned, nothing sent).
has "git: scope check reads the fleet lane map" "lane-map.sh' - every live agent on EVERY machine" "$prompt"
has "git: scope check can test paths" "--check <path,...> --agent CLE-79" "$prompt"
has "git: the spawn plans its lane row" "PLAN lane       lane-map.sh put --agent CLE-79 --repo repo --branch CLE-79-fix-it --scope 'fix it'" "$out"
printf '# Brief: fleet lane map\nbody\n' > "$T_TMP/brief-h.md"
out="$(bash "$T_SCRIPTS/spawn-claude.sh" CLE-81 "$T_TMP/repo" "$T_TMP/brief-h.md" "fix it" 2>&1)"
has "git: the lane scope is the brief's first heading" "--scope 'fleet lane map'" "$out"
out="$(SPAWN_LANE_SCOPE='lane map' SPAWN_LANE_FILES=a/b,c SPAWN_LANE_TOPIC=t-1 bash "$T_SCRIPTS/spawn-claude.sh" CLE-80 "$T_TMP/repo" "$T_TMP/brief.md" "fix it" 2>&1)"
has "git: SPAWN_LANE_* fill the row" "--scope 'lane map' --files 'a/b,c' --topic 't-1'" "$out"
has "git: leak gate quotes the identity" "dev@example.com dev@example.com" "$prompt"
has "git: red-run owners are told via spool-send" "tell them with spool-send.sh" "$prompt"
# SPL-1253: the deploy-gate footer rides every git-repo brief.
has "git: deploy-gate footer names the pre-push command" "./run -a do_check_pre_push" "$prompt"
has "git: deploy-gate footer requires Postgres, not memory" "must run on POSTGRES" "$prompt"
has "git: deploy-gate footer names the audited override" "SPL_PREPUSH_OVERRIDE=1" "$prompt"
has "git: deploy-gate footer forbids a working-around of a refused prd mutation" "do_spl_desk_up" "$prompt"
# CLE-77829: the gate's lint parts, the re-run after the rebase, the scanner reds.
has "git: deploy-gate footer re-runs the gate after the rebase" "AGAIN after the mandatory rebase" "$prompt"
has "git: deploy-gate footer names the lint parts" "do_check_pre_push_lint" "$prompt"
has "git: deploy-gate footer names the tool installer" "do_install_lint_tools" "$prompt"
has "git: deploy-gate footer checks the scanner workflows on the sha" "gh run list --commit <sha>': 61..67 and 85" "$prompt"
has "git: deploy-gate footer: a scanner red on your sha is yours" "a scanner red on your sha is your red" "$prompt"
# ... and NOT on a non-git session (checked at the top loop).
hasnt "claude: no deploy-gate footer outside a repo" "DEPLOY-GATE (SPL-1250" "$(cat "$T_TMP/plan-claude/prompt.txt")"

t_done
