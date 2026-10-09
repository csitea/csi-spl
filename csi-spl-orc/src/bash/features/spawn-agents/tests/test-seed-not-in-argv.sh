#!/usr/bin/env bash
# The seed prompt is never in an agent CLI's argv (c-698 2026-10-09: one
# 'pkill -f "git push"' matched the seed on 12 seats' argv and killed them
# all). Every kind's launch carries only "Read and follow your seed: <file>",
# the file holds the full seed; a restore kick goes the same way.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe
printf '# Brief: hidden marker\nBRIEF-BODY-MARKER-77\n' > "$T_TMP/brief.md"
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

# --- 1. spawn: every kind, a git lane (the seed carries "git push") ----------
for k in claude grok agy qwen mistral; do
  id=c-071; [ "$k" = grok ] && id=g-071; [ "$k" = agy ] && id=a-071
  [ "$k" = qwen ] && id=q-071; [ "$k" = mistral ] && id=m-071
  P="$T_TMP/plan-$k"; mkdir -p "$P"
  out="$(SPAWN_PLAN_DIR="$P" SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' \
    bash "$T_SCRIPTS/spawn-$k.sh" "$id" "$T_TMP/repo" "$T_TMP/brief.md" "slug words 77" 2>&1)"
  launch="$(cat "$P/launch.cmd" 2>/dev/null)"; seed="$(cat "$P/prompt.txt" 2>/dev/null)"
  has "$k: control: the seed file holds the full seed (git push)" "git push origin HEAD:master" "$seed"
  has "$k: control: ... and the brief path" "read your full task brief at $T_TMP/brief.md" "$seed"
  hasnt "$k: the launch carries no 'git push'" "git push" "$launch"
  hasnt "$k: ... no seed text" "INTEGRATION / CLOSING STEPS" "$launch"
  hasnt "$k: ... no brief path" "$T_TMP/brief.md" "$launch"
  hasnt "$k: ... no slug" "slug words 77" "$launch"
  hasnt "$k: ... no command name" "do_check_pre_push" "$launch"
  has "$k: the launch points at the seed file" "\"Read and follow your seed: $P/prompt.txt\"" "$launch"
  hasnt "$k: the printed plan's launch line carries no 'git push'" "git push" "$(grep '^PLAN launch' <<<"$out")"
  has "$k: the plan names the seed file" "PLAN seed" "$out"
done
has "agy: the pointer follows --prompt-interactive" "--prompt-interactive \"Read and follow your seed: " "$(cat "$T_TMP/plan-agy/launch.cmd")"
has "qwen: the pointer follows --prompt-interactive" "--prompt-interactive \"Read and follow your seed: " "$(cat "$T_TMP/plan-qwen/launch.cmd")"

# --- 2. a live spawn writes the seed to <spool root>/<id>/lifetime/prompt.txt --
live="$(SPAWN_DRY_RUN=0 bash -c '
  . "$1/../lib/spool-env.inc.sh"; . "$1/spawn-core.inc.sh"
  MSGDIR="$2/c-072" PROMPT="seed with git push origin HEAD:master \$HOME \"q\"" SPAWN_PROMPT_FLAG=
  _spawn_seed_file; printf "%s" "$_sp_prompt_args"' _ "$T_SCRIPTS" "$SPOOL_ROOT" 2>&1)"
eq "live: the seed file holds the seed byte for byte" 'seed with git push origin HEAD:master $HOME "q"' "$(cat "$SPOOL_ROOT/c-072/lifetime/prompt.txt" 2>/dev/null)"
eq "live: the argv part is the pointer only" " \"Read and follow your seed: $SPOOL_ROOT/c-072/lifetime/prompt.txt\"" "$live"
eq "live: the seed file is 0664" 664 "$(stat -c %a "$SPOOL_ROOT/c-072/lifetime/prompt.txt" 2>/dev/null)"

# --- 3. restore: the kick goes to lifetime/kick.txt, argv names it ----------
export RESTORE_PRINT=1 CLAUDE_BIN=claude GROK_BIN=grok AGY_BIN=agy QWEN_BIN=qwen
git -C "$T_TMP/repo" worktree add -q -b c-073-x "$T_TMP/wt" master
out="$(bash "$T_SCRIPTS/restore-claude.sh" c-073 "$T_TMP/wt" sid-a "$T_TMP/brief.md" 2>&1)"
cmd="$(head -1 <<<"$out")"
hasnt "restore claude: the command carries no kick text" "SESSION RESTORED" "$cmd"
hasnt "restore claude: ... no brief path" "$T_TMP/brief.md" "$cmd"
has "restore claude: the command points at the kick file" "--resume sid-a \"Read and follow your restore note: $SPOOL_ROOT/c-073/lifetime/kick.txt\"" "$cmd"
has "restore claude: control: the kick itself is planned" "SESSION RESTORED" "$out"
for k in grok agy qwen; do
  id=g-074; [ "$k" = agy ] && id=a-074; [ "$k" = qwen ] && id=q-074
  cmd="$(bash "$T_SCRIPTS/restore-$k.sh" "$id" "$T_TMP/wt" s-1 'kick with git push origin HEAD:master' 2>&1)"; cmd="$(sed -n 1p <<<"$cmd")"
  hasnt "restore $k: a given kick is not in the command" "git push" "$cmd"
  has "restore $k: ... its file is" "\"Read and follow your restore note: $SPOOL_ROOT/$id/lifetime/kick.txt\"" "$cmd"
done
bash -c '. "$1/restore-core.inc.sh"; _rs_write_kick "$2/c-075/lifetime/kick.txt" "kick \$X \"q\""' _ "$T_SCRIPTS" "$SPOOL_ROOT" >/dev/null 2>&1
eq "restore live: the kick file holds the kick byte for byte" 'kick $X "q"' "$(cat "$SPOOL_ROOT/c-075/lifetime/kick.txt" 2>/dev/null)"

t_done
