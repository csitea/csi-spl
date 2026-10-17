#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_issue places a lane's issue and ends it (owner HUM-10,
# t1 5ea2e615 msg 346238a8; csi-spl-doc/doc/md/lane-issue-and-docs.md). The
# hub is stubbed (spl_desk_issue_run logs its args), so the test proves which
# calls are made: a brief with no key files one (wip, the lane assigned, the
# owner's words + the topic link) and records the key; a key is linked; a
# roster that does not know the lane gets the placing desk as assignee; an end
# needs a reason; an end as done (SPL-2229) needs a cnf repo whose fetched
# origin trunk has the sha; a dry run calls nothing and writes nothing.
# No issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msg
# 5863d0d6): a filed issue names a spec folder on origin/master and its epic
# (the brief's Epic: line, the spec's pin, or the hub's "Spec NNN" epic).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

S="$T/spool"
# The specs repo (LI_SPEC_REPO): 135 and 077 plain, 040 pins its epic, 099
# committed but never pushed (not on origin/master).
SR="$T/specs"
sg() { git -C "$SR/repo" -c user.name='FirstName LastName' -c user.email=dev@example.com "$@"; }
git init -q --bare "$SR/origin.git" && git init -q -b master "$SR/repo"
for d in 135-work-process 077-plain 040-pinned; do mkdir -p "$SR/repo/csi-spl-doc/specs/$d"; printf '# Spec %s\n' "$d" >"$SR/repo/csi-spl-doc/specs/$d/spec.md"; done
printf '# Spec 040\n\nEpic SPL-74\n' >"$SR/repo/csi-spl-doc/specs/040-pinned/spec.md"
sg add -A && sg commit -q -m specs && sg remote add origin "$SR/origin.git" && sg push -q origin master 2>/dev/null
mkdir -p "$SR/repo/csi-spl-doc/specs/099-local-only" && echo x >"$SR/repo/csi-spl-doc/specs/099-local-only/spec.md"
sg add -A && sg commit -q -m local-only
export LI_SPEC_REPO="$SR/repo"
ES=$'Spec: csi-spl-doc/specs/135-work-process\nEpic: SPL-1'
mkdir -p "$S/dispatch" "$S/c-123/lifetime" "$T/state/dev/desk/t1/box-a/spool/c-002"
printf '%s\n' LEASE_MASTER=c-002 LEASE_ORCH=c-001 LEASE_ENV=dev LEASE_TENANT=t1 >"$S/dispatch/lease.conf"
cat >"$T/brief.md" <<'EOF'
# Brief: make the widget blue (one lane)

Owner HUM-10, t1 topic 5ea2e615-ca23-451f-9fea-e1b87c369476: "make it blue".

Spec: csi-spl-doc/specs/135-work-process
Epic: SPL-1

## Task
Paint it.
EOF
cp "$T/brief.md" "$S/c-123/lifetime/brief.md"

