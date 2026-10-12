#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_issue places a lane's issue and ends it (owner HUM-10,
# t1 5ea2e615 msg 346238a8; csi-spl-doc/doc/md/lane-issue-and-docs.md). The
# hub is stubbed (spl_desk_issue_run logs its args), so the test proves which
# calls are made: a brief with no key files one (wip, the lane assigned, the
# owner's words + the topic link) and records the key; a key is linked; a
# roster that does not know the lane gets the placing desk as assignee; an end
# needs a reason; a dry run calls nothing and writes nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

S="$T/spool"
mkdir -p "$S/dispatch" "$S/c-123/lifetime" "$T/state/dev/desk/t1/box-a/spool/c-002"
printf '%s\n' LEASE_MASTER=c-002 LEASE_ORCH=c-001 LEASE_ENV=dev LEASE_TENANT=t1 >"$S/dispatch/lease.conf"
cat >"$T/brief.md" <<'EOF'
# Brief: make the widget blue (one lane)

Owner HUM-10, t1 topic 5ea2e615-ca23-451f-9fea-e1b87c369476: "make it blue".

## Task
Paint it.
EOF
cp "$T/brief.md" "$S/c-123/lifetime/brief.md"

STUBS='do_spl_desk_cnf() { SPL_WUI_URL=https://wui.invalid; return 0; }
spl_desk_issue_run() {
  local a; for a in "$@"; do printf "%s|" "$a"; done >>"$STUB_LOG"; echo >>"$STUB_LOG"
  if [[ "$1" == create && -n "${DESC_COPY:-}" ]]; then
    local i; for ((i = 1; i <= $#; i++)); do [[ "${!i}" == --description-file ]] && { i=$((i + 1)); cp "${!i}" "$DESC_COPY"; }; done
  fi
  if [[ "${ROSTER:-1}" == 0 && " $* " == *" --assignee c-123 "* ]]; then echo "FATAL spool issue $1 as c-002: hub refused: bad_assignee"; return 1; fi
  [[ "$1" == create ]] && echo "{\"op\": \"create\", \"result\": {\"key\": \"SPL-42\", \"epic\": \"SPL-1\"}}"
  return 0
}
'
run() {  # VAR=value... -> output in $T/o, rc in $rc
  : >"$T/calls.log"
  SNIPPET="${STUBS}do_spl_lane_issue" in_orc SPOOL_ROOT="$S" SPOOL_DESK_BOX=box-a TENANT_ID= "$@" >"$T/o" 2>&1; rc=$?
}

# A dry run calls nothing and writes nothing.
run AGENT_ID=c-123 BRIEF="$T/brief.md"
[[ $rc -eq 0 && ! -s "$T/calls.log" && ! -e "$S/c-123/lifetime/issue" ]] && grep -q 'would: spool issue create' "$T/o" &&
  pass "dry run: plans the create, no hub call, no file" || fail "dry run (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"

# No key: files one.
run AGENT_ID=c-123 BRIEF="$T/brief.md" DESC_COPY="$T/desc.md" DRY_RUN=0
line="$(head -1 "$T/calls.log")"
[[ $rc -eq 0 && "$(cat "$S/c-123/lifetime/issue" 2>/dev/null)" == SPL-42 ]] &&
  pass "no key: files one and records SPL-42 in lifetime/issue" || fail "file (rc=$rc): $(cat "$T/o")"
[[ "$line" == "create|--title|make the widget blue (one lane)|--description-file|"*"|--status|wip|--assignee|c-123|" ]] &&
  pass "... title = the brief's heading, status wip, the lane assigned" || fail "create args: $line"
grep -q '"make it blue"' "$T/desc.md" && grep -qx -- '- Lane: c-123' "$T/desc.md" &&
  grep -qx -- '- Topic: https://wui.invalid/t/5ea2e615-ca23-451f-9fea-e1b87c369476' "$T/desc.md" && ! grep -q 'Paint it' "$T/desc.md" &&
  pass "... description = the owner's words up to the first ## + the lane + the topic link" || fail "description: $(cat "$T/desc.md")"
grep -qx 'Issue: SPL-42' "$S/c-123/lifetime/brief.md" && pass "... the recorded brief carries the key" || fail "brief: $(tail -2 "$S/c-123/lifetime/brief.md")"

# A key: linked, never a second issue.
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 ]] && ! grep -q '^create' "$T/calls.log" && grep -qx 'update|--ref|SPL-7|--status|wip|--assignee|c-123|' "$T/calls.log" &&
  grep -q '^comment|--ref|SPL-7|--body|Lane c-123 placed on SPL-7' "$T/calls.log" && [[ "$(cat "$S/c-123/lifetime/issue")" == SPL-7 ]] &&
  pass "a key: wip, the lane assigned, a comment; no create" || fail "link (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"

