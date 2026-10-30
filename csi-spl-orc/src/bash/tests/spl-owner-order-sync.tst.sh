#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: ORDER_CMD=sync of do_spl_owner_order (spec 168 B2, SPL-4357; risk
#          R1 of section 8): the owner-order ledgers copied both ways with
#          another box, append-only. Synthetic orders only. The far box is a
#          dir here: a fake ssh runs the far step locally, a fake sudo drops
#          its user switch.
#   1. a dry run prints the counts and writes nothing
#   2. DRY_RUN=0 copies what each side lacks (push and pull); the old lines
#      stay a byte-for-byte prefix (append-only); a copied line gains
#      synced_from / synced_at and keeps its own source (c-697 N3: a hand-
#      appended "source hub" lift is no more trusted on the far box)
#   3. idempotent: a second run copies 0 and changes no byte
#   4. the same order with another text on the two boxes: exit 3, nothing
#      written on either side
#   5. a malformed far ledger: exit 2, nothing written
#   6. the far box answers to another BOX_TAG, or ssh fails: exit 1
#   7. a sync that cannot verify the far file refuses: the append is lost
#      (exit 1), or the file changed between the read and the append (exit 1,
#      nothing appended)
#   8. CONTROL: with the far side already equal, nothing is copied
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

H="$T/here" F="$T/far"
M1=11111111-aaaa-4bbb-8ccc-000000000001 M2=22222222-aaaa-4bbb-8ccc-000000000002
M3=33333333-aaaa-4bbb-8ccc-000000000003 L1=44444444-aaaa-4bbb-8ccc-000000000004
mkdir -p "$T/stub"
# fake ssh <dest> <cmd>: the far step runs here. $T/ssh-down = unreachable;
# $T/drop-append = the append is acked but lost; $T/race = a line lands on
# the far file just before the append.
cat >"$T/stub/fakessh" <<STUB
#!/usr/bin/env bash
[ -e "$T/ssh-down" ] && { echo "ssh: connect to host: Connection refused" >&2; exit 255; }
cmd="\$2"
if [[ "\$cmd" == *" append "* ]]; then
  [ -e "$T/drop-append" ] && { cat >/dev/null; echo "result appended"; exit 0; }
  [ -e "$T/race" ] && echo '{"op":"lift","order":"$M3","lift_msg":"$L1","source":"given","reason":"race","by":"c-900","at":"x"}' >>"$F/repo-x.jsonl"
fi
PATH="$T/stub:\$PATH" bash -c "\$cmd"
STUB
printf '#!/usr/bin/env bash\nwhile [ "${1:-}" = -n ] || [ "${1:-}" = -u ] || [ "${1:-}" = -H ]; do [ "$1" = -u ] && shift; shift; done\nexec "$@"\n' >"$T/stub/sudo"
chmod +x "$T/stub/fakessh" "$T/stub/sudo"
printf 'OWNER_USER=spooluser\nAGENT_USER=agentuser\nBOX_TAG=sat\n' >"$T/far.env"

order() {  # <file> <id> <text> [source]
  jq -n -c --arg o "$2" --arg t "$3" --arg s "${4:-given}" \
    '{op: "add", order: $o, repo: "repo-x", paths: ["docs/**"], text: $t, source: $s, gate: "content",
      ts: "2026-10-29T15:46:10Z", owner: "HUM-10", topic: "", expires: "", note: "", by: "c-900", at: "2026-10-29T16:00:00Z"}' >>"$1"
}
fresh() {
  rm -rf "$H" "$F" "$T/ssh-down" "$T/drop-append" "$T/race"; mkdir -p "$H" "$F"
  order "$H/repo-x.jsonl" "$M1" 'keep the contents'
  order "$H/repo-x.jsonl" "$M2" 'never rename it'
  # N3: a hand-appended lift that claims the hub
  echo '{"op":"lift","order":"'"$M2"'","lift_msg":"'"$L1"'","source":"hub","reason":"hand","by":"c-999","at":"2026-10-30T00:00:00Z"}' >>"$H/repo-x.jsonl"
  order "$F/repo-x.jsonl" "$M3" 'bump the version'
}
sync() {
  SNIPPET="do_spl_owner_order" in_orc ORDER_CMD=sync TO_BOX=sat OWNER_ORDER_DIR="$H" ORDER_SYNC_REMOTE_DIR="$F" \
    ORDER_SYNC_BOX_ENV="$T/far.env" ORDER_SYNC_FROM_BOX=pc ORDER_SYNC_SSH_CMD="$T/stub/fakessh" "$@" >"$T/o" 2>&1
  RC=$?
}
shas() { sha256sum "$H/repo-x.jsonl" "$F/repo-x.jsonl" 2>/dev/null | cut -d' ' -f1 | paste -sd' '; }