STUBS='do_spl_desk_cnf() { SPL_WUI_URL=https://wui.invalid; return 0; }
spl_desk_issue_run() {
  local a; for a in "$@"; do printf "%s|" "$a"; done >>"$STUB_LOG"; echo >>"$STUB_LOG"
  [[ "$1" == list ]] && { printf "%s\n" "${EPICS:-no epics}"; return 0; }
  echo "$DESK_AGENT" >>"$STUB_LOG.as"
  if [[ "$1" =~ ^(create|update)$ && -n "${DESC_COPY:-}" ]]; then
    local i; for ((i = 1; i <= $#; i++)); do [[ "${!i}" == --description-file ]] && { i=$((i + 1)); cp "${!i}" "$DESC_COPY.$1"; }; done
  fi
  if [[ "${ROSTER:-1}" == 0 && " $* " == *" --assignee c-123 "* ]]; then echo "FATAL spool issue $1 as c-002: hub refused: bad_assignee"; return 1; fi
  if [[ "$1" == create && "${REFUSE_TOPIC:-0}" == 1 ]]; then
    local j; for ((j = 1; j <= $#; j++)); do [[ "${!j}" == --description-file ]] && { j=$((j + 1)); break; }; done
    [[ "$(sed -n 2p "${!j}")" == /t/fcf09921-8f21-4518-a117-f8ddb41bfff5 ]] || { echo "FATAL spool issue create as c-002: hub refused: unknown_discussion"; return 1; }
  fi
  local ds=""; [[ -n "${RESOLVE:-}" ]] && ds=", \"discussions\": [{\"task_id\": \"$RESOLVE\"}]"
  [[ "$1" == create ]] && echo "{\"op\": \"create\", \"result\": {\"key\": \"SPL-42\", \"epic\": \"SPL-1\"$ds}}"
  return 0
}
do_spl_desk_reply() { printf "post|%s|%s|%s|\n" "$DESK_TASK" "$DRY_RUN" "$DESK_BODY" >>"$STUB_LOG"; }
'
run() {  # VAR=value... -> output in $T/o, rc in $rc
  : >"$T/calls.log"; : >"$T/calls.log.as"
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
[[ "$line" == "create|--title|make the widget blue (one lane)|--description-file|"*"|--status|wip|--epic|SPL-1|--assignee|c-123|" ]] &&
  pass "... title = the brief's heading, status wip, under the brief's epic, the lane assigned" || fail "create args: $line"
grep -q '"make it blue"' "$T/desc.md.create" && grep -qx -- '- Lane: c-123' "$T/desc.md.create" &&
  grep -qx -- '- Topic: https://wui.invalid/t/5ea2e615-ca23-451f-9fea-e1b87c369476' "$T/desc.md.create" && ! grep -q 'Paint it' "$T/desc.md.create" &&
  pass "... description = the owner's words up to the first ## + the lane + the topic link" || fail "description: $(cat "$T/desc.md.create")"
grep -qx 'Issue: SPL-42' "$S/c-123/lifetime/brief.md" && pass "... the recorded brief carries the key" || fail "brief: $(tail -2 "$S/c-123/lifetime/brief.md")"

# Q4A (spec 135 section 7.1): the card starts the description, names its own
# key once filed, and the key is posted back in the topic.
[[ "$(sed -n 1,4p "$T/desc.md.create")" == $'## Source\n/t/5ea2e615-ca23-451f-9fea-e1b87c369476\n\n## Restart' ]] &&
  grep -qx -- '- key: <new>' "$T/desc.md.create" && grep -qx -- '- last citing sha: none' "$T/desc.md.create" &&
  grep -qx -- '- spec: csi-spl-doc/specs/135-work-process' "$T/desc.md.create" &&
  pass "card: ## Source /t/<topic> then ## Restart at the top of the description" || fail "card: $(head -16 "$T/desc.md.create")"
grep -q '^update|--ref|SPL-42|--description-file|' "$T/calls.log" && grep -qx -- '- key: SPL-42' "$T/desc.md.update" &&
  grep -q '"make it blue"' "$T/desc.md.update" && pass "... once filed, the card names SPL-42" || fail "card key: $(cat "$T/calls.log")"
grep -qx 'post|5ea2e615-ca23-451f-9fea-e1b87c369476|0|\*\*Planned, not built yet.\*\* Tracked as \*\*SPL-42\*\*: make the widget blue (one lane) (lane c-123).|' "$T/calls.log" &&
  pass "... the key is posted back in the topic" || fail "post back: $(cat "$T/calls.log")"
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_POST=0 DRY_RUN=0
[[ $rc -eq 0 ]] && grep -q '^create|' "$T/calls.log" && ! grep -q '^post|' "$T/calls.log" &&
  pass "control: LANE_ISSUE_POST=0 files the issue, posts nothing" || fail "post control (rc=$rc): $(cat "$T/calls.log")"
run AGENT_ID=c-123 BRIEF="$T/brief.md"
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q 'would: post' "$T/o" &&
  pass "dry run: plans the post, posts nothing" || fail "dry post (rc=$rc): $(cat "$T/o")"

# A key: linked, never a second issue.
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 ]] && ! grep -q '^create' "$T/calls.log" && grep -qx 'update|--ref|SPL-7|--status|wip|--assignee|c-123|' "$T/calls.log" &&
  grep -q '^comment|--ref|SPL-7|--body|Lane c-123 placed on SPL-7' "$T/calls.log" && [[ "$(cat "$S/c-123/lifetime/issue")" == SPL-7 ]] &&
  ! grep -q '^post|' "$T/calls.log" && pass "a key: wip, the lane assigned, a comment; no create, no post (no migration)" || fail "link (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"

# The roster does not announce the lane: the placing desk, qualified by its box.
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 ROSTER=0 DRY_RUN=0
[[ $rc -eq 0 ]] && grep -qx 'update|--ref|SPL-7|--status|wip|--assignee|c-002@box-a|' "$T/calls.log" && grep -q 'does not announce c-123' "$T/o" &&
  pass "bad_assignee: retried with the placing desk c-002@box-a, said why" || fail "roster fallback (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"

# SPL-1707: the desk files as an agent its sidecar announces. 2026-10-13 on a satellite box:
# c-002 on a usage-limit screen (run report "stop"), the lease on box-b, so the
# sidecar left c-002 out and the hub refused it (from_not_announced).
mkdir -p "$T/state/dev/desk/t1/box-a/spool/c-946"
printf '# agent-run v1 1\nc-002\tstop\twd S2: HIT 10s ago\nc-946\trun\n' >"$S/dispatch/agent-run.tsv"
echo "c-002@box-b 1" >"$S/dispatch/lease"
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 && "$(sort -u "$T/calls.log.as")" == c-946 ]] && grep -q 'does not announce c-002' "$T/o" &&
  pass "c-002 stopped, the lease on box-b: files as c-946, which the desk announces, said why" || fail "announced pick (rc=$rc): $(cat "$T/calls.log.as") / $(cat "$T/o")"
echo "c-002@box-a 1" >"$S/dispatch/lease"
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 && "$(sort -u "$T/calls.log.as")" == c-002 ]] && ! grep -q 'does not announce' "$T/o" &&
  pass "control: the lease mirror seats c-002 on box-a: files as c-002" || fail "lease control (rc=$rc): $(cat "$T/calls.log.as")"
