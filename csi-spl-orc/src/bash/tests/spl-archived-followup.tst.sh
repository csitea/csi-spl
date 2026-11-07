#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_archived_followup (SPL-4955; owner HUM-10, msg 51465f86: "to
# create an additional discussion to complete the tasks on the archived
# discussion"). Hermetic: the rows are a file, the post, the link and the sender
# are stubs that log; the lease lives in a temp spool root.
#   1 the first run only stamps `since`: nothing older is followed up
#   2 a dry run prints the plan and calls nothing
#   3 one post per topic in its channel, naming the old topic and what was left;
#     link before unlink; a row-only topic is posted too
#   4 a re-run with the same rows posts nothing more: issues are linked again
#     (a crash after the post), a row-only topic is skipped
#   5 a lease held on another box does nothing
#   6 a failed post: no link, ONE blocker however many runs
#   7 a test workspace is skipped
#   8 an issue under two archived topics moves once
#   9 a reviewer seat's issue is not work left (W3)
#  10 the box that acts: the holder's when it has the seat, else the first box of
#     the roster; nowhere = no post, one blocker, rc 0; the real desk check agrees
#     with the real do_spl_desk_post on the same dirs; a desk only under another
#     user's root runs the real commands as that user (W1)
#  11 a row declined after the post is added to that discussion, once (W4)
#  12 (with AFU_TEST_PG_DSN) the real statement joins a row by every binding form
#  13 a channel the box map holds, a workspace's * row, a sole seat, a map that
#     cannot be read: no post, reply or link, one blocker naming what was left;
#     CONTROL: another channel of the same workspace still posts
# RED CONTROLS: without the action file every case fails; without the journal
# read case 4 posts twice; without the poster check case 5 posts; without
# spl_afu_work_left case 9 posts; without spl_afu_desk_seated case 10d posts;
# without spl_afu_late_rows case 11 replies nothing; without the other roots of
# spl_afu_desk_seated case 10g posts nothing and sends a blocker; without the
# pinned check case 10j reads the stub as this user's desk; without
# spl_afu_channel_held every case of 13 but its control posts.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool" LOG="$T/calls.log" ST="$T/fu"
OLD="aaaaaaaa-0000-4000-8000-000000000001" OLD2="bbbbbbbb-0000-4000-8000-000000000002" OLD3="cccccccc-0000-4000-8000-000000000003"
NEW="dddddddd-0000-4000-8000-000000000004"
AT="2026-11-07T01:00:00Z"
mkdir -p "$SP/dispatch" "$T/bin" "$T/state/dev/desk/t1/box-a/spool/c-002" && : >"$LOG"
echo key >"$T/state/dev/desk/t1/box-a/pinned"
printf 'LEASE_ENV=dev\nLEASE_MACHINE=box-a\nLEASE_MASTER=c-002\nLEASE_ORCH=c-001\n' >"$SP/dispatch/lease.conf"
echo "c-002@box-a $(date +%s)" >"$SP/dispatch/lease"
: >"$SP/channel-rules.tsv"
{
  printf 'issue\tt1\t%s\tdev\t%s\tSPL-1\twip\tthe first job\tbox-a\tHUM-1\n' "$OLD" "$AT"
  printf 'issue\tt1\t%s\tdev\t%s\tSPL-2\ttodo\tthe second job\tbox-a\tHUM-1\n' "$OLD" "$AT"
  printf 'row\tt1\t%s\tdev\t%s\tabcd1234\tdeclined\ta queued job\tbox-a\tHUM-1\n' "$OLD2" "$AT"
} >"$T/rows"
cat >"$T/bin/post" <<EOF
#!/usr/bin/env bash
echo "post \$TENANT_ID \$DESK_AGENT \$DESK_CHANNEL" >>"$LOG"
cp "\$DESK_BODY_FILE" "$T/last-body"
[ ! -e "$T/post-fails" ] || { echo "hub said no"; exit 1; }
echo "{\"send\":{\"task_id\":\"$NEW\"}}"
EOF
cat >"$T/bin/link" <<EOF
#!/usr/bin/env bash
echo "\$MODE \$ISSUE_REF \$ISSUE_DISCUSSION" >>"$LOG"
EOF
cat >"$T/bin/reply" <<EOF
#!/usr/bin/env bash
echo "reply \$TENANT_ID \$DESK_AGENT \$DESK_TASK \$DESK_TO" >>"$LOG"
cp "\$DESK_BODY_FILE" "$T/last-reply"
EOF
cat >"$T/bin/send" <<EOF
#!/usr/bin/env bash
echo "send \$*" >>"$LOG"
EOF
chmod +x "$T/bin/"*

