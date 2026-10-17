#!/usr/bin/env bash
# test-lane-issue.sh — every lane carries an issue, keeps it and the docs
# current (owner HUM-10, t1 5ea2e615 msg 346238a8; how it is enforced:
# csi-spl-doc/doc/md/lane-issue-and-docs.md).
#   A. spawn-window.sh: a git lane with a brief and no key is refused (exit
#      12, its claim released) when no issue can be placed; a key is linked,
#      none is filed; a plain dir and a respawn have no issue step.
#   B. spawn-core.inc.sh: the seed's YOUR ISSUE block names the key.
#   C. kill-your-self-report.sh --gate, after the ACCEPTED: refused while the
#      key is wip (no landed commit citing it in its subject scope, no end
#      reason) and when the landed commits change behaviour with neither a
#      csi-spl-doc/ change nor a `Docs: none (<why>)` line.
#      An issue-end `done` record (SPL-2229, work landed in another repo)
#      passes only with the repo + sha do_spl_lane_issue checked.
#   D. the same gate, no landed commit and no end reason: the hub's status
#      (SPL-1813, a stub read, no network): done passes; wip, a failed read,
#      a slow read and another key's done are refused.
#   E. li_brief_epic_spec (the enqueue's check): no issue without an epic
#      and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6): a brief that
#      files an issue names a spec folder on origin/master and its epic.
# Control per refusal: the same case with the gate cut out of a copy of the
# scripts passes, so each check proves the gate, not the fixture.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux
unset LEASE_MACHINE LANE_FLEET SPAWN_BOX SPAWN_REMOTE_CMD SPAWN_PLACE_MAP_CMD SPAWN_DRY_RUN SPAWN_BOX_PICK_CMD \
  SPAWN_ORC_RUN SPAWN_ISSUE SPAWN_ISSUE_CREATE SPAWN_ISSUE_CMD SPAWN_REUSE_ID SPAWN_LANE_TOPIC REPORT_TO
export SPAWN_BOX_PICK=0 SPOOL_BIN=/opt/x/spool MISTRAL_BIN=/opt/x/vibe SPOOL_MISTRAL_MAX_PRICE=1
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' SPAWN_START_CHECK=0

# A repo with an origin (a git lane), and a plain dir.
R="$T_TMP/repo"
g() { git -C "$R" -c user.name='FirstName LastName' -c user.email=dev@example.com "$@"; }
git init -q --bare "$T_TMP/origin.git"
git init -q -b master "$R"
g commit -q --allow-empty -m init
g remote add origin "$T_TMP/origin.git"
g push -q origin master 2>/dev/null
mkdir -p "$T_TMP/plain"
printf '# Brief: fix the widget\n\nOwner words.\n\n## Task\nDo it.\n' >"$T_TMP/nokey.md"
printf '# Brief: fix the gadget\n\nIssue: SPL-77\n\n## Task\nDo it.\n' >"$T_TMP/key.md"

# A copy of the scripts with the placement step cut out (the control).
CTL="$T_TMP/ctl/spawn-agents"; mkdir -p "$CTL"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL/"
sed -i 's/^sw_issue "\$@" || .*$/:/' "$CTL/scripts/spawn-window.sh"
sed -i 's/^  li_gate "\$SPOOL_ROOT" "\$ID" "\$WORKDIR" || return 3$/  :/' "$CTL/scripts/kill-your-self-report.sh"
check "control: the copy has no placement step" sh -c "! grep -q '^sw_issue ' '$CTL/scripts/spawn-window.sh'"
check "control: the copy has no issue gate" sh -c "! grep -q 'li_gate \"' '$CTL/scripts/kill-your-self-report.sh'"

sw() {  # SCRIPTS ENV... -- ARGS -> stdout+stderr in $T_TMP/o, rc in $RC
  local d="$1"; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env "${envs[@]}" bash "$d/spawn-window.sh" "$@" >"$T_TMP/o" 2>&1; RC=$?
}