# ---- 1. dry run ---------------------------------------------------------------
fresh; s0="$(shas)"
sync
[[ $RC == 0 ]] && grep -q 'sync repo-x here=pc box=sat push=3 pull=1 (dry run)' "$T/o" && [[ "$(shas)" == "$s0" ]] &&
  pass "1. dry run: push=3 pull=1 printed, no byte written" || fail "1. rc=$RC $(cat "$T/o")"
grep -q 'keep the contents\|bump the version' "$T/o" && fail "1. order text on stdout" || pass "1. no order text on stdout"

# ---- 2. both ways, append-only ------------------------------------------------
fresh; cp "$H/repo-x.jsonl" "$T/h0"; cp "$F/repo-x.jsonl" "$T/f0"
sync DRY_RUN=0
[[ $RC == 0 ]] && grep -q 'push=3 pull=1' "$T/o" && grep -q 'OK the repo-x ledger: 3 line(s) copied to sat, 1 from it, verified' "$T/o" &&
  pass "2. DRY_RUN=0: 3 pushed, 1 pulled, verified" || fail "2. rc=$RC $(cat "$T/o")"
[[ "$(head -c "$(stat -c %s "$T/h0")" "$H/repo-x.jsonl")" == "$(cat "$T/h0")" && "$(head -c "$(stat -c %s "$T/f0")" "$F/repo-x.jsonl")" == "$(cat "$T/f0")" ]] &&
  pass "2. append-only: each old file is a byte prefix of the new one" || fail "2. a line was rewritten"
[[ "$(wc -l <"$H/repo-x.jsonl")" == 4 && "$(wc -l <"$F/repo-x.jsonl")" == 4 ]] && pass "2. both ledgers hold 4 lines" || fail "2. lines: $(wc -l "$H/repo-x.jsonl" "$F/repo-x.jsonl")"
jq -e -s --arg o "$M1" 'map(select(.order == $o and .op == "add"))[0] | .synced_from == "pc" and (.synced_at | test("Z$")) and .text == "keep the contents"' "$F/repo-x.jsonl" >/dev/null &&
  pass "2. a pushed line: synced_from pc, synced_at, the text word for word" || fail "2. far: $(cat "$F/repo-x.jsonl")"
jq -e -s --arg o "$M3" 'map(select(.order == $o))[0] | .synced_from == "sat"' "$H/repo-x.jsonl" >/dev/null &&
  pass "2. a pulled line: synced_from sat" || fail "2. here: $(cat "$H/repo-x.jsonl")"
jq -e -s 'map(select(.op == "lift"))[0] | .source == "hub" and .synced_from == "pc"' "$F/repo-x.jsonl" >/dev/null &&
  pass "2. N3: the hand-appended 'source hub' lift arrives marked synced_from pc (B3 re-reads it on the hub)" || fail "2. N3: $(cat "$F/repo-x.jsonl")"