run() {
  SNIPPET="spl_test_workspace() { [[ \"\$1\" == e2e ]]; }; do_spl_archived_followup" in_orc SPOOL_ROOT="$SP" LEASE_MACHINE=box-a \
    ARCHIVED_FOLLOWUP_STATE_DIR="$ST" ARCHIVED_FOLLOWUP_ROWS_FILE="${ROWS:-$T/rows}" ARCHIVED_FOLLOWUP_POST_CMD="$T/bin/post" \
    ARCHIVED_FOLLOWUP_REPLY_CMD="$T/bin/reply" ARCHIVED_FOLLOWUP_LINK_CMD="$T/bin/link" ARCHIVED_FOLLOWUP_SEND="$T/bin/send" "$@" 2>&1
}
count() { grep -c "$1" "$LOG"; }

# 1. forward-only
out="$(run DRY_RUN=0)"
[[ -s "$ST/since" && ! -s "$LOG" ]] && pass "1 the first run stamps since and follows up nothing" || fail "1 first run: $out // $(cat "$LOG")"

# 2. dry run
out="$(run DRY_RUN=1)"
[[ ! -s "$LOG" && "$out" == *"WOULD follow up t1 topic $OLD"* && "$out" == *SPL-1* ]] && pass "2 dry run: the plan, nothing called" || fail "2 dry: $out // $(cat "$LOG")"

# 3. the live run
out="$(run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(count '^post t1 c-002 dev$')" == 2 ]] && pass "3a one post per topic, as the holder, in the channel" || fail "3a rc $rc: $out // $(cat "$LOG")"
if [[ "$(grep -n "^link SPL-1 $NEW$" "$LOG" | cut -d: -f1)" -lt "$(grep -n "^unlink SPL-1 $OLD$" "$LOG" | cut -d: -f1)" ]]; then pass "3b link before unlink, new then old"
else fail "3b order: $(cat "$LOG")"; fi
[[ "$(count '^link SPL-2 ')" == 1 && "$(count '^unlink SPL-2 ')" == 1 ]] && pass "3c every issue moves" || fail "3c: $(cat "$LOG")"
[[ "$(cat "$T/last-body")" == *"/t/$OLD2"* && "$(cat "$T/last-body")" == *"ask abcd1234: a queued job"* ]] && pass "3d the row-only post names the old topic and the row" || fail "3d: $(cat "$T/last-body")"
grep -q "^t1"$'\t'"$OLD"$'\t'"$NEW"'$' "$ST/journal.tsv" && pass "3e the journal keeps old -> new" || fail "3e: $(cat "$ST/journal.tsv" 2>&1)"

# 4. a re-run: no second post
n_post="$(count '^post ')"
out="$(run DRY_RUN=0)"
[[ "$(count '^post ')" == "$n_post" && "$(count '^link SPL-1 ')" == 2 ]] && pass "4 a re-run posts nothing; a left issue is linked to the same discussion" || fail "4: $out // $(cat "$LOG")"

# 5. another box holds the lease and has the seat
: >"$LOG"; echo "c-003@box-b $(date +%s)" >"$SP/dispatch/lease"
sed 's/\tbox-a\t/\tbox-a,box-b\t/' "$T/rows" >"$T/rows5"
out="$(ROWS="$T/rows5" run DRY_RUN=0)"
[[ ! -s "$LOG" && "$out" == *"box box-b follows it up"* ]] && pass "5 a remote holder with the seat: nothing here" || fail "5: $out // $(cat "$LOG")"
echo "c-002@box-a $(date +%s)" >"$SP/dispatch/lease"

