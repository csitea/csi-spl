#!/usr/bin/env bash
# test-kill-your-self-result.sh — practice 07 (agent-token-focus-plan): the
#   --result body is <= 800 chars (outcome, numbers, sha, detail path); a long
#   detail goes to the report file, and text cut to fit is kept whole there.
#   The report file is never empty (m-897's was 0 bytes, c-894 finding 3).
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

# m-897 passed --detail /dev/null: the report file was 0 bytes.
rm -f "$REPORT_DIR/c-007.md"
out="$(bash "$R" --result --outcome "DONE proof: nothing to land" --sha none --numbers "0, 0 -> 0" --detail /dev/null "$W")"
check "an empty --detail leaves a non-empty report" [ -s "$REPORT_DIR/c-007.md" ]
eq "it holds the outcome, numbers and sha" "# c-007 report"$'\n\n'"DONE proof: nothing to land"$'\n'"numbers: 0, 0 -> 0"$'\n'"sha: none" "$(cat "$REPORT_DIR/c-007.md")"
has "the body names that file" "detail: $REPORT_DIR/c-007.md" "$out"
rm -f "$REPORT_DIR/c-007.md"
bash "$R" --result --outcome "no detail" --sha c3 "$W" >/dev/null
has "no --detail at all: the named file still exists with the outcome" "no detail" "$(cat "$REPORT_DIR/c-007.md" 2>/dev/null)"
echo keep >"$REPORT_DIR/c-007.md"
err="$(bash "$R" --result --outcome x --detail "$T_TMP/missing.md" "$W" 2>&1 >/dev/null)"; rc=$?
eq "an unreadable --detail is refused" 2 "$rc"
has "the refusal says nothing was written" "nothing written" "$err"
eq "and the old report is not truncated" "keep" "$(cat "$REPORT_DIR/c-007.md")"
t_done