echo "c-002@box-b 1" >"$S/dispatch/lease"
printf '# agent-run v1 1\nc-002\tstop\theld: rotation since 5s\nc-946\trun\n' >"$S/dispatch/agent-run.tsv"
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 && "$(sort -u "$T/calls.log.as")" == c-002 ]] &&
  pass "control: a rotation holds c-002: files as c-002" || fail "held control (rc=$rc): $(cat "$T/calls.log.as")"
printf '# agent-run v1 1\nc-002\tstop\twd S2: HIT 10s ago\nc-946\trun\n' >"$S/dispatch/agent-run.tsv"
touch -d '-10 minutes' "$S/dispatch/agent-run.tsv"
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 && "$(sort -u "$T/calls.log.as")" == c-002 ]] &&
  pass "control: a stale run report drops nothing: files as c-002" || fail "stale control (rc=$rc): $(cat "$T/calls.log.as")"
printf '# agent-run v1 1\nc-002\tstop\twd S2: HIT 10s ago\n' >"$S/dispatch/agent-run.tsv"
run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 && "$(sort -u "$T/calls.log.as")" == c-002 ]] &&
  pass "nobody announced: the first seated (c-002), as before" || fail "fallback (rc=$rc): $(cat "$T/calls.log.as")"
rm -rf "$S/dispatch/agent-run.tsv" "$S/dispatch/lease" "$T/state/dev/desk/t1/box-a/spool/c-946"

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
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "end as done with no LANE_LANDED_REPO is refused (landing moves it, not the lane)" || fail "end done (rc=$rc)"
run AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_REASON='superseded by c-130' DRY_RUN=0
[[ $rc -eq 0 ]] && grep -qx 'update|--ref|SPL-42|--status|diss|' "$T/calls.log" &&
  grep -qx 'comment|--ref|SPL-42|--body|Lane c-123 ended without landing (diss): superseded by c-130 (booked by desk c-002 for lane c-123: the hub books only an agent its box announces)|' "$T/calls.log" &&
  [[ "$(cut -f1,2 "$S/c-123/lifetime/issue-end")" == $'diss\tsuperseded by c-130' ]] &&
  pass "end: diss, the reason as a comment (naming the desk that booked it for the lane) and in lifetime/issue-end" || fail "end (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"

# SPL-2287: the end books the LANE as the actor where the hub can. The hub
# books the --as agent and takes only one the desk's box announces: a seat in
# the desk's spool. SPL-2236's diss was booked to c-002, not its lane c-311.
mkdir -p "$T/state/dev/desk/t1/box-a/spool/c-123"
printf '# agent-run v1 1\nc-002\trun\nc-123\trun\n' >"$S/dispatch/agent-run.tsv"
run AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_REASON='superseded by c-130' DRY_RUN=0
[[ $rc -eq 0 && "$(sort -u "$T/calls.log.as")" == c-123 ]] && grep -qx 'update|--ref|SPL-42|--status|diss|' "$T/calls.log" &&
  grep -qx 'comment|--ref|SPL-42|--body|Lane c-123 ended without landing (diss): superseded by c-130|' "$T/calls.log" &&
  pass "end: the desk seats and announces c-123: the status change and the comment act as c-123" ||
  fail "end as the lane (rc=$rc): as=$(sort -u "$T/calls.log.as" | tr '\n' ' ') / $(cat "$T/calls.log")"
