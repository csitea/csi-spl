#!/usr/bin/env bash
# A review-only lane gets its lane-map row (SPL-5353). Its brief's `Topic:` is
# the report task's relay hash (c-845, R7 of SPL-5273: uuid5 of
# "spool-task:archived-seats-free"), which names no discussion, so the hub
# refused the put (bad_frame, rdb 0264) and only the background lane.log knew.
# Now a refused put retries with the discussion of the issue's other lane (the
# Author: lane first), and a row still not written says so in ONE WARN line in
# <ID>/lane-unlinked.log. The hub is a stub lane-map.sh: a put lands only for a
# topic in $FAKE_GOOD, `list` prints $FAKE_LIST.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
H=8a8983d1-eb0b-5577-ad9a-f04b4563feb9
D=b4b264a7-95e9-40aa-a863-529c8637c181
E=0c2d08a2-b1c1-4bb7-983d-3237203a77ec
FAKE="$T_TMP/fake"; mkdir -p "$FAKE/scripts"; ln -s "$T_FEAT/lib" "$FAKE/lib"
cat >"$FAKE/scripts/lane-map.sh" <<'EOF'
#!/usr/bin/env bash
verb="$1"; shift
if [ "$verb" = list ]; then echo list >>"$FAKE_CALLS"; cat "$FAKE_LIST"; exit 0; fi
while [ $# -gt 0 ]; do [ "$1" = --topic ] && t="$2"; shift; done
echo "put ${t:-}" >>"$FAKE_CALLS"
case " ${FAKE_DOWN:-} " in *" ${t:-none} "*) echo "[WARN] lane not written (live): hub did not answer"; exit 2 ;; esac
case " ${FAKE_SLOW:-} " in *" ${t:-none} "*) exit 124 ;; esac
case " $FAKE_GOOD " in *" ${t:-none} "*) echo "[OK] lane put"; exit 0 ;; esac
echo "[WARN] lane not written (live): bad_frame: topic ${t:-} names no single discussion (rdb 0264: a lane needs one)"
exit 2
EOF
export FAKE_CALLS FAKE_LIST="$T_TMP/list.json" FAKE_GOOD FAKE_DOWN="" FAKE_SLOW=""
# shellcheck source=../scripts/spawn-core.inc.sh
. "$T_SCRIPTS/spawn-core.inc.sh"
row() { printf '{"agent_id":"%s","agent_box":"%s","topic":"%s","issue_key":"%s","state":"%s"}' "$1" "${5:-box-a}" "$2" "$3" "$4"; }
lanes() { local IFS=,; printf '{"fleet":"main","hub":"ok","lanes":[%s]}\n' "$*" >"$FAKE_LIST"; }

# put ID BRIEF_BODY [ASK_TOPIC]: one live spawn step; waits (at most 5 s) for
# its background put to end: an [OK] in lane.log or a WARN line; prints the calls
put() {
  local id="$1" _i
  FAKE_CALLS="$T_TMP/calls-$id"; : >"$FAKE_CALLS"
  mkdir -p "$SPOOL_ROOT/$id/lifetime"; printf '%s\n' "$2" >"$T_TMP/brief-$id.md"
  TITLE="$id" BRIEF="$T_TMP/brief-$id.md" BRANCH="$id-x" REPO=/x/csi-spl SLUG=x SPAWN_DRY_RUN=0 _SP_DIR="$FAKE/scripts" \
    SPAWN_LANE_TOPIC="${3:-}" _spawn_lane_put 2>"$T_TMP/err-$id"
  for _i in $(seq 50); do
    grep -q '\[OK\]' "$SPOOL_ROOT/$id/lane.log" 2>/dev/null && break
    [ -s "$SPOOL_ROOT/$id/lane-unlinked.log" ] && break
    sleep 0.1
  done
  paste -sd' ' "$FAKE_CALLS"
}
warn() { cat "$SPOOL_ROOT/$1/lane-unlinked.log" 2>/dev/null; }
REVIEW="# Lane brief: SPL-5273 R7 code review of 7241abd0f, review only

Issue: SPL-5273
Topic: $H (the archived-seats-free topic)
Author: c-815@box-a

