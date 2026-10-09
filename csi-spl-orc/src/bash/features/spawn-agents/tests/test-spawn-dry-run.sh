#!/usr/bin/env bash
# The five launchers, rendered with SPAWN_DRY_RUN=1: spool root, spool
# protocol in the seed prompt, id guards, worktree plan, and parity (the five
# kinds say the same thing once their own declarations are normalised).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe
WD="$T_TMP/plain"; mkdir -p "$WD"
echo brief > "$T_TMP/brief.md"

# mistral has no legacy prefix (specs/110 3.1): its id is m-077.
for k in claude grok agy qwen mistral; do
  p="$(printf '%s' "$k" | sed 's/claude/CLE/;s/grok/GRK/;s/agy/AGY/;s/qwen/QWN/')"
  id="$p-77"; [ "$k" = mistral ] && id=m-077
  mkdir -p "$T_TMP/plan-$k"
  out="$(SPAWN_PLAN_DIR="$T_TMP/plan-$k" bash "$T_SCRIPTS/spawn-$k.sh" "$id" "$WD" "$T_TMP/brief.md" "do the thing" 2>&1)"; rc=$?
  eq "$k: dry run exits 0" 0 "$rc"
  has "$k: spool dir planned under SPOOL_ROOT" "PLAN spooldir   ${SPOOL_ROOT}/${id}/{inbox,outbox,archive}" "$out"
  check "$k: dry run created nothing" test ! -e "$SPOOL_ROOT/$id"
  has "$k: non-git WORKDIR runs in place" "PLAN worktree   none: ${WD}" "$out"
  prompt="$(cat "$T_TMP/plan-$k/prompt.txt")"
  has "$k: prompt names the spool id" "Your spool agent id is ${id}" "$prompt"
  has "$k: prompt teaches spool recv" "SPOOL_ROOT=${SPOOL_ROOT} /opt/x/spool recv --as ${id}" "$prompt"
  has "$k: prompt teaches spool-send.sh" "spool-send.sh --from ${id} --to <PEER-ID>" "$prompt"
  has "$k: prompt says local mode is unsigned" "UNSIGNED" "$prompt"
  has "$k: prompt names the orchestrator" "today CLE-00 here" "$prompt"
  has "$k: reports go to the lease holder (specs/058 N1)" "--to orchestrator" "$prompt"
  # CLE-77943 (2026-10-02): owner text went to the standby dispatcher that last posted in the topic.
  has "$k: owner text goes to the dispatch lease holder" "csi-spl-orc && sudo -u ${SPOOL_BOX_USER} env SPOOL_ROOT=${SPOOL_ROOT} LEASE_CMD=show ./run -a do_spl_dispatch_lease" "$prompt"
  has "$k: ... never to the last dispatcher in the topic" "never to a fixed dispatcher id and never to the dispatcher that last posted in that topic" "$prompt"
  # CLE-77896: three lanes once greeted one new member; no lane posts social messages.
  has "$k: prompt forbids greetings and social posts" "Never post greetings, welcomes or social messages; only post what your brief asks for." "$prompt"
  # CLE-77938 (owner 2026-10-02): one agent does one small task, then exits.
  has "$k: prompt limits the lane to one small task" "You do ONE small task. If someone sends you a different task, refuse it and tell CLE-00 so it spawns a new lane. When your task is verified done: report and /exit-clean." "$prompt"
  # c-440 (2026-10-06): a 'pkill -f <action>' matched this prompt on 15 agents' argv.
  has "$k: prompt says stop by stop action or pid, never pkill -f" "Stop a run with its stop action (e.g. './run -a do_stop_pre_push') or its own pid, never 'pkill -f'" "$prompt"
  hasnt "$k: no markdown-inbox root" "/var/tmp/claude/msgs" "$prompt"
  hasnt "$k: no inbox-send.sh" "inbox-send" "$prompt"
  hasnt "$k: no git closing steps outside a repo" "INTEGRATION / CLOSING STEPS" "$prompt"
  launch="$(cat "$T_TMP/plan-$k/launch.cmd")"
  has "$k: launch exports SPOOL_ROOT" "SPOOL_ROOT='${SPOOL_ROOT}'" "$launch"
  has "$k: launch exports SPOOL_AGENT_ID" "SPOOL_AGENT_ID='${id}'" "$launch"
  has "$k: the CLI starts through spool-harness --as (spec 012 T013), mirrored (specs/036)" "spool-harness.sh' --as '${id}' --mirror -- '" "$launch"
  [ "$k" = grok ] && printf '%s\n' "$out" > "$T_TMP/grok.out"
  # Normalise the kind-specific parts for the parity check below.
  printf '%s' "$prompt" | sed -E "s/^As your VERY FIRST action, .*\. Then read your full task brief/Then read your full task brief/; s/${id}([^0-9]|$)/ID\1/g" > "$T_TMP/norm-$k"
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
check "parity: claude and mistral prompts match after normalisation" cmp -s "$T_TMP/norm-claude" "$T_TMP/norm-mistral"

