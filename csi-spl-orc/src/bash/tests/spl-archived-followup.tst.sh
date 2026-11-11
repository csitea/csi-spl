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
#  12 the real statement joins a row by every binding form, on AFU_TEST_PG_DSN or
#     a throwaway Postgres (CI caches the image; an unlisted SKIP fails its job)
#     12c an archive younger than the settle time (default 10 min) or none is not
#     followed up yet (SPL-5259); CONTROL 12d: a settle time of 0 takes it
#  13 a channel the box map holds, a workspace's * row, a sole seat, a map that
#     cannot be read, a malformed column 7: no post, reply or link, one blocker
#     naming what was left, even after an earlier blocker of the topic;
#     CONTROL: another channel of the same workspace still posts
#  14 the follow-up takes the archived parent's stored priority (SPL-5147): 2 -> 2;
#     CONTROL none -> none; a dry run calls nothing; a failed copy still moves the
#     issues, fails the run, sends one blocker and is journalled; a later run with
#     no row left tries it again until it takes (R7 c-714 W2); a final refusal is
#     not journalled; a follow-up the hub has not stored yet is retried
# RED CONTROLS: without the action file every case fails; without the journal
# read case 4 posts twice; without the poster check case 5 posts; without
# spl_afu_work_left case 9 posts; without spl_afu_desk_seated case 10d posts;
# without spl_afu_late_rows case 11 replies nothing; without the other roots of
# spl_afu_desk_seated case 10g posts nothing and sends a blocker; without the
# pinned check case 10j reads the stub as this user's desk; without
# spl_afu_channel_held every case of 13 but its controls posts; reading only the
# word in column 7, 13i..k post; with one failed.keys key per topic, 13m and 13n
# send no second blocker. Without the alarm 13h2..h4 fail; a * row read like a
# channel row posts in 13k2 and 13k3; the old held text fails 13f2; without
# spl_afu_inherit case 14a stays unset; without spl_afu_pending 14f and 14h fail;
# without the final-refusal check 14j journals the copy.
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
if grep -qxF "\$ISSUE_REF" "$T/link-nf" 2>/dev/null; then
  printf '%s\n' "FATAL spool issue link as c-002: spool: hub refused: not_found (no such issue)" "ERROR Action failed with status 1"; exit 1
fi
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
cat >"$T/bin/inherit" <<EOF
#!/usr/bin/env bash
echo "inherit \$TENANT_ID \$DESK_AGENT \$PRIORITY_FROM \$PRIORITY_TO" >>"$T/inherit.log"
if [ -s "$T/inherit-why" ]; then cat "$T/inherit-why"; exit 1; fi
if [ -s "$T/inherit-fails" ]; then
  n=\$(sed -n 1p "$T/inherit-fails"); sed -i 1d "$T/inherit-fails"; echo "\$n"; exit 1
fi
[ ! -f "$T/prio/\$PRIORITY_FROM" ] || cp "$T/prio/\$PRIORITY_FROM" "$T/prio/\$PRIORITY_TO"
EOF
mkdir -p "$T/prio"
chmod +x "$T/bin/"*

