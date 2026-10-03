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

for k in claude qwen; do
  id=CLE-79; [ "$k" = qwen ] && id=QWN-79
  mkdir -p "$T_TMP/plan-$k"
  SPAWN_PLAN_DIR="$T_TMP/plan-$k" SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' \
    bash "$T_SCRIPTS/spawn-$k.sh" "$id" "$T_TMP/repo" "$T_TMP/brief.md" "fix it" >/dev/null 2>&1
  prompt="$(cat "$T_TMP/plan-$k/prompt.txt")"
  n="$(wc -c < "$T_TMP/plan-$k/prompt.txt")"
  check "$k: seed is at most 8000 bytes (got $n)" [ "$n" -le 8000 ]
  for r in 1 2 3 4 5 6 7 8 a b c d e; do
    has "$k: rule ($r) present" "($r) " "$prompt"
  done
  has "$k: the seed links the rules doc" "lane-integration-rules.md" "$prompt"
  hasnt "$k: no measured anecdotes in the seed" "Measured on this box" "$prompt"
  hasnt "$k: no FETCH_HEAD race numbers in the seed" "168/200" "$prompt"
done
check "the linked rules doc exists" test -f "$T_SCRIPTS/../../../../../../csi-spl-doc/doc/md/lane-integration-rules.md"

t_done
