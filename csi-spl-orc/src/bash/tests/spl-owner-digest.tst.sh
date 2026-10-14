#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the needs-owner label (do_spl_issue_needs_owner) and the daily owner
#          digest (do_spl_owner_digest_post), t1 topic fda34661. The hub is
#          never called: the issue read, the writes, the list and the post are
#          stubbed functions that record what they were given.
#   needs-owner
#     1. an eval issue -> + needs-owner, blocked, one "Needs owner since" line
#     2. re-marking keeps the first "since" and replaces the step
#     3. qas keeps qas (waiting for the owner's acceptance)
#     4. a done issue is refused
#     5. clear drops the label and the line, the status stays
#     6. nothing to change -> no write
#     7. DRY_RUN=1 reads and plans, writes nothing
#     8. DRY_RUN=0 ensures the label, then one update with labels/status/description
#     9. OWNER_STEP missing or multi-line is refused
#   digest
#    10. render: oldest first, waited, link, step; no line -> says so; done left out
#    11. render: nothing labelled -> empty (no post)
#    12. the holder on another box -> no list, no post
#    13. not the cnf hour -> no post
#    14. the hour, DRY_RUN=0 -> ONE note post into the cnf channel as the holder, stamp
#    15. the same day again -> no post
#    16. nothing waiting -> no post, the day is stamped
#    17. DRY_RUN=1 prints the post, sends nothing, no stamp
#    18. CONTROL: the stamp is what stops the second post
#   form (owner HUM-10 msg 03d0ef42, how-to-post.md rule 10)
#    19. the digest ends with ONE ```poll form: Go / Hold / No go per item with a step
#    20. poll.mjs (the WUI's own parser, through node) accepts it as a radio form
#    21. CONTROL: prose options and no poll block fail the same check
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }
has() { grep -qF -- "$2" <<<"$3" && pass "$1" || fail "$1" "no '$2' in: $3"; }

