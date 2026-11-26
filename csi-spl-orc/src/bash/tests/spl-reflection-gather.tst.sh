#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_reflection_gather (spec 166 row B8) gathers the last 24 h at
# night and queues one refactor lane whose brief carries the gathered file.
#   1. a fixture repo with one revert in the window (and one before it), a
#      fake CI report with 2 reds in the window (and one before it), 2 owner
#      msg ids, one diss issue in the window: the gathered file lists the
#      revert, both reds and both msg ids, and none of the older ones
#   2. the enqueued brief carries Class: refactor, Kind, Epic: and Spec: lines
#      and the gathered file, and passes the existing enqueue gate (the real
#      do_spl_spawn_enqueue, li_brief_epic_spec on a fixture specs repo): the
#      queue op is called with refactor and claude:reflection-<night>; the
#      ask goes to the hub once; the night is stamped
#   2b. the queued brief is mode 0660, group-readable: written from a 0600
#      mktemp file by plain cp it kept 0600 and the placer could not read it
#      (SPL-5826). Red control: master's cp gives 600
#   3. nothing is written to git: the fixture repo's refs and status, and this
#      checkout's status, are the same before and after
#   4. red control: the same brief without its Spec: line is refused by the
#      existing gate (one FATAL line), no queue op, no stamp
#   5. by day nothing runs: no read, no gathered file, no stamp
#   6. a second tick the same night does nothing
#   7. DRY_RUN=1 (the default): the gathered file and the brief are printed,
#      no ask, no queue op
#   8. not the dispatch holder's box: nothing
#   9. a reader that fails is one "(not read" line; the lane is still queued
#   9b. sections 3, 4 and 5: a reader that fails says why, its last stderr
#      line cut to 200 chars, with the state dir, the home dir and a key
#      path masked (SPL-5469); a reader that failed through do_log (stdout,
#      coloured, no stderr) gives its last stdout line. Red control: master's 2>/dev/null readers print
#      the fixed "(not read: ...)" text, so the three cases fail there
#  10. the lane mix gives no vendor fit for private data: nothing queued, rc 1,
#      no stamp
#  11. the cron row: manifest row reflection every 15 min after zombie-topics,
#      its script is executable, refuses a worktree, passes REFLECTION_DRY_RUN
#      from lease.conf
#  12. the brief names its discussion on a Discussion: line, the topic in
#      cnf env.rhythm.reflection_discussion, so li_discussion_from_brief never
#      picks a topic of the gathered owner messages (SPL-5646)
#  12b. the template's Discussion: line holds no fixed uuid. Red control: the
#      old line back (the owner topic c0b0d572, archived 2026-11-04) renders
#      a brief whose Discussion: is not the cnf topic, and the template check
#      names the uuid
#  12c. a cnf with no reflection_discussion, or one that is not a uuid: FATAL,
#      rc 1, no gathered file, no queue op, no stamp
#  12d. the real all.env.yaml names a uuid that is not c0b0d572
#  13. the owner SQL on a real Postgres (rdb migrations, runtime login): an
#      owner with role admin and a biz_owner are listed; a tester, a developer,
#      an older post, another workspace are not. Red control: the old
#      role = 'owner' join lists nobody (SPL-5460)
#  14. section 1 counts fail-fast stops apart (SPL-5648): a report with 1 red
#      and 2 "gate fail-fast: stopped" lines in the window lists the red and
#      says "2 stopped by fail-fast, not listed". Red control: master listed 3
#  15. section 3 names who set each diss (SPL-5648): updated_by when the
#      issue's updated_at is its canceled_at (the diss was its last write),
#      "by HUM-10"; a later write leaves the line without "by" and the
#      section says why once. Red control: master named no actor
#  16. section 7 lists the stalled wip issues (SPL-5825, owner msg 8389d2d8):
#      a wip issue no live lane, no live ask and no master commit of the last
#      72 h names is listed with its title cut to 80 chars and its last commit
#      date or "none"; one named by a live lane (issue_key or branch slug), a
#      queued ask or a commit 1 day old is not; a done ask or a done lane does
#      not count; SPL-70 is not named by SPL-703. Red control: the same issue
#      with its live lane taken out of the lane map is listed. A lane map read
#      LOCAL-ONLY is one "(not read" line and no issue line
#  16b. section 7 reads the whole commit message (b14-01): a wip key named
#      only in a commit body (Refs: SPL-7) inside the 72 h is not stalled,
#      (none); a judge that fails (python3 exits 1) is one "(not read: the
#      judge failed: ...)" line, never an empty section. Red control: master
#      read subjects only and ignored the judge's rc: A listed SPL-7 with
#      "last commit none", B printed nothing
#  17. the brief lists the night's live origin topics (SPL-5829): the
#      topics of section 4 newest first, once each, without the backlog
#      (cnf) topic, an archived one, one whose archive state is unread and a
#      relay hash; it binds each proposed row to a Discussion: line of its
#      own, never the backlog alone, and the lane to link its origin topics.
#      An archive state not read is one (not read line, whatever is listed;
#      REFLECTION_ORIGIN_MAX caps the reads (R7 c-168 W2, N1). The brief's row
#      lines (Topic: and Discussion:) put on a row brief set its issue topic
#      (spl_lane_issue_topic) and lane-map discussion; red control: a
#      Discussion: line alone does not set the issue topic (R7 c-168 W1).
#      Red control: master's template renders none, so a lane on it links
#      only the backlog topic and its push fails commit-links (SPL-5826).
#      A night with no live owner topic is one (none line
#  18. section 6 reads the zombie sweep log under SPL_VAR_APP_DIR, as the
#      cron that writes it (r65-01): REFLECTION_ZOMBIE_LOG unset and
#      SPL_VAR_APP_DIR=$T/v gives the summary in $T/v/zombie-topics/cron.log;
#      a tree at <b>/csi/csi-spl gives <b>/../var/csi/csi-spl/...; the
#      override wins over both; no override and no tree (SPL_RUN_PATHS_TOP=)
#      is one "(not read: ...)" line naming REFLECTION_ZOMBIE_LOG. Red
#      control: master read a literal box path, so $T/v was never read
#  19. the brief fits the lane's start budget on a busy night (SPL-6633;
#      2026-11-26: 380 owner messages, a 76870 B brief, the start refused):
#      seed (a 10180 B fixture, that night's seed) + brief through
#      brief-token-estimate.sh at its default budget:
#        quiet night (the fixture above)    pasted as before, byte for byte   rc 0
#        400 owner msgs in 60 topics        section 4 grouped per topic       rc 0
#        400 msgs in 400 topics + 60 reds   grouped, then each section capped rc 0
#      the gathered file stays whole in every case. Red control: the old
#      paste-all (REFLECTION_BRIEF_GATHER_BYTES past the file) on both busy
#      fixtures: rc 3, the FATAL line of that night
#  20. section 2 counts a commit as a revert by its SUBJECT only (SPL-6639):
#      a fixture repo with one real revert and one feat commit whose body has
#      a "Reverted: postgres PASS" line lists exactly the revert. Red control:
#      master's git log --grep='^Revert' (any message line) lists both
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
NIGHT_NOW=2026-01-15T19:30Z
NIGHT=2026-01-15
SLUG="reflection-$NIGHT"
TPL="$PROJ_ROOT/src/bash/features/dispatch/brief-reflection.tpl.md"

mkdir -p "$T/spool/dispatch" "$T/bin"
echo "c-002@box-a 1793464017" >"$T/spool/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"
printf '#!/bin/bash\necho "mix kind=$LANE_MIX_KIND sensitive=$LANE_MIX_SENSITIVE" >>"%s/mix.log"\necho "pick=${PICK:-claude}"\n' "$T" >"$T/bin/mix"
chmod +x "$T/bin/mix"