# 6. a failed post: no link, one blocker
: >"$LOG"; printf 'issue\tt1\t%s\tdev\t%s\tSPL-3\twip\tjob\tbox-a\tHUM-1\n' "$OLD3" "$AT" >"$T/rows6"; touch "$T/post-fails"
out="$(ROWS="$T/rows6" run DRY_RUN=0)"; rc=$?
out2="$(ROWS="$T/rows6" run DRY_RUN=0)"
if [[ $rc -eq 1 && "$(count '^link ')" == 0 && "$(count '^send .*--to orchestrator --kind blocker')" == 1 && "$(count '^post ')" == 2 ]]; then pass "6 a failed post: rc 1, no link, retried, one blocker"
else fail "6 rc $rc: $out // $out2 // $(cat "$LOG")"; fi
rm -f "$T/post-fails"

# 7. a test workspace
: >"$LOG"; printf 'issue\te2e\t%s\tdev\t%s\tSPL-4\twip\tjob\n' "$OLD3" "$AT" >"$T/rows7"
out="$(ROWS="$T/rows7" run DRY_RUN=0)"
[[ ! -s "$LOG" ]] && pass "7 a test workspace is skipped" || fail "7: $out // $(cat "$LOG")"

# 8. one issue under two archived topics
: >"$LOG"; rm -f "$ST/journal.tsv"
{ printf 'issue\tt1\t%s\tdev\t%s\tSPL-5\twip\tjob\tbox-a\tHUM-1\n' "$OLD" "$AT"; printf 'issue\tt1\t%s\tdev\t%s\tSPL-5\twip\tjob\tbox-a\tHUM-1\n' "$OLD3" "$AT"; } >"$T/rows8"
out="$(ROWS="$T/rows8" run DRY_RUN=0)"
[[ "$(count '^post ')" == 1 && "$(count '^link SPL-5 ')" == 1 ]] && pass "8 an issue under two topics moves once, one post" || fail "8: $out // $(cat "$LOG")"

# 9. a reviewer seat
fresh() { : >"$LOG"; rm -f "$ST/journal.tsv" "$ST/rows.seen" "$ST/failed.keys"; }
fresh
{ printf 'issue\tt1\t%s\tdev\t%s\tSPL-6\twip\tSeat brief: R7 review of spec 155\tbox-a\tHUM-1\n' "$OLD" "$AT"; printf 'issue\tt1\t%s\tdev\t%s\tSPL-7\twip\tbug: R7 review gate reds\tbox-a\tHUM-1\n' "$OLD3" "$AT"; } >"$T/rows9"
out="$(ROWS="$T/rows9" run DRY_RUN=0)"
[[ "$(count '^post ')" == 1 && "$(count '^link SPL-6 ')" == 0 && "$(count '^link SPL-7 ')" == 1 ]] && pass "9 a reviewer seat's issue is left out; CONTROL: a bug about the review gate is work" || fail "9: $out // $(cat "$LOG")"