do_log() { echo "$*"; }
# shellcheck source=../../../lib/bash/funcs/spl-desk-issue.func.sh
. "$PROJ_ROOT/lib/bash/funcs/spl-desk-issue.func.sh"
# shellcheck source=../run/spl-issue-update.func.sh
. "$PROJ_ROOT/src/bash/run/spl-issue-update.func.sh"
# shellcheck source=../run/spl-issue-list.func.sh
. "$PROJ_ROOT/src/bash/run/spl-issue-list.func.sh"
# shellcheck source=../run/spl-issue-needs-owner.func.sh
. "$PROJ_ROOT/src/bash/run/spl-issue-needs-owner.func.sh"
# shellcheck source=../run/spl-owner-digest-post.func.sh
. "$PROJ_ROOT/src/bash/run/spl-owner-digest-post.func.sh"
spl_dry_run() { local d="${DRY_RUN:-1}"; [[ "$d" == 0 || "$d" == 1 ]] || return 2; [[ "$d" == 1 ]]; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CALLS="$T/calls"; : >"$CALLS"

# --- needs-owner stubs: the issue the hub "holds" is $T/issue.json ---
issue() {  # status labels-json description
  python3 -c 'import json,sys; print(json.dumps({"result":{"issue":{"key":"SPL-7","status":sys.argv[1],"labels":json.loads(sys.argv[2]),"description":sys.argv[3]}}}))' "$@" >"$T/issue.json"
}
spl_desk_issue_run() { echo "run $*" >>"$CALLS"; cat "$T/issue.json"; }
spl_desk_issue() { echo "issue $*" >>"$CALLS"; }
spl_desk_issue_once() { :; }
do_spl_issue_update() {
  { echo "update labels=[$ISSUE_LABELS] status=$ISSUE_STATUS"; cat "$ISSUE_DESCRIPTION_FILE"; } >"$T/update"
  echo "update" >>"$CALLS"
}
mark() { : >"$CALLS"; rm -f "$T/update"; ( unset ISSUE_STATUS OWNER_STEP OWNER_STEP_CLEAR; local kv; for kv in "$@"; do export "${kv?}"; done; export ISSUE_REF=SPL-7; do_spl_issue_needs_owner 2>&1 ); }
STEP='`cd csi-spl-orc && ENV=prd STEP=030-cloud-run-hub make do-provision`'

# 1
issue eval '["task"]' 'Spec text.'
out="$(mark DRY_RUN=0 OWNER_STEP="$STEP")"
has "1. labels gain needs-owner" "labels=[task,needs-owner] status=blocked" "$(head -1 "$T/update" 2>/dev/null)"
has "1. the description keeps its text" "Spec text." "$(cat "$T/update")"
grep -qE "^\*\*Needs owner\*\* since 20[0-9-]{8}T[0-9:]{8}Z: \`cd csi-spl-orc" "$T/update" && pass "1. one Needs-owner line with since" || fail "1. line" "$(cat "$T/update")"

# 2
issue blocked '["task","needs-owner"]' $'Spec text.\n\n**Needs owner** since 2026-09-26T09:59:05Z: old step'
mark DRY_RUN=0 OWNER_STEP='new step' >/dev/null
has "2. the first since is kept" "**Needs owner** since 2026-09-26T09:59:05Z: new step" "$(cat "$T/update")"
eq "2. still one line" 1 "$(grep -c 'Needs owner' "$T/update")"
has "2. no duplicate label" "labels=[task,needs-owner] status=blocked" "$(head -1 "$T/update")"

# 3
issue qas '[]' ''
mark DRY_RUN=0 OWNER_STEP='accept it in /issues' >/dev/null
has "3. qas stays qas" "labels=[needs-owner] status=qas" "$(head -1 "$T/update")"

# 4
issue 'done' '[]' 'x'
out="$(mark DRY_RUN=0 OWNER_STEP='x')"; rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$T/update" ] && pass "4. a done issue is refused" || fail "4. done refused" "rc $rc: $out"

# 5
issue blocked '["bug","needs-owner"]' $'Body.\n\n**Needs owner** since 2026-09-26T09:59:05Z: step'
mark DRY_RUN=0 OWNER_STEP_CLEAR=1 >/dev/null
has "5. clear drops the label, keeps the status" "labels=[bug] status=blocked" "$(head -1 "$T/update")"
eq "5. ... and the line" 0 "$(grep -c 'Needs owner' "$T/update")"

# 6
issue blocked '["needs-owner"]' '**Needs owner** since 2026-09-26T09:59:05Z: same step'
out="$(mark DRY_RUN=0 OWNER_STEP='same step')"
[ ! -f "$T/update" ] && grep -q "nothing to change" <<<"$out" && pass "6. unchanged -> no write" || fail "6. unchanged" "$out"

# 7
issue eval '[]' 'Body.'
out="$(mark DRY_RUN=1 OWNER_STEP='x')"
[ ! -f "$T/update" ] && grep -q "^run get --ref SPL-7" "$CALLS" && ! grep -q "^issue label" "$CALLS" && grep -q "^PLAN SPL-7" <<<"$out" \
  && pass "7. DRY_RUN=1 reads and plans only" || fail "7. dry run" "$out / $(cat "$CALLS")"

# 8
mark DRY_RUN=0 OWNER_STEP='x' >/dev/null
eq "8. DRY_RUN=0: get, label, update in that order" "run get --ref SPL-7|issue label --name needs-owner --color #b45309|update" "$(paste -sd'|' "$CALLS")"

# 9
out="$(mark DRY_RUN=0 OWNER_STEP='')"; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$CALLS" ] && pass "9. empty OWNER_STEP refused before any read" || fail "9. empty step" "$out"
out="$(mark DRY_RUN=0 OWNER_STEP=$'a\nb')"; rc=$?
[ "$rc" -ne 0 ] && [ ! -s "$CALLS" ] && pass "9. multi-line OWNER_STEP refused" || fail "9. multi-line" "$out"

# --- digest ---
NOW=$(date -u -d 2026-10-12T06:30:00Z +%s)   # 09:30 in Europe/Helsinki (EEST)
cat >"$T/list.json" <<'EOF'
{"result":{"issues":[
 {"key":"SPL-1126","title":"Perf P3: hub startup probe","status":"blocked","labels":["needs-owner"],"updated_at":"2026-10-12T05:00:00Z",
  "description":"x\n\n**Needs owner** since 2026-10-10T06:30:00Z: `make do-provision`"},
 {"key":"SPL-595","title":"Owner: Azure app","status":"blocked","labels":["task","needs-owner"],"updated_at":"2026-10-12T05:00:00Z",
  "description":"**Needs owner** since 2026-09-26T09:59:05Z: register the Azure app"},
 {"key":"SPL-2","title":"Live proof","status":"qas","labels":["needs-owner"],"updated_at":"2026-10-12T04:30:00Z","description":"none"},
 {"key":"SPL-9","title":"closed","status":"done","labels":["needs-owner"],"updated_at":"2026-01-01T00:00:00Z","description":""}
]}}
EOF
body="$(spl_owner_digest_render "$T/list.json" "$NOW" needs-owner)"
eq "10. three open items, oldest first" "SPL-595 SPL-1126 SPL-2" "$(grep -oE '^[0-9]+\. \[SPL-[0-9]+\]' <<<"$body" | grep -oE 'SPL-[0-9]+' | paste -sd' ')"
has "10. the waited time and since" "waiting **15 d** (since 2026-09-26T09:59:05Z)" "$body"
has "10. a same-site issue link" "[SPL-1126](/issues?issue=SPL-1126)" "$body"
has "10. the step" "  Step: \`make do-provision\`" "$body"
has "10. an item with no line says so" "no step written in the issue yet" "$body"
has "10. hours under a day" "SPL-2](/issues?issue=SPL-2) Live proof - waiting **2 h**" "$body"
has "10. the header counts" "## Waiting for you: 3 step(s)" "$body"

echo '{"result":{"issues":[]}}' >"$T/empty.json"
eq "11. nothing labelled -> empty" "" "$(spl_owner_digest_render "$T/empty.json" "$NOW" needs-owner)"

ROOT="$T/spool"; mkdir -p "$ROOT/dispatch"
echo "SPOOL_BOX_TAG=box-a" >"$ROOT/box.env"
printf 'LEASE_ENV=prd\nLEASE_TENANT=t1\n' >"$ROOT/dispatch/lease.conf"
cat >"$T/cnf.yaml" <<'EOF'
env:
  owner_digest:
    hour: 9
    timezone: Europe/Helsinki
    channel: spool-hub-devel
EOF
do_spl_desk_cnf() { export SPL_CNF="$T/cnf.yaml"; }
LIST="$T/list.json"
list_stub() { echo "list $*" >>"$CALLS"; cat "$LIST"; }
post_stub() { echo "post $DESK_AGENT $DESK_CHANNEL $DESK_KIND $ENV $TENANT_ID" >>"$CALLS"; cp "$DESK_BODY_FILE" "$T/posted"; }
digest() {
  : >"$CALLS"
  env -u ENV -u TENANT_ID -u DESK_AGENT SPOOL_ROOT="$ROOT" OWNER_DIGEST_STATE="$T/stamp" OWNER_DIGEST_LIST_FN=list_stub \
    OWNER_DIGEST_POST_FN=post_stub OWNER_DIGEST_NOW="${2:-$NOW}" DRY_RUN="$1" bash -c "$(declare -f); $(declare -p T CALLS LIST); do_spl_owner_digest_post" 2>&1
}

echo "c-002@box-b 1791827665" >"$ROOT/dispatch/lease"
out="$(digest 0)"
[ ! -s "$CALLS" ] && grep -q "not on this box" <<<"$out" && pass "12. holder on another box -> nothing" || fail "12. other box" "$out"

echo "c-002@box-a 1791827665" >"$ROOT/dispatch/lease"
out="$(digest 0 "$((NOW - 3600))")"
[ ! -s "$CALLS" ] && grep -q "not the hour" <<<"$out" && pass "13. not the hour -> nothing" || fail "13. hour" "$out"

out="$(digest 0)"
eq "14. one list and one note post as the holder into the cnf channel" "list --label needs-owner --status eval,todo,wip,blocked,onhold,qas --limit 500|post c-002 spool-hub-devel note prd t1" "$(paste -sd'|' "$CALLS")"
eq "14. the post is the rendered digest" "$body" "$(cat "$T/posted")"
eq "14. the day is stamped (box timezone)" "2026-10-12" "$(cat "$T/stamp" 2>/dev/null)"

out="$(digest 0 "$((NOW + 600))")"
[ ! -s "$CALLS" ] && grep -q "already ran on 2026-10-12" <<<"$out" && pass "15. the same day again -> nothing" || fail "15. same day" "$out"

rm -f "$T/stamp"; LIST="$T/empty.json"
out="$(digest 0)"
eq "16. nothing waiting -> a list, no post" "list" "$(cut -d' ' -f1 "$CALLS" | paste -sd'|')"
eq "16. ... and the day is stamped" "2026-10-12" "$(cat "$T/stamp" 2>/dev/null)"

rm -f "$T/stamp"; LIST="$T/list.json"
out="$(digest 1)"
! grep -q "^post" "$CALLS" && [ ! -f "$T/stamp" ] && grep -q "PLAN owner-digest: 3 item(s), as c-002 into #spool-hub-devel" <<<"$out" \
  && pass "17. DRY_RUN=1 prints, sends nothing, no stamp" || fail "17. dry run" "$out"

# 18. CONTROL: without the stamp the second run of the day posts again
digest 0 >/dev/null; rm -f "$T/stamp"; digest 0 >/dev/null
eq "18. CONTROL: no stamp -> a second post (the stamp is the guard)" 1 "$(grep -c '^post' "$CALLS")"

# --- the form: every question to the owner is a poll (msg 03d0ef42) ---
POLL_MJS="$PROJ_ROOT/../csi-spl-wui/src/utils/poll.mjs"
# poll_form <body>: "<questions> <keys of each>" of the body's ONE form, or "none"
poll_form() {
  if command -v node >/dev/null 2>&1 && [ -f "$POLL_MJS" ]; then
    node --input-type=module -e '
      const { splitPolls } = await import(process.argv[1])
      const p = splitPolls(process.argv[2]).filter((s) => s.type === "poll")
      if (p.length !== 1 || p[0].poll.multi) { console.log("none"); process.exit(0) }
      const q = p[0].poll.questions
      console.log(`${q.length} ${q.map((x) => x.options.map((o) => o.key).join(",")).join(" ")}`)
    ' "$POLL_MJS" "$1"
  else
    # no node on this runner: the exact marker lines
    local n; n="$(grep -c '^(GO) Go$' <<<"$1")"
    grep -qx '```poll' <<<"$1" && [ "$n" -gt 0 ] && [ "$n" = "$(grep -c '^(HLD) Hold$' <<<"$1")" ] &&
      [ "$n" = "$(grep -c '^(NO) No go$' <<<"$1")" ] && echo "$n$(for ((i = 0; i < n; i++)); do printf " GO,HLD,NO"; done)" || echo none
  fi
}

# 19
eq "19. one form, one question per item with a step (SPL-2 has none)" "SPL-595: register the Azure app|SPL-1126: \`make do-provision\`" \
  "$(sed -n '/^```poll$/,/^```$/p' <<<"$body" | grep -E '^SPL-' | paste -sd'|')"
eq "19. the form comes after the list" "1" "$(grep -c '^```poll$' <<<"$body")"
has "19. the list text is kept" "  Step: \`make do-provision\`" "$body"

# 20
eq "20. poll.mjs accepts the form: 2 radio questions, Go / Hold / No go" "2 GO,HLD,NO GO,HLD,NO" "$(poll_form "$body")"

# 21. CONTROL: the same check refuses prose options with no poll block
prose="$(printf '%s\n' "## Waiting for you: 1 step(s)" "" "1. [SPL-595](/issues?issue=SPL-595) Azure app" "  Step: register the Azure app" "" "(a) go (b) hold - say 1 or 2")"
eq "21. CONTROL: prose options, no poll block -> no form" "none" "$(poll_form "$prose")"

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
