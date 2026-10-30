#!/usr/bin/env bash
# test-channel-workspace-move-box.sh — the box steps of a channel move into
# another workspace (spec 169 T10, cases C11 and C12):
#   1. usage: a bad verb, id, tenant or key is refused (exit 2), nothing done
#   2. rule-rows: without --apply only a PLAN line, the map unchanged; with it
#      the channel's row moves to <DST> (other columns, other rows, comments
#      and the file mode kept); a re-run changes nothing; a <DST> row already
#      there beside the <SRC> row is refused (exit 3), the map unchanged
#   3. probe (C11): a desk whose probe DM fails exits 1 and records nothing;
#      a good probe records its msg id, and a re-run reuses it, sends nothing
#   4. lane-notes (C12): one note per lane, old -> new key; a re-run sends none
# Seams: CMB_PROBE_CMD (the probe DM), CMB_SEND_CMD (spool-send.sh); both
# record every call (an absent call means "not made", not "not recorded").
# CMB_SCRIPT runs a planted copy for the red controls.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${CMB_SCRIPT:-$HERE/../scripts/channel-workspace-move-box.sh}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }

export SPOOL_TEST=1 SPOOL_ROOT="$T/spool" CHANNEL_MOVE_STATE="$T/state"
export SPOOL_CHANNEL_RULES_MAP="$T/spool/channel-rules.tsv"
mkdir -p "$T/spool"
DOC=11111111-2222-4333-8444-555555555555
MOVE=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee

seed_map() {
  rm -rf "$CHANNEL_MOVE_STATE"
  printf '# tenant\tchannel\tdoc\tenv\tdesk\tsole\n' >"$SPOOL_CHANNEL_RULES_MAP"
  printf 'src1\tproj\t%s\tprd\tc-101\tc-102@boxa\n' "$DOC" >>"$SPOOL_CHANNEL_RULES_MAP"
  printf 'src1\tother\t%s\tprd\tc-103\n' "$DOC" >>"$SPOOL_CHANNEL_RULES_MAP"
  chmod 0640 "$SPOOL_CHANNEL_RULES_MAP"
}

# probe stub: CMB_PROBE_FAIL=<agent> fails that agent's probe
cat >"$T/probe" <<'EOF'
#!/usr/bin/env bash
echo "probe $CMB_ENV $CMB_TENANT $CMB_AGENT $CMB_TO $CMB_TASK" >>"$STUB_LOG"
[ "${CMB_PROBE_FAIL:-}" = "$CMB_AGENT" ] && { echo "unknown_agent" >&2; exit 4; }
h="$(printf '%s' "$CMB_AGENT" | md5sum)"
printf '{"msg_id":"%s-%s-4%s-8%s-%s","task_id":"%s"}\n' "${h:0:8}" "${h:8:4}" "${h:12:3}" "${h:15:3}" "${h:18:12}" "$CMB_TASK"
EOF
cat >"$T/send" <<'EOF'
#!/usr/bin/env bash
printf 'send' >>"$STUB_LOG"; printf ' [%s]' "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
EOF
chmod +x "$T/probe" "$T/send"
export CMB_PROBE_CMD="$T/probe" CMB_SEND_CMD="$T/send" STUB_LOG="$T/calls.log"

run() { : >"$STUB_LOG"; bash "$S" "$@" >"$T/out" 2>&1; }

# --- 1. usage --------------------------------------------------------------------------
for bad in "nope" "rule-rows --move x --src src1 --dst dst1 --channel proj" \
  "rule-rows --move $MOVE --src SRC --dst dst1 --channel proj" \
  "rule-rows --move $MOVE --src src1 --dst src1 --channel proj" \
  "probe --move $MOVE --env stg --tenant dst1 --to HUM-1 --agent c-101" \
  "probe --move $MOVE --env prd --tenant dst1 --to HUM-1 --agent bob"; do
  seed_map; cp "$SPOOL_CHANNEL_RULES_MAP" "$T/before"
  # shellcheck disable=SC2086 # the case's words, split on purpose
  run $bad; rc=$?
  [[ $rc -eq 2 && ! -s "$STUB_LOG" ]] && cmp -s "$T/before" "$SPOOL_CHANNEL_RULES_MAP" \
    && pass "1. usage refused: $bad" || fail "1. usage '$bad': rc=$rc $(cat "$T/out")"
