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
gate "$CTL/scripts" c-071
eq "C1 control (no issue gate): the same lane exits" 0 "$RC"

printf 'diss\tsuperseded by c-099\t2026-10-12T10:00:00Z\n' >"$SPOOL_ROOT/c-071/lifetime/issue-end"
gate "$T_SCRIPTS" c-071
eq "C2 ended without landing, with a reason: exits" 0 "$RC"
has "C2 ... the reason is in the line" "ended without landing: diss superseded by c-099" "$(cat "$T_TMP/e")"

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
t_done