# 10. which box acts
one() { printf 'issue\t%s\t%s\tdev\t%s\tSPL-8\twip\tjob\t%s\tHUM-1\n' "$1" "$OLD" "$AT" "$2" >"$T/rows10"; }
fresh; echo "c-002@box-b $(date +%s)" >"$SP/dispatch/lease"; one t1 box-a
out="$(ROWS="$T/rows10" run DRY_RUN=0)"
[[ "$(count '^post t1 c-002 dev$')" == 1 ]] && pass "10a the holder's box has no seat there, this one has: it posts" || fail "10a: $out // $(cat "$LOG")"
fresh; echo "c-002@box-a $(date +%s)" >"$SP/dispatch/lease"; one t1 box-b
out="$(ROWS="$T/rows10" run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && ! -s "$LOG" && "$out" == *"box box-b follows it up"* ]] && pass "10b the holder here has no seat, another box has: nothing here, no blocker" || fail "10b rc $rc: $out // $(cat "$LOG")"
fresh; one t1 ""
out="$(ROWS="$T/rows10" run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(count '^post t1 c-002 dev$')" == 1 && "$(count '^send ')" == 0 ]] && pass "10c no box in the roster but a desk here: the holder's box tries the post" || fail "10c rc $rc: $out // $(cat "$LOG")"
fresh; one t2 ""
out="$(ROWS="$T/rows10" run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(count '^post ')" == 0 && "$(count '^send .*--to orchestrator --kind blocker')" == 1 && "$out" == *"roster: no box"* ]] && pass "10c2 no box in the roster and no desk: no post, rc 0, one blocker" || fail "10c2 rc $rc: $out // $(cat "$LOG")"
fresh; one t2 box-a
out="$(ROWS="$T/rows10" run DRY_RUN=0)"; rc=$?; out2="$(ROWS="$T/rows10" run DRY_RUN=0)"
[[ $rc -eq 0 && "$(count '^post ')" == 0 && "$(count '^send .*--to orchestrator --kind blocker')" == 1 && "$out" == *"no desk for c-002 on box-a in t2"* ]] && pass "10d no desk on this box: no post, rc 0, ONE blocker over 2 runs" || fail "10d rc $rc: $out // $out2 // $(cat "$LOG")"
# the real do_spl_desk_post reads the same dirs the same way
DESK_STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() { echo "{\"task_id\":\"'"$NEW"'\"}"; }
do_spl_desk_post'
real_post() { SNIPPET="$DESK_STUBS" in_orc SPOOL_ROOT="$SP" TENANT_ID="$1" DESK_BOX=box-a DESK_AGENT=c-002 DESK_CHANNEL=dev DESK_BODY=x DRY_RUN=0 2>&1; }
seat_check() { SNIPPET="AFU_BOX=box-a AFU_AGENT=c-002; spl_afu_desk_seated $1" in_orc SPOOL_ROOT="$SP" >/dev/null 2>&1; }
out="$(real_post t2)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"FATAL no desk for c-002 on box-a in t2"* ]] && ! seat_check t2; then pass "10e the real post is FATAL where the check says no desk"; else fail "10e rc $rc: $out"; fi
out="$(real_post t1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"$NEW"* ]] && seat_check t1; then pass "10f CONTROL: the real post sends where the check says a desk"; else fail "10f rc $rc: $out"; fi