# The fixture repo: a bare origin, a clone with the spec folder and four
# commits, two of them reverts (one before the window, one in it).
R="$T/repo"
g() { git -C "$R" -c user.name='FirstName LastName' -c user.email=dev@example.com "$@"; }
at() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" g commit -q --allow-empty -m "$2"; }
git init -q --bare "$T/origin.git" && git init -q -b master "$R"
mkdir -p "$R/csi-spl-doc/specs/166-orchestrator-daily-rhythm"
echo "# Spec 166" >"$R/csi-spl-doc/specs/166-orchestrator-daily-rhythm/spec.md"
g add -A && GIT_AUTHOR_DATE=2026-01-13T10:00:00Z GIT_COMMITTER_DATE=2026-01-13T10:00:00Z g commit -q -m "feat: base"
at 2026-01-10T10:00:00Z 'fix(y, SPL-703): older than 72 h'
at 2026-01-14T10:00:00Z 'feat(z, SPL-704): one day old'
at 2026-01-13T12:00:00Z 'Revert "feat(old): before the window"'
at 2026-01-15T08:00:00Z 'feat(x): a thing'
at 2026-01-15T09:00:00Z 'Revert "feat(x): a thing"'
g remote add origin "$T/origin.git" && g push -q origin master 2>/dev/null
OLD_REV="$(g rev-parse --short 'HEAD~2')"; NEW_REV="$(g rev-parse --short HEAD)"

cat >"$T/ci.txt" <<'EOF'
== 10_ci-quality.yml on master -- last 100 run(s), 2026-01-09T00:00:00Z .. 2026-01-15T18:00:00Z
== failed runs, newest first
   9001  2026-01-15T10:00:00Z  abc1234  wui-e2e  || FAIL: a shard
   9000  2026-01-15T09:00:00Z  abc1230  iac-suite
   8000  2026-01-10T09:00:00Z  abc0000  old-job
== first red per JOB, over the 3 failed run(s)
      1 wui-e2e
EOF
M1=11111111-0000-4000-8000-000000000001
M2=22222222-0000-4000-8000-000000000002
printf '%s\tt-aaaa\t2026-01-15T07:00:00Z\n%s\tt-bbbb\t2026-01-15T11:00:00Z\n' "$M1" "$M2" >"$T/owner.tsv"
cat >"$T/diss.json" <<'EOF'
{"op": "list", "result": {"issues": [
 {"key": "SPL-902", "title": "set by the owner", "status": "diss", "canceled_at": "2026-01-15T13:00:00Z", "updated_at": "2026-01-15T13:00:00Z", "updated_by": "HUM-10"},
 {"key": "SPL-901", "title": "a lane dropped by its gate", "status": "diss", "canceled_at": "2026-01-15T12:00:00.5Z", "updated_at": "2026-01-15T12:00:01Z", "updated_by": "c-002"},
 {"key": "SPL-800", "title": "an old one", "status": "diss", "canceled_at": "2026-01-10T12:00:00Z", "updated_at": "2026-01-10T12:00:00Z"}]}}
EOF
DISC=33333333-0000-4000-8000-000000000003
printf 'env:\n  rhythm:\n    reflection_discussion: %s\n' "$DISC" >"$T/cnf.yaml"
LONG_TITLE="stalled: $(printf 'x%.0s' {1..100})"
cat >"$T/wip.json" <<EOF
{"op": "list", "result": {"issues": [
 {"key": "SPL-701", "title": "$LONG_TITLE", "status": "wip"},
 {"key": "SPL-703", "title": "its last commit is 5 days old", "status": "wip"},
 {"key": "SPL-704", "title": "a commit 1 day old", "status": "wip"},
 {"key": "SPL-705", "title": "a live lane carries it", "status": "wip"},
 {"key": "SPL-706", "title": "a live lane's branch slug names it", "status": "wip"},
 {"key": "SPL-707", "title": "a queued ask names it", "status": "wip"},
 {"key": "SPL-708", "title": "only a done ask names it", "status": "wip"},
 {"key": "SPL-709", "title": "only a done lane carries it", "status": "wip"},
 {"key": "SPL-70", "title": "a shorter key", "status": "wip"}]}}
EOF
LANE_705='{"agent_id": "c-9", "agent_box": "box-a", "branch": "c-9-x", "scope": "a lane", "issue_key": "SPL-705", "state": "live"}'
cat >"$T/lanes.json" <<EOF
{"hub": "ok", "lanes": [$LANE_705,
 {"agent_id": "c-8", "agent_box": "box-b", "branch": "c-8-c002-spl706-fix", "scope": "x", "issue_key": "", "state": "live"},
 {"agent_id": "c-7", "agent_box": "box-a", "branch": "c-7-y", "scope": "y", "issue_key": "SPL-709", "state": "done"}]}
EOF
cat >"$T/asks.json" <<'EOF'
{"hub": "ok", "asks": [
 {"ask_id": "a1", "state": "queued", "summary": "QUEUE: SPL-707 a follow-up", "topic": "dispatch-x", "placement": "claude:x"},
 {"ask_id": "a2", "state": "done", "summary": "SPL-708 placed long ago", "topic": "dispatch-y", "placement": "claude:y"}]}
EOF
echo "2026-01-15T19:01:00Z OK zombie sweep, night of 2026-01-15 (DRY_RUN=1, cap 500, idle 7 d): 3 candidate(s); would archive 1" >"$T/zombie.log"

# The hub and the readers, replaced (SNIPPET of in_orc): calls land in
# $T/calls.log. The real do_spl_spawn_enqueue and its gate run.
STUBS='
spl_reflection_ci_report() { [[ "${CI_FAIL:-0}" == 1 ]] && { echo "gh: no token"; return 1; }; echo ci >>"$T/reads"; cat "$T/ci.txt"; }
spl_reflection_owner_msgs() { [[ "${OWNER_FAIL:-0}" == 1 ]] && { printf "psql: a first line\npsql: error: %0250d\n" 0 >&2; return 1; }; cat "$T/owner.tsv"; }
spl_reflection_ended_read() { [[ "${ENDED_FAIL:-0}" == 2 ]] && { printf "\033[0;31m 💣 [FATAL] no desk for c-002 on box-a\033[0m\n"; return 1; }
  [[ "${ENDED_FAIL:-0}" == 1 ]] && { echo "FATAL desk: cannot read $HOME/.gcp/.csi/key-csi-spl-dev.json: permission denied" >&2; return 1; }; cat "$T/diss.json"; }
spl_reflection_share_line() { [[ "${SHARE_FAIL:-0}" == 1 ]] && { echo "spool: no queue db under $SPL_STATE_DIR/spawn-q in $HOME" >&2; return 1; }; echo "share of 4 known live lanes: refactor 1 25%; phase night"; }
spl_reflection_wip_read() { cat "$T/wip.json"; }
spl_reflection_lanes_read() { cat "${LANES_JSON:-$T/lanes.json}"; }
spl_reflection_asks_read() { cat "$T/asks.json"; }
spl_spawn_q_init() { LANE_FLEET=main ASKS_BOX=box-a; }
spl_asks_hub() { echo "hub $*" >>"$STUB_LOG"; }
spl_asks_discussion_ok() { :; }
spl_asks_by() { echo c-001@box-a; }
spl_asks_holder() { echo c-001@box-a; }
spl_spawn_place_dispatch() { echo c-002@box-a; }
spl_spawn_q_resolve() { echo "$ASK_ID"; }
spl_spawn_q_op() { echo "qop $*" >>"$STUB_LOG"; echo "{\"position\": 1, \"queue_len\": 1, \"summary\": \"x\"}"; }
spl_spawn_q_reply() { :; }
do_spl_reflection_gather'