done

# --- 2. rule-rows ----------------------------------------------------------------------
seed_map; cp "$SPOOL_CHANNEL_RULES_MAP" "$T/before"
run rule-rows --move "$MOVE" --src src1 --dst dst1 --channel proj; rc=$?
[[ $rc -eq 0 ]] && grep -q '^PLAN rule-row src1 #proj -> dst1 #proj' "$T/out" && cmp -s "$T/before" "$SPOOL_CHANNEL_RULES_MAP" \
  && pass "2. without --apply: PLAN only, map unchanged" || fail "2. plan: rc=$rc $(cat "$T/out")"
run rule-rows --move "$MOVE" --src src1 --dst dst1 --channel proj --apply; rc=$?
want="$(printf 'dst1\tproj\t%s\tprd\tc-101\tc-102@boxa' "$DOC")"
[[ $rc -eq 0 ]] && grep -qxF "$want" "$SPOOL_CHANNEL_RULES_MAP" && ! grep -q "^src1	proj	" "$SPOOL_CHANNEL_RULES_MAP" \
  && pass "2. --apply moves the row to dst1, columns 3-6 kept" || fail "2. apply: rc=$rc $(cat "$T/out" "$SPOOL_CHANNEL_RULES_MAP")"
grep -q '^# tenant' "$SPOOL_CHANNEL_RULES_MAP" && grep -q "^src1	other	" "$SPOOL_CHANNEL_RULES_MAP" \
  && [[ "$(stat -c %a "$SPOOL_CHANNEL_RULES_MAP")" == 640 && "$(wc -l <"$SPOOL_CHANNEL_RULES_MAP")" -eq 3 ]] \
  && pass "2. other rows, the comment and the mode 0640 kept" || fail "2. kept: $(stat -c %a "$SPOOL_CHANNEL_RULES_MAP") $(cat "$SPOOL_CHANNEL_RULES_MAP")"
cp "$SPOOL_CHANNEL_RULES_MAP" "$T/after1"
run rule-rows --move "$MOVE" --src src1 --dst dst1 --channel proj --apply; rc=$?
[[ $rc -eq 0 ]] && grep -q 'already' "$T/out" && cmp -s "$T/after1" "$SPOOL_CHANNEL_RULES_MAP" \
  && pass "2. a re-run changes nothing and says already" || fail "2. rerun: rc=$rc $(cat "$T/out")"
seed_map; printf 'dst1\tproj\t%s\tprd\tc-109\n' "$DOC" >>"$SPOOL_CHANNEL_RULES_MAP"; cp "$SPOOL_CHANNEL_RULES_MAP" "$T/before"
run rule-rows --move "$MOVE" --src src1 --dst dst1 --channel proj --apply; rc=$?
[[ $rc -eq 3 ]] && grep -q 'dst1 #proj' "$T/out" && cmp -s "$T/before" "$SPOOL_CHANNEL_RULES_MAP" \
  && pass "2. a dst1 row beside the src1 row: refused, exit 3, unchanged" || fail "2. conflict: rc=$rc $(cat "$T/out")"
seed_map
run rule-rows --move "$MOVE" --src src1 --dst dst1 --channel proj --to-name proj2 --apply; rc=$?
[[ $rc -eq 0 ]] && grep -q "^dst1	proj2	$DOC	" "$SPOOL_CHANNEL_RULES_MAP" \
  && pass "2. --to-name renames the channel column" || fail "2. to-name: rc=$rc $(cat "$SPOOL_CHANNEL_RULES_MAP")"
rm -rf "$SPOOL_CHANNEL_RULES_MAP" "$CHANNEL_MOVE_STATE"
run rule-rows --move "$MOVE" --src src1 --dst dst1 --channel proj --apply; rc=$?
[[ $rc -eq 0 && ! -e "$SPOOL_CHANNEL_RULES_MAP" ]] && grep -q 'no rule row' "$T/out" \
  && pass "2. no map on this box: nothing to do, no file made" || fail "2. no map: rc=$rc $(cat "$T/out")"

