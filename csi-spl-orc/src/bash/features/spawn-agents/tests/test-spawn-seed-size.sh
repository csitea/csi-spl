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
# The live repo has the developer guide, so the seed carries STEP 0: size that.
git init -q "$T_TMP/repo" && mkdir -p "$T_TMP/repo/csi-spl-doc/doc/md" && echo guide >"$T_TMP/repo/csi-spl-doc/doc/md/developer-guide.md"
git -C "$T_TMP/repo" add -A && git -C "$T_TMP/repo" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q -m init
git -C "$T_TMP/repo" branch -M master
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

# The checkout root, as pwd and as readlink -f see it, and the sandbox root
# become the live install root and a mktemp-length dir.
T_ROOT="${T_FEAT%/csi-spl-orc/src/bash/features/spawn-agents}"
T_ROOT_REAL="$(readlink -f "$T_ROOT")"
# A root is replaced only on a path boundary (followed by / or the end): a
# checkout that is a prefix of the live root (/opt/csi/csi-spl) must not turn
# /opt/csi/csi-spl-desk-cron, or its own first-pass output, into
# ...-desk-cron-desk-cron (+50 B, SPL-2206).
seed_root() {  # S ROOT LIVE
  local s="${1//"$2/"/"$3/"}"
  case "$s" in *"$2") s="${s%"$2"}$3" ;; esac
  printf '%s' "$s"
}
seed_norm() {
  local s="$1" tmp_real
  tmp_real="$(readlink -f "$T_TMP")"
  s="$(seed_root "$s" "$tmp_real" /tmp/tmp.XXXXXXXXXX)"; s="$(seed_root "$s" "$T_TMP" /tmp/tmp.XXXXXXXXXX)"
  s="$(seed_root "$s" "$T_ROOT_REAL" /opt/csi/csi-spl-desk-cron)"; s="$(seed_root "$s" "$T_ROOT" /opt/csi/csi-spl-desk-cron)"
  printf '%s' "$s"
}
check "control: the size check normalises a checkout path" [ "$(seed_norm "x ${T_ROOT}/a ${T_TMP}/b")" = "x /opt/csi/csi-spl-desk-cron/a /tmp/tmp.XXXXXXXXXX/b" ]
# A checkout root that is a prefix of the live root, as pwd and readlink see it.
eq "control: a prefix checkout root leaves the live root alone" \
  "x /opt/csi/csi-spl-desk-cron/a /opt/csi/csi-spl-desk-cron/b 'cd /opt/csi/csi-spl' /opt/csi/csi-spl-desk-cron" \
  "$(T_ROOT=/opt/csi/csi-spl T_ROOT_REAL=/opt/csi/csi-spl seed_norm "x /opt/csi/csi-spl/a /opt/csi/csi-spl-desk-cron/b 'cd /opt/csi/csi-spl' /opt/csi/csi-spl")"

# Vendor parity (SPL-2214, the "Grok burns 3-4x" hypotheses of t1 bd5579e7):
# every kind gets claude's seed, sentence for sentence, except the lines a
# harness needs (how it retitles itself, vibe's teardown), and at most
# SEED_PARITY_MAX bytes more. Measured 2026-10-16: grok +135 B, mistral +315 B.
SEED_PARITY_MAX=400
declare -A SEED_NORM SEED_BYTES
seed_sentences() { printf '%s' "$1" | sed 's/\. /.\n/g' | grep -vE '^As your VERY FIRST action, |^\(8\) TEAR DOWN ' | sort; }
seed_extra() {  # KIND_SEED CLAUDE_SEED: the sentences of the first that the second lacks, and back
  comm -3 <(seed_sentences "$1") <(seed_sentences "$2")
}
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
  SEED_NORM[$k]="${norm//"$id"/<ID>}"; SEED_BYTES[$k]="$n"
  # 8200: +200 for STEP 0, the developer-guide ack (owner t1 4e373f5d msg 56d7073e)
  # 8400: +200 for the ACCEPTED-gated exit line (SPAWN_EXIT_RULE, owner msg 3b4d2cb9)
  # 8500: +100 for the lane-map exit 4 ('unknown:' lanes are not free, c-904 follow-up)
  # 8650: +150 for INTEGRATION (4): push with do_spl_push_master and poll (SPL-1578, mistral 8609)
  # 8935: +285 for the truth rule that opens every seed (assets/seed-truth-rule.txt + its space, SPL-2097, owner msg 3e1eb819)
  check "$k: seed is at most 8935 bytes at the live paths (got $n)" [ "$n" -le 8935 ]
  has "$k: the sized seed carries STEP 0" "STEP 0, before any edit" "$prompt"
  hasnt "$k: the sized seed carries no checkout path" "$T_ROOT/" "$norm"
  for r in 1 2 3 4 5 6 7 8 a b c d e; do
    has "$k: rule ($r) present" "($r) " "$prompt"
  done
  has "$k: the seed links the rules doc" "lane-integration-rules.md" "$prompt"
  # Every lane keeps its worktree after the push (owner t1 37349c9b msg
  # ec060ebc): the retire lists it, the disk sweep removes it after 24 h.
  hasnt "$k: step (8) does not remove the worktree" "worktree remove" "$prompt"
  has "$k: step (8) keeps the worktree" "(8) TEAR DOWN after (7) is green: HEAD on origin/master; KEEP " "$prompt"
  has "$k: step (8) names the 24 h disk sweep" "the disk sweep, which removes them after 24 h" "$prompt"
  # vibe runs its hooks (the DM-reply mirror) in the worktree: an m- lane says so
  [ "$k" = mistral ] && has "$k: step (8) names vibe's hooks" "vibe's hooks run in it" "$prompt"
  hasnt "$k: no measured anecdotes in the seed" "Measured on this box" "$prompt"
  hasnt "$k: no FETCH_HEAD race numbers in the seed" "168/200" "$prompt"
done
for k in grok agy qwen mistral; do
  eq "$k: the seed states claude's rules, no sentence more or less" "" "$(seed_extra "${SEED_NORM[$k]}" "${SEED_NORM[claude]}")"
  check "$k: the seed is at most $SEED_PARITY_MAX bytes over claude's (got $(( SEED_BYTES[$k] - SEED_BYTES[claude] )))" \
    [ $(( SEED_BYTES[$k] - SEED_BYTES[claude] )) -le "$SEED_PARITY_MAX" ]
done
# Controls: a grok-only sentence, and a rule a kind loses, both show.
has "control: a grok-only sentence is caught" "Read every skill first." \
  "$(seed_extra "${SEED_NORM[grok]} Read every skill first." "${SEED_NORM[claude]}")"
has "control: a rule a kind loses is caught" "(5) After (4)" \
  "$(seed_extra "${SEED_NORM[grok]//"(5) After (4)"/}" "${SEED_NORM[claude]}")"
check "the linked rules doc exists" test -f "$T_SCRIPTS/../../../../../../csi-spl-doc/doc/md/lane-integration-rules.md"

t_done