has "agy: prompt goes after --prompt-interactive" '--prompt-interactive "' "$(cat "$T_TMP/plan-agy/launch.cmd")"
has "qwen: prompt goes after --prompt-interactive" '--prompt-interactive "' "$(cat "$T_TMP/plan-qwen/launch.cmd")"
has "qwen: --yolo approves tool calls" "--yolo" "$(cat "$T_TMP/plan-qwen/launch.cmd")"
has "qwen: retitles through riname --agent" "riname.sh --agent QWN-77" "$(cat "$T_TMP/plan-qwen/launch.cmd")"
has "claude: session named after the id" "--name 'CLE-77'" "$(cat "$T_TMP/plan-claude/launch.cmd")"
has "grok: retitles through riname --agent" "riname.sh --agent GRK-77 \\\"do the thing\\\"" "$(cat "$T_TMP/plan-grok/launch.cmd")"
has "grok: claude permission flag, which this grok build accepts" "--dangerously-skip-permissions" "$(cat "$T_TMP/plan-grok/launch.cmd")"
has "grok: permission mode does not depend on config.toml" "--permission-mode bypassPermissions" "$(cat "$T_TMP/plan-grok/launch.cmd")"
has "grok: resume stub repeats the permission flags" "--permission-mode bypassPermissions --resume" "$(cat "$T_TMP/grok.out")"