# run NOW [VAR=value]...: the action, output in $T/out, rc in $rc.
run() {
  local now="$1"; shift
  SNIPPET="$STUBS" in_orc T="$T" RHYTHM_NOW="$now" SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a \
    REFLECTION_STATE="$T/stamp" REFLECTION_DIR="$T/spool/dispatch/reflection" SPAWN_PLACE_BRIEF_DIR="$T/briefs" \
    REFLECTION_REPO="$R" REFLECTION_ZOMBIE_LOG="$T/zombie.log" REFLECTION_MIX_CMD="$T/bin/mix" REFLECTION_CNF="$T/cnf.yaml" \
    LI_SPEC_REPO="$R" LI_SPEC_FETCH_TIMEOUT=5 ENV= TENANT_ID= DESK_AGENT= "$@" >"$T/out" 2>&1
  rc=$?
}
reset() { rm -rf "$T/stamp" "$T/reads" "$T/briefs" "$T/spool/dispatch/reflection"; : >"$T/calls.log"; }
snap() { { git -C "$R" for-each-ref --format='%(refname) %(objectname)'; git -C "$R" status --porcelain; git -C "$APP_ROOT" status --porcelain; } 2>&1; }
GF="$T/spool/dispatch/reflection/$NIGHT.md"

# --- 1-3. at night: the gathered file, the enqueue through the gate, no git write ---
reset; BEFORE="$(snap)"
run "$NIGHT_NOW" DRY_RUN=0
[[ $rc == 0 ]] && pass "1. at night the action runs (rc 0)" || fail "1. rc=$rc: $(cat "$T/out")"
grep -q "^- $NEW_REV .*Revert \"feat(x): a thing\"" "$GF" 2>/dev/null && ! grep -q "$OLD_REV" "$GF" &&
  pass "1. the gathered file lists the revert in the window, not the one before it" || fail "1. reverts: $(cat "$GF" 2>/dev/null)"
grep -q '^- run 9001  2026-01-15T10:00:00Z  abc1234  wui-e2e  || FAIL: a shard$' "$GF" && grep -q '^- run 9000 .* iac-suite$' "$GF" && ! grep -q old-job "$GF" &&
  pass "1. it lists both CI reds in the window, not the older one" || fail "1. reds: $(cat "$GF" 2>/dev/null)"
grep -q "^- msg $M1, topic t-aaaa" "$GF" && grep -q "^- msg $M2, topic t-bbbb" "$GF" &&
  pass "1. it lists the window's owner msg ids" || fail "1. owner ids: $(cat "$GF" 2>/dev/null)"
grep -q '^- SPL-901 ended diss 2026-01-15T12:00:00Z: a lane dropped by its gate$' "$GF" && ! grep -q SPL-800 "$GF" &&
  grep -q 'phase night' "$GF" && grep -q 'OK zombie sweep, night of 2026-01-15' "$GF" &&
  pass "1. it lists the diss lane in the window, the share line and the zombie summary" || fail "1. rest: $(cat "$GF" 2>/dev/null)"
B="$T/briefs/$SLUG.md"
grep -qx 'Class: refactor' "$B" 2>/dev/null && grep -qx 'Kind: specs_and_docs' "$B" && grep -qx 'Epic: SPL-2129' "$B" &&
  grep -qx 'Spec: csi-spl-doc/specs/166-orchestrator-daily-rhythm' "$B" && grep -q "msg $M1" "$B" && ! grep -q '{GATHER}\|{NIGHT}' "$B" &&
  pass "2. the brief carries Class: refactor, Kind, Epic: and Spec: lines and the gathered file" || fail "2. brief: $(cat "$B" 2>/dev/null)"
[[ "$(stat -c %a "$B" 2>/dev/null)" == 660 ]] &&
  pass "2b. the queued brief is group-readable, mode 0660 (the placer runs as another user)" || fail "2b. brief mode: $(stat -c %a "$B" 2>/dev/null)"
grep -q "^qop queue .* c-001@box-a  claude:$SLUG refactor" "$T/calls.log" &&
  pass "2. it passes the enqueue gate: the queue op takes refactor, claude:$SLUG" || fail "2. qop: $(cat "$T/calls.log") $(cat "$T/out")"
[[ "$(grep -c '^hub put .*--topic '"$SLUG" "$T/calls.log")" == 1 ]] && grep -qx 'mix kind=specs_and_docs sensitive=1' "$T/mix.log" &&
  pass "2. one ask put on the hub, topic $SLUG; the vendor asked as specs_and_docs on private data" || fail "2. hub: $(cat "$T/calls.log")"
# --- 12. the brief's discussion is its Discussion: line, the cnf topic ------------
LIB="$PROJ_ROOT/src/bash/features/spawn-agents/lib/lane-issue.inc.sh"
disc_of() { bash -c 'do_log() { :; }; . "$1"; li_discussion_from_brief "$2"' _ "$LIB" "$1" 2>/dev/null; }
got="$(disc_of "$B")"
[[ "$got" == "$DISC" ]] && grep -qx "Discussion: $DISC" "$B" &&
  pass "12. the brief's discussion is the cnf topic (its Discussion: line)" || fail "12. discussion: '$got'"
[[ "$(cat "$T/stamp" 2>/dev/null)" == "$NIGHT" ]] && pass "2. the night is stamped $NIGHT" || fail "2. stamp: $(cat "$T/stamp" 2>/dev/null)"
[[ "$(snap)" == "$BEFORE" ]] && pass "3. nothing is written to git (fixture refs and status, this checkout's status)" ||
  fail "3. git changed: $(diff <(echo "$BEFORE") <(snap))"

# --- 12b. no fixed uuid on the template's Discussion: line; red control: the old line
fixed_disc() { grep -oE '^Discussion: .*[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' "$1"; }
[[ -z "$(fixed_disc "$TPL")" ]] && grep -qx 'Discussion: {DISCUSSION}' "$TPL" &&
  pass "12b. the template's Discussion: line is {DISCUSSION}, no fixed topic uuid" || fail "12b. template: $(fixed_disc "$TPL")"
reset; sed 's/^Discussion: .*/Discussion: c0b0d572-c575-4849-8792-4c3ce4d170f2/' "$TPL" >"$T/old.tpl.md"
run "$NIGHT_NOW" DRY_RUN=0 REFLECTION_TPL="$T/old.tpl.md"
got="$(disc_of "$T/briefs/$SLUG.md")"
[[ "$got" != "$DISC" && -n "$(fixed_disc "$T/old.tpl.md")" ]] &&
  pass "12b. red control: the old Discussion: line renders '$got', not the cnf topic, and the template check names it" ||
  fail "12b. red control did not go red: '$got'"

# --- 12c. no reflection_discussion in the cnf, or not a uuid: nothing ---------------
for bad in 'env:\n  rhythm:\n    zombie_max: 500\n' 'env:\n  rhythm:\n    reflection_discussion: c0b0d572\n'; do
  reset; printf "$bad" >"$T/bad.yaml"
  run "$NIGHT_NOW" DRY_RUN=0 REFLECTION_CNF="$T/bad.yaml"
  [[ $rc != 0 && ! -e "$GF" && ! -e "$T/stamp" ]] && ! grep -q '^qop\|^hub' "$T/calls.log" &&
    grep -q 'FATAL reflection: cnf env.rhythm.reflection_discussion .* must be a live topic' "$T/out" &&
    pass "12c. cnf '$(tail -1 <<<"$(printf "$bad")" | sed 's/^ *//')': FATAL, no gathered file, no queue op, no stamp" ||
    fail "12c. rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"