# --- 3. probe (C11) --------------------------------------------------------------------
P=(probe --move "$MOVE" --env prd --tenant dst1 --to HUM-10 --agent c-101)
run "${P[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$STUB_LOG" ]] && grep -q '^PLAN probe c-101' "$T/out" && pass "3. without --apply: no probe sent" || fail "3. plan: rc=$rc $(cat "$T/out")"
CMB_PROBE_FAIL=c-101 run "${P[@]}" --apply; rc=$?
[[ $rc -eq 1 ]] && grep -q 'c-101' "$T/out" && ! grep -qs '^probe	c-101	' "$CHANNEL_MOVE_STATE/$MOVE/box.tsv" \
  && pass "3. C11 a failed probe: exit 1, names the agent, records nothing" || fail "3. fail: rc=$rc $(cat "$T/out")"
run "${P[@]}" --apply; rc=$?
id1="$(tail -n1 "$T/out")"
[[ $rc -eq 0 && "$id1" =~ ^[0-9a-f-]{36}$ ]] && grep -q "^probe	c-101	$id1	" "$CHANNEL_MOVE_STATE/$MOVE/box.tsv" \
  && grep -qx "probe prd dst1 c-101 HUM-10 $MOVE" "$STUB_LOG" \
  && pass "3. a good probe goes to the caller on the move's task; its msg id is recorded" || fail "3. good: rc=$rc $(cat "$T/out" "$STUB_LOG")"
run "${P[@]}" --apply; rc=$?
[[ $rc -eq 0 && ! -s "$STUB_LOG" && "$(tail -n1 "$T/out")" == "$id1" ]] \
  && pass "3. a re-run reuses the recorded probe, sends nothing" || fail "3. rerun: rc=$rc $(cat "$T/out" "$STUB_LOG")"

# --- 4. lane-notes (C12) ---------------------------------------------------------------
cat >"$T/lanes.json" <<'EOF'
[{"agent":"c-201","topic":"dispatch-11112222","old_key":"SRC-7","new_key":"DST-1"},
 {"agent":"g-202@boxb","topic":"","old_key":"SRC-9","new_key":"DST-2"}]
EOF
L=(lane-notes --move "$MOVE" --from c-001 --lanes "$T/lanes.json")
run "${L[@]}"; rc=$?
[[ $rc -eq 0 && ! -s "$STUB_LOG" ]] && [[ "$(grep -c '^PLAN note' "$T/out")" -eq 2 ]] && pass "4. without --apply: 2 PLAN lines, no send" || fail "4. plan: rc=$rc $(cat "$T/out")"
run "${L[@]}" --apply; rc=$?
[[ $rc -eq 0 && "$(grep -c '^send' "$STUB_LOG")" -eq 2 ]] \
  && grep -q '\[--to\] \[c-201\].*\[--task\] \[dispatch-11112222\].*SRC-7 -> DST-1' "$STUB_LOG" \
  && grep -q '\[--to\] \[g-202@boxb\] \[--kind\] \[note\] \[--body\].*SRC-9 -> DST-2' "$STUB_LOG" \
  && grep -q '\[--from\] \[c-001\]' "$STUB_LOG" \
  && pass "4. C12 one note per lane, old -> new, on its topic" || fail "4. notes: rc=$rc $(cat "$T/out" "$STUB_LOG")"
run "${L[@]}" --apply; rc=$?
[[ $rc -eq 0 && ! -s "$STUB_LOG" ]] && pass "4. a re-run sends no second note" || fail "4. rerun: rc=$rc $(cat "$STUB_LOG")"
printf '[{"agent":"c-201","topic":"","old_key":"SRC-7; rm","new_key":"DST-1"}]' >"$T/bad.json"
run lane-notes --move "$MOVE" --from c-001 --lanes "$T/bad.json" --apply; rc=$?
[[ $rc -eq 2 && ! -s "$STUB_LOG" ]] && pass "4. a malformed key: refused, nothing sent" || fail "4. bad key: rc=$rc $(cat "$T/out")"

echo "channel-workspace-move-box: $fails failure(s)"
[[ $fails -eq 0 ]]
