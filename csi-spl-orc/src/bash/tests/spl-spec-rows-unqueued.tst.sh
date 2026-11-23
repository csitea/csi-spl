#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_spec_rows_unqueued (spl-spec-rows-unqueued.func.sh,
#          spec-rows-unqueued.py; SPL-6337) lists decided/signed specs on
#          origin/master whose open build rows have no citing commit on master,
#          no queued or placed ask and no live lane.
#   1. RED CONTROL: fixture decided spec with unqueued row B1 is listed in
#      table, json and digest formats; the same spec with B1 queued is not
#   2. placed ask (state done, reason "placed: ...") suppresses the row; a
#      declined or non-placed done ask does not
#   3. multi-row summary with a row-specific placement slug credits only its
#      own row (B1 placement quoting "B1, B2" leaves B2 unqueued)
#   4. live lane suppresses the row; a done lane does not
#   5. citing non-spec-doc commit on master (subject or paired body) suppresses
#      its row; a docs(spec-NNN) spec-update commit mentioning the row does not
#   6. status filtering: Decided, signed, v1.2 signed are included; Draft,
#      "Draft — Q1 decided", NOT SIGNED, never signed, Implemented are excluded
#   7. spec-closed rows (DROPPED, Implemented, Row status bullet) are excluded
#   8. fail-closed: unreachable hub in asks or LOCAL-ONLY in lanes returns rc 1
#   9. read-only: fixture git repo refs and status unchanged before and after
#  10. ./run -a do_spl_spec_rows_unqueued runs cleanly via the lazy loader
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }
has() { grep -qF -- "$2" <<<"$3" && pass "$1" || fail "$1" "no '$2' in: $3"; }
nhas() { ! grep -qF -- "$2" <<<"$3" && pass "$1" || fail "$1" "unexpected '$2' in: $3"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
mkdir -p "$REPO/csi-spl-doc/specs/901-widget" \
  "$REPO/csi-spl-doc/specs/902-signed-panel" \
  "$REPO/csi-spl-doc/specs/903-draft-only" \
  "$REPO/csi-spl-doc/specs/904-not-signed" \
  "$REPO/csi-spl-doc/specs/905-v12-signed" \
  "$REPO/csi-spl-doc/specs/906-implemented"

cat >"$REPO/csi-spl-doc/specs/901-widget/spec.md" <<'EOF'
# Spec 901: widget

**Feature ID**: `901-widget` · **Status**: Decided v0.6

## 6. Build order (rows a later lane can take)

| # | lane | task | red control |
|---|---|---|---|
| B1 | api | build widget store | test fails |
| B2 | wui | build widget page | e2e fails |
| B3 | orc | build widget check | unit fails |
| B4 | api | DROPPED (Q1 = A): removed | - |
| B5 | api | build widget hook | hook fails |
| B6 | doc | build widget docs | lint fails |

Row status:

- **B6: Implemented** (SPL-100)
EOF

cat >"$REPO/csi-spl-doc/specs/902-signed-panel/spec.md" <<'EOF'
# Spec 902: signed panel

Status: **v1.0, signed** by all four seats.

## 4. Build rows

| row | area | task |
|---|---|---|
| S1 | api | first slice |
| S2 (Implemented, SPL-200) | wui | second slice |
EOF

cat >"$REPO/csi-spl-doc/specs/903-draft-only/spec.md" <<'EOF'
# Spec 903: draft

- **Status:** Draft — Q1 decided by owner; Q2 open

## 4. Build rows

| row | task |
|---|---|
| B1 | should not be listed while draft |
EOF

cat >"$REPO/csi-spl-doc/specs/904-not-signed/spec.md" <<'EOF'
# Spec 904: not signed

Version v0.3 (2026-11-01): NOT SIGNED, two defects open.
v0.1 was never signed.

## 4. Build rows

| row | task |
|---|---|
| B1 | should not be listed while unsigned |
EOF

cat >"$REPO/csi-spl-doc/specs/905-v12-signed/spec.md" <<'EOF'
# Spec 905: multi-version signed

Version v1.4 (2026-11-10): adds extra notes.

Version v1.3 draft (2026-11-05): Not signed yet.

v1.2, signed (2026-10-26): core rows ready.

## 6. Build rows

| row | task |
|---|---|
| B1 | core work |
EOF

cat >"$REPO/csi-spl-doc/specs/906-implemented/spec.md" <<'EOF'
# Spec 906: already implemented

**Status**: Implemented (decided 2026-10-01)

## 6. Build rows

| row | task |
|---|---|
| B1 | already shipped |
EOF

git -C "$REPO" init -q -b master
git -C "$REPO" config user.name "FirstName LastName"
git -C "$REPO" config user.email "dev@example.com"
git -C "$REPO" add csi-spl-doc/specs
git -C "$REPO" commit -q -m "docs(spec-901, SPL-1): spec 901 v0.6 mentioning B1 and B2 in subject"
# Non-spec-doc commit citing B3 in body only (paired form)
mkdir -p "$REPO/src"
echo "ok" >"$REPO/src/widget.txt"
git -C "$REPO" add src/widget.txt
git -C "$REPO" commit -q -m "feat(orc, SPL-2): add widget check" -m "Spec 901 row B3: implemented widget check."
# Non-spec-doc commit citing S1 in subject
echo "ok2" >"$REPO/src/s1.txt"
git -C "$REPO" add src/s1.txt
git -C "$REPO" commit -q -m "feat(api, SPL-3): first slice (spec 902 S1)"
# Create origin/master ref pointing to master
git -C "$REPO" update-ref refs/remotes/origin/master "$(git -C "$REPO" rev-parse master)"

ASKS_EMPTY="$T/asks-empty.json"
LANES_EMPTY="$T/lanes-empty.json"
echo '{"fleet":"test","hub":"ok","asks":[]}' >"$ASKS_EMPTY"
echo '{"hub":"ok","lanes":[]}' >"$LANES_EMPTY"

run_sru() {
  local fmt="$1" asks="$2" lanes="$3"
  (
    cd "$PROJ_ROOT" || exit 1
    SPEC_UNQUEUED_REPO="$REPO" SPEC_UNQUEUED_REF="origin/master" \
      SPEC_UNQUEUED_FORMAT="$fmt" \
      SPEC_UNQUEUED_ASKS_FILE="$asks" \
      SPEC_UNQUEUED_LANES_FILE="$lanes" \
      RUN_STDOUT_IS_DATA=1 ./run -a do_spl_spec_rows_unqueued --quiet
  )
}

# 1. RED CONTROL + 5 + 6 + 7 + 10: unqueued B1, B2, B5 in 901; B1 in 905; none in 902/903/904/906
before_sha="$(git -C "$REPO" rev-parse origin/master)"
before_st="$(git -C "$REPO" status --porcelain)"

out_tbl="$(run_sru table "$ASKS_EMPTY" "$LANES_EMPTY")"; rc=$?
eq "1. table exits 0 via ./run" "0" "$rc"
has "1. RED CONTROL: 901-widget unqueued rows B1,B2,B5 listed" $'901-widget\tdecided v0.6\t3\tB1,B2,B5' "$out_tbl"
has "6. v1.2 signed spec 905-v12-signed listed" $'905-v12-signed\tsigned v1.2\t1\tB1' "$out_tbl"
nhas "5. spec 902 S1 cited by commit and S2 Implemented -> not listed" "902-signed-panel" "$out_tbl"
nhas "6. Draft spec 903 excluded" "903-draft-only" "$out_tbl"
nhas "6. NOT SIGNED spec 904 excluded" "904-not-signed" "$out_tbl"
nhas "6. Implemented spec 906 excluded" "906-implemented" "$out_tbl"
nhas "5. B3 cited in commit body -> excluded" "B3" "$out_tbl"
nhas "7. B4 DROPPED -> excluded" "B4" "$out_tbl"
nhas "7. B6 Row status Implemented -> excluded" "B6" "$out_tbl"
has "1. summary total line" "specs=2 rows=4" "$out_tbl"

out_dig="$(run_sru digest "$ASKS_EMPTY" "$LANES_EMPTY")"
has "1. digest line names 901-widget (B1, B2, B5)" "**901-widget** (B1, B2, B5)" "$out_dig"
has "1. digest line names 905-v12-signed (B1)" "**905-v12-signed** (B1)" "$out_dig"

# 1b. GREEN half of RED CONTROL: queue B1, B2, B5 (901) and B1 (905) -> nothing listed
ASKS_QUEUED="$T/asks-queued.json"
cat >"$ASKS_QUEUED" <<'EOF'
{"fleet":"test","hub":"ok","asks":[
  {"ask_id":"11111111-1111-1111-1111-111111111111","state":"queued","placement":"claude:c002-s901-b1-widget-store","summary":"spec 901 B1"},
  {"ask_id":"22222222-2222-2222-2222-222222222222","state":"queued","placement":"claude:c002-s901-b2-widget-page","summary":"spec 901 B2"},
  {"ask_id":"33333333-3333-3333-3333-333333333333","state":"done","reason":"placed: c-101@box-a","placement":"claude:c002-s901-b5-widget-hook","summary":"spec 901 B5"},
  {"ask_id":"44444444-4444-4444-4444-444444444444","state":"acked","placement":"claude:c002-s905-b1-core","summary":"spec 905 B1"}
]}
EOF
out_q_tbl="$(run_sru table "$ASKS_QUEUED" "$LANES_EMPTY")"
nhas "1. GREEN CONTROL: queued/placed 901-widget no longer listed" "901-widget" "$out_q_tbl"
nhas "1. GREEN CONTROL: acked/placing 905-v12-signed no longer listed" "905-v12-signed" "$out_q_tbl"
has "1. GREEN CONTROL: total specs=0 rows=0" "specs=0 rows=0" "$out_q_tbl"
eq "1. GREEN CONTROL: digest output empty when all queued" "" "$(run_sru digest "$ASKS_QUEUED" "$LANES_EMPTY")"

# 2. declined or non-placed done ask does NOT suppress; placed ask DOES
ASKS_MIX="$T/asks-mix.json"
cat >"$ASKS_MIX" <<'EOF'
{"fleet":"test","hub":"ok","asks":[
  {"ask_id":"aaaa1111-1111-1111-1111-111111111111","state":"declined","reason":"duplicate","placement":"claude:c002-s901-b1-widget","summary":"spec 901 B1"},
  {"ask_id":"aaaa2222-1111-1111-1111-111111111111","state":"done","reason":"handled in chat","placement":"","summary":"spec 901 B2"},
  {"ask_id":"aaaa3333-1111-1111-1111-111111111111","state":"done","reason":"placed: c-102@box-a","placement":"claude:c002-s901-b5-hook","summary":"spec 901 B5"}
]}
EOF
out_mix="$(run_sru json "$ASKS_MIX" "$LANES_EMPTY")"
eq "2. declined/non-placed kept unqueued; placed B5 suppressed" '["B1","B2"]' \
  "$(jq -c '.specs[] | select(.spec == "901-widget") | .unqueued' <<<"$out_mix")"

# 3. multi-row poll quote in summary with row-specific placement credits ONLY placement row
ASKS_MULTI="$T/asks-multi.json"
cat >"$ASKS_MULTI" <<'EOF'
{"fleet":"test","hub":"ok","asks":[
  {"ask_id":"bbbb1111-1111-1111-1111-111111111111","state":"done","reason":"placed: c-103@box-a","placement":"claude:c002-s901-b1-widget-store","summary":"QUEUE spec 901 build row (poll: all rows B1, B2, B5 at once)"}
]}
EOF
out_multi="$(run_sru json "$ASKS_MULTI" "$LANES_EMPTY")"
eq "3. placement s901-b1 suppresses only B1, leaving B2 and B5" '["B2","B5"]' \
  "$(jq -c '.specs[] | select(.spec == "901-widget") | .unqueued' <<<"$out_multi")"

# 4. live lane suppresses; done lane does not
LANES_MIX="$T/lanes-mix.json"
cat >"$LANES_MIX" <<'EOF'
{"hub":"ok","lanes":[
  {"agent_id":"c-201","state":"live","branch":"c-201-c002-s901-b2-widget-page","scope":"spec 901 row B2"},
  {"agent_id":"c-202","state":"done","branch":"c-202-c002-s901-b5-widget-hook","scope":"spec 901 row B5"}
]}
EOF
out_lane="$(run_sru json "$ASKS_EMPTY" "$LANES_MIX")"
eq "4. live lane suppresses B2; done lane leaves B5 unqueued" '["B1","B5"]' \
  "$(jq -c '.specs[] | select(.spec == "901-widget") | .unqueued' <<<"$out_lane")"

# 8. fail-closed when asks or lanes hub is unreachable
ASKS_BAD="$T/asks-bad.json"
LANES_BAD="$T/lanes-bad.json"
echo '{"fleet":"test","hub":"unreachable","asks":[]}' >"$ASKS_BAD"
echo '{"hub":"unreachable","lanes":[]}' >"$LANES_BAD"
err8a="$(run_sru table "$ASKS_BAD" "$LANES_EMPTY" 2>&1)"; rc8a=$?
[ "$rc8a" -ne 0 ] && grep -q "fail closed" <<<"$err8a" && pass "8a. unreachable asks fails closed (rc=$rc8a)" || fail "8a. asks fail-closed" "rc=$rc8a out=$err8a"
err8b="$(run_sru table "$ASKS_EMPTY" "$LANES_BAD" 2>&1)"; rc8b=$?
[ "$rc8b" -ne 0 ] && grep -q "fail closed" <<<"$err8b" && pass "8b. LOCAL-ONLY lanes fails closed (rc=$rc8b)" || fail "8b. lanes fail-closed" "rc=$rc8b out=$err8b"

# 9. read-only check on fixture git repo
eq "9. git ref unchanged" "$before_sha" "$(git -C "$REPO" rev-parse origin/master)"
eq "9. git status unchanged" "$before_st" "$(git -C "$REPO" status --porcelain)"

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