printf '# agent-run v1 1\nc-002\trun\nc-123\tstop\twd S2: HIT 10s ago\n' >"$S/dispatch/agent-run.tsv"
run AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_REASON='superseded by c-130' DRY_RUN=0
[[ $rc -eq 0 && "$(sort -u "$T/calls.log.as")" == c-002 ]] && grep -q '^comment|.*(booked by desk c-002 for lane c-123: ' "$T/calls.log" &&
  pass "control: seated but not announced (run report stop): the desk c-002 acts, the comment names the lane" ||
  fail "end not announced (rc=$rc): as=$(sort -u "$T/calls.log.as" | tr '\n' ' ') / $(cat "$T/calls.log")"
rm -rf "$S/dispatch/agent-run.tsv" "$T/state/dev/desk/t1/box-a/spool/c-123"

# End done (SPL-2229): the work landed in ANOTHER repo. The repo comes from the
# cnf by name (a src_dir basename), its clone is fetched, the sha must be on
# origin/<trunk>; anything else is refused with nothing called or written.
# Fixture: origin.git <- clone "dvn-web" (the cnf's), and a second clone that
# pushes the commits the first has not fetched yet.
lg() { git -C "$1" -c user.name='FirstName LastName' -c user.email=dev@example.com "${@:2}"; }
git init -q --bare "$T/lr/origin.git"
git init -q -b master "$T/lr/push" && lg "$T/lr/push" commit -q --allow-empty -m init &&
  lg "$T/lr/push" remote add origin "$T/lr/origin.git" && lg "$T/lr/push" push -q origin master 2>/dev/null
git clone -q "$T/lr/origin.git" "$T/lr/dvn-web" 2>/dev/null
lg "$T/lr/push" checkout -q -b wip && lg "$T/lr/push" commit -q --allow-empty -m wip-only && lg "$T/lr/push" push -q origin wip 2>/dev/null
WIP="$(lg "$T/lr/push" rev-parse HEAD)"
lg "$T/lr/push" checkout -q master && lg "$T/lr/push" commit -q --allow-empty -m landed && lg "$T/lr/push" push -q origin master 2>/dev/null
LANDED="$(lg "$T/lr/push" rev-parse HEAD)"
printf 'env:\n  steps:\n    021-firebase-hosted-sites:\n      sites:\n        ws-hidden-12: {src_dir: %s}\n' "$T/lr/dvn-web" >"$T/lr/cnf.yaml"
done_run() { rm -f "$S/c-123/lifetime/issue-end"; run AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done LANE_LANDED_CNF="$T/lr/cnf.yaml" SPOOL_BOX_USER= "$@"; }
refused() {  # LABEL WANT: refused, no hub call, no issue-end, the line says WANT
  [[ $rc -ne 0 && ! -s "$T/calls.log" && ! -e "$S/c-123/lifetime/issue-end" ]] && grep -q -- "$2" "$T/o" &&
    pass "$1" || fail "$1 (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"
}
# An unfetched clone: the sha is on its origin only. Fetched, then done.
! lg "$T/lr/dvn-web" cat-file -e "$LANDED^{commit}" 2>/dev/null && pass "control: the clone has not fetched the landed sha yet" || fail "control: clone already has $LANDED"
done_run LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA="${LANDED:0:7}" DRY_RUN=0
[[ $rc -eq 0 ]] && grep -qx 'update|--ref|SPL-42|--status|done|' "$T/calls.log" &&
  grep -q "^comment|--ref|SPL-42|--body|Lane c-123 landed in dvn-web ${LANDED:0:12} on origin/master (another repo, no csi-spl commit). Landed, not live.* (booked by desk c-002 for lane c-123: " "$T/calls.log" &&
  [[ "$(cut -f1,4,5 "$S/c-123/lifetime/issue-end")" == "done"$'\t'"dvn-web"$'\t'"$LANDED" ]] &&
  pass "done: an unfetched clone is fetched, the sha is on origin/master: done, a comment, issue-end with repo + full sha" ||
  fail "done (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"
cp "$S/c-123/lifetime/issue-end" "$T/lr/issue-end" 2>/dev/null
done_run LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA="$WIP" DRY_RUN=0
refused "done: a sha only on a wip branch (fetched as origin/wip) is refused" "is not on origin/master (a branch only?)"
done_run LANE_LANDED_REPO=other-web LANE_LANDED_SHA="$LANDED" DRY_RUN=0
refused "done: a repo name the cnf does not know is refused, naming the known ones" "'other-web' is no repo the cnf knows (src_dir names: dvn-web)"
for bad in "$T/lr/dvn-web" ../dvn-web https://github.com/example/dvn-web.git git@example.com:x/dvn-web.git ""; do
  done_run LANE_LANDED_REPO="$bad" LANE_LANDED_SHA="$LANDED" DRY_RUN=0
  refused "done: a path or URL as the repo is refused: '$bad'" "must be a repo NAME the cnf knows, not a path or URL"