# ---- specs/110 T005 (7e): the mistral adapter --------------------------------
ml="$(cat "$T_TMP/plan-mistral/launch.cmd")"
has "mistral: the launch line (spec 3.3)" "exec env -u MISTRAL_API_KEY VIBE_ENABLE_TELEMETRY=false VIBE_ENABLE_UPDATE_CHECKS=false VIBE_ENABLE_AUTO_UPDATE=false VIBE_EXPERIMENTS__ENABLE=false VIBE_TOOLS__BASH__DEFAULT_TIMEOUT=840 SPT_NOENV=1 bash '" "$ml"
has "mistral: ... vibe --auto-approve --max-price <cnf>, the seed positional" "--mirror -- '/opt/x/vibe' --auto-approve --max-price ${CNF_MAX:=$(sed -n '/^ *mistral_vibe:/,/^ *max_price:/s/^ *max_price: *//p' "$T_FEAT/../../../../../csi-spl-cnf/csi-spl/all.env.yaml")} \"As your VERY FIRST" "$ml"
check "mistral: the cnf holds a max_price" test -n "$CNF_MAX"
has "mistral: the pane env is named after the kind (no legacy prefix)" "export MISTRAL_TMUX_PANE='' MISTRAL_TMUX_SOCK=''" "$ml"
hasnt "mistral: ... never a '_TMUX_PANE' with an empty prefix" "export _TMUX_PANE" "$ml"
has "mistral: retitles through riname --agent" "riname.sh --agent m-077" "$ml"
# Measured (T005): vibe loads a trusted dir's AGENTS.md, never CLAUDE.md.
has "mistral: the first action reads CLAUDE.md (vibe does not load it)" "then read the workdir's CLAUDE.md, if it has one, and csi-spl-doc/doc/help/how-to-post.md" "$(cat "$T_TMP/plan-mistral/prompt.txt")"
hasnt "mistral control: the claude seed does not carry it" "vibe loads only AGENTS.md" "$(cat "$T_TMP/plan-claude/prompt.txt")"
mo="$(env -u SPAWN_PLAN_DIR bash "$T_SCRIPTS/spawn-mistral.sh" m-077 "$WD" "$T_TMP/brief.md" "do the thing" 2>&1)"
has "mistral: the plan names no prefix" "kind=mistral prefix=<none> bin=" "$mo"
has "mistral: the resume stub unsets the key and keeps the cap" "env -u MISTRAL_API_KEY VIBE_ENABLE_TELEMETRY=false VIBE_ENABLE_UPDATE_CHECKS=false VIBE_ENABLE_AUTO_UPDATE=false VIBE_EXPERIMENTS__ENABLE=false VIBE_TOOLS__BASH__DEFAULT_TIMEOUT=840 SPT_NOENV=1 vibe --auto-approve --max-price ${CNF_MAX} --resume <SESSION_ID>" "$mo"
# Env override (spec 2.4): an exported key never reaches the plan, the line unsets it.
# vibe 2.26.0's bash timeout kill leaves a `sudo -u <box user>` command alive
# on vibe's pipes and waits for them with no bound (m-617@sat 2026-10-09, n=2;
# specs/110 vibe-bash-timeout-sudo.md): the launch raises the timeout, so a
# push and its pre-push finish first, and keeps it under the S4 cap for bash.
has "mistral: vibe's bash timeout is raised to 840 s" "VIBE_TOOLS__BASH__DEFAULT_TIMEOUT=840 " "$ml"
s4cap="$(mkdir -p "$T_TMP/wdctx" && env -u WD_TOOL_MAX WD_CTX="$T_TMP/wdctx" bash -c '. "$1" - - -; wd_tool_cap bash' _ "$T_FEAT/../watchdog/situations/lib.inc.sh")"
check "mistral: ... below the watchdog's S4 cap for bash (${s4cap:-none} s)" test "${s4cap:-0}" -gt 840
hasnt "mistral control: the claude launch line leaves vibe's timeout alone" "VIBE_TOOLS__BASH__DEFAULT_TIMEOUT" "$(cat "$T_TMP/plan-claude/launch.cmd")"
mo="$(MISTRAL_API_KEY=planted-fake-key-77 SPAWN_PLAN_DIR="$T_TMP/plan-mistral" bash "$T_SCRIPTS/spawn-mistral.sh" m-077 "$WD" "$T_TMP/brief.md" x 2>&1)"
hasnt "mistral: an exported MISTRAL_API_KEY is in no plan output" "planted-fake-key-77" "$mo$(cat "$T_TMP/plan-mistral/launch.cmd")"
has "mistral: ... and the launch still unsets it" "env -u MISTRAL_API_KEY " "$(cat "$T_TMP/plan-mistral/launch.cmd")"
eq "mistral: SPOOL_MISTRAL_MAX_PRICE overrides the cnf" 1 "$(SPOOL_MISTRAL_MAX_PRICE=0.25 bash "$T_SCRIPTS/spawn-mistral.sh" m-077 "$WD" 2>&1 | grep -c -- '--auto-approve --max-price 0.25 ')"
# trust-workdir: the vibe store follows the agent user's HOME (sat's home is
# /mnt/data/home/<user>, never a literal /home/<user>); vibe reads `trusted`.
AH="$T_TMP/mnt/data/home/agent"; mkdir -p "$AH/.vibe" "$WD/.vibe-trust"
printf 'trusted = []\nuntrusted = ["%s"]\n' "$WD/.vibe-trust" >"$AH/.vibe/trusted_folders.toml"
HOME="$AH" bash "$T_SCRIPTS/trust-workdir.sh" "$WD/.vibe-trust" "$(id -un)" mistral >/dev/null 2>&1
eq "mistral trust: the dir is trusted in <HOME>/.vibe, and leaves untrusted" "['$WD/.vibe-trust'] []" "$(python3 -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); print(d["trusted"], d["untrusted"])' "$AH/.vibe/trusted_folders.toml")"
HOME="$AH" bash "$T_SCRIPTS/trust-workdir.sh" "$WD/.vibe-trust" "$(id -un)" mistral >/dev/null 2>&1
eq "mistral trust: a second run adds nothing" 1 "$(grep -c vibe-trust "$AH/.vibe/trusted_folders.toml")"
rm -rf "$AH/.vibe"; HOME="$AH" bash "$T_SCRIPTS/trust-workdir.sh" "$WD/.vibe-trust" "$(id -un)" mistral >/dev/null 2>&1
check "mistral trust control: no ~/.vibe (vibe never ran) creates nothing" test ! -e "$AH/.vibe"
# CONTROLS: a title of another kind, and a cap that is not a dollar amount.
mo="$(bash "$T_SCRIPTS/spawn-mistral.sh" q-004 "$WD" 2>&1)"; rc=$?
eq "mistral control: title q-004 refused by the mistral adapter" 1 "$rc"
has "mistral control: ... by letter" "does not carry the mistral letter m-" "$mo"
bash "$T_SCRIPTS/spawn-mistral.sh" MST-77 "$WD" >/dev/null 2>&1; eq "mistral control: no legacy MST- id" 1 "$?"
bash "$T_SCRIPTS/spawn-qwen.sh" m-077 "$WD" >/dev/null 2>&1;  eq "mistral control: qwen refuses an m- id" 1 "$?"
mo="$(SPOOL_MISTRAL_MAX_PRICE=lots bash "$T_SCRIPTS/spawn-mistral.sh" m-077 "$WD" 2>&1)"; rc=$?
eq "mistral control: a cap that is not a dollar amount refused" 1 "$rc"
has "mistral control: ... and named" "no cost cap" "$mo"

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
# CLE-77965: a backticked word in the double-quoted seed ran as a command and
# dropped out of every seed ("PUT THE PATHSPEC ON THE , THEN COMMIT").
has "git: seed keeps the quoted word 'add'" "PUT THE PATHSPEC ON THE 'add', THEN COMMIT" "$prompt"
hasnt "git: dry run runs no seed word as a command" "command not found" "$out"
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
# spec 065 L8: the report carries sha + note link per released commit.
has "git: report asks for sha + note link" "Report sha + note link per released commit ('SHA=<sha> ENV=<env> ./run -a do_release_note_link')" "$prompt"
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