SNIPPET="do_spl_owner_order" in_orc ORDER_CMD=match ORDER_REPO=repo-x ORDER_PATHS=docs/a.md OWNER_ORDER_DIR="$F" >"$T/m" 2>&1; mrc=$?
[[ $mrc == 3 ]] && grep -q "^$M1 " "$T/m" && ! grep -q "^$M2 " "$T/m" &&
  pass "2. the far ledger folds: M1 active there, M2 lifted" || fail "2. far match rc=$mrc $(cat "$T/m")"

# ---- 3. idempotent ---------------------------------------------------------------
s1="$(shas)"
sync DRY_RUN=0
[[ $RC == 0 ]] && grep -q 'push=0 pull=0' "$T/o" && [[ "$(shas)" == "$s1" ]] &&
  pass "3. second run: push=0 pull=0, not a byte changed" || fail "3. rc=$RC $(cat "$T/o")"

# ---- 4. conflict ------------------------------------------------------------------
fresh; order "$F/repo-x.jsonl" "$M1" 'keep the contents, all of them'; s0="$(shas)"
sync DRY_RUN=0
[[ $RC == 3 ]] && grep -q 'order(s) 11111111 differ between here and sat' "$T/o" && [[ "$(shas)" == "$s0" ]] &&
  pass "4. the same order, another text: exit 3, nothing written either side" || fail "4. rc=$RC $(cat "$T/o")"

# ---- 5. malformed far ---------------------------------------------------------------
fresh; echo '{"op": broken' >>"$F/repo-x.jsonl"; s0="$(shas)"
sync DRY_RUN=0
[[ $RC == 2 ]] && grep -q 'ledger is malformed' "$T/o" && [[ "$(shas)" == "$s0" ]] &&
  pass "5. a malformed far ledger: exit 2, nothing written" || fail "5. rc=$RC $(cat "$T/o")"

# ---- 6. the wrong box, no ssh ---------------------------------------------------------
fresh; s0="$(shas)"
sync DRY_RUN=0 TO_BOX=pc2 ORDER_SYNC_FROM_BOX=pc
[[ $RC == 1 ]] && grep -q "answers as box 'sat', not 'pc2'" "$T/o" && [[ "$(shas)" == "$s0" ]] &&
  pass "6. a far box with another BOX_TAG: exit 1, nothing written" || fail "6. rc=$RC $(cat "$T/o")"
touch "$T/ssh-down"
sync DRY_RUN=0
[[ $RC == 1 ]] && grep -q 'cannot read the box env file of sat' "$T/o" && [[ "$(shas)" == "$s0" ]] &&
  pass "6. ssh down: exit 1, nothing written" || fail "6. rc=$RC $(cat "$T/o")"

# ---- 7. cannot verify -------------------------------------------------------------------
fresh; touch "$T/drop-append"
sync DRY_RUN=0
[[ $RC == 1 ]] && grep -q 'cannot verify sat' "$T/o" &&
  pass "7. the append acked but lost: exit 1 'cannot verify'" || fail "7. rc=$RC $(cat "$T/o")"
fresh; touch "$T/race"; cp "$F/repo-x.jsonl" "$T/f0"
sync DRY_RUN=0
[[ $RC == 1 ]] && grep -q 'result changed' "$T/o" && [[ "$(wc -l <"$F/repo-x.jsonl")" == 2 ]] &&
  pass "7. the far file changed after the read: exit 1, nothing appended (only the racing line)" || fail "7. rc=$RC $(cat "$T/o")"

# ---- 8. CONTROL: already equal -------------------------------------------------------------
fresh; cp "$H/repo-x.jsonl" "$F/repo-x.jsonl"; order "$H/repo-x.jsonl" "$M3" 'bump the version'
cp "$H/repo-x.jsonl" "$F/repo-x.jsonl"; s0="$(shas)"
sync DRY_RUN=0
[[ $RC == 0 ]] && grep -q 'push=0 pull=0' "$T/o" && [[ "$(shas)" == "$s0" ]] &&
  pass "8. CONTROL equal ledgers: nothing copied" || fail "8. rc=$RC $(cat "$T/o")"

echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