done
done_run LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA='HEAD' DRY_RUN=0
refused "done: a ref that is not a sha is refused" "LANE_LANDED_SHA must be a commit sha"
done_run LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA=0123456789abcdef DRY_RUN=0
refused "done: a sha no repo has is refused" "is no commit of dvn-web, even after a fetch"
done_run LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA="$LANDED" LANE_LANDED_CNF= DRY_RUN=0
refused "done: a sandbox with no LANE_LANDED_CNF reads no cnf (never the live clones)" "'dvn-web' is no repo the cnf knows (src_dir names: none)"
SNIPPET=". \"\$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh\"; li_end_record SPL-42 '$T/lr/issue-end' c-123" in_orc >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qx "issue gate: SPL-42 landed in another repo: dvn-web ${LANDED:0:12} (checked on its origin trunk)" "$T/o" &&
  pass "done: li_gate's record check passes that issue-end, naming repo + short sha" || fail "li_end_record (rc=$rc): $(cat "$T/o")"
rm -f "$S/c-123/lifetime/issue-end"
done_run LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA="$LANDED"
[[ $rc -eq 0 && ! -s "$T/calls.log" && ! -e "$S/c-123/lifetime/issue-end" ]] && grep -q "OK DRY_RUN SPL-42 -> done (landed in dvn-web" "$T/o" &&
  pass "done, dry run: checked, no hub call, nothing written" || fail "done dry (rc=$rc): $(cat "$T/o")"

# SPL-2420: a customer repo of env.box.landed_repos (name, src_dir, trunk,
# box), its clone on one box only. The entry's name counts, not the basename.
printf 'env:\n  box:\n    landed_repos:\n      - {name: cust-rel, src_dir: %s, trunk: master}\n      - {name: far-rel, src_dir: %s, trunk: master, box: box-b}\n      - {name: lost-rel, src_dir: %s}\n' \
  "$T/lr/dvn-web" "$T/lr/not-here" "$T/lr/not-here" >"$T/lr/cust.yaml"
done_run LANE_LANDED_REPO=cust-rel LANE_LANDED_SHA="$LANDED" LANE_LANDED_CNF="$T/lr/cust.yaml" DRY_RUN=0
[[ $rc -eq 0 ]] && grep -qx 'update|--ref|SPL-42|--status|done|' "$T/calls.log" &&
  [[ "$(cut -f1,4,5 "$S/c-123/lifetime/issue-end")" == "done"$'\t'"cust-rel"$'\t'"$LANDED" ]] &&
  pass "landed_repos: a cnf customer repo by its name, sha on its trunk: done, issue-end names it" ||
  fail "landed_repos done (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"
done_run LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA="$LANDED" LANE_LANDED_CNF="$T/lr/cust.yaml" DRY_RUN=0
refused "landed_repos: RED CONTROL an unknown name (the basename, not the entry's name) is refused" "'dvn-web' is no repo the cnf knows (src_dir names: cust-rel far-rel lost-rel)"
done_run LANE_LANDED_REPO=cust-rel LANE_LANDED_SHA="$WIP" LANE_LANDED_CNF="$T/lr/cust.yaml" DRY_RUN=0
refused "landed_repos: a sha off the cnf trunk is refused" "is not on origin/master (a branch only?)"
done_run LANE_LANDED_REPO=far-rel LANE_LANDED_SHA="$LANDED" LANE_LANDED_CNF="$T/lr/cust.yaml" SPOOL_BOX_TAG=box-a DRY_RUN=0
refused "landed_repos: a clone on another box is refused in one line naming both boxes" "is not a git repo on this box (box-a); its clone is on box box-b: run it there"
done_run LANE_LANDED_REPO=lost-rel LANE_LANDED_SHA="$LANDED" LANE_LANDED_CNF="$T/lr/cust.yaml" SPOOL_BOX_TAG=box-a DRY_RUN=0
refused "landed_repos: no clone and no cnf box: refused, saying the cnf names no box" "on this box (box-a); the cnf names no box for it"
printf 'env:\n  box:\n    landed_repos:\n      - {name: cust-rel, src_dir: %s, trunk: main}\n' "$T/lr/dvn-web" >"$T/lr/main.yaml"
done_run LANE_LANDED_REPO=cust-rel LANE_LANDED_SHA="$LANDED" LANE_LANDED_CNF="$T/lr/main.yaml" DRY_RUN=0
refused "landed_repos: a cnf trunk the clone lacks is refused (never another branch)" "cust-rel has no origin/main"