done

# --- 12d. the real cnf names a uuid, not the archived owner topic -------------------
real="$(yq -r '.env.rhythm.reflection_discussion // ""' "$PROJ_ROOT/../csi-spl-cnf/csi-spl/all.env.yaml" 2>/dev/null)"
[[ "$real" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ && "$real" != c0b0d572-* ]] &&
  pass "12d. all.env.yaml names reflection_discussion $real" || fail "12d. all.env.yaml: '$real'"

# --- 4. red control: the brief without its Spec: line is refused by the gate -------
reset; grep -v '^Spec:' "$TPL" >"$T/nospec.tpl.md"
run "$NIGHT_NOW" DRY_RUN=0 REFLECTION_TPL="$T/nospec.tpl.md"
[[ $rc != 0 ]] && ! grep -q '^qop' "$T/calls.log" && grep -q 'FATAL ask not queued: no issue without an epic and a git spec .*no spec folder named' "$T/out" &&
  [[ ! -e "$T/stamp" ]] && pass "4. red control: the same brief without Spec: is refused by the existing gate, no queue op, no stamp" ||
  fail "4. red: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 5. by day nothing runs ---------------------------------------------------------
reset; run 2026-01-15T12:00Z DRY_RUN=0
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$GF" && ! -e "$T/stamp" ]] && grep -q 'phase day: the reflection runs at night only' "$T/out" &&
  pass "5. by day: no read, no gathered file, no stamp" || fail "5. day: rc=$rc $(cat "$T/out")"

# --- 6. a second tick the same night ------------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0; rm -f "$T/reads"; : >"$T/calls.log"
run 2026-01-16T05:30Z DRY_RUN=0
[[ $rc == 0 && ! -e "$T/reads" ]] && ! grep -q '^qop' "$T/calls.log" && grep -q "already ran in the night of $NIGHT" "$T/out" &&
  pass "6. 06:30 CET the next morning is the same night: nothing" || fail "6. second tick: $(cat "$T/out")"

# --- 7. DRY_RUN=1 -------------------------------------------------------------------
reset; run "$NIGHT_NOW"
[[ $rc == 0 && -s "$GF" ]] && ! grep -q '^hub\|^qop' "$T/calls.log" && grep -q "PLAN reflection: would queue $SLUG" "$T/out" &&
  grep -qx 'Spec: csi-spl-doc/specs/166-orchestrator-daily-rhythm' "$T/out" && [[ ! -e "$T/briefs/$SLUG.md" ]] &&
  pass "7. DRY_RUN=1: the gathered file and the brief, no ask, no queue op" || fail "7. dry: rc=$rc $(cat "$T/calls.log") $(cat "$T/out")"

# --- 8. not the holder's box --------------------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0 SPOOL_BOX_TAG=box-b
[[ $rc == 0 && ! -e "$T/reads" && ! -e "$T/stamp" ]] && grep -q 'is not on this box (box-b)' "$T/out" &&
  pass "8. not the dispatch holder's box: nothing" || fail "8. box: $(cat "$T/out")"

# --- 9. a reader that fails ---------------------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0 CI_FAIL=1
grep -q '^(not read: do_report_ci_gate failed: gh: no token)$' "$GF" 2>/dev/null && grep -q '^qop queue' "$T/calls.log" &&
  pass "9. a failed CI read is one (not read line; the lane is still queued" || fail "9. not read: $(cat "$GF" 2>/dev/null) $(cat "$T/out")"

# --- 9b. sections 3, 4 and 5 say why (SPL-5469) -----------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=1 ENDED_FAIL=1 OWNER_FAIL=1 SHARE_FAIL=1
grep -qxF '(not read: the diss issues were not listed: FATAL desk: cannot read <key>: permission denied)' "$GF" 2>/dev/null &&
  pass "9b. section 3: the diss read's stderr line, the key path masked" || fail "9b. section 3: $(grep -F 'not read' "$GF" 2>/dev/null) $(tail -3 "$T/out")"
L4="$(grep -F '(not read: the hub DB read failed: ' "$GF" 2>/dev/null)"
W4="psql: error: $(printf '%0250d' 0)"
[[ "$L4" == "(not read: the hub DB read failed: ${W4:0:200})" ]] &&
  pass "9b. section 4: the hub read's last stderr line, cut to 200 chars" || fail "9b. section 4: ${L4:-$(grep -F 'not read' "$GF" 2>/dev/null)}"
grep -qxF '(not read: do_spl_spawn_share failed: spool: no queue db under <state>/spawn-q in <home>)' "$GF" 2>/dev/null &&
  pass "9b. section 5: the share's stderr line, the state and home dirs masked" || fail "9b. section 5: $(grep -F 'not read' "$GF" 2>/dev/null)"
! grep -qF -e "$HOME" -e "$T/state" "$GF" 2>/dev/null && [[ -s "$GF" ]] &&
  pass "9b. no home or state dir in the gathered file" || fail "9b. a path leaked: $(grep -F -e "$HOME" -e "$T/state" "$GF" 2>/dev/null)"
reset; run "$NIGHT_NOW" DRY_RUN=1 ENDED_FAIL=2
grep -qxF '(not read: the diss issues were not listed: 💣 [FATAL] no desk for c-002 on box-a)' "$GF" 2>/dev/null &&
  pass "9b. section 3: a do_log FATAL on stdout (no stderr) is the reason, colours stripped" || fail "9b. stdout reason: $(grep -F 'not read' "$GF" 2>/dev/null | cat -v)"

# --- 10. no vendor fit for private data ---------------------------------------------
reset; run "$NIGHT_NOW" DRY_RUN=0 PICK=agy
[[ $rc != 0 && ! -e "$T/stamp" ]] && ! grep -q '^qop\|^hub' "$T/calls.log" && grep -q 'no vendor for private data' "$T/out" &&
  pass "10. the mix picks agy for private data: not queued, rc $rc, no stamp" || fail "10. vendor: rc=$rc $(cat "$T/out")"

# --- 11. the cron row ---------------------------------------------------------------
MF="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
CRON="$PROJ_ROOT/src/bash/scripts/reflection-cron.sh"
grep -qE '^reflection +\| \*/15 \* \* \* \* +\| src/bash/scripts/reflection-cron.sh +\| reflection/cron.log' "$MF" &&
  [[ "$(grep -nE '^(zombie-topics|reflection) ' "$MF" | cut -d: -f2 | cut -d' ' -f1 | tr '\n' ' ')" == "zombie-topics reflection " ]] &&
  pass "11. manifest row reflection runs reflection-cron.sh every 15 min, after zombie-topics" || fail "11. no manifest row"
[[ -x "$CRON" ]] && pass "11. the cron script is executable" || fail "11. $CRON not executable"
mkdir -p "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts"; cp "$CRON" "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/"
bash "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/reflection-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 2 ]] && grep -q 'agent worktree' "$T/cout" && pass "11. the cron script refuses an agent worktree (rc 2)" || fail "11. worktree: rc=$rc $(cat "$T/cout")"
O="$T/orc/csi-spl-orc"; mkdir -p "$O/src/bash/scripts"; cp "$CRON" "$O/src/bash/scripts/"
printf '#!/bin/bash\necho "reflection: DRY_RUN=$DRY_RUN $*"\n' >"$O/run"; chmod +x "$O/run"
echo REFLECTION_DRY_RUN=0 >>"$T/spool/dispatch/lease.conf"
SPOOL_ROOT="$T/spool" bash "$O/src/bash/scripts/reflection-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q 'reflection: DRY_RUN=0 -a do_spl_reflection_gather' "$T/cout" &&
  pass "11. REFLECTION_DRY_RUN=0 in lease.conf runs the action with DRY_RUN=0" || fail "11. lease knob: rc=$rc $(cat "$T/cout")"