# --- A. placement -----------------------------------------------------------
sw "$T_SCRIPTS" SPAWN_DRY_RUN=1 SPAWN_ISSUE_CREATE=0 -- claude c-050 "$R" "$T_TMP/nokey.md" widget
eq "A1 no key, filing off: refused, exit 12" 12 "$RC"
has "A1 ... the line says a lane without an issue does not start" "a lane without an issue key does not start" "$(cat "$T_TMP/o")"
has "A1 ... and names the command that files one" "./run -a do_spl_lane_issue" "$(cat "$T_TMP/o")"
sw "$CTL/scripts" SPAWN_DRY_RUN=1 SPAWN_ISSUE_CREATE=0 -- claude c-050 "$R" "$T_TMP/nokey.md" widget
eq "A1 control (no placement step): the same spawn starts -> the refusal is the gate's" 0 "$RC"

sw "$T_SCRIPTS" SPAWN_DRY_RUN=1 -- claude c-051 "$R" "$T_TMP/nokey.md" widget
eq "A2 no key: the dry run plans" 0 "$RC"
has "A2 ... to file one from the brief" "PLAN issue      file one from $T_TMP/nokey.md (wip, assignee c-051)" "$(cat "$T_TMP/o")"

sw "$T_SCRIPTS" SPAWN_DRY_RUN=1 SPAWN_ISSUE_CREATE=0 -- claude c-052 "$R" "$T_TMP/key.md" gadget
eq "A3 the brief's Issue: line: starts with filing off" 0 "$RC"
has "A3 ... and links that key" "PLAN issue      link SPL-77 -> wip, assignee c-052" "$(cat "$T_TMP/o")"
sw "$T_SCRIPTS" SPAWN_DRY_RUN=1 SPAWN_ISSUE=SPL-80 -- claude c-053 "$R" "$T_TMP/nokey.md" widget
has "A3 SPAWN_ISSUE links that key" "PLAN issue      link SPL-80" "$(cat "$T_TMP/o")"

sw "$T_SCRIPTS" SPAWN_DRY_RUN=1 SPAWN_ISSUE_CREATE=0 -- claude c-054 "$T_TMP/plain" "$T_TMP/nokey.md" widget
eq "A4 a plain dir (no git lane): no issue step" 0 "$RC"
hasnt "A4 ... no PLAN issue" "PLAN issue" "$(cat "$T_TMP/o")"
mkdir -p "$SPOOL_ROOT/c-055"
sw "$T_SCRIPTS" SPAWN_DRY_RUN=1 SPAWN_ISSUE_CREATE=0 SPAWN_REUSE_ID=1 -- claude c-055 "$R" "$T_TMP/nokey.md" widget
eq "A5 a respawn (SPAWN_REUSE_ID=1) keeps what it has: no issue step" 0 "$RC"

# A live spawn whose placement fails: refused before any window, claim released.
printf '#!/bin/sh\necho "FATAL spool issue create for $AGENT_ID: hub refused"\nexit 1\n' >"$T_TMP/fail-cmd"
chmod +x "$T_TMP/fail-cmd"
sw "$T_SCRIPTS" SPAWN_ISSUE_CMD="$T_TMP/fail-cmd" -- claude c-056 "$R" "$T_TMP/nokey.md" widget
eq "A6 live, the hub refuses: exit 12" 12 "$RC"
has "A6 ... the hub's FATAL is in the line" "hub refused" "$(cat "$T_TMP/o")"
check "A6 ... the claimed id is released" test ! -e "$SPOOL_ROOT/c-056"
check "A6 ... and no window was made" sh -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-windows -a -F '#{window_name}' | grep -qx c-056"