run() {
  SNIPPET="spl_test_workspace() { [[ \"\$1\" == e2e ]]; }; do_spl_archived_followup" in_orc SPOOL_ROOT="$SP" LEASE_MACHINE=box-a \
    ARCHIVED_FOLLOWUP_STATE_DIR="$ST" ARCHIVED_FOLLOWUP_ROWS_FILE="${ROWS:-$T/rows}" ARCHIVED_FOLLOWUP_POST_CMD="$T/bin/post" \
    ARCHIVED_FOLLOWUP_REPLY_CMD="$T/bin/reply" ARCHIVED_FOLLOWUP_LINK_CMD="$T/bin/link" ARCHIVED_FOLLOWUP_SEND="$T/bin/send" ARCHIVED_FOLLOWUP_PRIORITY_CMD="$T/bin/inherit" ARCHIVED_FOLLOWUP_PRIORITY_WAIT=0 "$@" 2>&1
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
  printf 't1\tcrlf\t%s\tprd\tc-001\t-\tno-auto-post\r\n' "$DOC"
  printf 't1\ttypo\t%s\tprd\tc-001\t-\tno_auto_post\n' "$DOC"
  printf 'ws-typo\t*\t-\t-\t-\t-\tbogus\n'
  printf 'ws-short\t*\t-\t-\t-\tno-auto-post\n'
  printf 'ws-dash\t*\t-\t-\t-\t-\t-\n'
  printf 't1\tdash\t%s\tprd\tc-001\t-\t-\n' "$DOC"
  printf 't1\tblank\t%s\tprd\tc-001\t-\t\n' "$DOC"
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
[[ "$(count "already has its follow-up, /t/$NEW")" == 1 && "$(count 'no follow-up is posted')" == 0 && "$out" != *"no follow-up discussion"* ]] && pass "13f2 its blocker names the follow-up it already has" || fail "13f2: $out // $(cat "$LOG")"
fresh; held t1 held; out="$(ROWS="$T/rows13" run DRY_RUN=1)"
[[ ! -s "$LOG" && "$out" == *"WOULD name t1 topic $OLD in a blocker, no post"* ]] && pass "13g a dry run says so and sends nothing" || fail "13g: $out // $(cat "$LOG")"
mv "$SP/channel-rules.tsv" "$T/map13"; fresh; held t1 elsewhere
out="$(ROWS="$T/rows13" run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(count '^post ')" == 0 && "$(count '^send .*--kind blocker')" == 1 ]] && pass "13h no map on this box: no post, one blocker" || fail "13h rc $rc: $out // $(cat "$LOG")"
[[ "$out" == *"ALARM"*"is missing"* && "$(count 'ALARM.*is missing')" == 1 ]] && pass "13h2 no map on this box: an alarm in the log and the blocker" || fail "13h2: $out // $(cat "$LOG")"
mkdir "$SP/channel-rules.tsv"; fresh; held t1 elsewhere
out="$(ROWS="$T/rows13" run DRY_RUN=0)"
[[ "$(count '^post ')" == 0 && "$out" == *"ALARM"*"is unreadable"* && "$(count 'ALARM.*is unreadable')" == 1 && "$out" != *"column 7"* ]] && pass "13h3 a map that cannot be read: held, an alarm, no column 7 story" || fail "13h3: $out // $(cat "$LOG")"
rmdir "$SP/channel-rules.tsv"
: >"$SP/channel-rules.tsv"; chmod 000 "$SP/channel-rules.tsv"
if [[ -r "$SP/channel-rules.tsv" ]]; then pass "13h4 a mode 000 map (skipped: this user reads mode 000)"
else fresh; held t1 elsewhere; out="$(ROWS="$T/rows13" run DRY_RUN=0)"
  [[ "$(count '^post ')" == 0 && "$out" == *"ALARM"*"is unreadable"* ]] && pass "13h4 a mode 000 map: held, an alarm" || fail "13h4: $out // $(cat "$LOG")"; fi
rm -f "$SP/channel-rules.tsv"
mv "$T/map13" "$SP/channel-rules.tsv"
# column 7 is the word, empty or "-": anything else holds, it cannot be told apart from a hold
check_held t1 crlf i "a CRLF column 7"
check_held t1 typo j "a misspelt column 7"
check_held ws-typo any-channel k "a malformed column 7 on a workspace's * row"
check_held ws-short any-channel k2 "a * row with the word in the wrong column"
check_held ws-dash any-channel k3 "a * row with - in column 7"
for c in dash blank; do
  fresh; held t1 "$c"; out="$(ROWS="$T/rows13" run DRY_RUN=0)"
  [[ "$(count "^post t1 c-002 $c\$")" == 1 && "$(count '^send ')" == 0 ]] && pass "13l CONTROL: column 7 $c posts, no blocker" || fail "13l $c: $out // $(cat "$LOG")"
done
# a held blocker has its own key: an earlier blocker of the topic does not swallow it, nor the reverse
cp "$SP/channel-rules.tsv" "$T/map13"
fresh; held t2 late; out="$(ROWS="$T/rows13" run DRY_RUN=0)"; first="$(count '^send .*--kind blocker')"
printf 't2\tlate\t%s\tprd\tc-001\t-\tno-auto-post\n' "$DOC" >>"$SP/channel-rules.tsv"
: >"$LOG"; out="$(ROWS="$T/rows13" run DRY_RUN=0)"; second="$(count '^send .*--kind blocker')"; named="$(count 'SPL-9 (wip): the left job')"
out2="$(ROWS="$T/rows13" run DRY_RUN=0)"
[[ "$first" == 1 && "$second" == 1 && "$named" == 1 && "$(count '^send .*--kind blocker')" == 1 ]] && pass "13m a desk blocker, then the hold: one more blocker naming the work, not repeated" || fail "13m $first $second $named: $out // $out2 // $(cat "$LOG")"
fresh; out="$(ROWS="$T/rows13" run DRY_RUN=0)"; first="$(count '^send .*--kind blocker')"
cp "$T/map13" "$SP/channel-rules.tsv"; : >"$LOG"; out="$(ROWS="$T/rows13" run DRY_RUN=0)"
[[ "$first" == 1 && "$(count '^send .*--kind blocker')" == 1 && "$out" == *"no desk for c-002 on box-a in t2"* ]] && pass "13n CONTROL: the hold, then no desk: the desk blocker is still sent" || fail "13n $first: $out // $(cat "$LOG")"