# a desk only under another user's root (measured 2026-11-07 on a real box). This user's real post refuses; the run goes as that user.
mkdir -p "$T/other-root/desk/t3/box-a/spool/c-002"
echo key >"$T/other-root/desk/t3/box-a/pinned"
# a stub in this user's root (seat dir, empty pinned): t4 has the live desk under
# the other user, t5 only the stub
mkdir -p "$T/other-root/desk/t4/box-a/spool/c-002" "$T/state/dev/desk/t4/box-a/spool/c-002" "$T/state/dev/desk/t5/box-a/spool/c-002"
echo key >"$T/other-root/desk/t4/box-a/pinned"; : >"$T/state/dev/desk/t4/box-a/pinned"; : >"$T/state/dev/desk/t5/box-a/pinned"
cat >"$T/bin/as" <<EOF
#!/usr/bin/env bash
u="\$1"; shift; [[ "\$1" == "--" ]] && shift
[[ "\$1" == test ]] && exec "\$@"
a=" \$* "
echo "as \$u \${*: -1} \$(grep -oE '(TENANT_ID=|DESK_BOX=|DESK_AGENT=|ISSUE_REF=|MODE=|DRY_RUN=)[^ ]*' <<<"\$a" | tr '\n' ' ')" >>"$LOG"
[[ "\$a" == *" do_spl_desk_post "* ]] && printf '%s\n' "\$*" | grep -q 'the second job' && echo "{\"send\":{\"task_id\":\"$NEW\"}}"
exit 0
EOF
chmod +x "$T/bin/as"
ROOTS="spl_desk_roots() { printf '%s\t%s\n' \"\$(id -un)\" \"\$SPL_STATE_DIR\"; printf 'desk-u\t%s\n' '$T/other-root'; }"
fresh; echo "c-002@box-a $(date +%s)" >"$SP/dispatch/lease"
printf 'issue\tt3\t%s\tdev\t%s\tSPL-8\twip\tthe second job\tbox-a\tHUM-1\n' "$OLD" "$AT" >"$T/rows10g"
out="$(real_post t3)"; rc=$?
[[ $rc -ne 0 && "$out" == *"FATAL no desk for c-002 on box-a in t3"* ]] && pass "10g CONTROL: the real post as this user refuses a desk under another user's root" || fail "10g rc $rc: $out"
out="$(SNIPPET="$ROOTS; spl_test_workspace() { return 1; }; do_spl_archived_followup" in_orc SPOOL_ROOT="$SP" LEASE_MACHINE=box-a ARCHIVED_FOLLOWUP_STATE_DIR="$ST" ARCHIVED_FOLLOWUP_ROWS_FILE="$T/rows10g" ARCHIVED_FOLLOWUP_SEND="$T/bin/send" SPL_DESK_AS_CMD="$T/bin/as" DRY_RUN=0 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(count '^as desk-u do_spl_desk_post TENANT_ID=t3 DESK_BOX=box-a DESK_AGENT=c-002\|^as desk-u do_spl_desk_post TENANT_ID=t3 DESK_AGENT=c-002 DESK_BOX=box-a')" == 1 && "$(count '^as desk-u do_spl_issue_link .*ISSUE_REF=SPL-8 MODE=link')" == 1 && "$(count '^as desk-u do_spl_issue_link .*MODE=unlink')" == 1 && "$(count '^send ')" == 0 ]] && pass "10h the post and both links run as the desk's user, no blocker" || fail "10h rc $rc: $out // $(cat "$LOG")"
out="$(SNIPPET="$ROOTS; AFU_BOX=box-a AFU_AGENT=c-002; spl_afu_desk_seated t3 && echo \"user=\$AFU_DESK_USER\"; spl_afu_desk_seated t1 && echo \"user=[\$AFU_DESK_USER]\"; spl_afu_desk_seated t2 || echo none" in_orc SPOOL_ROOT="$SP" SPL_DESK_AS_CMD="$T/bin/as" 2>&1)"
[[ "$out" == *"user=desk-u"* && "$out" == *"user=[]"* && "$out" == *none* ]] && pass "10i the check names the other user, none for its own desk, and refuses where no root has it" || fail "10i: $out"
out="$(SNIPPET="$ROOTS; AFU_BOX=box-a AFU_AGENT=c-002; spl_afu_desk_seated t4 && echo \"user=\$AFU_DESK_USER\"; spl_afu_desk_seated t5 || echo stub-is-none" in_orc SPOOL_ROOT="$SP" SPL_DESK_AS_CMD="$T/bin/as" 2>&1)"
[[ "$out" == *"user=desk-u"* && "$out" == *stub-is-none* ]] && pass "10j a stub in this user's root loses to the other user's live desk; a stub alone is no desk" || fail "10j: $out"

# 11. a row declined after the follow-up was posted
fresh
printf 'issue\tt1\t%s\tdev\t%s\tSPL-9\twip\tjob\tbox-a\tHUM-1\n' "$OLD" "$AT" >"$T/rows11"
out="$(ROWS="$T/rows11" run DRY_RUN=0)"
printf 'row\tt1\t%s\tdev\t%s\tfeed0001\tdeclined\ta late job\tbox-a\tHUM-1\n' "$OLD" "$AT" >"$T/rows11b"
out="$(ROWS="$T/rows11b" run DRY_RUN=0)"
[[ "$(count '^post ')" == 1 && "$(count "^reply t1 c-002 $NEW HUM-1\$")" == 1 && "$(cat "$T/last-reply")" == *"ask feed0001: a late job"* ]] && pass "11a a late row goes into the existing discussion, not a new one" || fail "11a: $out // $(cat "$LOG")"
out="$(ROWS="$T/rows11b" run DRY_RUN=0)"
[[ "$(count '^reply ')" == 1 ]] && pass "11b the late row is added once" || fail "11b: $out // $(cat "$LOG")"
fresh
printf 'row\tt1\t%s\tdev\t%s\tfeed0002\tdeclined\ta first job\tbox-a\tHUM-1\n' "$OLD" "$AT" >"$T/rows11c"
out="$(ROWS="$T/rows11c" run DRY_RUN=0)"; out="$(ROWS="$T/rows11c" run DRY_RUN=0)"
[[ "$(count '^post ')" == 1 && "$(count '^reply ')" == 0 ]] && pass "11c a row listed in the first post is not added again" || fail "11c: $out // $(cat "$LOG")"