# --- B. the seed --------------------------------------------------------------
mkdir -p "$T_TMP/plan-b"
SPAWN_DRY_RUN=1 SPAWN_PLAN_DIR="$T_TMP/plan-b" bash "$T_SCRIPTS/spawn-claude.sh" c-060 "$R" "$T_TMP/key.md" gadget >/dev/null 2>&1
s="$(cat "$T_TMP/plan-b/prompt.txt" 2>/dev/null)"
has "B1 the seed names the issue" "YOUR ISSUE: SPL-77 (status wip)" "$s"
has "B1 ... the commit-subject form" "'feat(orc, SPL-77): ...'" "$s"
has "B1 ... the docs rule" "or its message carries the line 'Docs: none (<why>)'" "$s"
has "B1 ... and the end command" "AGENT_ID=c-060 LANE_ISSUE_OP=end" "$s"
mkdir -p "$SPOOL_ROOT/c-061/lifetime" "$T_TMP/plan-b2"; echo SPL-91 >"$SPOOL_ROOT/c-061/lifetime/issue"
SPAWN_DRY_RUN=1 SPAWN_PLAN_DIR="$T_TMP/plan-b2" bash "$T_SCRIPTS/spawn-claude.sh" c-061 "$R" "$T_TMP/nokey.md" widget >/dev/null 2>&1
has "B2 the placed key (lifetime/issue) wins" "YOUR ISSUE: SPL-91" "$(cat "$T_TMP/plan-b2/prompt.txt" 2>/dev/null)"
mkdir -p "$T_TMP/plan-b3"
SPAWN_DRY_RUN=1 SPAWN_PLAN_DIR="$T_TMP/plan-b3" bash "$T_SCRIPTS/spawn-claude.sh" c-062 "$T_TMP/plain" "$T_TMP/nokey.md" widget >/dev/null 2>&1
hasnt "B3 a plain dir: no issue block" "YOUR ISSUE" "$(cat "$T_TMP/plan-b3/prompt.txt" 2>/dev/null)"

# --- C. the exit gate ---------------------------------------------------------
N=0
accepted() {  # ID: an ACCEPTED from its spawner c-928
  N=$((N + 1))
  mkdir -p "$SPOOL_ROOT/$1/archive" "$SPOOL_ROOT/$1/lifetime"
  printf '# Brief\n\nSpawner: c-928\n' >"$SPOOL_ROOT/$1/lifetime/brief.md"
  jq -n --arg id "$(printf 'c%07d-0000-4000-8000-000000000000' "$N")" \
    '{v: 1, msg_id: $id, ts: "2026-10-12T10:00:00Z", from: "c-928", to: "x", kind: "result", task_id: "dispatch-t", body: "ACCEPTED", files: []}' \
    >"$SPOOL_ROOT/$1/archive/a-$N.json"
}
land() {  # MSG FILE...: commit the files on master, push, fetch
  local m="$1" f; shift
  for f in "$@"; do mkdir -p "$R/$(dirname "$f")"; echo "$N $m" >>"$R/$f"; done
  g add -A >/dev/null && g commit -q -m "$m" && g push -q origin master 2>/dev/null && g fetch -q origin
}
gate() {  # SCRIPTS ID -> rc in $RC, stderr in $T_TMP/e
  (cd "$R" && SPOOL_AGENT_ID="$2" bash "$1/kill-your-self-report.sh" --gate "$R" 2>"$T_TMP/e" >/dev/null); RC=$?
}

accepted c-070
gate "$T_SCRIPTS" c-070
eq "C0 no key (placed before the rule): not checked, exit 0" 0 "$RC"
hasnt "C0 ... and silent: the ACCEPTED line stays the one line" "issue gate" "$(cat "$T_TMP/e")"

accepted c-071; echo SPL-5 >"$SPOOL_ROOT/c-071/lifetime/issue"
land "chore: unrelated, mentions SPL-5 only in passing" csi-spl-orc/x.txt
gate "$T_SCRIPTS" c-071
eq "C1 key wip, no commit cites it in its subject scope: refused, exit 3" 3 "$RC"
has "C1 ... the line says still wip" "issue SPL-5 is still wip" "$(cat "$T_TMP/e")"
has "C1 ... and names the end command" "LANE_ISSUE_OP=end" "$(cat "$T_TMP/e")"
has "C1 ... and the done option for work landed in another repo (SPL-2229)" "LANE_ISSUE_STATUS=done LANE_LANDED_REPO=<cnf repo name> LANE_LANDED_SHA=<sha>" "$(cat "$T_TMP/e")"
gate "$CTL/scripts" c-071
eq "C1 control (no issue gate): the same lane exits" 0 "$RC"

printf 'diss\tsuperseded by c-099\t2026-10-12T10:00:00Z\n' >"$SPOOL_ROOT/c-071/lifetime/issue-end"
gate "$T_SCRIPTS" c-071
eq "C2 ended without landing, with a reason: exits" 0 "$RC"
has "C2 ... the reason is in the line" "ended without landing: diss superseded by c-099" "$(cat "$T_TMP/e")"

