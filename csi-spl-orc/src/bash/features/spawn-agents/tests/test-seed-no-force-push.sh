#!/usr/bin/env bash
# The never-force-push rule reaches every kind (owner HUM-10 2026-10-10, msgs
# 853a4084, 9c482b22, 1cdfa5ba: "change the rules for all of the other agent
# types as well"; 1ca01c83: "NOBODY PUSH FORCE'S TO THE MASTER. ONLY AFTER
# EXPLICIT APPROVAL FROM ME"). Renders the seed each of the five launchers writes for a new
# seat (SPAWN_DRY_RUN=1, SPAWN_PLAN_DIR/prompt.txt), in a git repo and in a
# plain dir, and asserts the rule is in it. Control: the same launchers with
# the rule's one home (NO_FORCE in spawn-core.inc.sh) removed, as before the
# rule -> the line is missing for every kind.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe SPOOL_MISTRAL_MAX_PRICE=1
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
RULE="NO FORCE-PUSH. No agent force-pushes master (\`--force\`, \`--force-with-lease\`, \`+ref\`) without the owner's explicit approval of that one push; even then the owner decides who does it, often by hand. Ask and wait; an approval is never permission to go ahead alone. A refused push means someone landed first: fetch, rebase onto origin/master, re-test, push again; never SPL_PREPUSH_OVERRIDE it through. Owner: \"Everyone respects the work of the others. We are team and not a bunch of selfish cawboys\" (2026-10-10)."
echo brief > "$T_TMP/brief.md"
mkdir -p "$T_TMP/plain"
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

# The control tree: this feature's scripts and lib, with the old source of
# spawn-core.inc.sh (the NO_FORCE definition and its rendering removed).
CTL="$T_TMP/ctl/spawn-agents"; mkdir -p "$CTL"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL/"
sed -i '/^NO_FORCE=/d; s/ \${NO_FORCE}//' "$CTL/scripts/spawn-core.inc.sh"
check "control: the old source has no NO_FORCE definition" sh -c "! grep -qE '^NO_FORCE=|[{]NO_FORCE[}]' '$CTL/scripts/spawn-core.inc.sh'"

seed() {  # SCRIPTS_DIR KIND ID WORKDIR PLAN -> prints the rendered seed
  mkdir -p "$5"
  SPAWN_PLAN_DIR="$5" bash "$1/spawn-$2.sh" "$3" "$4" "$T_TMP/brief.md" "no force" >"$5/out" 2>&1
  cat "$5/prompt.txt" 2>/dev/null
}

for k in claude grok agy qwen mistral; do
  id=CLE-79; [ "$k" = grok ] && id=GRK-79; [ "$k" = agy ] && id=AGY-79
  [ "$k" = qwen ] && id=QWN-79; [ "$k" = mistral ] && id=m-079
  for w in repo plain; do
    s="$(seed "$T_SCRIPTS" "$k" "$id" "$T_TMP/$w" "$T_TMP/plan-$k-$w")"
    has "$k/$w: the rendered seed carries the never-force-push rule" "$RULE" "$s"
    hasnt "$k/$w: ... once, not a second copy" "$RULE"*"$RULE" "$s"
    c="$(seed "$CTL/scripts" "$k" "$id" "$T_TMP/$w" "$T_TMP/ctl-$k-$w")"
    has "$k/$w: control renders a seed" "Your spool agent id is ${id}" "$c"
    hasnt "$k/$w: control (old source): the rule is missing -> FAIL" "$RULE" "$c"
  done
  # In a repo, INTEGRATION (4) points at the rule instead of keeping a copy.
  has "$k/repo: INTEGRATION (4) points at the rule" "(rejected: 'FETCH --force', then NO FORCE-PUSH below)" "$(cat "$T_TMP/plan-$k-repo/prompt.txt")"
done
t_done