# Kind: answer in the brief: the filed issue is labelled answer (the label made first).
printf '# Brief: evaluate the runner\n\nKind: answer\n%s\n' "$ES" >"$T/answer.md"
run AGENT_ID=c-124 BRIEF="$T/answer.md" DRY_RUN=0
grep -q '^label|--name|answer|' "$T/calls.log" && grep -q '^create|--title|evaluate the runner|.*|--status|wip|--labels|answer|--epic|SPL-1|--assignee|c-124|' "$T/calls.log" &&
  pass "Kind: answer: the label exists, the issue carries it" || fail "answer label (rc=$rc): $(cat "$T/calls.log")"
run AGENT_ID=c-125 BRIEF="$T/brief.md" DRY_RUN=0
! grep -q -- '--labels' "$T/calls.log" && pass "control: no Kind: answer, no label" || fail "label control: $(cat "$T/calls.log")"

# discussion: the first answer files the discussion's issue (owner Q1A).
run AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=5ea2e615-ca23-451f-9fea-e1b87c369476 LANE_ISSUE_TITLE='Evaluate the runner' LANE_ISSUE_TEXT='"is the VM dead?"' LANE_ISSUE_ANSWER=1 LANE_ISSUE_SPEC=csi-spl-doc/specs/135-work-process LANE_ISSUE_EPIC=SPL-1 DESC_COPY="$T/d2.md" DRY_RUN=0
[[ $rc -eq 0 ]] && grep -q '^create|--title|Evaluate the runner|.*|--status|eval|--labels|answer|--epic|SPL-1|--assignee|c-002|' "$T/calls.log" &&
  grep -qx 'SPL-42' "$T/o" && grep -qx -- '- Topic: https://wui.invalid/t/5ea2e615-ca23-451f-9fea-e1b87c369476' "$T/d2.md.create" && grep -q 'is the VM dead' "$T/d2.md.create" &&
  grep -qx '## Source' "$T/d2.md.create" && grep -q '^post|5ea2e615-ca23-451f-9fea-e1b87c369476|0|\*\*Planned, not built yet.\*\* Tracked as \*\*SPL-42\*\*' "$T/calls.log" &&
  pass "discussion: eval, answer label, the taker assigned, the card, the key printed and posted back" || fail "discussion (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"
run AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=5ea2e615-ca23-451f-9fea-e1b87c369476 DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'acks, chatter and announcements file no issue' "$T/o" &&
  pass "discussion with no title (an ack): refused, nothing filed" || fail "no title (rc=$rc): $(cat "$T/o")"
run AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=nope LANE_ISSUE_TITLE=x DRY_RUN=0
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "discussion with a bad topic: refused" || fail "bad topic (rc=$rc)"

# SPL-1593 (rdb 0194): every issue links a discussion; a placement never
# fails on the link (c-002, dispatch-fcf09921 msg c5c7d032).
# (1) A full topic id: the card's Source line carries it (tested above).
# (2) An 8-hex short id: the card carries it, the hub resolves it inside the
# tenant, and the card and the post-back then use the full id.
printf '# Brief: short topic\n\nOwner on dispatch-0a1b2c3d: "do it".\n%s\n' "$ES" >"$T/short.md"
run AGENT_ID=c-126 BRIEF="$T/short.md" DESC_COPY="$T/s.md" RESOLVE=0a1b2c3d-0000-4000-8000-000000000001 DRY_RUN=0
[[ $rc -eq 0 && "$(sed -n 2p "$T/s.md.create")" == /t/0a1b2c3d ]] && [[ "$(sed -n 2p "$T/s.md.update")" == /t/0a1b2c3d-0000-4000-8000-000000000001 ]] &&
  grep -q '^post|0a1b2c3d-0000-4000-8000-000000000001|0|' "$T/calls.log" && ! grep -q 'WARN brief' "$T/o" &&
  pass "short id: the card sends /t/0a1b2c3d; the resolved full id goes into the card and the post-back" || fail "short id (rc=$rc): $(cat "$T/calls.log") / $(cat "$T/o")"
# (3) No topic: the tenant's default (t1: fcf09921), one WARN naming the brief, no post-back.
printf '# Brief: no topic at all\n\nJust do it.\n%s\n' "$ES" >"$T/none.md"
run AGENT_ID=c-127 BRIEF="$T/none.md" DESC_COPY="$T/n.md" DRY_RUN=0
[[ $rc -eq 0 && "$(sed -n 2p "$T/n.md.create")" == /t/fcf09921-8f21-4518-a117-f8ddb41bfff5 ]] &&
  [[ "$(grep -c "WARN brief $T/none.md names no topic" "$T/o")" == 1 ]] && ! grep -q '^post|' "$T/calls.log" &&
  [[ "$(cat "$S/c-127/lifetime/issue")" == SPL-42 ]] &&
  pass "no topic: links t1's default fcf09921, one WARN line names the brief, no post-back" || fail "no topic (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"
