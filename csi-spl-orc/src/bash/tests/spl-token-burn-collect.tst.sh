#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_burn_collect's incremental read and push (spec 140
# T022, T023) on a synthetic claude transcript in a mktemp home; no live
# transcript, tmux, crontab or hub is touched.
#   1. the first tick starts every file at its end: no history counted
#   2. a 500-byte row appended: the offset moves by exactly 500, that row only
#      is read; a half-written row (no newline yet) is not consumed until it
#      ends
#   3. one message id streamed over two ticks still counts its MAX once
#   4. a file truncated below its offset, or replaced (new inode), is read
#      again from 0. Control: without the inode check the replaced file's
#      new row is never read
#   5. the push: one fleet_tokens_push frame (lane, samples with the spec
#      140 3.4 fields), each sample the minute's FULL totals; an ack
#      unqueues; a failed push keeps the buckets queued and the next ack
#      sends them; TOKEN_BURN_PUSH=0 pushes nothing
#   6. a tick that finds the lock held skips (rc 0), changes nothing
#   7. token-burn-collect-cron.sh refuses an agent worktree; allowed, it logs
#      one tick line per tick with its milliseconds
#   8. only the first tick lists every transcript dir: a new project dir's
#      transcript and an active session's new subagent are read the next
#      tick, an idle session's on its dir's slice. Control: without the
#      active-session listing that subagent waits
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "FAIL: jq and python3 are required"; exit 1; }

NOW=1792080000 H="$T/home" S="$T/state"
M0=$((NOW - NOW % 60 - 120))
P="$H/.claude/projects/-opt-x-wt-c-101/22222222-2222-2222-2222-222222222222.jsonl"
mkdir -p "$(dirname "$P")" "$T/spool"
cat >"$T/push" <<'EOF'
#!/usr/bin/env bash
cat >>"$PUSH_LOG"; echo >>"$PUSH_LOG"
[ "${PUSH_FAIL:-0}" = 1 ] && { echo 'unknown command "fleet-tokens"' >&2; exit 1; }
echo '{"type":"ack","lane_op":"fleet_tokens_push","inserted":1}'
EOF
chmod +x "$T/push"

tick() {
  env TOKEN_BURN_STATE_DIR="$S" TOKEN_BURN_HOMES="$H" TOKEN_BURN_NOW="$NOW" TOKEN_BURN_LIVE_CMD=true \
    TOKEN_BURN_PUSH_CMD="$T/push" PUSH_LOG="$T/pushed" SPOOL_ROOT="$T/spool" \
    COLLECT_FUNC="$PROJ_ROOT/src/bash/run/spl-token-burn-collect.func.sh" "$@" \
    bash -c 'source "$COLLECT_FUNC"; do_spl_token_burn_collect' 2>&1
}
offset() { awk -F'\t' -v p="$1" '$2 == p { print $4 }' "$S/files.tsv"; }
outsum() { awk -F'\t' '$1 == "c-101" { o += $6 } END { print o + 0 }' "$S/buckets.tsv"; }
# crow <ts> <id> <out> [pad]: one assistant row, padded with a "pad" field
crow() {
  printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","model":"m-x","usage":{"input_tokens":1,"output_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"pad":"%s"}\n' \
    "$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z)" "$2" "$3" "${4:-}"
}
# row500 <ts> <id> <out>: a row of exactly 500 bytes, newline included
row500() { local r; r="$(crow "$1" "$2" "$3")"; crow "$1" "$2" "$3" "$(printf '%*s' $((499 - ${#r})) '' | tr ' ' x)"; }

crow $((M0 + 1)) msg_OLD 999 >"$P"
out="$(tick)"
[[ "$out" == *"mode=first"* && "$(offset "$P")" == "$(stat -c %s "$P")" && "$(outsum)" == 0 ]] &&
  pass "1. the first tick starts every file at its end, counts no history" || fail "1. $out | $(offset "$P")"

o1="$(offset "$P")"; row500 $((M0 + 2)) msg_A 100 >>"$P"
out="$(tick)"
[[ "$(( $(offset "$P") - o1 ))" == 500 && "$out" == *"claude_rows=1 "* && "$(outsum)" == 100 ]] &&
  pass "2. 500 bytes appended: the offset moves by 500, that one row is read" || fail "2. moved $(( $(offset "$P") - o1 )) | $out"
o2="$(offset "$P")"; crow $((M0 + 3)) msg_A 300 | tr -d '\n' >>"$P"
out="$(tick)"
[[ "$(offset "$P")" == "$o2" && "$out" == *"claude_rows=0 "* ]] && pass "2. a half-written row is not consumed" || fail "2. partial: $(offset "$P") vs $o2 | $out"
echo >>"$P"
out="$(tick)"
[[ "$out" == *"claude_rows=1 "* && "$(outsum)" == 300 ]] &&
  pass "3. msg_A streamed over two ticks (100, then 300) counts its MAX once: 300" || fail "3. $(outsum) | $out"

