#!/usr/bin/env bash
# Step 0 of every git lane's seed: read the developer guide and confirm it
# with do_dev_guide_ack (owner t1 4e373f5d msg 56d7073e: every new coding
# person or agent "must agree that they have read" it). Renders the seed each
# of the five launchers writes (SPAWN_DRY_RUN=1, SPAWN_PLAN_DIR/prompt.txt) in
# a repo that has the guide, in one that has not and in a plain dir. Control:
# the same launchers with DEV_GUIDE removed from spawn-core.inc.sh -> missing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe SPOOL_MISTRAL_MAX_PRICE=1
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
echo brief > "$T_TMP/brief.md"
mkdir -p "$T_TMP/plain"
for r in repo noguide; do
  git init -q --bare "$T_TMP/$r-origin.git"
  git init -q "$T_TMP/$r"
  if [ "$r" = repo ]; then
    mkdir -p "$T_TMP/$r/csi-spl-doc/doc/md"; echo guide > "$T_TMP/$r/csi-spl-doc/doc/md/developer-guide.md"
    git -C "$T_TMP/$r" add -A
  fi
  git -C "$T_TMP/$r" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
  git -C "$T_TMP/$r" branch -M master
  git -C "$T_TMP/$r" remote add origin "$T_TMP/$r-origin.git"
  git -C "$T_TMP/$r" push -q origin master 2>/dev/null
done

CTL="$T_TMP/ctl/spawn-agents"; mkdir -p "$CTL"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL/"
sed -i 's/\${DEV_GUIDE:+\${DEV_GUIDE} }//' "$CTL/scripts/spawn-core.inc.sh"
check "control: the old source renders no DEV_GUIDE" sh -c "! grep -q '[{]DEV_GUIDE:+' '$CTL/scripts/spawn-core.inc.sh'"

seed() {  # SCRIPTS_DIR KIND ID WORKDIR PLAN -> prints the rendered seed
  mkdir -p "$5"
  SPAWN_PLAN_DIR="$5" bash "$1/spawn-$2.sh" "$3" "$4" "$T_TMP/brief.md" "guide" >"$5/out" 2>&1
  cat "$5/prompt.txt" 2>/dev/null
}

for k in claude grok agy qwen mistral; do
  id="c-079"; [ "$k" = grok ] && id="g-079"; [ "$k" = agy ] && id="a-079"
  [ "$k" = qwen ] && id="q-079"; [ "$k" = mistral ] && id="m-079"
  s="$(seed "$T_SCRIPTS" "$k" "$id" "$T_TMP/repo" "$T_TMP/plan-$k-repo")"
  has "$k: step 0 reads the guide" "STEP 0, before any edit: read csi-spl-doc/doc/md/developer-guide.md, then confirm:" "$s"
  has "$k: ... and acks it under its own id" "env AGENT_ID=${id} DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack" "$s"
  has "$k: ... before the scope rules" "No ack, no push. SCOPE + COLLISION CONTROL" "$s"
  hasnt "$k: repo without the guide: no step 0" "STEP 0" "$(seed "$T_SCRIPTS" "$k" "$id" "$T_TMP/noguide" "$T_TMP/plan-$k-noguide")"
  hasnt "$k: plain dir: no step 0" "STEP 0" "$(seed "$T_SCRIPTS" "$k" "$id" "$T_TMP/plain" "$T_TMP/plan-$k-plain")"
  c="$(seed "$CTL/scripts" "$k" "$id" "$T_TMP/repo" "$T_TMP/ctl-$k")"
  has "$k: control renders a seed" "Your spool agent id is ${id}" "$c"
  hasnt "$k: control (no DEV_GUIDE): step 0 is missing -> FAIL" "STEP 0" "$c"
done
t_done