SPOOL_ROOT="$T/no-spool" bash "$O/src/bash/scripts/reflection-cron.sh" >"$T/cout" 2>&1
grep -q 'reflection: DRY_RUN=1 ' "$T/cout" && pass "11. no lease knob: DRY_RUN=1" || fail "11. default dry: $(cat "$T/cout")"


# --- 14. section 1: fail-fast stops counted, not listed (SPL-5648) ----------------
FUNC="$PROJ_ROOT/src/bash/run/spl-reflection-gather.func.sh"
fn() { bash -c 'do_log() { :; }; source "$1"; shift; "$@"' _ "$FUNC" "$@"; }
cat >"$T/ci-ff.txt" <<'CI'
== failed runs, newest first
   9101  2026-01-15T10:00:00Z  abc1234  wui-e2e  || FAIL: a shard
   9101  2026-01-15T10:00:00Z  abc1234  iac-suite  || gate fail-fast: stopped, so the next gate run starts; red in this run: wui-e2e
   9101  2026-01-15T10:00:00Z  abc1234  api-suite  || gate fail-fast: stopped, so the next gate run starts; red in this run: wui-e2e
   8100  2026-01-10T10:00:00Z  abc0000  old-job  || gate fail-fast: stopped, so the next gate run starts; red in this run: x