# SPL-2229: the record do_spl_lane_issue writes after it checked the sha on
# the other repo's origin trunk (c-263's case: dvn-web 9c74186, on its master).
accepted c-078; echo SPL-13 >"$SPOOL_ROOT/c-078/lifetime/issue"
printf 'done\tlanded in dvn-web 9c741867a396 on origin/master\t2026-10-16T10:00:00Z\tdvn-web\t9c741867a396dc4a76bbbc772545d12d06d62e34\n' >"$SPOOL_ROOT/c-078/lifetime/issue-end"
gate "$T_SCRIPTS" c-078
eq "C2b landed in another repo (issue-end done + repo + sha): exits" 0 "$RC"
has "C2b ... the line names the repo and the short sha" "issue gate: SPL-13 landed in another repo: dvn-web 9c741867a396 (checked on its origin trunk)" "$(cat "$T_TMP/e")"
printf 'done\tlanded somewhere\t2026-10-16T10:00:00Z\n' >"$SPOOL_ROOT/c-078/lifetime/issue-end"
gate "$T_SCRIPTS" c-078
eq "C2b a done record with no repo + sha (not the check's): refused" 3 "$RC"
has "C2b ... naming the command that checks it" "LANE_ISSUE_STATUS=done LANE_LANDED_REPO=" "$(cat "$T_TMP/e")"

accepted c-072; echo SPL-6 >"$SPOOL_ROOT/c-072/lifetime/issue"
land "feat(orc, SPL-6): a behaviour change" csi-spl-orc/src/bash/run/thing.func.sh csi-spl-orc/src/bash/tests/thing.tst.sh
gate "$T_SCRIPTS" c-072
eq "C3 landed code, no doc change, no Docs: none: refused, exit 3" 3 "$RC"
has "C3 ... naming the code path" "changes behaviour (csi-spl-orc/src/bash/run/thing.func.sh)" "$(cat "$T_TMP/e")"
gate "$CTL/scripts" c-072
eq "C3 control (no issue gate): the same lane exits" 0 "$RC"
land "doc(SPL-6): the thing, documented" csi-spl-doc/doc/md/thing.md
gate "$T_SCRIPTS" c-072
eq "C4 ... its doc change landed: exits" 0 "$RC"
has "C4 ... the line names the doc commit" "docs: doc change in" "$(cat "$T_TMP/e")"

accepted c-073; echo SPL-7 >"$SPOOL_ROOT/c-073/lifetime/issue"
land "fix(api, SPL-7): an internal fix

Docs: none ()" csi-spl-api/x.go
gate "$T_SCRIPTS" c-073
eq "C5 'Docs: none ()' with no why: refused" 3 "$RC"
land "fix(api, SPL-7): rename a local

Docs: none (no behaviour a reader sees)" csi-spl-api/y.go
gate "$T_SCRIPTS" c-073
eq "C6 'Docs: none (<why>)': exits" 0 "$RC"

accepted c-074; echo SPL-8 >"$SPOOL_ROOT/c-074/lifetime/issue"
land "test(orc, SPL-8): a test only" csi-spl-orc/src/bash/tests/only.tst.sh csi-spl-wui/tests/e2e/a.test.mjs
gate "$T_SCRIPTS" c-074
eq "C7 a test(...) subject never closes (c-341's rule): still wip, refused" 3 "$RC"
has "C7 ... the line names the Closes: form" "'Closes: SPL-8' trailer" "$(cat "$T_TMP/e")"
land "test(orc, SPL-8): one more case

Closes: SPL-8" csi-spl-orc/src/bash/tests/only.tst.sh
gate "$T_SCRIPTS" c-074
eq "C7 ... with a 'Closes: SPL-8' trailer, tests only: no behaviour change, exits" 0 "$RC"
has "C7 ... and says so" "docs: no behaviour change" "$(cat "$T_TMP/e")"

accepted c-075; mkdir -p "$SPOOL_ROOT/c-075/lifetime"
printf '# Brief\n\nSpawner: c-928\nIssue: SPL-9\n' >"$SPOOL_ROOT/c-075/lifetime/brief.md"
gate "$T_SCRIPTS" c-075
eq "C8 the key from the recorded brief's Issue: line (no lifetime/issue): checked, refused" 3 "$RC"