crow $((M0 + 4)) msg_T 7 >"$P"
out="$(tick)"
[[ "$(offset "$P")" == "$(stat -c %s "$P")" && "$(outsum)" == 307 ]] &&
  pass "4. truncated below its offset: read again from 0" || fail "4. truncate: $(offset "$P") $(outsum) | $out"
# a new file (new inode) at least as long as the old offset
replace() { { crow $((M0 + 5)) msg_I 10 "$(printf '%*s' 200 '' | tr ' ' y)"; crow $((M0 + 5)) msg_I2 1; } >"$P.new"; mv -f "$P.new" "$P"; }
cp -a "$S" "$T/state-before-replace"; replace
out="$(tick)"
[[ "$(outsum)" == 318 ]] && pass "4. replaced by a new inode: read again from 0" || fail "4. inode: $(outsum) | $out"
mkdir -p "$T/ctl"; cp "$PROJ_ROOT/src/bash/run/spl-cost-tokens-read.func.sh" "$T/ctl/"
python3 - "$PROJ_ROOT/src/bash/run/spl-token-burn-collect.func.sh" "$T/ctl/spl-token-burn-collect.func.sh" <<'EOF'
import sys; s = open(sys.argv[1]).read()
old = 'old[1] if old[0] == ino and size >= old[1] else 0'
assert old in s; open(sys.argv[2], 'w').write(s.replace(old, 'old[1] if size >= old[1] else 0'))
EOF
rm -rf "$S"; mv "$T/state-before-replace" "$S"; replace
tick COLLECT_FUNC="$T/ctl/spl-token-burn-collect.func.sh" >/dev/null
[[ "$(outsum)" != 318 ]] && pass "4. control: without the inode check the new file's rows are missed ($(outsum))" || fail "4. control read them anyway"

rm -rf "$S" "$T/pushed"; : >"$P"; tick >/dev/null
crow $((M0 + 6)) msg_P1 40 >>"$P"; tick PUSH_FAIL=1 >/dev/null
q1="$(awk -F'\t' '$10 == 1' "$S/buckets.tsv" | wc -l)"
crow $((M0 + 7)) msg_P2 2 >>"$P"; out="$(tick)"
f="$(grep . "$T/pushed" | tail -1)"
ok="$(jq -r '[.type == "lane", .lane_op == "fleet_tokens_push",
  (.samples | length == 1), (.samples[0] | keys == (["agent_id","cache_read","cache_write","is_metered","minute","model","tokens_in","tokens_out","vendor"])),
  (.samples[0] | .agent_id == "c-101" and .vendor == "claude" and .tokens_out == 42 and .tokens_in == 2 and .is_metered == true),
  (.samples[0].minute | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00Z$"))] | all' <<<"$f" 2>/dev/null)"
[[ "$q1" == 1 && "$ok" == true && "$out" == *"queued=1 "*"pushed=1"* ]] &&
  pass "5. a failed push keeps the bucket queued; the next frame carries the minute's full totals (42)" || fail "5. q1=$q1 ok=$ok | $f | $out"
[[ "$(awk -F'\t' '$10 == 1' "$S/buckets.tsv" | wc -l)" == 0 ]] && pass "5. an ack unqueues" || fail "5. still queued after the ack"
n="$(grep -c . "$T/pushed")"; crow $((M0 + 8)) msg_P3 1 >>"$P"; out="$(tick TOKEN_BURN_PUSH=0)"
[[ "$(grep -c . "$T/pushed")" == "$n" && "$out" == *"queued=1 "*"pushed=0"* ]] && pass "5. TOKEN_BURN_PUSH=0 queues, pushes nothing" || fail "5. push off: $out"

cp "$S/files.tsv" "$T/files.before"; crow $((M0 + 9)) msg_L 5 >>"$P"
exec 8>"$S/collect.lock"; flock -n 8
out="$(tick)"; rc=$?
exec 8>&-
[[ "$rc" == 0 && "$out" == SKIP* ]] && cmp -s "$S/files.tsv" "$T/files.before" &&
  pass "6. the lock held: the tick skips, rc 0, no state written" || fail "6. rc=$rc $out"

CRON="$PROJ_ROOT/src/bash/scripts/token-burn-collect-cron.sh"
mkdir -p "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts"; cp "$CRON" "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/"
out="$(bash "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/token-burn-collect-cron.sh" 2>&1)"; rc=$?
[[ "$rc" == 2 && "$out" == *"agent worktree"* ]] && pass "7. the cron wrapper refuses an agent worktree (exit 2)" || fail "7. rc=$rc $out"
out="$(env TOKEN_BURN_ALLOW_WORKTREE=1 TOKEN_BURN_TICKS=2 TOKEN_BURN_TICK_S=0 TOKEN_BURN_PUSH=0 TOKEN_BURN_STATE_DIR="$S" \
  TOKEN_BURN_HOMES="$H" TOKEN_BURN_LIVE_CMD=true SPOOL_ROOT="$T/spool" bash "$CRON" 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(grep -c 'token-burn tick mode=next .* ms=[0-9]' <<<"$out")" == 2 ]] &&
  pass "7. allowed, it logs one tick line per tick with its ms" || fail "7. rc=$rc $out"