# ---- 102 T001: the flags come from ONE helper, the updater is off ------------
# spec 9.1, 9.2 (060 FR-061). Each harness's launch carries exactly the
# helper's flags and DISABLE_AUTOUPDATER=1 in the env that crosses the user hop.
. "$T_FEAT/lib/spool-env.inc.sh"
for k in claude grok agy qwen mistral; do
  flags="$(spool_claude_perm_flags "$k")"
  check "T001 $k: the helper has flags for the harness" test -n "$flags"
  has "T001 $k: the launch carries the helper's flags" " ${flags}" "$(cat "$T_TMP/plan-$k/launch.cmd")"
  has "T001 $k: the launch env carries DISABLE_AUTOUPDATER=1" "DISABLE_AUTOUPDATER='1'" "$(cat "$T_TMP/plan-$k/launch.cmd")"
done
spool_claude_perm_flags nosuch >/dev/null 2>&1; eq "T001: an unknown harness gets no flags (rc 2)" 2 "$?"
# The harness exports it as the agent user even when the hop dropped the env.
out="$(env -u DISABLE_AUTOUPDATER bash "$T_SCRIPTS/spool-harness.sh" --as CLE-77 env 2>/dev/null)"
has "T001: spool-harness hands DISABLE_AUTOUPDATER=1 to the CLI" "DISABLE_AUTOUPDATER=1" "$out"
orc="$(cd "$T_FEAT/../.." && pwd)"
eq "T001: one definition of spool_claude_perm_flags under orc/" 1 "$(grep -rn 'spool_claude_perm_flags''()' "$orc" | wc -l)"
# A launcher that writes a permission flag itself bypasses the helper. The
# grep reads code lines only (comments may name a flag).
t001_literal() {  # DIR -> the launcher lines with a literal permission flag
  grep -nE -- '--dangerously-skip-permissions|--permission-mode|--yolo' "$1"/spawn-*.sh "$1"/restore-*.sh 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}