# 12. the real statement, on a scratch schema
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if [[ -z "${AFU_TEST_PG_DSN:-}" ]] && command -v docker >/dev/null && command -v psql >/dev/null && docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  PG_CTR="spl-archived-followup-pg-$$"
  trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
  docker run -d --rm --label "csi-spl.lane=${AGENT_ID:-${SPOOL_AGENT_ID:-}}" --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
    -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
  # shellcheck source=pg-throwaway.inc.sh
  source "$TEST_DIR/pg-throwaway.inc.sh"
  PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
  for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
  AFU_TEST_PG_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
fi
if [[ -n "${AFU_TEST_PG_DSN:-}" ]]; then
  SCH="afu_$$"
  psql -X -q "$AFU_TEST_PG_DSN" -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE SCHEMA $SCH; SET search_path = $SCH;
CREATE TABLE messages (tenant_id text, task_id uuid, channel text, archived_at timestamptz, from_id text, ts timestamptz);
CREATE TABLE roster (tenant_id text, box_id text, agent_id text);
CREATE TABLE issues (tenant_id text, number int, status text, title text, kind text, labels text[], archived_at timestamptz, deleted_at timestamptz);
CREATE TABLE issue_discussions (tenant_id text, number int, task_id uuid);
CREATE TABLE issue_counters (tenant_id text, prefix text);
CREATE TABLE fleet_asks (ask_id text, discussion text, topic text, state text, reason text, summary text, updated_at timestamptz);
CREATE FUNCTION issue_discussion_default(text) RETURNS uuid LANGUAGE sql AS 'SELECT ''00000000-0000-4000-8000-000000000000''::uuid';
INSERT INTO messages VALUES ('t1', '$OLD', 'dev', now() - interval '1 hour', 'HUM-1', now()),
  ('t1', '$OLD3', 'dev', now() - interval '30 seconds', 'HUM-1', now()), ('t1', '$OLD2', 'dev', NULL, 'HUM-1', now());
INSERT INTO issues VALUES ('t1', 41, 'todo', 'a live job', 'issue', '{}', NULL, NULL), ('t1', 42, 'todo', 'a deleted job', 'issue', '{}', NULL, now()),
  ('t1', 43, 'wip', 'a job of a topic archived 30 s ago', 'issue', '{}', NULL, NULL), ('t1', 44, 'wip', 'a job of a live topic', 'issue', '{}', NULL, NULL);
INSERT INTO issue_discussions VALUES ('t1', 41, '$OLD'), ('t1', 42, '$OLD'), ('t1', 43, '$OLD3'), ('t1', 44, '$OLD2');
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
  [[ "$(grep '^issue' "$T/sql.out" | cut -f6 | tr '\n' ' ')" == "SPL-41 " ]] &&
    pass "12b a deleted issue is not work left (SPL-5244: the owner deleted SPL-5068, its move was refused every run)" || fail "12b: $(grep '^issue' "$T/sql.out" 2>&1)"
  [[ "$(cut -f3 "$T/sql.out" | sort -u)" == "$OLD" ]] &&
    pass "12c a topic archived 30 s ago is not followed up yet (it may be put back: SPL-5259, csi-rel 637bfd01 archived 11:25:18Z, restored 11:25:41Z), nor a live one" || fail "12c: $(cut -f1-3,6 "$T/sql.out" 2>&1)"
  SNIPPET="spl_pg_env() { shift; \"\$1\" \"\$AFU_TEST_PG_DSN&options=-csearch_path%3D$SCH\" \"\${@:2}\"; }; _spl_afu_read '$T/sql0.out' '2020-01-01T00:00:00Z' c-002 0" in_orc AFU_TEST_PG_DSN="$AFU_TEST_PG_DSN" SPL_PROXY_DSN=unused >"$T/sql0.log" 2>&1
  [[ "$(grep '^issue' "$T/sql0.out" | cut -f6 | sort | tr '\n' ' ')" == "SPL-41 SPL-43 " ]] &&
    pass "12d CONTROL: a settle time of 0 takes the topic archived 30 s ago, still not the live one" || fail "12d: $(cat "$T/sql0.log") // $(cut -f1-3,6 "$T/sql0.out" 2>&1)"
  psql -X -q "$AFU_TEST_PG_DSN" -c "DROP SCHEMA $SCH CASCADE" >/dev/null 2>&1