# 8. the scan after the first tick (real clock): no tick lists every dir. A
# new project dir's transcript is read the next tick; a new subagent file of
# a session whose transcript moved in the last TOKEN_BURN_ACTIVE_S too; one
# of an idle session, in a dir whose mtime did not move, on the tick of its
# dir's slice (crc32 of the dir name), within TOKEN_BURN_SLICES ticks
H9="$T/home9" S9="$T/state9" P9="$T/home9/.claude/projects"
tick9() {
  env TOKEN_BURN_STATE_DIR="$S9" TOKEN_BURN_HOMES="$H9" TOKEN_BURN_LIVE_CMD=true TOKEN_BURN_PUSH=0 SPOOL_ROOT="$T/spool" \
    COLLECT_FUNC="$PROJ_ROOT/src/bash/run/spl-token-burn-collect.func.sh" "$@" bash -c 'source "$COLLECT_FUNC"; do_spl_token_burn_collect' 2>&1
}
burn9() { awk -F'\t' -v a="$1" '$1 == a { o += $6 } END { print o + 0 }' "$S9/buckets.tsv"; }
listed() { sed -n 's/.* listed=\([0-9]*\) .*/\1/p' <<<"$1"; }
sess() { mkdir -p "$P9/-opt-x-wt-$1/$2/subagents"; crow "$(date +%s)" "msg_$1" 0 >"$P9/-opt-x-wt-$1/$2.jsonl"; }
for i in $(seq 120 139); do sess "c-$i" "s$i"; done
sess c-111 33333333-3333-3333-3333-333333333333; sess c-113 55555555-5555-5555-5555-555555555555
find "$P9" -exec touch -d '-1 hour' {} +
touch "$P9/-opt-x-wt-c-113/55555555-5555-5555-5555-555555555555.jsonl"
out0="$(tick9)"; tick9 >/dev/null
mkdir -p "$P9/-opt-x-wt-c-112"; crow "$(date +%s)" msg_F1 5 >"$P9/-opt-x-wt-c-112/44444444-4444-4444-4444-444444444444.jsonl"
for a in c-111/33333333-3333-3333-3333-333333333333 c-113/55555555-5555-5555-5555-555555555555; do
  crow "$(date +%s)" "msg_sub_${a%%/*}" 6 >"$P9/-opt-x-wt-$a/subagents/agent-a1.jsonl"
  touch -d '-1 hour' "$P9/-opt-x-wt-$a/subagents" "$P9/-opt-x-wt-$a" "$P9/-opt-x-wt-${a%%/*}"
done
out="$(tick9)"
[[ "$out0" == *"scan=full"* && "$out" == *"scan=slice"* && "$(listed "$out")" -lt "$(listed "$out0")" ]] &&
  pass "8. only the first tick lists every dir (listed $(listed "$out0")), the next one a slice ($(listed "$out"))" || fail "8. listing: $out0 | $out"
[[ "$(burn9 c-112)" == 5 && "$(burn9 c-113)" == 6 ]] &&
  pass "8. the next tick reads a new project dir's transcript and an active session's new subagent" || fail "8. next: c-112=$(burn9 c-112) c-113=$(burn9 c-113) | $out"
slice() { python3 -c 'import sys, zlib; print(zlib.crc32(sys.argv[1].encode()) % 10)' "$1"; }
want="$(slice -opt-x-wt-c-111)"
got=-; [[ "$(burn9 c-111)" == 6 ]] && got="${out##*scan=slice}"
for _ in $(seq 1 10); do
  [[ "$got" == - ]] || break
  out="$(tick9)"; [[ "$(burn9 c-111)" == 6 ]] && got="${out##*scan=slice}"
done
got="${got%% *}"
[[ "$got" == "$want" ]] && pass "8. the idle session's subagent is read on its dir's slice ($want of 10)" || fail "8. slice: got=$got want=$want | $out"
rm -rf "$S9"; tick9 >/dev/null
crow "$(date +%s)" msg_sub2 7 >"$P9/-opt-x-wt-c-113/55555555-5555-5555-5555-555555555555/subagents/agent-a2.jsonl"
touch "$P9/-opt-x-wt-c-113/55555555-5555-5555-5555-555555555555.jsonl"
touch -d '-1 hour' "$P9/-opt-x-wt-c-113/55555555-5555-5555-5555-555555555555/subagents" "$P9/-opt-x-wt-c-113"
out="$(tick9 TOKEN_BURN_ACTIVE_S=0)"
[[ "$out" != *"scan=slice$(slice -opt-x-wt-c-113) "* && "$(burn9 c-113)" == 0 ]] && pass "8. control: without the active-session listing that subagent waits for its slice" || fail "8. control: c-113=$(burn9 c-113) | $out"

echo "spl-token-burn-collect: $fails failure(s)"
exit "$fails"
