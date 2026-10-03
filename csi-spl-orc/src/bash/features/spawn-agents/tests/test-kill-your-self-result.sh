#!/usr/bin/env bash
# test-kill-your-self-result.sh — practice 07 (agent-token-focus-plan): the
#   --result body is <= 800 chars (outcome, numbers, sha, detail path); a long
#   detail goes to the report file, and text cut to fit is kept whole there.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
R="$T_SCRIPTS/kill-your-self-report.sh"
export REPORT_DIR="$T_TMP/reports" SPOOL_AGENT_ID=c-007
W="$T_TMP/wt" && git init -q "$W" && git -C "$W" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
head_="$(git -C "$W" rev-parse --short HEAD)"

out="$(bash "$R" --result --outcome "landed the fix" --numbers "n=3, 1563 -> 412 B" "$W")"; rc=$?
eq "exits 0" 0 "$rc"
eq "short body: outcome, numbers, sha (HEAD by default), detail path" \
  "landed the fix"$'\n'"numbers: n=3, 1563 -> 412 B"$'\n'"sha: $head_"$'\n'"detail: $REPORT_DIR/c-007.md" "$out"
hasnt "no discovery text in result mode" "discovery" "$out"

big="$(printf 'line %s of the long detail\n' $(seq 200))"
out="$(printf '%s\n' "$big" | bash "$R" --result --outcome ok --sha a1 --sha b2 --detail - "$W")"
has "both shas are named" "sha: a1 b2" "$out"
eq "the long detail went to the file" "$big" "$(cat "$REPORT_DIR/c-007.md")"
check "the body stays short" [ "${#out}" -lt 200 ]

long="$(printf 'y%.0s' $(seq 3000))"
out="$(bash "$R" --result --outcome "$long" --numbers "$long" "$W")"
check "an over-long body is cut to <= 800 chars" [ "$(printf '%s\n' "$out" | wc -m)" -le 800 ]
has "the cut body still names the detail file" "detail: $REPORT_DIR/c-007.md" "$out"
check "the whole outcome is kept in the detail file" grep -q "$long" "$REPORT_DIR/c-007.md"

out="$(bash "$R" --result --outcome "doc only" --detail-path doc/md/x.md "$W")"
has "--detail-path names a doc instead of the report file" "detail: doc/md/x.md" "$out"
bash "$R" --result "$W" >/dev/null 2>&1; eq "--outcome is required" 2 "$?"
t_done