# The roster does not announce the lane: the placing desk, qualified by its box.
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 ROSTER=0 DRY_RUN=0
[[ $rc -eq 0 ]] && grep -qx 'update|--ref|SPL-7|--status|wip|--assignee|c-002@box-a|' "$T/calls.log" && grep -q 'does not announce c-123' "$T/o" &&
  pass "bad_assignee: retried with the placing desk c-002@box-a, said why" || fail "roster fallback (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"

# No seated desk of the lease: refused, nothing called.
run AGENT_ID=c-123 BRIEF="$T/brief.md" SPOOL_DESK_BOX=box-z DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'no seated desk of the lease' "$T/o" &&
  pass "no seated desk on this box: refused, no hub call" || fail "no desk (rc=$rc): $(cat "$T/o")"

# A bad id or op.
run AGENT_ID=nope DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "a bad AGENT_ID is refused" || fail "bad id (rc=$rc)"

# End: needs a reason; then status + comment + issue-end.
echo SPL-42 >"$S/c-123/lifetime/issue"
run AGENT_ID=c-123 LANE_ISSUE_OP=end DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" && ! -e "$S/c-123/lifetime/issue-end" ]] && grep -q 'LANE_ISSUE_REASON must say why' "$T/o" &&
  pass "end with no reason: refused, nothing called" || fail "end no reason (rc=$rc): $(cat "$T/o")"
run AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done LANE_ISSUE_REASON=x DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "end as done is refused (landing moves it, not the lane)" || fail "end done (rc=$rc)"
run AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_REASON='superseded by c-130' DRY_RUN=0
[[ $rc -eq 0 ]] && grep -qx 'update|--ref|SPL-42|--status|diss|' "$T/calls.log" &&
  grep -q '^comment|--ref|SPL-42|--body|Lane c-123 ended without landing (diss): superseded by c-130|' "$T/calls.log" &&
  [[ "$(cut -f1,2 "$S/c-123/lifetime/issue-end")" == $'diss\tsuperseded by c-130' ]] &&
  pass "end: diss, the reason as a comment and in lifetime/issue-end" || fail "end (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"

# Kind: answer in the brief: the filed issue is labelled answer (the label made first).
printf '# Brief: evaluate the runner\n\nKind: answer\n' >"$T/answer.md"
run AGENT_ID=c-124 BRIEF="$T/answer.md" DRY_RUN=0
grep -q '^label|--name|answer|' "$T/calls.log" && grep -q '^create|--title|evaluate the runner|.*|--status|wip|--labels|answer|--assignee|c-124|' "$T/calls.log" &&
  pass "Kind: answer: the label exists, the issue carries it" || fail "answer label (rc=$rc): $(cat "$T/calls.log")"
run AGENT_ID=c-125 BRIEF="$T/brief.md" DRY_RUN=0
! grep -q -- '--labels' "$T/calls.log" && pass "control: no Kind: answer, no label" || fail "label control: $(cat "$T/calls.log")"

# discussion: the first answer files the discussion's issue (owner Q1A).
run AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=5ea2e615-ca23-451f-9fea-e1b87c369476 LANE_ISSUE_TITLE='Evaluate the runner' LANE_ISSUE_TEXT='"is the VM dead?"' LANE_ISSUE_ANSWER=1 DESC_COPY="$T/d2.md" DRY_RUN=0
[[ $rc -eq 0 ]] && grep -q '^create|--title|Evaluate the runner|.*|--status|eval|--labels|answer|--assignee|c-002|' "$T/calls.log" &&
  grep -qx 'SPL-42' "$T/o" && grep -qx -- '- Topic: https://wui.invalid/t/5ea2e615-ca23-451f-9fea-e1b87c369476' "$T/d2.md" && grep -q 'is the VM dead' "$T/d2.md" &&
  pass "discussion: eval, answer label, the taker assigned, the topic linked, the key printed" || fail "discussion (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"
run AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=5ea2e615-ca23-451f-9fea-e1b87c369476 DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'acks, chatter and announcements file no issue' "$T/o" &&
  pass "discussion with no title (an ack): refused, nothing filed" || fail "no title (rc=$rc): $(cat "$T/o")"
run AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=nope LANE_ISSUE_TITLE=x DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "discussion with a bad topic: refused" || fail "bad topic (rc=$rc)"

echo "spl-lane-issue: $fails failure(s)"
exit "$fails"