# 13. a channel the box map holds
DOC="11111111-0000-4000-8000-000000000001"
{
  printf 't1\theld\t%s\tprd\tc-001\t-\tno-auto-post\n' "$DOC"
  printf 'ws-held\t*\t-\t-\t-\t-\tno-auto-post\n'
  printf 't1\tsolo\t%s\tprd\tc-001\tc-900@box-z\n' "$DOC"
  printf 't1\tmine\t%s\tprd\tc-001\tc-002@box-a\n' "$DOC"
} >"$SP/channel-rules.tsv"
held() { printf 'issue\t%s\t%s\t%s\t%s\tSPL-9\twip\tthe left job\tbox-a\tHUM-1\n' "$1" "$OLD" "$2" "$AT" >"$T/rows13"; }
mkdir -p "$T/state/dev/desk/ws-held/box-a/spool/c-002"; echo key >"$T/state/dev/desk/ws-held/box-a/pinned"
moved() { grep -cE '^(post|reply|link|unlink) ' "$LOG"; }
# TENANT CHANNEL NAME WHY: two runs, nothing moves, one blocker that lists the work
check_held() {
  fresh; held "$1" "$2"
  out="$(ROWS="$T/rows13" run DRY_RUN=0)"; rc=$?
  out2="$(ROWS="$T/rows13" run DRY_RUN=0)"; rc2=$?
  if [[ $rc -eq 0 && $rc2 -eq 0 && "$(moved)" == 0 && "$(count '^send .*--kind blocker')" == 1 ]] && grep -q 'SPL-9 (wip): the left job' "$LOG"; then pass "13$3 $4: nothing moves, one blocker naming the work"
  else fail "13$3 rc $rc/$rc2: $out // $out2 // $(cat "$LOG")"; fi
}
check_held t1 held a "a channel row"
check_held ws-held any-channel b "a workspace's * row"
check_held t1 solo c "another seat's sole-seat channel"
fresh; held t1 elsewhere; out="$(ROWS="$T/rows13" run DRY_RUN=0)"
[[ "$(count '^post t1 c-002 elsewhere$')" == 1 && "$(count '^send ')" == 0 ]] && pass "13d CONTROL: another channel of the same workspace posts, no blocker" || fail "13d: $out // $(cat "$LOG")"
fresh; held t1 mine; out="$(ROWS="$T/rows13" run DRY_RUN=0)"
[[ "$(count '^post t1 c-002 mine$')" == 1 ]] && pass "13e CONTROL: the holder here is the channel's sole seat: it posts" || fail "13e: $out // $(cat "$LOG")"
# a late row and a left link, with the journal already there: still nothing moves
fresh; printf 't1\t%s\t%s\n' "$OLD" "$NEW" >"$ST/journal.tsv"
{ held t1 held; cat "$T/rows13"; printf 'row\tt1\t%s\theld\t%s\tabcd1234\tdeclined\ta late job\tbox-a\tHUM-1\n' "$OLD" "$AT"; } >"$T/rows13f"
out="$(ROWS="$T/rows13f" run DRY_RUN=0)"
[[ "$(moved)" == 0 ]] && pass "13f a topic posted before the hold: no reply, no link" || fail "13f: $out // $(cat "$LOG")"
fresh; held t1 held; out="$(ROWS="$T/rows13" run DRY_RUN=1)"
[[ ! -s "$LOG" && "$out" == *"WOULD name t1 topic $OLD in a blocker, no post"* ]] && pass "13g a dry run says so and sends nothing" || fail "13g: $out // $(cat "$LOG")"
mv "$SP/channel-rules.tsv" "$T/map13"; fresh; held t1 elsewhere
out="$(ROWS="$T/rows13" run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(count '^post ')" == 0 && "$(count '^send .*--kind blocker')" == 1 ]] && pass "13h no map on this box: no post, one blocker" || fail "13h rc $rc: $out // $(cat "$LOG")"
mv "$T/map13" "$SP/channel-rules.tsv"