else
  echo "SKIP: 12 needs AFU_TEST_PG_DSN, or docker, psql and a cached $PG_IMAGE image"
fi

# 14. the follow-up's priority. A stub hub: the copy is a file of the parent's id.
PAR="eeeeeeee-0000-4000-8000-000000000005"
printf 'issue\tt1\t%s\tdev\t%s\tSPL-9\twip\ta job\tbox-a\tHUM-1\n' "$PAR" "$AT" >"$T/rows14"
fresh14() { rm -rf "$ST14" "$T/prio"/* "$T/inherit-fails" "$T/inherit-why" "$T/inherit.log"; mkdir -p "$ST14"; echo 2020-01-01T00:00:00Z >"$ST14/since"; : >"$LOG"; }
ST14="$T/fu14"
run14() { ROWS="$T/rows14" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST14" "$@"; }
fresh14; echo 2 >"$T/prio/$PAR"
out="$(run14 DRY_RUN=0)"
[[ "$(cat "$T/prio/$NEW" 2>/dev/null)" == 2 && "$(cat "$T/inherit.log")" == "inherit t1 c-002 $PAR $NEW" ]] &&
  pass "14a a parent at priority 2: the follow-up reads 2" || fail "14a: $out // $(cat "$T/inherit.log" 2>&1)"
fresh14
out="$(run14 DRY_RUN=0)"
[[ ! -e "$T/prio/$NEW" && "$(count "^link SPL-9 $NEW")" == 1 ]] &&
  pass "14b CONTROL a parent with none: the follow-up has none" || fail "14b: $out"
fresh14; echo 2 >"$T/prio/$PAR"
out="$(run14)"
[[ ! -e "$T/inherit.log" && ! -e "$T/prio/$NEW" ]] && pass "14c a dry run copies nothing" || fail "14c: $out"
fresh14; echo 2 >"$T/prio/$PAR"; echo "internal: priority not inherited" >"$T/inherit-fails"
out="$(run14 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$(grep -c inherit "$T/inherit.log")" == 1 && "$(count "^link SPL-9 $NEW")" == 1 && "$out" == *"internal: priority"* &&
   "$(cat "$ST14/inherit.pending" 2>/dev/null)" == "t1"$'\t'"$PAR"$'\t'"$NEW" && "$(count '^send .*did not take its priority.*the next run tries again')" == 1 ]] &&
  pass "14d a failed copy: one try, the issue still moves, the run fails and says why, the copy is journalled, one blocker" || fail "14d (rc=$rc): $out // $(cat "$LOG")"
: >"$T/rows14.empty"
echo "internal: priority not inherited" >"$T/inherit-fails"
out="$(ROWS="$T/rows14.empty" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST14" DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$(grep -c inherit "$T/inherit.log")" == 2 && -s "$ST14/inherit.pending" && "$(count '^send')" == 1 ]] &&
  pass "14f the issues gone from the topic, a run with no row still tries the copy; failing again it stays journalled, no second blocker" || fail "14f (rc=$rc): $out // $(cat "$LOG")"
out="$(ROWS="$T/rows14.empty" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST14")"; rc=$?
[[ "$(grep -c inherit "$T/inherit.log")" == 2 && -s "$ST14/inherit.pending" && "$out" == *"WOULD try again"* ]] &&
  pass "14g a dry run names the waiting copy and calls nothing" || fail "14g (rc=$rc): $out"
out="$(ROWS="$T/rows14.empty" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST14" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c inherit "$T/inherit.log")" == 3 && "$(cat "$T/prio/$NEW" 2>/dev/null)" == 2 && ! -s "$ST14/inherit.pending" ]] &&
  pass "14h a later run takes the copy and clears the journal" || fail "14h (rc=$rc): $out"
out="$(ROWS="$T/rows14.empty" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST14" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c inherit "$T/inherit.log")" == 3 ]] && pass "14i once taken, nothing tries again" || fail "14i (rc=$rc): $out"
fresh14; echo 2 >"$T/prio/$PAR"; echo "not_followup: refused" >"$T/inherit-fails"
out="$(run14 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$(grep -c inherit "$T/inherit.log")" == 1 && "$(count "^link SPL-9 $NEW")" == 1 && ! -s "$ST14/inherit.pending" &&
   "$(count '^send .*not_followup.*refused it for good')" == 1 ]] &&
  pass "14j a final refusal: the issue still moves, one blocker, nothing journalled" || fail "14j (rc=$rc): $out // $(cat "$LOG")"
fresh14; echo 2 >"$T/prio/$PAR"; printf 'not_found: no such target topic\nnot_found: no such target topic\n' >"$T/inherit-fails"
out="$(run14 DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c inherit "$T/inherit.log")" == 3 && "$(cat "$T/prio/$NEW" 2>/dev/null)" == 2 ]] &&
  pass "14e a follow-up the hub has not stored yet is tried again" || fail "14e (rc=$rc): $out"

# 14k: the real cause, not ./run's trailer. The prd shape of 2026-11-10T03:05Z: a box
# spool built before --from/--to (spl_desk_issue_run's FATAL, the flag usage), then
# the two lines ./run adds; the log and the blocker named only the last.
fresh14; echo 2 >"$T/prio/$PAR"
printf '%s\n' "FATAL spool issue inherit-priority as c-002: flag provided but not defined: -from" "Usage of issue inherit-priority:" "  -apply" \
  "ERROR Action failed with status 1" "FATAL Command 'do_spl_topic_inherit_priority' failed at line 131 with status 1." >"$T/inherit-why"
out="$(run14 DRY_RUN=0)"; rc=$?
[[ $rc -ne 0 && "$out" == *"did not take its priority: FATAL spool issue inherit-priority as c-002: flag provided but not defined: -from"* &&
   "$(count '^send .*its priority: FATAL spool issue inherit-priority as c-002: flag provided but not defined: -from\. The issues')" == 1 ]] &&
  pass "14k the log and the blocker name the spool error, not ./run's failed-at-line trailer" || fail "14k (rc=$rc): $out // $(cat "$LOG")"
rm -f "$T/inherit-why"

# 15. a move the hub refuses not_found (SPL-5244: the issue is gone): final. ONE
# blocker and one failed.keys key; the next run skips it, no WARN, no link call.
# CONTROL: the other issue of the same topic moves, as in 3.
ST15="$T/fu15"; mkdir -p "$ST15"; echo 2020-01-01T00:00:00Z >"$ST15/since"; : >"$LOG"
{ printf 'issue\tt1\t%s\tdev\t%s\tSPL-50\ttodo\ta gone job\tbox-a\tHUM-1\n' "$PAR" "$AT"
  printf 'issue\tt1\t%s\tdev\t%s\tSPL-51\ttodo\ta live job\tbox-a\tHUM-1\n' "$PAR" "$AT"; } >"$T/rows15"
echo SPL-50 >"$T/link-nf"
run15() { ROWS="$T/rows15" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST15" DRY_RUN=0; }
out="$(run15)"; rc=$?
[[ "$(count '^send .*SPL-50.*not_found (no such issue).*nothing tries again')" == 1 ]] && grep -qxF "t1"$'\t'"$PAR"$'\t'"move:SPL-50" "$ST15/failed.keys" &&
  pass "15a a not_found move: one blocker naming the hub's answer, one failed.keys key" || fail "15a (rc=$rc): $out // $(cat "$LOG") // $(cat "$ST15/failed.keys" 2>&1)"
[[ "$(count "^link SPL-51 $NEW$")" == 1 && "$(count "^unlink SPL-51 $PAR$")" == 1 ]] &&
  pass "15b CONTROL the topic's other issue moves" || fail "15b: $(cat "$LOG")"
n15="$(count '^link SPL-50 ')"
out="$(run15)"; rc=$?
[[ $rc -eq 0 && "$(count '^link SPL-50 ')" == "$n15" && "$(count '^send ')" == 1 && "$out" != *"SPL-50 was not moved"* ]] &&
  pass "15c the next run: no link call, no WARN, no second blocker, rc 0" || fail "15c (rc=$rc): $out // $(cat "$LOG")"
rm -f "$T/link-nf"

# 16. a follow-up that is itself archived: the journal's chain is followed to its
# last entry (SPL-5244: 4f48f878 -> bc6ebfd8 -> b0cce04e), no hub read; the chained
# follow-up does not take the priority again (its own hop did). CONTROL: 3a..3e
# and 14a are the one-hop journal.
A16="11111111-0000-4000-8000-000000000016" B16="22222222-0000-4000-8000-000000000016" C16="33333333-0000-4000-8000-000000000016"
ST16="$T/fu16"; mkdir -p "$ST16"; echo 2020-01-01T00:00:00Z >"$ST16/since"; : >"$LOG"; rm -f "$T/inherit.log"
printf 't1\t%s\t%s\nt1\t%s\t%s\n' "$A16" "$B16" "$B16" "$C16" >"$ST16/journal.tsv"
printf 'issue\tt1\t%s\tdev\t%s\tSPL-60\ttodo\ta job\tbox-a\tHUM-1\n' "$A16" "$AT" >"$T/rows16"
out="$(ROWS="$T/rows16" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST16" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(count '^post ')" == 0 && "$(count "^link SPL-60 $C16$")" == 1 && "$(count "^unlink SPL-60 $A16$")" == 1 && "$(count "^link SPL-60 $B16")" == 0 && ! -e "$T/inherit.log" ]] &&
  pass "16a an archived follow-up: the issue moves to the chain's last entry, not into the archived one, no priority copy" || fail "16a (rc=$rc): $out // $(cat "$LOG")"
# 16b: the chain's LAST entry is archived too (no journal row of its own yet). The
# move went there (16a, today's path); the next run reads the issue under that
# archived topic and follows it up once, like any archive; a run after it, with no
# row left, does nothing. No loop, no retry every run.
printf 'issue\tt1\t%s\tdev\t%s\tSPL-60\ttodo\ta job\tbox-a\tHUM-1\n' "$C16" "$AT" >"$T/rows16c"; : >"$LOG"
out="$(ROWS="$T/rows16c" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST16" DRY_RUN=0)"; rc=$?
: >"$T/rows16e"
out3="$(ROWS="$T/rows16e" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST16" DRY_RUN=0)"; rc3=$?
[[ $rc -eq 0 && $rc3 -eq 0 && "$(count '^post ')" == 1 && "$(count "^link SPL-60 $NEW$")" == 1 && "$(count "^unlink SPL-60 $C16$")" == 1 && "$(grep -c . "$LOG")" == 3 ]] &&
  grep -qxF "t1"$'\t'"$C16"$'\t'"$NEW" "$ST16/journal.tsv" &&
  pass "16b the last entry archived too: followed up once as its own archive, then nothing; no loop" || fail "16b (rc=$rc/$rc3): $out // $out3 // $(cat "$LOG")"
# 16c: a journal cycle (the action never writes one, a hand edit could) ends.
printf 't1\t%s\t%s\nt1\t%s\t%s\n' "$A16" "$B16" "$B16" "$A16" >"$ST16/journal.tsv"; : >"$LOG"
out="$(ROWS="$T/rows16" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST16" DRY_RUN=0)"; rc=$?
[[ "$(count '^link SPL-60 ')" == 1 && "$(count '^post ')" == 0 ]] && pass "16c a journal cycle ends: one link, no post" || fail "16c (rc=$rc): $out // $(cat "$LOG")"

# 17. the settle knob: a leading zero (bash octal, psql decimal) or past 1440 is refused, nothing called.
: >"$LOG"; bad=""
for v in 02640 010 1441 99999; do
  out="$(ROWS="$T/rows16e" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST16" ARCHIVED_FOLLOWUP_SETTLE_MIN="$v" DRY_RUN=0)"; rc=$?
  [[ $rc -ne 0 && "$out" == *"FATAL ARCHIVED_FOLLOWUP_SETTLE_MIN must be 0..1440 minutes, got $v"* ]] || bad+=" $v(rc=$rc)"
done
for v in 0 10 1440; do
  out="$(ROWS="$T/rows16e" run ARCHIVED_FOLLOWUP_STATE_DIR="$ST16" ARCHIVED_FOLLOWUP_SETTLE_MIN="$v" DRY_RUN=0)"; rc=$?
  [[ $rc -eq 0 ]] || bad+=" ok-$v(rc=$rc)"
done
[[ -z "$bad" && ! -s "$LOG" ]] && pass "17 settle: 02640, 010, 1441, 99999 refused; 0, 10, 1440 run" || fail "17:$bad // $(cat "$LOG")"

echo "spl-archived-followup: $fails failure(s)"
[[ $fails -eq 0 ]]
