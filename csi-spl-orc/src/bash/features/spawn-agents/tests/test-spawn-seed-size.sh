#!/usr/bin/env bash
# The seed states rules, not their history (token plan practice 02): a git
# lane's prompt stays under the cap, keeps every rule number, and points at
# the doc that holds the measured why.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
echo brief > "$T_TMP/brief.md"
git init -q --bare "$T_TMP/origin.git"
git init -q "$T_TMP/repo" && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

# The checkout root, as pwd and as readlink -f see it, and the sandbox root
# become the live install root and a mktemp-length dir.
T_ROOT="${T_FEAT%/csi-spl-orc/src/bash/features/spawn-agents}"
T_ROOT_REAL="$(readlink -f "$T_ROOT")"
seed_norm() {
  local s="$1" tmp_real
  tmp_real="$(readlink -f "$T_TMP")"
  s="${s//"$tmp_real"//tmp/tmp.XXXXXXXXXX}"; s="${s//"$T_TMP"//tmp/tmp.XXXXXXXXXX}"
  s="${s//"$T_ROOT_REAL"//opt/csi/csi-spl-desk-cron}"; s="${s//"$T_ROOT"//opt/csi/csi-spl-desk-cron}"
  printf '%s' "$s"
}
check "control: the size check normalises a checkout path" [ "$(seed_norm "x ${T_ROOT}/a ${T_TMP}/b")" = "x /opt/csi/csi-spl-desk-cron/a /tmp/tmp.XXXXXXXXXX/b" ]

for k in claude grok agy qwen mistral; do
  id=CLE-79; [ "$k" = grok ] && id=GRK-79; [ "$k" = agy ] && id=AGY-79
  [ "$k" = qwen ] && id=QWN-79; [ "$k" = mistral ] && id=m-079
  mkdir -p "$T_TMP/plan-$k"
  SPAWN_PLAN_DIR="$T_TMP/plan-$k" SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' \
    bash "$T_SCRIPTS/spawn-$k.sh" "$id" "$T_TMP/repo" "$T_TMP/brief.md" "fix it" >/dev/null 2>&1
  prompt="$(cat "$T_TMP/plan-$k/prompt.txt")"
  # Sized at the live install's paths, not this checkout's: the seed embeds
  # the checkout and the sandbox ~16 times, and CI's longer checkout path
  # alone added ~240 B (c-603, wf 10 run 37873606666).
  norm="$(seed_norm "$prompt")"
  n="$(printf '%s' "$norm" | wc -c)"
  check "$k: seed is at most 8000 bytes at the live paths (got $n)" [ "$n" -le 8000 ]
  hasnt "$k: the sized seed carries no checkout path" "$T_ROOT/" "$norm"
  for r in 1 2 3 4 5 6 7 8 a b c d e; do
    has "$k: rule ($r) present" "($r) " "$prompt"
  done
  has "$k: the seed links the rules doc" "lane-integration-rules.md" "$prompt"
  # vibe runs its hooks (the DM-reply mirror) in the worktree: an m- lane keeps it
  if [ "$k" = mistral ]; then
    hasnt "$k: step (8) does not remove the worktree" "worktree remove" "$prompt"
    has "$k: step (8) keeps the worktree for vibe's hooks" "(8) TEAR DOWN after (7) is green: HEAD on origin/master; KEEP " "$prompt"
  else
    has "$k: step (8) removes the worktree" "worktree remove" "$prompt"
  fi
  hasnt "$k: no measured anecdotes in the seed" "Measured on this box" "$prompt"
  hasnt "$k: no FETCH_HEAD race numbers in the seed" "168/200" "$prompt"
done
check "the linked rules doc exists" test -f "$T_SCRIPTS/../../../../../../csi-spl-doc/doc/md/lane-integration-rules.md"

t_done