# 12. the real statement, on a scratch schema
if [[ -n "${AFU_TEST_PG_DSN:-}" ]]; then
  SCH="afu_$$"
  psql -X -q "$AFU_TEST_PG_DSN" -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE SCHEMA $SCH; SET search_path = $SCH;
CREATE TABLE messages (tenant_id text, task_id uuid, channel text, archived_at timestamptz, from_id text, ts timestamptz);
CREATE TABLE roster (tenant_id text, box_id text, agent_id text);
CREATE TABLE issues (tenant_id text, number int, status text, title text, kind text, labels text[], archived_at timestamptz);
CREATE TABLE issue_discussions (tenant_id text, number int, task_id uuid);
CREATE TABLE issue_counters (tenant_id text, prefix text);
CREATE TABLE fleet_asks (ask_id text, discussion text, topic text, state text, reason text, summary text, updated_at timestamptz);
CREATE FUNCTION issue_discussion_default(text) RETURNS uuid LANGUAGE sql AS 'SELECT NULL::uuid';
INSERT INTO messages VALUES ('t1', '$OLD', 'dev', now(), 'HUM-1', now());
INSERT INTO roster VALUES ('t1', 'box-b', 'c-002'), ('t1', 'box-a', 'c-002'), ('t1', 'box-a', 'c-003');
INSERT INTO fleet_asks VALUES ('a0000001-x', '$OLD', '', 'declined', 'discussion archived: x', 'full discussion', now()),
  ('a0000002-x', '${OLD:0:8}', '', 'declined', 'discussion archived: x', 'short discussion', now()),
  ('a0000003-x', NULL, '$OLD', 'declined', 'discussion archived: x', 'full topic', now()),
  ('a0000004-x', NULL, 'dispatch-${OLD:0:8}', 'declined', 'discussion archived: x', 'dispatch topic', now()),
  ('a0000005-x', NULL, 'dispatch-${OLD2:0:8}', 'declined', 'discussion archived: x', 'another topic', now());
SQL
  SNIPPET="spl_pg_env() { shift; \"\$1\" \"\$AFU_TEST_PG_DSN&options=-csearch_path%3D$SCH\" \"\${@:2}\"; }; _spl_afu_read '$T/sql.out' '2020-01-01T00:00:00Z' c-002" in_orc AFU_TEST_PG_DSN="$AFU_TEST_PG_DSN" SPL_PROXY_DSN=unused >"$T/sql.log" 2>&1
  [[ "$(cut -f1,8 "$T/sql.out" | sort | tr '\n' ';')" == *"full discussion"*"full topic"*"short discussion"* && "$(grep -c '^row' "$T/sql.out")" == 4 && "$(cut -f9,10 "$T/sql.out" | sort -u)" == "box-a,box-b"$'\t'"HUM-1" ]] &&
    pass "12 the real statement: a row by all 4 binding forms, not another topic's; sorted roster; last human" || fail "12: $(cat "$T/sql.log") // $(cat "$T/sql.out" 2>&1)"
  psql -X -q "$AFU_TEST_PG_DSN" -c "DROP SCHEMA $SCH CASCADE" >/dev/null 2>&1
else
  echo "SKIP: 12 needs AFU_TEST_PG_DSN"
fi

echo "spl-archived-followup: $fails failure(s)"
[[ $fails -eq 0 ]]
