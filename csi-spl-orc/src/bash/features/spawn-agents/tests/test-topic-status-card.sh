#!/usr/bin/env bash
# test-topic-status-card.sh — the live topic status card (SDLC round 1 row 07,
#   SPL-2089): one card per owner issue topic, posted once and then EDITED in
#   place. A state change edits the existing message and creates no new one;
#   an unchanged card calls the hub not at all; the default discussion and a
#   topic with no recent move get no card; a box that does not hold the
#   dispatch lease touches nothing; a source that cannot be read touches no
#   card; a failed edit is retried, never re-posted; a card whose author
#   left after the lease moved is re-posted ONCE by the new holder; a topic
#   where only a spawn ask moved gets its card too, edited as the ask lands
#   (SPL-5542).
# The hub is a stub: hub.tsv holds one row per message (msg id, topic, body
# sha); post appends a row, edit rewrites the row of its id.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
R="$T_SCRIPTS/topic-status-card.sh"
B="$T_TMP/bin"; H="$T_TMP/hub.tsv"; L="$T_TMP/calls.log"; G="$T_TMP/repo"
mkdir -p "$B" "$T_TMP/src"; : >"$H"; : >"$L"; : >"$T_TMP/results.tsv"
T1=11111111-1111-4111-8111-111111111111
T2=22222222-2222-4222-8222-222222222222
DEF=fcf09921-8f21-4518-a117-f8ddb41bfff5
TOLD=33333333-3333-4333-8333-333333333333

# shellcheck disable=SC2016 # the stubs expand at their own run time
cat >"$B/post" <<'EOF'
#!/usr/bin/env bash
[ -e "$CARD_T_DIR/post.fail" ] && exit 1
# a DM topic: the desk reply's exit 6 (the hub's dm_not_blocker, SPL-2584)
grep -qxs "$1" "$CARD_T_DIR/post.dm" && { echo "dm-refused $1" >>"$CARD_T_DIR/calls.log"; exit 6; }
# a result post (SPL-6433) is kept apart from the cards: results.tsv, ids 9...
if ! grep -q '^\*\*Status card\*\*' "$2"; then
  [ -e "$CARD_T_DIR/result.fail" ] && { echo "FATAL planted refusal" >&2; exit 1; }
  id="$(printf '9%07d-0000-4000-8000-%012d' "$(( $(wc -l <"$CARD_T_DIR/results.tsv") + 1 ))" 0)"
  printf '%s\t%s\n' "$id" "$1" >>"$CARD_T_DIR/results.tsv"; cp "$2" "$CARD_T_DIR/last-result.md"
  printf '{"msg_id":"%s","task_id":"%s"}\n' "$id" "$1"; exit 0
fi
id="$(printf '%08d-0000-4000-8000-%012d' "$(( $(wc -l <"$CARD_T_DIR/hub.tsv") + 1 ))" 0)"
printf '%s\t%s\t%s\n' "$id" "$1" "$(sha256sum <"$2" | cut -c1-16)" >>"$CARD_T_DIR/hub.tsv"
echo "post $1 by $DESK_AGENT" >>"$CARD_T_DIR/calls.log"
printf '{"msg_id":"%s","task_id":"%s"}\n' "$id" "$1"
EOF
cat >"$B/edit" <<'EOF'
#!/usr/bin/env bash
[ -e "$CARD_T_DIR/edit.fail" ] && exit 1
[ -e "$CARD_T_DIR/gone.$DESK_AGENT" ] && exit 1
grep -q "^$1	" "$CARD_T_DIR/hub.tsv" || exit 1
awk -F'\t' -v OFS='\t' -v id="$1" -v h="$(sha256sum <"$2" | cut -c1-16)" '$1 == id { $3 = h } { print }' \
  "$CARD_T_DIR/hub.tsv" >"$CARD_T_DIR/hub.tmp" && mv "$CARD_T_DIR/hub.tmp" "$CARD_T_DIR/hub.tsv"