eq "T001: no spawn/restore script writes its own permission flag" "" "$(t001_literal "$T_SCRIPTS")"
# CONTROL: a fixture copy of a launcher with a literal flag is caught.
FX="$T_TMP/t001-fixture"; mkdir -p "$FX"; cp "$T_SCRIPTS"/spawn-*.sh "$T_SCRIPTS"/restore-*.sh "$FX/"
sed -i 's/^SPAWN_KIND=qwen$/SPAWN_KIND=qwen\nSPAWN_PERM_FLAGS=--yolo/' "$FX/spawn-qwen.sh"
eq "T001 control: a launcher with a literal flag is caught (1 line)" 1 "$(t001_literal "$FX" | wc -l)"
has "T001 control: ... and named" "spawn-qwen.sh" "$(t001_literal "$FX")"
fleet="$T_FEAT/../spool-install/assets/claude/settings/00-fleet.json"
eq "T001: 00-fleet.json env block turns the updater off" 1 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["env"]["DISABLE_AUTOUPDATER"])' "$fleet")"

# c-636 (restart drill 4): a spawn records its brief at <id>/lifetime/brief.md,
# the file restore-mistral.sh reads, else a restored seat gets no task back.
out="$(SPAWN_PLAN_DIR="$T_TMP/plan-claude" bash "$T_SCRIPTS/spawn-claude.sh" CLE-78 "$WD" "$T_TMP/brief.md" 2>&1)"
has "brief: the plan records the brief under lifetime/" "PLAN brief      $T_TMP/brief.md -> ${SPOOL_ROOT}/CLE-78/lifetime/brief.md" "$out"
out="$(SPAWN_PLAN_DIR="$T_TMP/plan-claude" bash "$T_SCRIPTS/spawn-claude.sh" CLE-79 "$WD" 2>&1)"
hasnt "brief: a plain session records none" "PLAN brief" "$out"
# shellcheck source=../scripts/spawn-core.inc.sh
( . "$T_SCRIPTS/spawn-core.inc.sh"; spawn_record_brief "$T_TMP/rb/m-078" "$T_TMP/brief.md"; spawn_record_brief "$T_TMP/rb/m-079" "" )
eq "brief: lifetime/brief.md is a copy of the brief" "brief" "$(cat "$T_TMP/rb/m-078/lifetime/brief.md" 2>/dev/null)"
eq "brief: ... readable by the agent user and the box user (0664)" 664 "$(stat -c %a "$T_TMP/rb/m-078/lifetime/brief.md" 2>/dev/null)"
check "brief: no brief, no lifetime dir" test ! -e "$T_TMP/rb/m-079"
# c-539@sat (2026-10-09): a watchdog respawn passes its restart seed as the
# brief; copied in, it nested in every later seed. A respawn keeps the brief.
echo seed > "$T_TMP/seed.md"
( . "$T_SCRIPTS/spawn-core.inc.sh"; SPAWN_REUSE_ID=1 spawn_record_brief "$T_TMP/rb/m-078" "$T_TMP/seed.md" )
eq "brief: a respawn (SPAWN_REUSE_ID=1) keeps the recorded brief, not its seed" "brief" "$(cat "$T_TMP/rb/m-078/lifetime/brief.md" 2>/dev/null)"
( . "$T_SCRIPTS/spawn-core.inc.sh"; SPAWN_REUSE_ID=1 spawn_record_brief "$T_TMP/rb/m-080" "$T_TMP/brief.md" )
eq "brief: control: a respawn with no brief recorded yet records one" "brief" "$(cat "$T_TMP/rb/m-080/lifetime/brief.md" 2>/dev/null)"
( . "$T_SCRIPTS/spawn-core.inc.sh"; spawn_record_brief "$T_TMP/rb/m-078" "$T_TMP/seed.md" )
eq "brief: control: a fresh spawn of the id overwrites it" "seed" "$(cat "$T_TMP/rb/m-078/lifetime/brief.md" 2>/dev/null)"
# The reader: restore-mistral's lookup finds it.
check "brief: restore-mistral.sh reads lifetime/brief.md" grep -q 'lt/brief.md' "$T_SCRIPTS/restore-mistral.sh"

t_done