# A topic the hub does not resolve: one WARN naming the brief, then the default; the placement stands.
run AGENT_ID=c-128 BRIEF="$T/short.md" DESC_COPY="$T/u.md" REFUSE_TOPIC=1 DRY_RUN=0
[[ $rc -eq 0 && "$(grep -c '^create|' "$T/calls.log")" == 2 && "$(sed -n 2p "$T/u.md.create")" == /t/fcf09921-8f21-4518-a117-f8ddb41bfff5 ]] &&
  [[ "$(grep -c "WARN brief $T/short.md: topic /t/0a1b2c3d did not resolve in t1 (unknown_discussion)" "$T/o")" == 1 ]] &&
  [[ "$(cat "$S/c-128/lifetime/issue")" == SPL-42 ]] &&
  pass "an unresolved topic: one WARN naming the brief, the create again on the default, the lane keeps SPL-42" || fail "unresolved (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"
# Another tenant's default is its backlog topic, as rdb 0194 computes it.
want="$(printf 'spool-issue-backlog:acme' | sha256sum | cut -c1-32)"
want="${want:0:8}-${want:8:4}-${want:12:4}-${want:16:4}-${want:20:12}"
mkdir -p "$T/state/dev/desk/acme/box-a/spool/c-002"
run AGENT_ID=c-129 BRIEF="$T/none.md" DESC_COPY="$T/a.md" TENANT_ID=acme DRY_RUN=0
[[ "$(sed -n 2p "$T/a.md.create" 2>/dev/null)" == "/t/$want" ]] &&
  pass "tenant acme: the default is its backlog topic $want" || fail "acme default (rc=$rc): $(head -3 "$T/a.md.create" 2>/dev/null) / $(cat "$T/o")"

