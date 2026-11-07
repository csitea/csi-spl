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
# RED CONTROLS: without the action file every case fails; without the journal
# read case 4 posts twice; without spl_lease_remote case 5 posts.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool" LOG="$T/calls.log" ST="$T/fu"
OLD="aaaaaaaa-0000-4000-8000-000000000001" OLD2="bbbbbbbb-0000-4000-8000-000000000002" OLD3="cccccccc-0000-4000-8000-000000000003"
NEW="dddddddd-0000-4000-8000-000000000004"
AT="2026-11-07T01:00:00Z"
mkdir -p "$SP/dispatch" "$T/bin" && : >"$LOG"
printf 'LEASE_ENV=dev\nLEASE_MACHINE=box-a\nLEASE_MASTER=c-002\nLEASE_ORCH=c-001\n' >"$SP/dispatch/lease.conf"
echo "c-002@box-a $(date +%s)" >"$SP/dispatch/lease"
{
  printf 'issue\tt1\t%s\tdev\t%s\tSPL-1\twip\tthe first job\n' "$OLD" "$AT"
  printf 'issue\tt1\t%s\tdev\t%s\tSPL-2\ttodo\tthe second job\n' "$OLD" "$AT"
  printf 'row\tt1\t%s\tdev\t%s\tabcd1234\tdeclined\ta queued job\n' "$OLD2" "$AT"
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
cat >"$T/bin/send" <<EOF
#!/usr/bin/env bash
echo "send \$*" >>"$LOG"
EOF
chmod +x "$T/bin/"*

run() {
  SNIPPET="spl_test_workspace() { [[ \"\$1\" == e2e ]]; }; do_spl_archived_followup" in_orc SPOOL_ROOT="$SP" LEASE_MACHINE=box-a \
    ARCHIVED_FOLLOWUP_STATE_DIR="$ST" ARCHIVED_FOLLOWUP_ROWS_FILE="${ROWS:-$T/rows}" ARCHIVED_FOLLOWUP_POST_CMD="$T/bin/post" \
    ARCHIVED_FOLLOWUP_LINK_CMD="$T/bin/link" ARCHIVED_FOLLOWUP_SEND="$T/bin/send" "$@" 2>&1
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

# 5. another box holds the lease
: >"$LOG"; echo "c-003@box-b $(date +%s)" >"$SP/dispatch/lease"
out="$(run DRY_RUN=0)"
[[ ! -s "$LOG" && "$out" == *"held by c-003@box-b"* ]] && pass "5 a remote holder: nothing here" || fail "5: $out // $(cat "$LOG")"
echo "c-002@box-a $(date +%s)" >"$SP/dispatch/lease"

# 6. a failed post: no link, one blocker
: >"$LOG"; printf 'issue\tt1\t%s\tdev\t%s\tSPL-3\twip\tjob\n' "$OLD3" "$AT" >"$T/rows6"; touch "$T/post-fails"
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
{ printf 'issue\tt1\t%s\tdev\t%s\tSPL-5\twip\tjob\n' "$OLD" "$AT"; printf 'issue\tt1\t%s\tdev\t%s\tSPL-5\twip\tjob\n' "$OLD3" "$AT"; } >"$T/rows8"
out="$(ROWS="$T/rows8" run DRY_RUN=0)"
[[ "$(count '^post ')" == 1 && "$(count '^link SPL-5 ')" == 1 ]] && pass "8 an issue under two topics moves once, one post" || fail "8: $out // $(cat "$LOG")"

echo "spl-archived-followup: $fails failure(s)"
[[ $fails -eq 0 ]]
