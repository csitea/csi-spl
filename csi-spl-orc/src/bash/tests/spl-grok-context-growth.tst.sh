#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_grok_context_growth (SPL-2215) on synthetic sessions in a
# mktemp home; no live transcript is read.
#   1. the per-call table: grok's context of call N is the first
#      _meta.totalTokens of its Nth stream, claude's the input + cache read +
#      cache creation of its Nth message id
#   2. claude: a message id on 2 rows counts once, a sidechain row not at all
#   3. grok: the compaction (a fall > 50000) is seen, P is the context after it
#   4. a session older than GROWTH_DAYS is left out
#   5. the cap model: a cap of 100000 costs less than measured; CONTROL: the
#      cap removed (10000000) brings the growth back, above what was measured
#   6. no prompt or completion text reaches the output
#   7. a bad GROWTH_CAPS exits 2
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }
FUNC="$PROJ_ROOT/src/bash/run/spl-grok-context-growth.func.sh"
H="$T/home" TXT=PROMPT-TEXT-MUST-NOT-LEAK
G="$H/.grok/sessions/%2Fopt%2Fx%2Fcsi-spl-wt%2Fg-301/s1" OLD="$H/.grok/sessions/%2Fopt%2Fx%2Fcsi-spl-wt%2Fg-302/s2"
C="$H/.claude/projects/-opt-x-csi-spl-wt-c-101"
mkdir -p "$G" "$OLD" "$C"
# grok g-301: call 1 a 2000 side call, then 30000 + 3000 a call up to 201000,
# a compaction to 36000, then 20 more calls; every stream carries 2 updates.
# claude c-101: 40 calls of 60000 + 1000 a call, one id repeated, a sidechain row.
python3 - "$G" "$OLD" "$C/s.jsonl" "$TXT" <<'EOF'
import json, sys
g, old, c, txt = sys.argv[1:]
seq = [2000] + [30000 + 3000 * i for i in range(58)] + [36000 + 3000 * i for i in range(20)]
def grok(d, seq):
    with open(d + "/updates.jsonl", "w") as f:
        for n, t in enumerate(seq):
            for k in (0, 1):
                f.write(json.dumps({"params": {"update": {"text": txt},
                        "_meta": {"totalTokens": t + 10 * k, "streamStartMs": 1000 + n}}}) + "\n")
    json.dump({"compactionCount": 1}, open(d + "/signals.json", "w"))
grok(g, seq)
grok(old, [2000] + [500000] * 20)
with open(c, "w") as f:
    def row(mid, ctx, side=False):
        f.write(json.dumps({"type": "assistant", "isSidechain": side, "message": {"id": mid,
                "content": [{"type": "text", "text": txt}],
                "usage": {"input_tokens": 10, "cache_read_input_tokens": ctx - 110, "cache_creation_input_tokens": 100}}}) + "\n")
    for i in range(40):
        row("m%d" % i, 60000 + 1000 * i)
        if i == 5: row("m5", 60000 + 1000 * i)
    row("side", 999999, True)
EOF
touch -d '30 days ago' "$OLD/updates.jsonl"
run() {
  env GROWTH_HOMES="$H" "$@" bash -c 'do_log() { echo "$*" >&2; }; do_require_bin() { command -v "$1" >/dev/null; }
    source "$1"; do_spl_grok_context_growth' _ "$FUNC" 2>&1
}
out="$(run GROWTH_CAPS=100000,204800,10000000)"

grep -qxF '| 10 | 1 | 54000 | 1 | 69000 |' <<<"$out" && pass "1. call 10: grok 54000, claude 69000" || fail "1. table: $out"
grep -qE '^\| claude \| 1 \| 40 \|' <<<"$out" && pass "2. claude: a repeated id once, the sidechain left out (40 calls)" || fail "2. claude calls: $out"
grep -qF 'grok cap model: 1 compactions seen, median context after one P=36000' <<<"$out" && pass "3. grok compaction seen, P=36000" || fail "3. compaction: $out"
grep -qE '^\| grok \| 1 \| 79 \|' <<<"$out" && pass "4. the session older than GROWTH_DAYS is left out" || fail "4. old session: $out"
base="$(sed -n 's/.*measured input \([0-9]*\)$/\1/p' <<<"$out")"
sim() { awk -F'|' -v c="$1" '$2 + 0 == c { gsub(/ /, "", $4); print $4 }' <<<"$out"; }
[[ -n "$base" && "$(sim 100000)" -lt "$base" ]] && pass "5. a 100000 cap costs less than measured ($(sim 100000) < $base)" || fail "5. cap 100000: $(sim 100000) vs $base"
[[ -n "$base" && "$(sim 10000000)" -gt "$base" ]] && pass "5. CONTROL: cap removed -> the growth returns ($(sim 10000000) > $base)" || fail "5. control: $(sim 10000000) vs $base"
grep -qF "$TXT" <<<"$out" && fail "6. transcript text in the output" || pass "6. no transcript text in the output"
run GROWTH_CAPS=1e5 >/dev/null; [[ $? -eq 2 ]] && pass "7. a bad GROWTH_CAPS exits 2" || fail "7. bad caps did not exit 2"

echo "spl-grok-context-growth: $fails failure(s)"
exit "$fails"
