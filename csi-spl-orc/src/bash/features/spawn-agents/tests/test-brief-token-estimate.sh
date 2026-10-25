#!/usr/bin/env bash
# SPL-2177 (spec 048, epic SPL-2175): spool-harness estimates seed + brief
# tokens (brief-token-estimate.sh, bytes / 4) before the CLI starts. Under the
# budget the stub CLI runs as before; over it the launch is refused, exit 65,
# one FATAL line naming the estimate and the budget, and the CLI never runs.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
H="$T_SCRIPTS/spool-harness.sh"
E="$T_SCRIPTS/brief-token-estimate.sh"
export HOME="$T_TMP/home"
unset SPOOL_HUB_URL SPOOL_BOX_ID SPOOL_KEYS_DIR SPOOL_HARNESS_SIDECAR SPOOL_HARNESS_STRICT SPOOL_BRIEF_TOKEN_BUDGET

LT="$SPOOL_ROOT/c-901/lifetime"; mkdir -p "$LT"
head -c 4000 /dev/zero | tr '\0' s >"$LT/prompt.txt"
head -c 4000 /dev/zero | tr '\0' b >"$LT/brief.md"
PTR="Read and follow your seed: $LT/prompt.txt"
# The stub CLI: proves it ran, and with which pointer.
cat >"$T_TMP/cli" <<'EOF'
#!/usr/bin/env bash
echo "cli-ran $*"
EOF
chmod +x "$T_TMP/cli"

# ── the estimate itself ──
eq "estimate: 8000 B -> 2000 tokens" "estimate=2000 bytes=8000 budget=16000" "$(bash "$E" "$LT/prompt.txt" "$LT/brief.md")"
eq "estimate: rounds up (1 B -> 1 token)" "estimate=1 bytes=1 budget=16000" "$(printf x >"$T_TMP/one"; bash "$E" "$T_TMP/one")"
eq "estimate: a missing brief counts 0" "estimate=1000 bytes=4000 budget=16000" "$(bash "$E" "$LT/prompt.txt" "$T_TMP/none.md")"
SPOOL_BRIEF_TOKEN_BUDGET=2000 bash "$E" "$LT/prompt.txt" "$LT/brief.md" >/dev/null 2>&1
eq "estimate: at the budget passes" 0 "$?"
SPOOL_BRIEF_TOKEN_BUDGET=lots bash "$E" "$LT/prompt.txt" >/dev/null 2>&1
eq "estimate: a budget that is not a number -> 2" 2 "$?"

# ── under the budget: launches as today ──
out="$(bash "$H" --as c-901 -- "$T_TMP/cli" --flag "$PTR" 2>"$T_TMP/err")"
eq "under: exit 0" 0 "$?"
eq "under: the CLI runs with its pointer unchanged" "cli-ran --flag $PTR" "$out"
eq "under: silent on stderr" "" "$(cat "$T_TMP/err")"

# ── over the budget: refused, the CLI never runs ──
out="$(SPOOL_BRIEF_TOKEN_BUDGET=1999 bash "$H" --as c-901 -- "$T_TMP/cli" --flag "$PTR" 2>"$T_TMP/err")"
eq "over: exit 65" 65 "$?"
eq "over: the CLI did not run" "" "$out"
err="$(cat "$T_TMP/err")"
eq "over: exactly one stderr line" 1 "$(printf '%s\n' "$err" | wc -l)"
has "over: the line is FATAL" "FATAL brief-token-estimate" "$err"
has "over: it names the estimate" "estimate 2000 tokens (8000 B / 4)" "$err"
has "over: it names the budget" "over the budget 1999 tokens" "$err"
eq "over: nothing truncated (seed size kept)" 4000 "$(wc -c <"$LT/prompt.txt")"

# The default budget refuses an oversized brief with no env at all.
head -c 70000 /dev/zero | tr '\0' b >"$LT/brief.md"
bash "$H" --as c-901 -- "$T_TMP/cli" "$PTR" >/dev/null 2>"$T_TMP/err"
eq "over: the default budget (16000) refuses 74000 B" 65 "$?"
has "over: ...naming 18500 and 16000" "estimate 18500 tokens (74000 B / 4) is over the budget 16000 tokens" "$(cat "$T_TMP/err")"

# A launch with no seed pointer (a resume) is not estimated.
eq "resume: no pointer, the CLI runs" "cli-ran --resume x" "$(SPOOL_BRIEF_TOKEN_BUDGET=0 bash "$H" --as c-901 -- "$T_TMP/cli" --resume x 2>/dev/null)"

t_done
