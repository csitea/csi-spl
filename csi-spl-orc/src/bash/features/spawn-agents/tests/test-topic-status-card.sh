#!/usr/bin/env bash
# test-topic-status-card.sh — the live topic status card (SDLC round 1 row 07,
#   SPL-2089): one card per owner issue topic, posted once and then EDITED in
#   place. A state change edits the existing message and creates no new one;
#   an unchanged card calls the hub not at all; the default discussion and a
#   topic with no recent move get no card; a box that does not hold the
#   dispatch lease touches nothing; a source that cannot be read touches no
#   card; a failed edit is retried, never re-posted.
# The hub is a stub: hub.tsv holds one row per message (msg id, topic, body
# sha); post appends a row, edit rewrites the row of its id.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
R="$T_SCRIPTS/topic-status-card.sh"
B="$T_TMP/bin"; H="$T_TMP/hub.tsv"; L="$T_TMP/calls.log"; G="$T_TMP/repo"
mkdir -p "$B" "$T_TMP/src"; : >"$H"; : >"$L"
T1=11111111-1111-4111-8111-111111111111
T2=22222222-2222-4222-8222-222222222222
DEF=fcf09921-8f21-4518-a117-f8ddb41bfff5
TOLD=33333333-3333-4333-8333-333333333333

# shellcheck disable=SC2016 # the stubs expand at their own run time
cat >"$B/post" <<'EOF'
#!/usr/bin/env bash
[ -e "$CARD_T_DIR/post.fail" ] && exit 1
id="$(printf '%08d-0000-4000-8000-%012d' "$(( $(wc -l <"$CARD_T_DIR/hub.tsv") + 1 ))" 0)"
printf '%s\t%s\t%s\n' "$id" "$1" "$(sha256sum <"$2" | cut -c1-16)" >>"$CARD_T_DIR/hub.tsv"
echo "post $1 by $DESK_AGENT" >>"$CARD_T_DIR/calls.log"
printf '{"msg_id":"%s","task_id":"%s"}\n' "$id" "$1"
EOF
cat >"$B/edit" <<'EOF'
#!/usr/bin/env bash
[ -e "$CARD_T_DIR/edit.fail" ] && exit 1
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
printf '{"queue":[{"position":2,"queue_len":3,"state":"queued","topic":"22222222","summary":"Lane brief: row 10"}]}\n' >"$T_TMP/src/queue.json"
mkdir -p "$SPOOL_ROOT/c-777/lifetime" && echo SPL-12 >"$SPOOL_ROOT/c-777/lifetime/issue"

export CARD_T_DIR="$T_TMP" CARD_T_LEASE="c-002@pc" SPOOL_DESK_BOX=pc
export CARD_STATE_DIR="$T_TMP/state" CARD_GIT_DIR="$G" CARD_FETCH=0
CARD_NOW="$(date -u -d 2026-10-16T04:00:00Z +%s)"; export CARD_NOW
export CARD_POST_CMD="$B/post" CARD_EDIT_CMD="$B/edit" CARD_ISSUES_CMD="$B/issues"
export CARD_LANES_CMD="$B/lanes" CARD_QUEUE_CMD="$B/queue" CARD_LEASE_CMD="$B/lease" CARD_LAG_CMD="$B/lag"
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

eq "usage is refused" 64 "$(bash "$R" --bogus >/dev/null 2>&1; echo $?)"
t_done