# No issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msg
# 5863d0d6). Each refusal: one FATAL line naming the order, no create; its
# control is the same brief with the missing line added, which files.
eb() {  # FILE LINES...: a brief with those extra lines
  local f="$1"; shift; { printf '# Brief: epic and spec\n\nOwner on t1 topic 5ea2e615-ca23-451f-9fea-e1b87c369476.\n'; printf '%s\n' "$@"; } >"$f"
}
refused_es() {  # LABEL WANT
  [[ $rc -ne 0 ]] && ! grep -q '^create|' "$T/calls.log" && [[ ! -e "$S/c-130/lifetime/issue" ]] &&
    grep -q "FATAL refused, nothing filed: no issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6): $2" "$T/o" &&
    pass "$1" || fail "$1 (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"
}
filed_es() {  # LABEL EPIC
  [[ $rc -eq 0 ]] && grep -q "^create|.*|--epic|$2|--assignee|c-130|" "$T/calls.log" && [[ "$(cat "$S/c-130/lifetime/issue")" == SPL-42 ]] &&
    pass "$1" || fail "$1 (rc=$rc): $(cat "$T/o") / $(cat "$T/calls.log")"
}
rm -f "$S/c-130/lifetime/issue"
eb "$T/es-nospec.md" 'Epic: SPL-1'
run AGENT_ID=c-130 BRIEF="$T/es-nospec.md" DRY_RUN=0
refused_es "no spec named: refused, no hub call at all" "no spec folder named"
[[ ! -s "$T/calls.log" ]] && pass "... not even a read" || fail "no spec called: $(cat "$T/calls.log")"
run AGENT_ID=c-130 BRIEF="$T/es-nospec.md" LANE_ISSUE_SPEC=csi-spl-doc/specs/135-work-process DRY_RUN=0
filed_es "control: the same brief with LANE_ISSUE_SPEC files, under SPL-1" SPL-1
rm -f "$S/c-130/lifetime/issue"
eb "$T/es-ghost.md" 'Spec: csi-spl-doc/specs/098-nowhere' 'Epic: SPL-1'
run AGENT_ID=c-130 BRIEF="$T/es-ghost.md" DRY_RUN=0
refused_es "a spec folder that does not exist: refused" "csi-spl-doc/specs/098-nowhere is not a folder on origin/master"
eb "$T/es-local.md" 'Spec: csi-spl-doc/specs/099-local-only' 'Epic: SPL-1'
[[ -d "$SR/repo/csi-spl-doc/specs/099-local-only" ]] && pass "control: 099-local-only is in the local tree (committed, not pushed)" || fail "fixture 099"
run AGENT_ID=c-130 BRIEF="$T/es-local.md" DRY_RUN=0
refused_es "a spec committed locally but not on origin/master: refused" "csi-spl-doc/specs/099-local-only is not a folder on origin/master"
sg push -q origin master 2>/dev/null; git -C "$SR/repo" update-ref -d refs/remotes/origin/master; git -C "$SR/repo" update-ref refs/remotes/origin/master HEAD~1
run AGENT_ID=c-130 BRIEF="$T/es-local.md" DRY_RUN=0
filed_es "control: once 099 is on origin (a stale local ref is fetched once), it files" SPL-1
rm -f "$S/c-130/lifetime/issue"
eb "$T/es-noepic.md" 'Spec: csi-spl-doc/specs/077-plain'
run AGENT_ID=c-130 BRIEF="$T/es-noepic.md" EPICS='{"op": "list", "result": {"epics": [{"key": "SPL-60", "title": "Spec 078 - other"}]}}' DRY_RUN=0
refused_es "no epic (no Epic: line, no pin, no 'Spec 077' epic on the hub): refused" "csi-spl-doc/specs/077-plain has no epic titled 'Spec 077 - ...' on the hub"
grep -q '^list|--kind|epic|' "$T/calls.log" && pass "... after one read of the hub's epics" || fail "no epic read: $(cat "$T/calls.log")"
run AGENT_ID=c-130 BRIEF="$T/es-noepic.md" EPICS='{"op": "list", "result": {"epics": [{"key": "SPL-55", "title": "Spec 077 - plain"}, {"key": "SPL-56", "title": "Spec 077 - again"}]}}' DRY_RUN=0
refused_es "two 'Spec 077' epics: refused, both named" "csi-spl-doc/specs/077-plain has more than one (SPL-55 SPL-56) epic"
run AGENT_ID=c-130 BRIEF="$T/es-noepic.md" EPICS='{"op": "list", "result": {"epics": [{"key": "SPL-55", "title": "Spec 077 - plain"}]}}' DRY_RUN=0
filed_es "control: the hub's one epic titled 'Spec 077 - ...' (the spec import's mapping) is the epic" SPL-55
rm -f "$S/c-130/lifetime/issue"
run AGENT_ID=c-130 BRIEF="$T/es-noepic.md" LANE_ISSUE_EPIC=SPL-9 DRY_RUN=0
filed_es "control: LANE_ISSUE_EPIC names it, no hub read" SPL-9
! grep -q '^list|' "$T/calls.log" && pass "... no list call" || fail "list with an epic: $(cat "$T/calls.log")"
rm -f "$S/c-130/lifetime/issue"
eb "$T/es-pin.md" 'Spec: csi-spl-doc/specs/040-pinned'
run AGENT_ID=c-130 BRIEF="$T/es-pin.md" DRY_RUN=0
filed_es "the spec's pin (Epic SPL-74 in spec.md) is the epic" SPL-74
rm -f "$S/c-130/lifetime/issue"
run AGENT_ID=c-130 BRIEF="$T/es-noepic.md"
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q "would: look up the epic titled 'Spec 077 - ...'" "$T/o" &&
  pass "dry run: plans the epic look-up, no hub call" || fail "dry epic (rc=$rc): $(cat "$T/o")"
run AGENT_ID=c-130 BRIEF="$T/es-nospec.md"
[[ $rc -ne 0 ]] && grep -q 'no spec folder named' "$T/o" && pass "dry run: a brief with no spec is refused too" || fail "dry nospec (rc=$rc)"
run AGENT_ID=c-130 BRIEF="$T/es-nospec.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0
[[ $rc -eq 0 ]] && grep -qx 'update|--ref|SPL-7|--status|wip|--assignee|c-130|' "$T/calls.log" &&
  pass "an existing key is linked, not filed: no spec or epic asked" || fail "key with no spec (rc=$rc): $(cat "$T/o")"
run AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=5ea2e615-ca23-451f-9fea-e1b87c369476 LANE_ISSUE_TITLE='Evaluate' LANE_ISSUE_EPIC=SPL-1 DRY_RUN=0
[[ $rc -ne 0 ]] && ! grep -q '^create|' "$T/calls.log" && grep -q 'no spec folder named' "$T/o" &&
  pass "discussion with no LANE_ISSUE_SPEC: refused, nothing filed" || fail "discussion nospec (rc=$rc): $(cat "$T/o")"

echo "spl-lane-issue: $fails failure(s)"
exit "$fails"
