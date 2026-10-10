#!/usr/bin/env bash
# A lane closes itself only on the reviewer's ACCEPTED, every kind (owner
# HUM-10 msg 3b4d2cb9: "set up that exit clean ... and implement it in the
# loop"; c-002 msg f711ec97: c-878 and a-884 retired before the verdict).
# Renders the seed each of the five launchers writes (SPAWN_DRY_RUN=1,
# SPAWN_PLAN_DIR/prompt.txt) and asserts the ACCEPTED-gated closing line, in
# place of the old "report and /exit-clean". Control: the same launchers with
# the old closing line (SPAWN_EXIT_RULE set back to it) -> the gate is missing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe SPOOL_MISTRAL_MAX_PRICE=1
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
GATE="Run /exit-clean (the exit-clean skill) ONLY on a spool message on your task whose body starts with ACCEPTED (dispatch holder or spawner), never on your own done."
IDLE="When your task is verified done: send your result, then stay idle and answer send-backs."
OLD="When your task is verified done: report and /exit-clean."
echo brief > "$T_TMP/brief.md"

# The control tree: this feature's scripts and lib, the closing line as before.
CTL="$T_TMP/ctl/spawn-agents"; mkdir -p "$CTL"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL/"
sed -i "s|^SPAWN_EXIT_RULE=.*|SPAWN_EXIT_RULE=\"$OLD\"|" "$CTL/scripts/spawn-core.inc.sh"
check "control: the old closing line is in the control tree" grep -qF "SPAWN_EXIT_RULE=\"$OLD\"" "$CTL/scripts/spawn-core.inc.sh"

seed() {  # SCRIPTS_DIR KIND ID PLAN -> prints the rendered seed
  mkdir -p "$4"
  SPAWN_PLAN_DIR="$4" bash "$1/spawn-$2.sh" "$3" "$T_TMP/plain" "$T_TMP/brief.md" "exit gate" >"$4/out" 2>&1
  cat "$4/prompt.txt" 2>/dev/null
}
mkdir -p "$T_TMP/plain"
for k in claude grok agy qwen mistral; do
  id='c-079'; [ "$k" = grok ] && id='g-079'; [ "$k" = agy ] && id='a-079'
  [ "$k" = qwen ] && id='q-079'; [ "$k" = mistral ] && id='m-079'
  s="$(seed "$T_SCRIPTS" "$k" "$id" "$T_TMP/plan-$k")"
  has "$k: the seed says report, then stay idle for send-backs" "$IDLE" "$s"
  has "$k: the seed runs /exit-clean only on ACCEPTED" "$GATE" "$s"
  hasnt "$k: the old self-close on its own done is gone" "$OLD" "$s"
  c="$(seed "$CTL/scripts" "$k" "$id" "$T_TMP/ctl-$k")"
  has "$k: control renders a seed" "Your spool agent id is ${id}" "$c"
  hasnt "$k: control (old closing line): no ACCEPTED gate -> FAIL" "$GATE" "$c"
done
t_done
