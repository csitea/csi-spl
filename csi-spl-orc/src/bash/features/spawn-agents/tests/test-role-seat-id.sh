#!/usr/bin/env bash
# test-role-seat-id.sh — SPL-1685 (owner t1 ee1e58d5): a role seat's id follows
# the vendor that runs it (c-001 run by Grok is g-001). The ONE helper set in
# spool-env.inc.sh: spl_is_role_seat, spl_role_seat_num, spl_role_seat_id,
# spl_role_seat_ids and SPL_ROLE_SEAT_RX, a case per vendor letter, and a
# guard that no caller under csi-spl-orc/src keeps its own copy of the list.
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"

nope() { ! "$@" 2>/dev/null; }

# 1. every vendor letter x every seat number is a role seat, with and without a box
for l in a c g m q; do
  for n in 001 002 003; do
    check "1. role seat: $l-$n" spl_is_role_seat "$l-$n"
    check "1. role seat: $l-$n@box-a" spl_is_role_seat "$l-$n@box-a"
    eq "1. seat number of $l-$n@box-desk" "$n" "$(spl_role_seat_num "$l-$n@box-desk")"
    check "1. spool_spawn_is_seat $l-$n" spool_spawn_is_seat "$l-$n"
  done
done
for id in CLE-001 GRK-002 CLE-003@sat; do
  check "1. legacy role seat: $id" spl_is_role_seat "$id"
done
eq "1. seat number of legacy CLE-002" 002 "$(spl_role_seat_num CLE-002)"
for id in c-000 g-004 a-010 c-1001 x-001 C-001 G-001 HUM-001 CLE-004 CLE-0011 c-001@ c-001@a@b '' c-01; do
  check "1. not a role seat: '$id'" nope spl_is_role_seat "$id"
  check "1. no seat number for '$id'" nope spl_role_seat_num "$id"
done
check "1. CONTROL: a lane is no spawn seat" nope spool_spawn_is_seat c-422

# 2. the seat id a vendor runs a seat as
eq "2. claude 1" c-001 "$(spl_role_seat_id claude 1)"
eq "2. grok 1" g-001 "$(spl_role_seat_id grok 1)"
eq "2. agy 1" a-001 "$(spl_role_seat_id agy 1)"
eq "2. mistral 2" m-002 "$(spl_role_seat_id mistral 2)"
eq "2. qwen 3" q-003 "$(spl_role_seat_id qwen 3)"
eq "2. grok 002 (a seat number as read)" g-002 "$(spl_role_seat_id grok 002)"
for k in claude grok agy mistral qwen; do
  id="$(spl_role_seat_id "$k" 1)"
  eq "2. round trip $k: kind of $id" "$k" "$(spl_kind_of_agent_id "$id")"
done
check "2. no seat 4" nope spl_role_seat_id claude 4
check "2. no seat 0" nope spl_role_seat_id grok 0
check "2. no vendor x" nope spl_role_seat_id x 1

# 3. every id of one seat, one per vendor letter
eq "3. ids of g-002" "a-002 c-002 g-002 m-002 q-002" "$(spl_role_seat_ids g-002 | tr '\n' ' ' | sed 's/ $//')"
check "3. a lane has no seat ids" nope spl_role_seat_ids c-422

# 4. the RX is the same list for awk and jq callers
eq "4. awk takes the RX" "g-001 m-003" "$(printf 'g-001\nc-004\nm-003\nx-001\n' | awk -v s="^${SPL_ROLE_SEAT_RX}$" '$0 ~ s' | tr '\n' ' ' | sed 's/ $//')"
if command -v jq >/dev/null; then
  eq "4. jq takes the RX" '["a-002","q-001"]' "$(jq -c --arg s "^${SPL_ROLE_SEAT_RX}$" '[.[] | select(test($s))]' <<<'["a-002","c-004","q-001"]')"
fi

# 5. one list: no caller keeps its own copy (c-00[1-3], [A-Za-z]+-00[1-3],
# -00[1-3]$); legacy-only readers (uppercase CLE-) and tests are exempt
src="$(cd "$T_FEAT/../.." && pwd)"
copies="$(grep -rnE 'c-00\[[0-9-]+\]|\[A-Za-z\]\+-00\[|[^A-Z]-00\[1-3\]\$' "$src" --include='*.sh' 2>/dev/null |
  grep -vE '/tests?/|\.tst\.sh:|spool-env\.inc\.sh:|\[A-Z\]\+-00\[1-3\]|CLE-00\[1-3\]' || true)"
eq "5. no copy of the role seat list outside spool-env.inc.sh" "" "$copies"
t_done