== first red per JOB, over the 1 failed run(s)
CI
got="$(fn spl_reflection_ci_reds 2026-01-14T19:30:00Z 2026-01-15T19:30:00Z <"$T/ci-ff.txt")"
[[ "$got" == "- run 9101  2026-01-15T10:00:00Z  abc1234  wui-e2e  || FAIL: a shard
2 stopped by fail-fast, not listed" ]] &&
  pass "14. 1 red + 2 fail-fast stops in the window: the red listed, '2 stopped by fail-fast, not listed', the older stop not counted" ||
  fail "14. ci reds: $got"
got="$(grep -v 'FAIL: a shard' "$T/ci-ff.txt" | fn spl_reflection_ci_reds 2026-01-14T19:30:00Z 2026-01-15T19:30:00Z)"
[[ "$got" == "(none)
2 stopped by fail-fast, not listed" ]] && pass "14. only stops in the window: (none) and the count" || fail "14. stops only: $got"

# --- 15. section 3: who set each diss (SPL-5648) ----------------------------------
got="$(fn spl_reflection_ended 2026-01-14T19:30:00Z 2026-01-15T19:30:00Z <"$T/diss.json")"
grep -qxF -- '- SPL-902 ended diss 2026-01-15T13:00:00Z by HUM-10: set by the owner' <<<"$got" &&
  pass "15. the diss was the issue's last write: 'by HUM-10' (its updated_by)" || fail "15. actor: $got"
grep -qxF -- '- SPL-901 ended diss 2026-01-15T12:00:00Z: a lane dropped by its gate' <<<"$got" &&
  [[ "$(grep -c '^(no actor on 1 line' <<<"$got")" == 1 ]] && ! grep -q 'c-002' <<<"$got" &&
  pass "15. written after its diss: no 'by' (updated_by c-002 not guessed), the section says why once" || fail "15. no actor: $got"
reset; run "$NIGHT_NOW"
grep -qxF -- '- SPL-902 ended diss 2026-01-15T13:00:00Z by HUM-10: set by the owner' "$GF" 2>/dev/null &&
  grep -q '^(no actor on 1 line' "$GF" && pass "15. the gathered file carries the actor and the note" ||
  fail "15. gathered: $(sed -n '/^## 3/,/^## 4/p' "$GF" 2>/dev/null)"
got="$(printf '{"result":{"issues":[]}}' | fn spl_reflection_ended 2026-01-14T19:30:00Z 2026-01-15T19:30:00Z)"
[[ "$got" == "(none)" ]] && pass "15. no diss in the window: (none), no note" || fail "15. empty: $got"

# --- 16. section 7: the stalled wip issues (SPL-5825) ------------------------------
s7() { sed -n '/^## 7\. Stalled wip issues/,$p' "$GF" 2>/dev/null | grep -v '^#\|^$'; }
reset; run "$NIGHT_NOW"
want="- SPL-70: a shorter key (last commit none)
- SPL-701: ${LONG_TITLE:0:80} (last commit none)
- SPL-703: its last commit is 5 days old (last commit 2026-01-10)
- SPL-708: only a done ask names it (last commit none)
- SPL-709: only a done lane carries it (last commit none)"
got="$(s7)"
[[ "$got" == "$want" ]] &&
  pass "16. section 7 lists the wip issues with no live lane, no live ask and no commit in 72 h, title cut to 80, last commit or none" ||
  fail "16. stalled: got
$got
want
$want"
! grep -qE 'SPL-70[4567]' <<<"$got" &&
  pass "16. a commit 1 day old, a live lane (issue_key, branch slug spl706) and a queued ask keep an issue off the list" || fail "16. kept: $got"
# red control: the same issue with its live lane taken out of the lane map
jq -c --argjson l "$LANE_705" '.lanes -= [$l]' "$T/lanes.json" >"$T/lanes-no705.json"
reset; run "$NIGHT_NOW" LANES_JSON="$T/lanes-no705.json"
grep -qxF -- '- SPL-705: a live lane carries it (last commit none)' <<<"$(s7)" &&
  pass "16. red control: SPL-705 with its live lane out of the map is listed" || fail "16. red control: $(s7)"
echo '{"hub": "unreachable", "lanes": []}' >"$T/lanes-local.json"
reset; run "$NIGHT_NOW" LANES_JSON="$T/lanes-local.json"
got="$(s7)"
[[ "$got" == "(not read: the fleet lane map (do_spl_lane_map; LOCAL-ONLY is not read): hub: unreachable)" ]] &&
  pass "16. a lane map read LOCAL-ONLY: one (not read line, no issue line" || fail "16. local-only: $got"

# --- 16b. section 7 reads the commit body; a failed judge says so (b14-01) ---
git init -q "$T/b14" && git -C "$T/b14" -c user.name='FirstName LastName' -c user.email=dev@example.com \
  commit -q --allow-empty -m 'docs(orc): a change' -m 'Refs: SPL-7' && git -C "$T/b14" update-ref refs/remotes/origin/master HEAD
mkdir -p "$T/b14bin" && printf '#!/bin/sh\necho "a judge error" >&2\nexit 1\n' >"$T/b14bin/python3" && chmod +x "$T/b14bin/python3"
s7b() { REFLECTION_REPO="$T/b14" PATH="$1" bash -c 'do_log() { :; }; source "$0"
  spl_reflection_wip_read() { echo "{\"issues\":[{\"key\":\"SPL-7\",\"status\":\"wip\",\"title\":\"named in a body only\"}]}"; }
  spl_reflection_lanes_read() { echo "{\"hub\":\"ok\",\"lanes\":[]}"; }
  spl_reflection_asks_read() { echo "{\"hub\":\"ok\",\"asks\":[]}"; }
  spl_reflection_stalled "$(date +%s)" "$1"; echo "rc=$?"' "$FUNC" "$2"; }
got="$(s7b "$PATH" "$T/b14err")"
[[ "$got" == "(none)
rc=0" ]] && pass "16b. a key named only in a commit body inside 72 h: (none), not stalled" || fail "16b. body key: $got"
got="$(s7b "$T/b14bin:$PATH" "$T/b14err")"
[[ "$got" == "(not read: the judge failed: a judge error)
rc=0" ]] && pass "16b. the judge fails: one (not read: the judge failed: <its last stderr line>) line, rc 0" || fail "16b. judge failed: $got"

# --- 17. the brief lists the live origin topics, never the backlog alone (SPL-5829)
LIVE_OLD=44444444-0000-4000-8000-000000000004
LIVE_NEW=55555555-0000-4000-8000-000000000005
ARCH=66666666-0000-4000-8000-000000000006
UNREAD=77777777-0000-4000-8000-000000000007
RELAY=88888888-0000-5000-8000-000000000008
printf '%s\t%s\t%s\n' "$M1" "$LIVE_OLD" 2026-01-15T05:00:00Z "$M1" "$DISC" 2026-01-15T06:00:00Z "$M1" "$ARCH" 2026-01-15T07:00:00Z \
  "$M1" "$RELAY" 2026-01-15T08:00:00Z "$M1" "$UNREAD" 2026-01-15T09:00:00Z "$M2" "$LIVE_NEW" 2026-01-15T10:00:00Z \
  "$M2" "$LIVE_NEW" 2026-01-15T11:00:00Z >"$T/owner-origin.tsv"
cat >"$T/bin/archived" <<EOF2
#!/bin/bash
echo "\$1" >>"$T/archived.log"
case "\$1" in
  $ARCH) echo '{"lanes": [], "topic_archived_at": "2026-01-14T00:00:00Z"}' ;;
  $UNREAD) echo 'hub: 503' ;;
  *) echo '{"lanes": []}' ;;
esac
EOF2
chmod +x "$T/bin/archived"
# origin_of BRIEF: the uuids of its "## Origin topics" section other than the
# backlog topic, the discussions a lane's issue may link besides the fallback.
origin_of() { sed -n '/^## Origin topics$/,/^## /p' "$1" | grep -oE '^- [0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' | cut -c3- | grep -vx "$DISC" | tr '\n' ' '; }
cp "$T/owner.tsv" "$T/owner.keep"; cp "$T/owner-origin.tsv" "$T/owner.tsv"
reset; rm -f "$T/archived.log"; run "$NIGHT_NOW" DRY_RUN=0 SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived"
B="$T/briefs/$SLUG.md"
[[ $rc == 0 && "$(origin_of "$B")" == "$LIVE_NEW $LIVE_OLD " ]] && grep -qx "Discussion: $DISC" "$B" &&
  pass "17. the brief lists the live origin topics newest first, once each; the backlog, an archived, an unread and a relay-hash topic are left out" ||
  fail "17. origin topics: rc=$rc '$(origin_of "$B")' $(sed -n '/^## Origin topics$/,/^## Do$/p' "$B" 2>/dev/null) $(tail -3 "$T/out")"
! grep -qx "$RELAY" "$T/archived.log" 2>/dev/null && ! grep -qx "$DISC" "$T/archived.log" 2>/dev/null &&
  pass "17. the backlog and a relay hash are not even read for their archive state" || fail "17. archive reads: $(cat "$T/archived.log")"
grep -qx "(not read: 1 topic(s) whose archive state was not read (no answer, or past the cap of 20 reads): left out)" "$B" &&
  pass "17. an unread archive state is one (not read line even when topics are listed (R7 c-168 W2)" || fail "17. unread line: $(sed -n '/^## Origin topics$/,/^## Do$/p' "$B" 2>/dev/null)"
grep -q "Never \`$DISC\` alone" "$B" && grep -q 'spool issue link --ref <your key> --discussion <topic>' "$B" &&
  pass "17. the brief binds each row to its own topic, never the backlog alone, and the lane to link its origin topics" || fail "17. row rule missing"
# W1 (R7 c-168): the row lines the brief asks for set the row lane's issue
# topic (spl_lane_issue_topic, the placer's issue step) and its lane-map
# discussion (li_discussion_from_brief). row_brief LINES: a holder-placed
# row brief, its heading, the given lines, then a prose line naming another topic.
FUNC="$PROJ_ROOT/src/bash/run/spl-reflection-gather.func.sh"
issue_topic_of() { bash -c "$(sed -n '/^spl_lane_issue_topic()/,/^}/p' "$PROJ_ROOT/src/bash/run/spl-lane-issue.func.sh")"'
  spl_lane_issue_topic "$1"' _ "$1"; }
row_brief() { { echo "# Lane brief: bug - a row"; printf '%s\n' "$1"; echo "Class: bug"; echo "Placed from the owner's topic $LIVE_OLD (prose)."; } >"$T/row.md"; }
rows="$(sed -n '/^   Topic: <topic uuid>$/,/^   Discussion: <topic uuid>$/p' "$B" | sed -E "s/^ +//; s/<topic uuid>/$LIVE_NEW/")"
row_brief "$rows"
[[ "$(wc -l <<<"$rows")" == 2 && "$(issue_topic_of "$T/row.md")" == "$LIVE_NEW" && "$(disc_of "$T/row.md")" == "$LIVE_NEW" ]] &&
  pass "17. a row brief with the brief's two row lines files its issue on the origin topic and maps its lane to it" ||
  fail "17. row lines: '$rows' issue topic '$(issue_topic_of "$T/row.md")' discussion '$(disc_of "$T/row.md")'"
row_brief "Discussion: $LIVE_NEW"
[[ "$(issue_topic_of "$T/row.md")" != "$LIVE_NEW" ]] &&
  pass "17. red control (8718b4168's ask, a Discussion: line only): the issue step does not take it ('$(issue_topic_of "$T/row.md")')" ||
  fail "17. red control did not go red: a Discussion: line alone set the issue topic"
# red control: master's template (no Origin topics section) names no origin
# topic, so a lane on it links only the backlog
sed '/^## Origin topics$/,/^## Do$/{/^## Do$/!d}' "$TPL" >"$T/master.tpl.md"
reset; run "$NIGHT_NOW" DRY_RUN=0 SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived" REFLECTION_TPL="$T/master.tpl.md"
[[ -s "$T/master.tpl.md" && -z "$(origin_of "$T/briefs/$SLUG.md")" ]] && [[ "$(disc_of "$T/briefs/$SLUG.md")" == "$DISC" ]] &&
  pass "17. red control: master's template names no origin topic, only the backlog $DISC" || fail "17. red control did not go red: '$(origin_of "$T/briefs/$SLUG.md")'"
# no live owner topic in the night: one (none line, the fallback stays
printf '%s\t%s\t%s\n' "$M1" "$DISC" 2026-01-15T06:00:00Z "$M1" "$ARCH" 2026-01-15T07:00:00Z >"$T/owner.tsv"
reset; run "$NIGHT_NOW" DRY_RUN=0 SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived"
[[ $rc == 0 && -z "$(origin_of "$T/briefs/$SLUG.md")" ]] && grep -qx '(none: no owner message of the night is in a live topic other than the backlog; 1 archived)' "$T/briefs/$SLUG.md" &&
  ! grep -q '^(not read: ' <(sed -n '/^## Origin topics$/,/^## Do$/p' "$T/briefs/$SLUG.md") &&
  pass "17. no live owner topic: one (none line, the lane still queued on the fallback" || fail "17. none: rc=$rc $(sed -n '/^## Origin topics$/,/^## Do$/p' "$T/briefs/$SLUG.md" 2>/dev/null)"
# N1: at most REFLECTION_ORIGIN_MAX archive reads; the rest is counted unread
cp "$T/owner-origin.tsv" "$T/owner.tsv"
reset; rm -f "$T/archived.log"; run "$NIGHT_NOW" DRY_RUN=0 SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived" REFLECTION_ORIGIN_MAX=1
[[ "$(origin_of "$T/briefs/$SLUG.md")" == "$LIVE_NEW " && "$(wc -l <"$T/archived.log")" == 1 ]] &&
  grep -qx '(not read: 3 topic(s) whose archive state was not read (no answer, or past the cap of 1 reads): left out)' "$T/briefs/$SLUG.md" &&
  pass "17. REFLECTION_ORIGIN_MAX=1: one archive read, the newest live topic listed, the rest counted not read" ||
  fail "17. cap: '$(origin_of "$T/briefs/$SLUG.md")' reads $(wc -l <"$T/archived.log" 2>/dev/null) $(grep '^(not read' "$T/briefs/$SLUG.md")"
cp "$T/owner.keep" "$T/owner.tsv"

# --- 18. section 6: the zombie log under SPL_VAR_APP_DIR (r65-01) -------------------
mkdir -p "$T/v/zombie-topics" "$T/b/csi/csi-spl/.git" "$T/var/csi/csi-spl/zombie-topics"
echo "2026-01-15T19:02:00Z OK zombie sweep, night of 2026-01-15 (v): 1 candidate(s)" >"$T/v/zombie-topics/cron.log"
echo "2026-01-15T19:03:00Z OK zombie sweep, night of 2026-01-15 (tree): 2 candidate(s)" >"$T/var/csi/csi-spl/zombie-topics/cron.log"
s6() { env -u REFLECTION_ZOMBIE_LOG -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR -u SPL_RUN_PATHS_TOP "$@" \
  bash -c 'do_log() { :; }; source "$0"; spl_reflection_zombie' "$FUNC" 2>&1; }
got="$(s6 SPL_VAR_APP_DIR="$T/v")"
[[ "$got" == *"night of 2026-01-15 (v): 1 candidate(s)" ]] &&
  pass "18. REFLECTION_ZOMBIE_LOG unset: section 6 reads \$SPL_VAR_APP_DIR/zombie-topics/cron.log" || fail "18. SPL_VAR_APP_DIR: $got"
got="$(s6 SPL_RUN_PATHS_TOP="$T/b/csi/csi-spl")"
[[ "$got" == *"night of 2026-01-15 (tree): 2 candidate(s)" ]] &&
  pass "18. derived from the tree: <base>/../var/<org>/<app>/zombie-topics/cron.log" || fail "18. tree: $got"
got="$(s6 SPL_VAR_APP_DIR="$T/v" REFLECTION_ZOMBIE_LOG="$T/zombie.log")"
[[ "$got" == *"night of 2026-01-15 (DRY_RUN=1, cap 500, idle 7 d)"* ]] &&
  pass "18. REFLECTION_ZOMBIE_LOG set: the override wins" || fail "18. override: $got"
got="$(s6 SPL_RUN_PATHS_TOP=)"
[[ "$got" == "(not read: no zombie sweep log: REFLECTION_ZOMBIE_LOG unset and no SPL_VAR_APP_DIR derived)" ]] &&
  pass "18. no override and no tree: one (not read line naming REFLECTION_ZOMBIE_LOG" || fail "18. no dir: $got"
# r72-02: the derive runs in a $( ): no SPL_* export of spl_run_paths reaches the gather's shell
got="$(env -u REFLECTION_ZOMBIE_LOG -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR -u SPL_WT_ROOT SPL_RUN_PATHS_TOP="$T/b/csi/csi-spl" \
  bash -c 'do_log() { :; }; source "$0"; spl_reflection_zombie >/dev/null; printf "%s" "${SPL_WT_ROOT-unset}"' "$FUNC" 2>&1)"
[[ "$got" == unset ]] &&
  pass "18. derived from the tree, SPL_WT_ROOT unset before: still unset in the caller after" || fail "18. no-leak: SPL_WT_ROOT=$got"

# --- 19. the brief fits the start budget on a busy night (SPL-6633) ---------------
EST="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/brief-token-estimate.sh"
printf '%*s' 10180 '' | tr ' ' s >"$T/seed.txt"
B="$T/briefs/$SLUG.md"
est() { env -u SPOOL_BRIEF_TOKEN_BUDGET bash "$EST" "$T/seed.txt" "$B" >"$T/est" 2>&1; }
pasted() { sed -n '/^## The gathered file$/,$p' "$B" | tail -n +3; }
cp "$T/owner.tsv" "$T/owner.keep"; cp "$T/ci.txt" "$T/ci.keep"
reset; run "$NIGHT_NOW" DRY_RUN=0 SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived"; est; erc=$?
[[ $rc == 0 && $erc == 0 ]] && diff <(pasted) <(sed 's/^#/###/' "$GF") >/dev/null &&
  pass "19. quiet night: the gathered file pasted byte for byte as before; the brief is $(wc -c <"$B") B, seed + brief pass the estimate ($(cat "$T/est"))" ||
  fail "19. quiet: rc=$rc est=$erc $(cat "$T/est") $(diff <(pasted) <(sed 's/^#/###/' "$GF") | sed -n 1,5p)"
# owner_tsv N TOPICS: N owner msgs spread over TOPICS live topics, one minute apart
owner_tsv() { local i; for ((i = 0; i < $1; i++)); do
  printf '%08x-0000-4000-8000-%012x\t%08x-0000-4000-9000-%012x\t2026-01-15T%02d:%02d:00Z\n' "$i" "$i" "$((i % $2))" "$((i % $2))" "$((i / 60 % 24))" "$((i % 60))"
done >"$T/owner.tsv"; }
busy_ci() { local i; { sed -n '1,2p' "$T/ci.keep"; for ((i = 0; i < 60; i++)); do
  printf '   %d  2026-01-15T%02d:00:00Z  abc%04d  job-%d  || FAIL: %0180d\n' "$((9100 + i))" "$((i % 18))" "$i" "$i" 0; done; } >"$T/ci.txt"; }
for case in grouped capped; do
  if [[ $case == grouped ]]; then owner_tsv 500 60; cp "$T/ci.keep" "$T/ci.txt"; else owner_tsv 400 400; busy_ci; fi
  reset; run "$NIGHT_NOW" DRY_RUN=0 SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived"; est; erc=$?
  whole="$(grep -c "^- msg " "$GF" 2>/dev/null)"
  if [[ $case == grouped ]]; then
    ok() { grep -qxF "(500 owner msg id(s) in 60 topic(s), grouped per topic to fit the brief: read each topic's owner messages of the window with \`spool tail --task <topic>\` on the hub)" "$B" &&
      [[ "$(pasted | grep -c '^- topic .*: [0-9]* owner msg(s), ')" == 60 ]] && ! pasted | grep 'not pasted' >/dev/null; }
  else
    ok() { [[ "$(pasted | grep -c '^- topic ')" -lt 400 ]] && grep -qE "^\([0-9]+ more line\(s\) not pasted, to fit the brief: the whole list is in $GF on the queuing box\)$" "$B" &&
      [[ "$(pasted | sed -n '/^#### 1\./,/^#### 2\./p' | grep -c '^- run ')" -lt 60 ]]; }
  fi
  [[ $rc == 0 && $erc == 0 && "$whole" == "$(wc -l <"$T/owner.tsv")" ]] && ok &&
    pass "19. busy night ($case): the brief is $(wc -c <"$B") B, seed + brief pass the estimate ($(cat "$T/est")); the gathered file keeps all $whole msg lines" ||
    fail "19. busy $case: rc=$rc est=$erc whole=$whole $(cat "$T/est") $(pasted | sed -n 1,20p)"
  reset; run "$NIGHT_NOW" DRY_RUN=0 SPAWN_PLACE_ARCHIVED_CMD="$T/bin/archived" REFLECTION_BRIEF_GATHER_BYTES=100000000; est; erc=$?
  [[ $rc == 0 && $erc == 3 ]] && grep -q '^FATAL brief-token-estimate: seed + brief estimate [0-9]* tokens .* is over the budget 16000 tokens' "$T/est" &&
    pass "19. red control ($case): the old paste-all, $(wc -c <"$B") B, fails the estimate (rc 3)" ||
    fail "19. red control ($case) did not go red: rc=$rc est=$erc $(cat "$T/est")"
done
cp "$T/owner.keep" "$T/owner.tsv"; cp "$T/ci.keep" "$T/ci.txt"

# --- 20. section 2: a revert by its subject, never a body line (SPL-6639) ----------
R2="$T/repo-rev"
git init -q -b master "$R2"
at2() { GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" git -C "$R2" -c user.name='FirstName LastName' \
  -c user.email=dev@example.com commit -q --allow-empty -m "$2" -m "${3:-}"; }
at2 2026-01-15T08:00:00Z 'feat(x): a thing'
at2 2026-01-15T09:00:00Z 'Revert "feat(x): a thing"' 'This reverts commit 0000000.'
REAL_REV="$(git -C "$R2" rev-parse --short HEAD)"
at2 2026-01-15T10:00:00Z 'feat(api, SPL-6568): a body line starts with Revert' 'Reverted: postgres PASS, memory PASS.'
BODY_REV="$(git -C "$R2" rev-parse --short HEAD)"
s2() { REFLECTION_REPO="$R2" REFLECTION_REF=master REFLECTION_FETCH=0 \
  bash -c 'do_log() { :; }; source "$0"; spl_reflection_reverts 2026-01-15T00:00:00Z 2026-01-16T00:00:00Z' "$1" 2>&1; }
got="$(s2 "$FUNC")"
[[ "$(wc -l <<<"$got")" == 1 && "$got" == "- $REAL_REV 2026-01-15T09:00:00Z Revert \"feat(x): a thing\"" ]] &&
  pass "20. a real revert and a body 'Reverted:' line: exactly the revert listed" || fail "20. reverts: $got"
got="$(REFLECTION_REPO="$R2" REFLECTION_REF=master REFLECTION_FETCH=0 \
  bash -c 'do_log() { :; }; source "$0"; spl_reflection_reverts 2026-01-16T00:00:00Z 2026-01-17T00:00:00Z' "$FUNC" 2>&1)"
[[ "$got" == "(none)" ]] && pass "20. no commit in the window: (none)" || fail "20. empty: $got"
sed -e "s|--until=\"\$2\" --format=|--until=\"\$2\" --grep='^Revert' --format=|" -e "/^  out=\"\$(awk '\$4 ~ \/^Revert\/'/d" \
  "$FUNC" >"$T/reverts-old.func.sh"
got="$(s2 "$T/reverts-old.func.sh")"
grep -q -- "--grep='^Revert'" "$T/reverts-old.func.sh" && grep -q "^- $BODY_REV " <<<"$got" && grep -q "^- $REAL_REV " <<<"$got" &&
  pass "20. red control: master's --grep='^Revert' lists both, the body line too" || fail "20. red control: $got"

# --- 13. the owner SQL on a REAL Postgres: an admin owner listed, a tester not ------
# (SPL-5460: prd t1's owner holds role admin, not owner; the old role = 'owner'
# join listed nobody.) The real rdb migrations, the runtime login (RLS binds).
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1 || ! command -v psql >/dev/null; then
  echo "SKIP 13: no cached $PG_IMAGE image or no psql; the owner SQL is not run"
else
  export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
  # shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
  source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
  spl_export_go_path || fail "13. no go toolchain"
  BIN="$T/spool-bin"
  (cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || fail "13. spool build"
  PG_CTR="spl-reflection-pg-$$"
  trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
  docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
    -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
  # shellcheck source=pg-throwaway.inc.sh
  source "$TEST_DIR/pg-throwaway.inc.sh"
  PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
  for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
  OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
  RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
  q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
  "$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || fail "13. migrate"
  q -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
  q -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || fail "13. grants"
  q -c "INSERT INTO humans (human_id) VALUES ('HUM-10'), ('HUM-5'), ('HUM-51'), ('HUM-46')" >/dev/null
  q -c "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', decode(repeat('ab', 32), 'hex')), ('t2', decode(repeat('ac', 32), 'hex'))" >/dev/null
  q -c "INSERT INTO tenant_memberships (tenant_id, human_id, role, admitted_by) VALUES
     ('t1', 'HUM-10', 'admin', 'operator'), ('t1', 'HUM-5', 'biz_owner', 'operator'),
     ('t1', 'HUM-51', 'tester', 'operator'), ('t1', 'HUM-46', 'developer', 'operator'),
     ('t2', 'HUM-10', 'admin', 'operator')" >/dev/null || fail "13. seed memberships"
  # pm <tenant> <msg n> <from> <hours ago>
  pm() { q -c "INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
    VALUES ('$1', '20000000-0000-4000-8000-00000000000$2', '00000000-0000-4000-8000-00000000000$2', now(), 'box-wui', '$3', 'box-wui', 'c-001', 'note', 'b',
            '{}'::jsonb, 'sig', '\x00', now() - interval '$4 hours', now() + interval '60 days')" >/dev/null || fail "13. seed msg $2"; }
  pm t1 1 HUM-10 2    # listed: the owner, role admin
  pm t1 2 HUM-5 3     # listed: a biz_owner (tenant_owner)
  pm t1 3 HUM-51 1    # control: a tester
  pm t1 4 HUM-46 1    # control: a developer
  pm t1 5 HUM-10 30   # control: the owner, before the window
  pm t2 6 HUM-10 1    # control: the owner in another workspace
  now="$(date -u +%s)"
  got="$(env FUNC="$FUNC" PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="$RT_DSN" bash -c '
    set -uo pipefail; do_log() { :; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"; source "$FUNC"
    spl_reflection_owner_sql t1 "$1" "$2"' _ "$((now - 86400))" "$((now + 60))" 2>"$T/pgerr" | cut -f1 | sed 's/20000000-0000-4000-8000-00000000000//' | tr '
' ' ')"
  [[ "$got" == "2 1 " ]] &&
    pass "13. on Postgres as the runtime login: the owner with role admin and a biz_owner are listed; a tester, a developer, an older post and another workspace are not" ||
    fail "13. owner sql: got='$got' $(cat "$T/pgerr")"
  # red control: the pre-fix predicate (role = 'owner') lists nobody on the same rows.
  old="$(sed -n '/^spl_reflection_owner_sql()/,/^}/p' "$FUNC" | sed -n '/^SELECT/,/^ ORDER/p' |
    sed -e '/AND EXISTS/,/tenant_owner OR/d' -e "s|^  FROM messages m|  FROM messages m JOIN tenant_memberships tm ON tm.tenant_id = m.tenant_id AND tm.human_id = m.from_id AND tm.role = 'owner'|")"
  red="$(PGPASSWORD=rt psql -X -q -At "$RT_DSN" -v t=t1 -v since="$((now - 86400))" -v until="$((now + 60))" <<SQL 2>&1
BEGIN; SET LOCAL app.rls_scope = 'operator';
$old;
ROLLBACK;
SQL
)"
  grep -q "tm.role = 'owner'" <<<"$old" && [[ -z "$red" ]] &&
    pass "13. red control: the old role = 'owner' join lists nobody on the same rows" || fail "13. red control: '$red' sql: $old"
fi

echo "---"
[[ $fails == 0 ]] && echo "spl-reflection-gather: all passed" || echo "spl-reflection-gather: $fails FAILED"
exit $((fails > 0))