Report on task \`archived-seats-free\`."

# 1. c-845's case: the hash is refused, the reviewed lane's discussion lands.
FAKE_GOOD="$D $E"; lanes "$(row c-815 "$D" SPL-5273 "done")" "$(row c-900 "$E" SPL-9 live)"
eq "a review lane's refused hash retries with the reviewed lane's discussion" "put $H list put $D" "$(put c-845 "$REVIEW" "$H")"
eq "...and that row needs no WARN" "" "$(warn c-845)"
has "...lane.log says why the topic changed" "topic $H refused" "$(cat "$SPOOL_ROOT/c-845/lane.log" 2>/dev/null)"

# 2. No other lane of the issue: nothing to retry with -> one WARN line.
lanes "$(row c-900 "$E" SPL-9 live)"
eq "no other lane of the issue -> no second put" "put $H list" "$(put c-846 "$REVIEW" "$H")"
has "...the refusal is one WARN line in lane-unlinked.log" "WARN: LANE ROW REFUSED: c-846" "$(warn c-846)"
eq "...exactly one line" 1 "$(warn c-846 | wc -l)"
has "...naming the refused topic" "$H" "$(warn c-846)"

# 3. Two other lanes of the issue on different discussions and no Author: no guess.
lanes "$(row c-901 "$D" SPL-5273 "done")" "$(row c-902 "$E" SPL-5273 live)"
eq "two discussions, no Author: no guess" "put $H list" "$(put c-847 "${REVIEW/Author: c-815@box-a/}" "$H")"
has "...WARN" "WARN: LANE ROW REFUSED: c-847" "$(warn c-847)"
# ...but the Author's lane decides between them
lanes "$(row c-902 "$E" SPL-5273 live)" "$(row c-815 "$D" SPL-5273 "done")"
eq "two discussions, the Author's wins" "put $H list put $D" "$(put c-848 "$REVIEW" "$H")"
# ...on the Author's box: the same id with a row on another box is not it (R7 c-053 N2)
lanes "$(row c-815 "$E" SPL-5273 live box-b)" "$(row c-815 "$D" SPL-5273 "done" box-a)"
eq "Author c-815@box-a: its box-a row, not the box-b one listed first" "put $H list put $D" "$(put c-852 "$REVIEW" "$H")"
eq "...a bare Author c-815 takes the first of its rows" "put $H list put $E" "$(put c-853 "${REVIEW/c-815@box-a/c-815}" "$H")"
# ...and the lane's own old row (a restart) is no other lane
lanes "$(row c-851 "$E" SPL-5273 live)"
eq "its own row is not the reviewed lane" "put $H list" "$(put c-851 "${REVIEW/Author: c-815@box-a/}" "$H")"

# 4. Control: a lane with a discussion the hub takes: one put, no list, no WARN
#    (rdb 0264 holds for it: nothing replaces its own discussion).
eq "control: a lane with its own discussion puts once" "put $E" "$(put c-849 "${REVIEW/$H/$E}" "$E")"
eq "...no WARN" "" "$(warn c-849)"

# 5. The retry is refused too (outage, a gone topic): WARN names both.
FAKE_GOOD=""; lanes "$(row c-815 "$D" SPL-5273 "done")"
eq "a refused retry stops there" "put $H list put $D" "$(put c-850 "$REVIEW" "$H")"
has "...WARN names the retried discussion" "$D" "$(warn c-850)"
eq "...in one line" 1 "$(warn c-850 | wc -l)"

# 6. A hub that did not answer refused nothing (R7 c-053 B1): a lane whose
#    discussion the hub takes keeps it: one put, no list, one WARN line.
FAKE_GOOD="$D $E"; FAKE_DOWN="$E"; lanes "$(row c-815 "$D" SPL-5273 "done")"
eq "outage on a good topic: one put, no list, no other discussion" "put $E" "$(put c-860 "${REVIEW/$H/$E}" "$E")"
has "...the row not written is one WARN line" "WARN: LANE ROW REFUSED: c-860" "$(warn c-860)"
hasnt "...lane.log claims no refusal" "refused; again" "$(cat "$SPOOL_ROOT/c-860/lane.log" 2>/dev/null)"
# ...nor a put the timeout cut (the hub may have written it)
FAKE_DOWN=""; FAKE_SLOW="$E"
eq "timeout on a good topic: one put, no list" "put $E" "$(put c-861 "${REVIEW/$H/$E}" "$E")"
has "...WARN" "WARN: LANE ROW REFUSED: c-861" "$(warn c-861)"
FAKE_SLOW=""
t_done