accepted c-076; echo SPL-10 >"$SPOOL_ROOT/c-076/lifetime/issue"
land "fix(api): no key in the scope

Fixes: SPL-10" csi-spl-api/z.go
gate "$T_SCRIPTS" c-076
eq "C9 control: a 'Fixes: SPL-10' line does not close: refused" 3 "$RC"
land "fix(api): no key in the scope either

Closes: SPL-10
Docs: none (internal)" csi-spl-api/z.go
gate "$T_SCRIPTS" c-076
eq "C9 a 'Closes: SPL-10' trailer closes it: exits" 0 "$RC"

# --- D. the hub's status, when nothing landed (SPL-1813) ----------------------
# The stub hub: prints the do_spl_issue_status line for HUB_KEY (default the
# asked key) with HUB_STATUS; HUB_STATUS=down fails, =slow outlasts the timeout.
cat >"$T_TMP/hub-stub" <<'EOS'
#!/bin/sh
echo "$1" >>"$HUB_CALLS"
case "$HUB_STATUS" in
  down) echo "FATAL spool issue get: hub unreachable"; exit 1 ;;
  slow) sleep 5 ;;
esac
printf 'issue-status\t%s\t%s\n' "${HUB_KEY:-$1}" "$HUB_STATUS"
EOS
chmod +x "$T_TMP/hub-stub"
# A copy of the scripts with the hub step cut out: today's code before SPL-1813.
CTL_HUB="$T_TMP/ctl-hub/spawn-agents"; mkdir -p "$CTL_HUB"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$CTL_HUB/"
python3 - "$CTL_HUB/lib/lane-issue.inc.sh" <<'EOP'
import re, sys
p = sys.argv[1]; s = open(p).read()
s2 = re.sub(r'    if \[ "\$\(li_hub_status "\$key"\)" = "done" \]; then\n.*?\n    fi\n', '', s, count=1, flags=re.S)
assert s2 != s
open(p, 'w').write(s2)
EOP
check "control: the copy has no hub step" sh -c "! grep -q 'li_hub_status \"' '$CTL_HUB/lib/lane-issue.inc.sh'"
hub() {  # SCRIPTS ID STATUS [VAR=value]... -> rc in $RC, stderr in $T_TMP/e
  local d="$1" id="$2" st="$3"; shift 3
  : >"$T_TMP/hub-calls"
  (cd "$R" && env HUB_CALLS="$T_TMP/hub-calls" HUB_STATUS="$st" LI_HUB_STATUS_CMD="$T_TMP/hub-stub" "$@" \
    SPOOL_AGENT_ID="$id" bash "$d/kill-your-self-report.sh" --gate "$R" 2>"$T_TMP/e" >/dev/null); RC=$?
}

accepted c-077; echo SPL-11 >"$SPOOL_ROOT/c-077/lifetime/issue"
hub "$T_SCRIPTS" c-077 "done"
eq "D1 no landed commit, done on the hub: exits" 0 "$RC"
has "D1 ... the line says so" "issue gate: SPL-11 done on the hub (no landed commit)" "$(cat "$T_TMP/e")"
eq "D1 ... the hub was asked for that key, once" "SPL-11" "$(cat "$T_TMP/hub-calls")"
hub "$CTL_HUB/scripts" c-077 "done"
eq "D1 control (no hub step, today's code): the same lane is refused" 3 "$RC"

hub "$T_SCRIPTS" c-077 wip
eq "D2 wip on the hub: refused, exit 3" 3 "$RC"
has "D2 ... with today's line" "issue SPL-11 is still wip" "$(cat "$T_TMP/e")"
hub "$T_SCRIPTS" c-077 diss
eq "D2 diss on the hub (not done): refused" 3 "$RC"

