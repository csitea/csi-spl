#!/usr/bin/env bash
# rotate-ack-seen.tst.sh - spl_rotate_ack_seen finds an ack of a role seat
# that keeps no letter link (SPL-4507)
#
# Since SPL-4031 a role seat switch leaves ONE real spool dir and no
# a-/c-/g-/m-/q-00N links. spl_rotate_ack_seen read all five outboxes in one
# find; the missing ones made find exit 1, and under pipefail (./run sets it)
# the pipeline failed though grep matched. Box 1 2026-10-31: the master
# rotation 20261031T1115Z-master saw no ack for 600 s while c-002's ack had
# been in its outbox since 11:16:07Z. Cases, under set -o pipefail:
#   (a) seat 002 with only c-002/ (no letter link): the ack is seen
#   (b) the same with the letter links of the old layout: seen
#   (c) a plain lane id: seen; no ack at all: not seen
#   (d) an ack on another task or from another seat: not seen
#   (e) no outbox at all: not seen, rc 1
#
# Run: bash csi-spl-orc/src/bash/tests/rotate-ack-seen.tst.sh </dev/null
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export SPOOL_ROOT="$T/spool"
# shellcheck source=/dev/null
source "$HERE/../run/spl-rotate-lib.func.sh"
set -o pipefail

TASK=dispatch-rotate-20261031T1115Z-master
n=0
# ack DIR FROM TASK: one result message in <spool>/DIR/outbox
ack() {
  n=$((n + 1))
  mkdir -p "$SPOOL_ROOT/$1/outbox"
  printf '{"body":"ACK","files":[],"from":"%s","kind":"result","msg_id":"m-%s","task_id":"%s","to":"%s","ts":"2026-10-31T11:16:07Z","v":1}\n' \
    "$2" "$n" "$3" "$2" > "$SPOOL_ROOT/$1/outbox/20261031T111607Z--$2--ack-$n.json"
}
# expect NAME WANT ID TASK: spl_rotate_ack_seen ID TASK returns WANT (0 seen, 1 not)
expect() {
  local rc=0
  spl_rotate_ack_seen "$3" "$4" || rc=$?
  [[ "$rc" == "$2" ]] && pass "$1 (rc $rc)" || fail "$1: want rc $2, got $rc"
}

# (a) box 1's layout of 2026-10-31: c-002 real, no a-/g-/m-/q-002 entry
ack c-002 c-002 "$TASK"
expect "(a) seat 002, one real dir and no letter link: the ack is seen" 0 c-002 "$TASK"
expect "(a) asked as the seat's other letter (g-002): seen" 0 g-002 "$TASK"
for i in 1 2 3; do echo '{"kind":"note","task_id":"x","from":"c-002","msg_id":"n'"$i"'"}' > "$SPOOL_ROOT/c-002/outbox/n$i.json"; done
expect "(a) among other outbox files: seen" 0 c-002 "$TASK"

# (b) the old layout: every letter a link to the real dir
for l in a g m q; do ln -s c-002 "$SPOOL_ROOT/$l-002"; done
expect "(b) the letter links of the old layout: seen" 0 c-002 "$TASK"

# (c) a lane id is its own dir
ack c-710 c-710 lane-rotate-20261031T1116Z-lane-c-710
expect "(c) a lane id: seen" 0 c-710 lane-rotate-20261031T1116Z-lane-c-710
expect "(c) a lane id with no ack on that task: not seen" 1 c-710 "$TASK"

# (d) the wrong task or the wrong seat
ack c-003 c-003 orch-rotate-20261031T1205Z-orch
expect "(d) an ack on another task: not seen" 1 c-003 "$TASK"
ack c-001 c-005 dispatch-rotate-20261031T1215Z-master
expect "(d) a result on the task from a non-seat id: not seen" 1 c-001 dispatch-rotate-20261031T1215Z-master

# (e) no outbox of the seat exists
expect "(e) no outbox at all: not seen" 1 c-004 "$TASK"

echo
(( fails == 0 )) && { echo "rotate-ack-seen: all passed"; exit 0; }
echo "rotate-ack-seen: $fails failed"; exit 1