cp "$2" "$CARD_T_DIR/last-edit.md"
echo "edit $1 by $DESK_AGENT" >>"$CARD_T_DIR/calls.log"
EOF
# shellcheck disable=SC2016 # the stubs expand at their own run time
{
printf '#!/usr/bin/env bash\ncat "$CARD_T_DIR/src/issues.json"\n' >"$B/issues"
printf '#!/usr/bin/env bash\ncat "$CARD_T_DIR/src/lanes.json"\n' >"$B/lanes"
printf '#!/usr/bin/env bash\ncat "$CARD_T_DIR/src/queue.json"\n' >"$B/queue"
printf '#!/usr/bin/env bash\ncat "$CARD_T_DIR/src/asks.json"\n' >"$B/asks"
printf '#!/usr/bin/env bash\necho "$CARD_T_LEASE 6"\n' >"$B/lease"
printf '#!/usr/bin/env bash\necho "$1 $2" >>"$CARD_T_DIR/lag.log"; echo "$1 hub current served=x"; echo "$1 wui current served=x"\n' >"$B/lag"
}
chmod +x "$B"/*

# The fixture trunk: SPL-11 landed by a refactor, SPL-12 only by a test commit.
git init -q "$G"
gc() { git -C "$G" -c user.name='FirstName LastName' -c user.email=dev@example.com commit -q --allow-empty -m "$1"
  git -C "$G" update-ref refs/remotes/origin/master HEAD; }
gc "chore: root"; gc "test(orc, SPL-12): a test only"
issue() {  # KEY STATUS TOPIC UPDATED TITLE
  printf '{"key":"%s","kind":"issue","status":"%s","title":"%s","updated_at":"%s","discussions":[{"task_id":"%s"}]}' "$1" "$2" "$5" "$4" "$3"
}
put_issues() {  # STATUS_OF_SPL-11
  printf '{"result":{"default_discussion":"%s","issues":[%s,%s,%s,%s]}}\n' "$DEF" \
    "$(issue SPL-11 "$1" "$T1" 2026-10-16T03:00:00.123Z 'Lane brief: row 07')" \
    "$(issue SPL-12 wip "$T2" 2026-10-16T02:00:00Z 'Lane brief: row 09')" \
    "$(issue SPL-13 wip "$DEF" 2026-10-16T03:00:00Z 'an unlinked issue')" \
    "$(issue SPL-14 'done' "$TOLD" 2026-10-10T03:00:00Z 'an old topic')" >"$T_TMP/src/issues.json"
}
put_issues wip
printf '{"lanes":[{"agent_id":"c-601","agent_box":"pc","scope":"Lane brief: row 07","state":"live","updated_at":"2026-10-16T03:00:00Z"}]}\n' >"$T_TMP/src/lanes.json"
printf '{"asks":[]}\n' >"$T_TMP/src/asks.json"
printf '{"queue":[{"position":2,"queue_len":3,"state":"queued","topic":"22222222","summary":"Lane brief: row 10"}]}\n' >"$T_TMP/src/queue.json"
mkdir -p "$SPOOL_ROOT/c-777/lifetime" && echo SPL-12 >"$SPOOL_ROOT/c-777/lifetime/issue"

export CARD_T_DIR="$T_TMP" CARD_T_LEASE="c-002@pc" SPOOL_DESK_BOX=pc
export CARD_STATE_DIR="$T_TMP/state" CARD_GIT_DIR="$G" CARD_FETCH=0
CARD_NOW="$(date -u -d 2026-10-16T04:00:00Z +%s)"; export CARD_NOW
export CARD_POST_CMD="$B/post" CARD_EDIT_CMD="$B/edit" CARD_ISSUES_CMD="$B/issues"
export CARD_LANES_CMD="$B/lanes" CARD_QUEUE_CMD="$B/queue" CARD_LEASE_CMD="$B/lease" CARD_LAG_CMD="$B/lag"
export CARD_ASKS_CMD="$B/asks"
tick() { bash "$R" "$@" 2>&1; }
rows() { wc -l <"$H" | tr -d ' '; }
calls() { wc -l <"$L" | tr -d ' '; }

# 1. A box that does not hold the dispatch lease touches nothing.
out="$(CARD_T_LEASE="c-002@sat" tick)"; rc=$?
eq "not the lease box: exits 0" 0 "$rc"
has "not the lease box: says where the cards are kept" "held on sat" "$out"
eq "not the lease box: no hub call" 0 "$(calls)"

# 2. The first tick posts one card per moved topic, as the lease holder.
out="$(tick)"; rc=$?
eq "first tick exits 0" 0 "$rc"
eq "two cards posted (two moved topics)" 2 "$(rows)"
eq "posted by the lease holder" "post $T1 by c-002
post $T2 by c-002" "$(sort "$L")"
hasnt "the default discussion gets no card" "$DEF" "$(cat "$H")"
hasnt "a topic with no move in the window gets no card" "$TOLD" "$(cat "$H")"

# 3. The card shows the state, lane@box, queue place, landed sha and served.
card="$(tick --print)"
has "card: the issue and its state" "| SPL-11 | Lane brief: row 07 | wip | c-601@pc (live) |" "$card"
has "card: a lane from this box's lifetime/issue" "| SPL-12 | Lane brief: row 09 | wip | c-777@pc |" "$card"
has "card: a test-only commit lands nothing" "| c-777@pc | - | - | - | - |" "$card"
has "card: the queued ask of the topic, its place in line" "| - | Lane brief: row 10 | queued | - | 2/3 |" "$card"

# 4. A tick with nothing changed calls the hub not at all.
: >"$L"
tick >/dev/null
eq "unchanged: no post, no edit" 0 "$(calls)"
eq "unchanged: still two messages" 2 "$(rows)"

# 5. A state change EDITS the existing row; no new message is created.
gc "refactor(orc, SPL-11): the card"; sha="$(git -C "$G" rev-parse HEAD)"
put_issues 'done'
before="$(cat "$H")"
out="$(tick)"; rc=$?
eq "state change: exits 0" 0 "$rc"
eq "state change: still two messages (no new row)" 2 "$(rows)"
eq "state change: exactly one call, an edit by the author" "edit 00000001-0000-4000-8000-000000000000 by c-002" "$(cat "$L")"
has "state change: says edited in place" "edited in place" "$out"
eq "state change: the same message id, its body changed" "$(cut -f1,2 <<<"$before")" "$(cut -f1,2 "$H")"
check "state change: the T1 row's body sha moved" test "$(head -1 <<<"$before" | cut -f3)" != "$(head -1 "$H" | cut -f3)"
has "edited card: the landed sha, served dev and prd" "| \`${sha:0:12}\` | yes | yes |" "$(cat "$T_TMP/last-edit.md")"
has "edited card: the new state" "| SPL-11 | Lane brief: row 07 | done |" "$(cat "$T_TMP/last-edit.md")"
has "edited card: an as-of line" "_as of " "$(cat "$T_TMP/last-edit.md")"

# 6. A served env is cached: no second deploy probe for that sha.
: >"$T_TMP/lag.log"; : >"$L"
tick >/dev/null
eq "served cached: no deploy probe again" 0 "$(wc -l <"$T_TMP/lag.log" | tr -d ' ')"
eq "served cached: no hub call" 0 "$(calls)"
git -C "$G" update-ref refs/remotes/origin/master HEAD~1
has "landed cached: no history walk once landed" "| \`${sha:0:12}\` | yes | yes |" "$(tick --print)"
git -C "$G" update-ref refs/remotes/origin/master HEAD

# 7. A source that cannot be read touches no card.
put_issues blocked
out="$(CARD_ISSUES_CMD=false tick)"; rc=$?
eq "issues unreadable: exits 1" 1 "$rc"
has "issues unreadable: one WARN line" "WARN the issue list could not be read" "$out"
out="$(CARD_LANES_CMD=false tick)"; rc=$?
eq "lane map unreadable: exits 1" 1 "$rc"
eq "unreadable sources: no hub call" 0 "$(calls)"

# 8. A failed edit is retried next tick, never re-posted.
touch "$T_TMP/edit.fail"
out="$(tick)"; rc=$?
eq "edit fails: exits 1" 1 "$rc"
has "edit fails: WARN, never re-posted" "never re-posted" "$out"
eq "edit fails: no new message" 2 "$(rows)"
rm -f "$T_TMP/edit.fail"
tick >/dev/null
eq "edit retried next tick: one edit, no post" "edit 00000001-0000-4000-8000-000000000000 by c-002" "$(cat "$L")"
eq "edit retried: still two messages" 2 "$(rows)"

# 9. A card shows the newest CARD_CLOSED_MAX closed issues and counts the rest.
has "closed rows capped: an open issue always shown" "| SPL-11 | Lane brief: row 07 | blocked |" "$(CARD_CLOSED_MAX=0 tick --print)"
put_issues 'done'
card="$(CARD_CLOSED_MAX=0 tick --print)"
hasnt "closed rows capped: an older done row hidden" "| SPL-11 |" "$card"
has "closed rows capped: the hidden ones counted" "| +1 | older done/diss issues not shown |" "$card"

# 10. The lease moves on this box (SPL-2528): the old author still edits its
#   card while its desk is up; once it is gone the new holder posts ONE new
#   card, records itself as the author and edits that one from then on.
export CARD_T_LEASE="c-003@pc"
put_issues wip; : >"$L"
tick >/dev/null
eq "lease moved, old author up: it edits its own card" "edit 00000001-0000-4000-8000-000000000000 by c-002" "$(cat "$L")"
touch "$T_TMP/gone.c-002"; put_issues blocked; : >"$L"
out="$(tick)"; rc=$?
eq "old author gone: exits 0" 0 "$rc"
eq "old author gone: a failed edit, then one post by the holder" "post $T1 by c-003" "$(cat "$L")"
has "old author gone: says re-posted" "re-posted by c-003 as" "$out"
hasnt "old author gone: no WARN" "could not be edited" "$out"
eq "old author gone: one new message" 3 "$(rows)"
eq "old author gone: the card file names the holder" "c-003" "$(sed -n 2p "$CARD_STATE_DIR/$T1.card")"
: >"$L"; tick >/dev/null
eq "re-posted card unchanged: no hub call" 0 "$(calls)"
put_issues wip; : >"$L"; tick >/dev/null
eq "re-posted card: edited in place by the holder, no post" "edit 00000003-0000-4000-8000-000000000000 by c-003" "$(cat "$L")"
eq "re-posted card: still three messages" 3 "$(rows)"
touch "$T_TMP/edit.fail"; put_issues blocked; : >"$L"
out="$(tick)"
has "holder's own edit fails: WARN, never re-posted" "never re-posted" "$out"
eq "holder's own edit fails: no new message" 3 "$(rows)"
rm -f "$T_TMP/edit.fail" "$T_TMP/gone.c-002"

# 11. SPL-2584: a DM topic gets no status card. The hub refuses the post
#   (exit 6); the topic is marked and never tried again (red on the old code,
#   which retried the post every tick).
export CARD_STATE_DIR="$T_TMP/state11" CARD_T_LEASE="c-002@pc"
echo "$T2" >"$T_TMP/post.dm"; put_issues wip; : >"$L"
out="$(tick)"; rc=$?
eq "DM topic: the tick exits 0" 0 "$rc"
has "DM topic: says it gets no card" "is a DM topic: no status card there" "$out"
eq "DM topic: one refused try, the channel topic posted" "dm-refused $T2
post $T1 by c-002" "$(sort "$L")"
put_issues blocked; : >"$L"; tick >/dev/null
hasnt "DM topic: never tried again" "$T2" "$(cat "$L")"
rm -f "$T_TMP/post.dm"

# 12. SPL-5542: a topic carried over with a spawn ask and no issue gets ONE
#   card (red on the old code: only a moved issue kept a topic), and that card
#   is edited in place as the ask is placed and its lane's issue lands. An ask
#   with no move in the window, or of the default discussion, adds no card.
export CARD_STATE_DIR="$T_TMP/state12"; : >"$L"
T3=44444444-4444-4444-8444-444444444444
ask() {  # ID TOPIC STATE UPDATED REASON [POSITION]
  printf '{"ask_id":"%s","kind":"task","topic":"dispatch-x","discussion":"%s","state":"%s","summary":"carry over: row 11","reason":"%s","position":%s,"queue_len":2,"created_at":"%s","updated_at":"%s"}' \
    "$1" "$2" "$3" "$5" "${6:-0}" "$4" "$4"
}
put_asks() {  # STATE REASON [POSITION]
  printf '{"asks":[%s,%s,%s,%s]}\n' \
    "$(ask 55555555-5555-4555-8555-555555555555 "$T3" "$1" 2026-10-16T03:30:00Z "$2" "${3:-0}")" \
    "$(ask 66666666-6666-4666-8666-666666666666 "$TOLD" queued 2026-10-10T03:00:00Z '' 2)" \
    "$(ask 77777777-7777-4777-8777-777777777777 "$DEF" queued 2026-10-16T03:30:00Z '' 2)" \
    '{"ask_id":"88888888-8888-4888-8888-888888888888","kind":"blocker","discussion":"99999999-9999-4999-8999-999999999999","state":"open","updated_at":"2026-10-16T03:30:00Z"}' \
    >"$T_TMP/src/asks.json"
}
put_issues wip; put_asks queued '' 1
out="$(tick)"; rc=$?
eq "ask-only topic: the tick exits 0" 0 "$rc"
eq "ask-only topic: one card posted there" 1 "$(grep -c "$T3" "$L")"
hasnt "ask-only: an ask with no move in the window adds no card" "$TOLD" "$(cat "$L")"
hasnt "ask-only: an ask of the default discussion adds no card" "$DEF" "$(cat "$L")"
hasnt "ask-only: a blocker ask adds no card" "99999999" "$(cat "$L")"
has "ask-only card: the queued ask, its place in line" "| - | carry over: row 11 | queued | - | 1/2 | - | - | - |" "$(tick --print)"
id3="$(sed -n 1p "$CARD_STATE_DIR/$T3.card")"
printf '{"lanes":[{"agent_id":"c-888","agent_box":"pc","scope":"x","issue_key":"SPL-15","state":"live","updated_at":"2026-10-16T03:40:00Z"}]}\n' >"$T_TMP/src/lanes.json"
put_asks 'done' 'placed: c-888@pc'; : >"$L"
out="$(tick)"
eq "ask placed: one edit of the same card, no post" "edit $id3 by c-002" "$(grep "$T3\|$id3" "$L")"
has "ask placed: the lane and its issue" "| SPL-15 | carry over: row 11 | placed | c-888@pc (live) | - | - | - | - |" "$(cat "$T_TMP/last-edit.md")"
gc "fix(orc, SPL-15): the carried-over work"; sha15="$(git -C "$G" rev-parse HEAD)"; : >"$L"
tick >/dev/null
eq "ask landed: one edit of the same card, no post" "edit $id3 by c-002" "$(grep "$T3\|$id3" "$L")"
has "ask landed: the landed sha, served dev and prd" "| c-888@pc (live) | - | \`${sha15:0:12}\` | yes | yes |" "$(cat "$T_TMP/last-edit.md")"
: >"$L"; tick >/dev/null
eq "ask landed, unchanged: no hub call" 0 "$(calls)"
out="$(CARD_ASKS_CMD=false tick)"; rc=$?
eq "asks book unreadable: exits 1" 1 "$rc"
has "asks book unreadable: one WARN line" "WARN the asks book could not be read" "$out"

# 13. SPL-6433, the replay of topics 80e54ed8 and 035cb09e (prd t1, 11-18 and
#   11-23): an agent posted "Planned, not built yet. Tracked as SPL-21", the
#   issue turned done once its fix landed, and nothing else was posted. The
#   topic gets ONE result line (key, landed sha, live on dev / prd), never a
#   second; a card whose spawn ask placed a lane that has ended says
#   "lane done", never "placed" (the desk reply refuses that post, rule 19:
#   80e54ed8's card was refused every tick from 11-17); a refused post names
#   the refusal in its WARN.
export CARD_STATE_DIR="$T_TMP/state13"; : >"$L"; : >"$T_TMP/results.tsv"
T5=55555555-0000-4000-8000-555555555555
put13() {  # STATUS UPDATED
  printf '{"result":{"default_discussion":"%s","issues":[%s,%s]}}\n' "$DEF" \
    "$(issue SPL-21 "$1" "$T5" "$2" 'Lane brief: bug - planned work')" \
    "$(issue SPL-22 'done' "$T5" 2026-10-14T03:00:00Z 'done before the window')" >"$T_TMP/src/issues.json"
}
printf '{"lanes":[{"agent_id":"c-889","agent_box":"pc","scope":"x","issue_key":"SPL-21","state":"done","updated_at":"2026-10-16T03:40:00Z"}]}\n' >"$T_TMP/src/lanes.json"
printf '{"asks":[%s]}\n' "$(ask aaaaaaaa-5555-4555-8555-555555555555 "$T5" 'done' 2026-10-16T03:30:00Z 'placed: c-889@pc')" >"$T_TMP/src/asks.json"
printf '{"queue":[]}\n' >"$T_TMP/src/queue.json"
put13 wip 2026-10-16T03:00:00Z
tick >/dev/null
eq "replay, still wip: no result post" 0 "$(wc -l <"$T_TMP/results.tsv" | tr -d ' ')"
card="$(cat "$T_TMP/last-edit.md" 2>/dev/null; tick --print)"
has "replay card: an ask whose lane ended says lane done" "| SPL-21 | carry over: row 11 | lane done | c-889@pc (done) |" "$card"
hasnt "replay card: no row says placed for an ended lane" "| placed |" "$(tick --print)"
gc "fix(orc, SPL-21): the planned work"; sha21="$(git -C "$G" rev-parse HEAD)"
put13 'done' 2026-10-16T03:50:00Z
out="$(tick)"; rc=$?
eq "replay, done + landed: the tick exits 0" 0 "$rc"
eq "replay: one result post, in the topic" "$T5" "$(cut -f2 "$T_TMP/results.tsv")"
has "replay: says it posted the result" "OK result ${T5:0:8} posted as" "$out"
res="$(cat "$T_TMP/last-result.md")"
has "result: key, landed sha, live on dev and prd" "**SPL-21 done**: landed \`${sha21:0:12}\` on master; live on dev: yes, prd: yes." "$res"
has "result: how it was checked (rule 22)" "checked: the issue is done in the hub" "$res"
hasnt "result: a done issue outside the window is not announced" "SPL-22" "$res"
tick >/dev/null; tick >/dev/null
eq "replay: never a second result post" 1 "$(wc -l <"$T_TMP/results.tsv" | tr -d ' ')"

# 13b. Not served yet: the line says so; a refused post names the refusal,
#   is retried next tick and lands once.
export CARD_STATE_DIR="$T_TMP/state13b"; : >"$T_TMP/results.tsv"
printf '#!/usr/bin/env bash\necho "$1 hub pending served=x"\n' >"$B/lagp"; chmod +x "$B/lagp"
touch "$T_TMP/result.fail"
out="$(CARD_LAG_CMD="$B/lagp" tick)"; rc=$?
eq "refused result: the tick exits 1" 1 "$rc"
has "refused result: the WARN names the refusal" "WARN result ${T5:0:8} did not post (rc 1: FATAL planted refusal" "$out"
rm -f "$T_TMP/result.fail"
CARD_LAG_CMD="$B/lagp" tick >/dev/null
eq "refused result: posted once on the retry" 1 "$(wc -l <"$T_TMP/results.tsv" | tr -d ' ')"
has "not served yet: the line says not yet" "live on dev: not yet (pending), prd: not yet (pending)." "$(cat "$T_TMP/last-result.md")"

eq "usage is refused" 64 "$(bash "$R" --bogus >/dev/null 2>&1; echo $?)"
t_done