hub "$T_SCRIPTS" c-077 down
eq "D3 the hub unreachable: refused, exit 3" 3 "$RC"
has "D3 ... with today's line" "issue SPL-11 is still wip" "$(cat "$T_TMP/e")"
hub "$T_SCRIPTS" c-077 slow LI_HUB_TIMEOUT=1
eq "D3 the hub slower than LI_HUB_TIMEOUT: refused" 3 "$RC"
hub "$T_SCRIPTS" c-077 "done" HUB_KEY=SPL-12
eq "D4 another key's done in the answer: refused" 3 "$RC"
hub "$T_SCRIPTS" c-077 "done" LI_HUB_STATUS_CMD=
eq "D5 a sandbox (SPOOL_TEST=1) with no stub reads no hub: refused" 3 "$RC"
eq "D5 ... and the stub was never called" "" "$(cat "$T_TMP/hub-calls")"

# A landed commit or an end reason is decided before the hub is asked.
hub "$T_SCRIPTS" c-071 wip
eq "D6 an end reason: exits" 0 "$RC"
eq "D6 ... without a hub read" "" "$(cat "$T_TMP/hub-calls")"
hub "$T_SCRIPTS" c-072 wip
eq "D6 a landed commit: exits without a hub read" 0 "$RC"
eq "D6 ... and no hub read" "" "$(cat "$T_TMP/hub-calls")"
# --- E. the epic and spec of a brief that files an issue --------------------
SR="$T_TMP/specs"
sg() { git -C "$SR/repo" -c user.name='FirstName LastName' -c user.email=dev@example.com "$@"; }
git init -q --bare "$SR/origin.git" && git init -q -b master "$SR/repo"
for d in 135-work-process 040-pinned 041-two-pins; do mkdir -p "$SR/repo/csi-spl-doc/specs/$d"; echo "# $d" >"$SR/repo/csi-spl-doc/specs/$d/spec.md"; done
printf '# Spec 040\n\nEpic SPL-74\n' >"$SR/repo/csi-spl-doc/specs/040-pinned/spec.md"
printf '# Spec 041\n\nEpic SPL-75, was Epic SPL-74\n' >"$SR/repo/csi-spl-doc/specs/041-two-pins/spec.md"
sg add -A && sg commit -q -m specs && sg remote add origin "$SR/origin.git" && sg push -q origin master 2>/dev/null
mkdir -p "$SR/repo/csi-spl-doc/specs/099-local-only" && echo x >"$SR/repo/csi-spl-doc/specs/099-local-only/spec.md" && sg add -A && sg commit -q -m local
es() {  # LIB BRIEF-LINES... -> stdout+stderr in $T_TMP/o, rc in $RC
  local lib="$1"; shift
  printf '# Brief: e\n\n%s\n' "$@" >"$T_TMP/es.md"
  LI_SPEC_REPO="$SR/repo" LI_SPEC_FETCH_TIMEOUT=5 bash -c 'do_log() { echo "$*"; }; . "$1"; li_brief_epic_spec "$2"' _ "$lib" "$T_TMP/es.md" >"$T_TMP/o" 2>&1; RC=$?
}
LIB="$T_FEAT/lib/lane-issue.inc.sh"
# Today's code (origin/master before this rule) has no such check: the control.
OLD="$T_TMP/old-lane-issue.inc.sh"
sed '/^# No issue without an epic and a git spec/,$d' "$LIB" >"$OLD"; printf 'li_brief_epic_spec() { return 0; }\n' >>"$OLD"
RULE='no issue without an epic and a git spec (owner HUM-10, t1 7a98c2d1 msg 5863d0d6)'
es "$LIB" 'Epic: SPL-1'
eq "E1 no spec: refused" 1 "$RC"
has "E1 ... one FATAL line names the owner order and what to add" "FATAL refused, nothing filed: $RULE: no spec folder named. Add a 'Spec: csi-spl-doc/specs/<NNN-slug>' line" "$(cat "$T_TMP/o")"
es "$OLD" 'Epic: SPL-1'
eq "E1 control (no check, today's code): passes" 0 "$RC"
es "$LIB" 'Spec: csi-spl-doc/specs/135-work-process'
eq "E2 no epic (none on the brief, no pin): refused" 1 "$RC"
has "E2 ... says to add the Epic: line" "brief $T_TMP/es.md names no epic. Add an 'Epic: SPL-<n>' line (the level-1 epic of csi-spl-doc/specs/135-work-process)" "$(cat "$T_TMP/o")"
es "$OLD" 'Spec: csi-spl-doc/specs/135-work-process'
eq "E2 control (today's code): passes" 0 "$RC"
es "$LIB" 'Spec: csi-spl-doc/specs/098-nowhere' 'Epic: SPL-1'
eq "E3 a spec folder that does not exist: refused" 1 "$RC"
has "E3 ... named" "csi-spl-doc/specs/098-nowhere is not a folder on origin/master" "$(cat "$T_TMP/o")"
es "$LIB" 'Spec: csi-spl-doc/specs/099-local-only' 'Epic: SPL-1'
eq "E3 a spec committed but not on origin/master: refused" 1 "$RC"
es "$OLD" 'Spec: csi-spl-doc/specs/099-local-only' 'Epic: SPL-1'
eq "E3 control (today's code): passes" 0 "$RC"
es "$LIB" 'Spec: csi-spl-doc/specs/135-work-process' 'Epic: SPL-1'
eq "E4 a spec on origin/master and an epic: accepted" 0 "$RC"
eq "E4 ... prints spec and epic" "csi-spl-doc/specs/135-work-process	SPL-1" "$(cat "$T_TMP/o")"
es "$LIB" 'See csi-spl-doc/specs/040-pinned/spec.md section 2.'
eq "E5 a spec named in the text, its pin is the epic" "csi-spl-doc/specs/040-pinned	SPL-74" "$(cat "$T_TMP/o")"
es "$LIB" 'Issue: SPL-77'
eq "E6 an Issue: key (an existing issue, none filed): passes" 0 "$RC"
# E7: one match only. grep -m1 stops after a LINE but -o prints every match on
# it: a line naming the spec twice gave two lines and was refused (c-001 msg
# 97039c74, the reprice brief e20fb61e). Control: the -m1 -o code (27af8c2b1).
M1="$T_TMP/m1-lane-issue.inc.sh"
sed '/LI_SPEC_RE\|Epic:?\[\[:space:\]\]/ { s/ | sed -n 1p//; s/grep -oE/grep -m1 -oE/; }' "$LIB" >"$M1"
TWICE='Spec: csi-spl-doc/specs/135-work-process (see csi-spl-doc/specs/135-work-process/plan.md)'
es "$LIB" "$TWICE" 'Epic: SPL-1'
eq "E7 a Spec: line naming the same folder twice: accepted" 0 "$RC"
eq "E7 ... one spec, one epic" "csi-spl-doc/specs/135-work-process	SPL-1" "$(cat "$T_TMP/o")"
es "$M1" "$TWICE" 'Epic: SPL-1'
eq "E7 control (-m1 -o): refused" 1 "$RC"
es "$LIB" 'Spec: csi-spl-doc/specs/135-work-process, csi-spl-doc/specs/040-pinned' 'Epic: SPL-1'
eq "E8 two folders on the Spec: line: the first" "csi-spl-doc/specs/135-work-process	SPL-1" "$(cat "$T_TMP/o")"
es "$M1" 'Spec: csi-spl-doc/specs/135-work-process, csi-spl-doc/specs/040-pinned' 'Epic: SPL-1'
eq "E8 control (-m1 -o): refused" 1 "$RC"
es "$LIB" 'See csi-spl-doc/specs/040-pinned and csi-spl-doc/specs/135-work-process.'
eq "E9 two folders in the text: the first, its pin" "csi-spl-doc/specs/040-pinned	SPL-74" "$(cat "$T_TMP/o")"
es "$M1" 'See csi-spl-doc/specs/040-pinned and csi-spl-doc/specs/135-work-process.'
eq "E9 control (-m1 -o): refused" 1 "$RC"
es "$LIB" 'Spec: csi-spl-doc/specs/041-two-pins'
eq "E10 a spec line naming two epics: the first pin" "csi-spl-doc/specs/041-two-pins	SPL-75" "$(cat "$T_TMP/o")"
es "$M1" 'Spec: csi-spl-doc/specs/041-two-pins'
eq "E10 control (-m1 -o): not the one first pin" 1 "$([ "$(cat "$T_TMP/o")" = "csi-spl-doc/specs/041-two-pins	SPL-75" ]; echo $?)"
eq "E6 an Issue: key (an existing issue, none filed): passes" 0 "$RC"
t_done
