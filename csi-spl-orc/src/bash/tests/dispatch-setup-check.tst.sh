#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_dispatch_setup (DRY_RUN plan) and do_spl_dispatch_check (a
#          fixture per gap). No live agent, hub or tmux is touched: a fake
#          /proc holds the dispatchers, a scratch state dir holds the desks.
#   1. a fresh box: the dry run PLANs every step and writes nothing
#   2. a complete box: every step is OK, nothing is PLANned (idempotent)
#   3. a settings file newer than the session -> RELAUNCH, never a kill
#   4. the rendered brief carries the ids and no unrendered {TOKEN}
#   5. setup refuses a bad ENV, a bad id, master == failover
#   6. check: a complete box reports no gap and exits 0; a rotation restarts
#      the dispatcher in its setup worktree, so the check stays gap-free
#   7. check: each gap fails it - no process, not auto, missing seat, unread
#      over the max, stale lease, holder not a dispatcher, a loop down,
#      settings not loaded, model mismatch, the unanswered sweep never ran,
#      a hub / WUI input unserved past the grace (CLE-77918)
#   8. setup step 11: the sweep cron line is PLANned, then written once
#   9. the desk-reply rule (2026-10-03, c-002's prd reply refused while the
#      check said "loaded ok"): the brief teaches ONE command, run from the
#      seat's own worktree, that the allow rule matches; a compound taught
#      command, or a rule that matches nothing taught, is a GAP
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'kill ${H1:-} ${H2:-} 2>/dev/null; rm -rf "$T"' EXIT

P="$T/proc" S="$T/spool" ST="$T/state" R="$T/repo"
mkdir -p "$P" "$S" "$ST" "$T/home"
# the hub DB as fixture files: every OD seat seated and in every channel
SUBS="$T/subs"; mkdir -p "$SUBS"
for w in w1 w2; do
  { printf 'chan|lobby\nchan|team\n'
    for a in c-001 c-002 c-003; do printf 'ros|box-desk|%s\nsub|lobby|box-desk|%s|invite\nsub|team|box-desk|%s|invite\n' "$a" "$a" "$a"; done
  } >"$SUBS/$w.txt"
done
# a fake crontab (-l prints the file, <file> replaces it) and the checkout the
# sweep cron line points at, so step 11 never touches the real crontab
mkdir -p "$T/bin" "$T/shared/csi-spl-orc/src/bash/scripts"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
cp "$PROJ_ROOT/src/bash/scripts/unanswered-sweep-cron.sh" "$T/shared/csi-spl-orc/src/bash/scripts/"
git init -q "$R" && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init

# agent <pid> <id> [perm] [model]
agent() {
  mkdir -p "$P/$1" "$R-wt/$2"
  echo claude >"$P/$1/comm"
  printf 'HOME=%s\0SPOOL_AGENT_ID=%s\0' "$T/home" "$2" >"$P/$1/environ"
  printf 'claude\0--permission-mode\0%s\0%s' "${3:-auto}" "${4:+--model}" >"$P/$1/cmdline"
  [[ -n "${4:-}" ]] && printf '\0%s\0' "$4" >>"$P/$1/cmdline"
  ln -sfn "$R-wt/$2" "$P/$1/cwd"
  touch -d '2026-01-01 00:00:00' "$P/$1"
}
seat() { mkdir -p "$ST/desk/$2/box-desk/spool/$1"; touch "$ST/desk/$2/box-desk/pinned"; }

act() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" SPOOL_ROOT="$S" SPL_STATE_DIR="$ST" LEASE_PROC_ROOT="$P" \
    DISPATCH_BOX_USER=boxuser ENV=prd HOME="$T/home" SPOOL_DESK_BOX=box-desk LEASE_ALLOW_STALE=1 DISPATCH_SUBS_DIR="$SUBS" \
    PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" DESK_CRON_SRC="$T/shared" SWEEP_CRON_LOG_DIR="$T/log" \
    DISPATCH_LAG_CMD='echo "$ENV hub current served=a sha=b"; echo "$ENV wui pending served=a sha=b n=1 age=3m (in grace)"' "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/src/bash/run/spl-dispatch-*.func.sh "$PROJ_PATH"/src/bash/run/spl-unanswered-sweep*.func.sh \
      "$PROJ_PATH"/src/bash/run/spl-desk-install-service.func.sh; do source "$f"; done
    "$ACTION"'
}
setup() { act ACTION=do_spl_dispatch_setup "$@"; }
check() { act ACTION=do_spl_dispatch_check "$@"; }

# --- 1. fresh box -------------------------------------------------------------------------
seat CLE-9 w1; rm -rf "$ST/desk/w1/box-desk/spool"; seat CLE-9 w2; rm -rf "$ST/desk/w2/box-desk/spool"
before="$(find "$T" ! -path "$T/o" | sort | md5sum)"
setup >"$T/o" 2>&1; rc=$?
after="$(find "$T" ! -path "$T/o" | sort | md5sum)"
for step in posts-dir lease-conf brief worktree settings exclude spawn desk lease-loops; do
  grep -q "^PLAN $step " "$T/o" || { fail "1. no PLAN $step: $(cat "$T/o")"; }
done
[[ $rc -eq 0 && "$before" == "$after" ]] && grep -q 'DRY_RUN nothing was touched' "$T/o" &&
  pass "1. a fresh box: every step planned, nothing written" || fail "1. rc=$rc changed=$([[ "$before" != "$after" ]] && echo yes) $(cat "$T/o")"
[[ "$(grep -c '^PLAN desk ' "$T/o")" == 4 ]] && grep -q 'TENANT_ID=w2 DESK_AGENT=c-003' "$T/o" &&
  pass "1. a desk per dispatcher per workspace" || fail "1. desks: $(grep desk "$T/o")"
grep -q 'spawn-window.sh claude c-002 .* dispatcher-master' "$T/o" &&
  pass "1. the master is spawned with its fixed id" || fail "1. spawn line: $(grep spawn "$T/o")"

# --- 2. complete box ---------------------------------------------------------------------
for id in c-002 c-003; do seat $id w1; seat $id w2; done
agent 100 c-002; agent 200 c-003
# DRY_RUN=0 writes the file steps; the ensure runs a stub instead of real loops
setup DRY_RUN=0 LEASE_RUN=/bin/true >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$S/dispatch/lease.conf" && "$(stat -c %a "$S/dispatch/posts")" == 2777 && -f "$R-wt/c-003/.claude/settings.local.json" ]] &&
  grep -qx '.claude/settings.local.json' "$R/.git/info/exclude" &&
  pass "2. DRY_RUN=0 writes posts dir, lease.conf, briefs, settings, exclude" || fail "2. live: rc=$rc $(cat "$T/o")"
grep -qF 'Bash(sudo -u boxuser env ENV=prd TENANT_ID=* DESK_AGENT=c-002 * ./run -a do_spl_desk_reply)' "$R-wt/c-002/.claude/settings.local.json" &&
  grep -qF 'Bash(sudo -u boxuser env ENV=prd TENANT_ID=* DESK_AGENT=c-002 * ./run -a do_spl_desk_post)' "$R-wt/c-002/.claude/settings.local.json" &&
  grep -qF 'Bash(sudo -u boxuser env ENV=prd TENANT_ID=* DESK_AGENT=c-002 * ./run -a do_spl_topic_archive)' "$R-wt/c-002/.claude/settings.local.json" &&
  grep -qF 'Bash(sudo -u boxuser env ENV=prd * ./run -a do_spl_unanswered_sweep)' "$R-wt/c-002/.claude/settings.local.json" &&
  grep -qF 'Bash(sudo -u boxuser env ENV=prd ./run -a do_spl_unanswered_sweep)' "$R-wt/c-002/.claude/settings.local.json" &&
  python3 -m json.tool "$R-wt/c-002/.claude/settings.local.json" >/dev/null &&
  ! grep -q 'DESK_AGENT=c-003' "$R-wt/c-002/.claude/settings.local.json" &&
  pass "2. the settings allow reply / post / archive as the seat itself + the unanswered sweep, valid JSON" || fail "2. settings: $(cat "$R-wt/c-002/.claude/settings.local.json")"
for id in c-002 c-003; do touch -d '2025-12-31 00:00:00' "$R-wt/$id/.claude/settings.local.json"; done
setup >"$T/o" 2>&1
grep -v '^PLAN lease-loops' "$T/o" | grep '^PLAN' >/dev/null &&
  fail "2. a complete box still plans: $(grep '^PLAN' "$T/o")" || pass "2. a re-run on a complete box plans nothing but the ensure"
grep -q '^RELAUNCH' "$T/o" && fail "2. RELAUNCH on older settings" || pass "2. settings older than the session: no RELAUNCH"
# fleet mode (CLE-77911): DISPATCH_FLEET writes the fleet lines; a re-run without it keeps them
setup DRY_RUN=0 LEASE_RUN=/bin/true DISPATCH_FLEET=main DISPATCH_MACHINE=pc DISPATCH_PRIORITY=pc,sat DISPATCH_LEASE_TENANT=w1 >"$T/o" 2>&1
grep -qx 'LEASE_PRIORITY=pc,sat' "$S/dispatch/lease.conf" && grep -qx 'LEASE_TENANT=w1' "$S/dispatch/lease.conf" &&
  grep -qx 'LEASE_MACHINE=pc' "$S/dispatch/lease.conf" && ! grep -q '^LEASE_DESK_BOX=' "$S/dispatch/lease.conf" &&
  pass "2. DISPATCH_FLEET writes the fleet lines into lease.conf" || fail "2. fleet conf: $(cat "$S/dispatch/lease.conf")"
setup DRY_RUN=0 LEASE_RUN=/bin/true >"$T/o" 2>&1
grep -qx 'LEASE_FLEET=main' "$S/dispatch/lease.conf" && grep -qx 'LEASE_MASTER=c-002' "$S/dispatch/lease.conf" &&
  pass "2. a re-run without DISPATCH_FLEET keeps fleet mode (never leaves it silently)" || fail "2. fleet dropped: $(cat "$S/dispatch/lease.conf")"
# the asks timer's knobs (CLE-77929): written when given, kept on a re-run, a bad owner id refused
setup DRY_RUN=0 LEASE_RUN=/bin/true DISPATCH_ASKS_OWNER=HUM-10 DISPATCH_ASKS_RERAISE_MIN=20 >"$T/o" 2>&1
setup DRY_RUN=0 LEASE_RUN=/bin/true >"$T/o" 2>&1
grep -qx 'ASKS_OWNER=HUM-10' "$S/dispatch/lease.conf" && grep -qx 'ASKS_RERAISE_MIN=20' "$S/dispatch/lease.conf" && grep -qx 'LEASE_FLEET=main' "$S/dispatch/lease.conf" &&
  pass "2. DISPATCH_ASKS_* write the asks knobs; a re-run keeps them" || fail "2. asks knobs: $(cat "$S/dispatch/lease.conf")"
setup DRY_RUN=0 LEASE_RUN=/bin/true DISPATCH_ASKS_OWNER=owner >"$T/o" 2>&1 && fail "2. accepted DISPATCH_ASKS_OWNER=owner" || pass "2. a non-HUM owner id is refused"
# the per-role rankings (do_spl_lease_rank appends them): a re-run keeps them
# and every other key, byte-identical; a re-run with DISPATCH_FLEET keeps them too
printf 'LEASE_PRIORITY_ORCH=sat,pc\nLEASE_PRIORITY_DISPATCH=pc,sat\n' >>"$S/dispatch/lease.conf"
cp "$S/dispatch/lease.conf" "$T/lc.ranked"
setup DRY_RUN=0 LEASE_RUN=/bin/true >"$T/o" 2>&1
cmp -s "$T/lc.ranked" "$S/dispatch/lease.conf" && grep -qE '^OK +lease-conf ' "$T/o" &&
  pass "2. a re-run keeps the per-role rankings and every other key, byte-identical" ||
  fail "2. ranked re-run: $(diff "$T/lc.ranked" "$S/dispatch/lease.conf")"
setup DRY_RUN=0 LEASE_RUN=/bin/true DISPATCH_FLEET=main DISPATCH_MACHINE=pc DISPATCH_PRIORITY=pc,sat DISPATCH_LEASE_TENANT=w1 >"$T/o" 2>&1
grep -qx 'LEASE_PRIORITY_ORCH=sat,pc' "$S/dispatch/lease.conf" && grep -qx 'LEASE_PRIORITY_DISPATCH=pc,sat' "$S/dispatch/lease.conf" &&
  grep -qx 'ASKS_OWNER=HUM-10' "$S/dispatch/lease.conf" &&
  pass "2. a re-run with DISPATCH_FLEET keeps the per-role rankings" || fail "2. ranks dropped: $(cat "$S/dispatch/lease.conf")"
# back to the local-only conf the rest of this file checks
grep -vE '^(LEASE_(FLEET|MACHINE|PRIORITY[A-Z_]*|ENV|TENANT|DESK_BOX)|ASKS_[A-Z_]+)=' "$S/dispatch/lease.conf" >"$T/lc" && cat "$T/lc" >"$S/dispatch/lease.conf"

# --- 3. settings newer than the session ----------------------------------------------
touch "$R-wt/c-003/.claude/settings.local.json"
setup >"$T/o" 2>&1
grep -q '^RELAUNCH c-003 pid=200' "$T/o" && [[ -d "$P/200" ]] &&
  pass "3. settings written after the start -> RELAUNCH reported, nothing killed" || fail "3. $(cat "$T/o")"
touch -d '2025-12-31 00:00:00' "$R-wt/c-003/.claude/settings.local.json"

# --- 4. rendered brief -----------------------------------------------------------------
b="$S/dispatch/briefs/brief-dispatcher-c-002.md"
grep -q 'You are \*\*c-002\*\*, the \*\*master dispatcher' "$b" && grep -q 'w1, w2' "$b" && grep -q 'sudo -u boxuser env ENV=prd' "$b" &&
  ! grep -qE '\{(ID|ROLE|PEER|ORCH|MASTER|FAILOVER|SPOOL_ROOT|POSTS_DIR|ENV|TENANTS|ORC|BOX_USER|LEASE_RULE|FIRST_STEP)\}' "$b" &&
  pass "4. the brief is rendered with ids, workspaces and the box user" || fail "4. brief: $(head -5 "$b")"
# CLE-77938 (owner 2026-10-02): a new ask never goes to a running lane. Owner
# 2026-10-03: the OD that takes a post answers it, owns the topic, does the
# work itself, and spawns a NEW lane only for real lane work; 3-minute answers.
grep -q 'You never forward a new ask to a running lane' "$b" && grep -q '^| a \*\*new ask that is real lane work\*\* .*| spawn a NEW lane' "$b" &&
  ! grep -q 'about an area a \*\*live lane owns\*\*' "$b" &&
  pass "4. the brief gives every new lane-work ask a new lane" || fail "4. new-ask rule: $(grep -n 'new ask\|lane owns' "$b")"
grep -q 'answered within 3 minutes' "$b" && grep -q 'you own that topic' "$b" && grep -q 'Do the work yourself' "$b" &&
  ! grep -q 'does not read raw traffic' "$b" &&
  pass "4. the brief carries the owner rule of 2026-10-03: take, answer, own the topic, 3 minutes" || fail "4. owner rule: $(sed -n 1,20p "$b")"

# --- 5. refusals ---------------------------------------------------------------------------
setup ENV=stg >/dev/null 2>&1 && fail "5. ENV=stg accepted" || pass "5. ENV=stg refused"
setup DISPATCH_MASTER='x;y' >/dev/null 2>&1 && fail "5. bad id accepted" || pass "5. a bad id is refused"
setup DISPATCH_FAILOVER=c-002 >/dev/null 2>&1 && fail "5. master == failover accepted" || pass "5. master == failover refused"

# --- 6. check: complete box ---------------------------------------------------------------
echo "c-002 $(date +%s)" >"$S/dispatch/lease"
# The holders outlive every check below, however loaded the box (a 30 s hold
# ran out before check 7 under a parallel suite); the trap stops them.
( exec 7>"$S/dispatch/renew.run"; flock 7; exec sleep 600 ) & H1=$!
( exec 7>"$S/dispatch/watch.run"; flock 7; exec sleep 600 ) & H2=$!
sleep 0.3
printf 'ts=%s\nopen=2\nper=w1=2\nto=c-002\nsent=ok\n' "$(date +%s)" >"$S/dispatch/unanswered.last"
date +%s >"$S/dispatch/rotate.dispatch.last"
check >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'dispatch check: no gap' "$T/o" && grep -q '| c-003 desks | 2/2 workspaces | ok |' "$T/o" &&
  pass "6. a complete box: no gap, exit 0" || fail "6. rc=$rc $(cat "$T/o")"
grep -qE '\| unanswered sweep \| last [0-9]+s ago to c-002, 2 open \(w1=2\) \| ok \|' "$T/o" &&
  pass "6. the sweep row shows its age and open count" || fail "6. sweep row: $(grep -i sweep "$T/o")"
# 2026-10-01: from the desk cron's checkout (a second worktree of the same
# repo) the check looked for <that checkout>-wt/c-002 and saw GAPs
git -C "$R" worktree add -q --detach "$T/cron-co"
check APP_PATH="$T/cron-co" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '| c-002 desk-reply permission | loaded | ok |' "$T/o" &&
  pass "6. run from a second worktree: the dispatcher worktrees of the main checkout" || fail "6. second worktree: rc=$rc $(cat "$T/o")"
mkdir -p "$T/plain" "$S/agents"
printf '{"id": "c-002", "worktree": "%s"}\n' "$R-wt/c-002" >"$S/agents/c-002.json"
printf '{"id": "c-003", "worktree": "%s"}\n' "$R-wt/c-003" >"$S/agents/c-003.json"
check APP_PATH="$T/plain" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '| c-003 desk-reply permission | loaded | ok |' "$T/o" &&
  pass "6. outside any checkout: the worktree from the identity map" || fail "6. identity map: rc=$rc $(cat "$T/o")"
rm -rf "$S/agents"
# a rotation (task 6a02db62): at 2026-10-02 11:00Z the rotation started the
# fresh dispatchers in <setup worktree>-wt/<id>, a new worktree without the
# settings - 2 GAP rows. The real path: spl_rotate_workdir (the id's newest
# registry rundir) -> spawn-core's worktree choice (dry run) -> the check.
G="$T/g"; mkdir -p "$G/spool"; echo brief >"$G/brief.md"
git init -q --bare "$G/origin.git"
git init -q "$G/repo" && git -C "$G/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$G/repo" branch -M master && git -C "$G/repo" remote add origin "$G/origin.git" && git -C "$G/repo" push -q origin master 2>/dev/null
git -C "$G/repo" fetch -q origin
git -C "$G/repo" worktree add -q -b c-002-dispatcher-master "$G/repo-wt/c-002" origin/master
mkdir -p "$G/repo-wt/c-002/.claude" && cp "$R-wt/c-002/.claude/settings.local.json" "$G/repo-wt/c-002/.claude/"
touch -d '2025-12-31 00:00:00' "$G/repo-wt/c-002/.claude/settings.local.json"
# the live shape the 11:00Z rotation left: a worktree nested in the setup one
git -C "$G/repo-wt/c-002" worktree add -q -b c-002-rotate "$G/repo-wt/c-002-wt/c-002" origin/master
rot_cwd() {  # <registry rundir> -> the dir the rotation's spawn runs the new session in
  printf 'c-002\tclaude\t%%9\t%s\t20261002T110253Z\n' "$1" >"$G/spool/registry.tsv"
  local wd
  wd="$(env SPOOL_ROOT="$G/spool" bash -c 'do_log() { :; }; source "$1/src/bash/run/spl-rotate-lib.func.sh"; spl_rotate_workdir c-002' _ "$PROJ_ROOT")"
  env -u TMUX -u TMUX_PANE -u SPOOL_AGENT_ID SPAWN_DRY_RUN=1 SPAWN_TEST_SANDBOX=1 SPOOL_TEST=1 SPAWN_REUSE_ID=1 SPOOL_NOW=2026-10-02T12:00:00Z \
    SPOOL_ROOT="$G/spool" SPOOL_TMUX_SOCKET="$G/tmux.sock" SPOOL_BOX_USER="$(id -un)" SPOOL_AGENT_USER="$(id -un)" SPOOL_BOX_TAG= \
    bash "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-claude.sh" c-002 "$wd" "$G/brief.md" rotate 2>&1 |
    sed -nE 's/^PLAN worktree +(reuse|add) ([^ ]+).*/\2/p'
}
for from in "$G/repo-wt/c-002" "$G/repo-wt/c-002-wt/c-002"; do
  cwd="$(rot_cwd "$from")"
  [[ "$cwd" == "$G/repo-wt/c-002" && -f "$cwd/.claude/settings.local.json" ]] &&
    pass "6. a rotation from ${from#"$G"/} restarts in the setup worktree, settings there" ||
    fail "6. rotation from ${from#"$G"/}: the new session runs in '${cwd:-nothing}'"
  # the new session as spawn records it: its cwd, and the identity map's worktree
  rm -rf "$P/100"; agent 100 c-002; ln -sfn "$cwd" "$P/100/cwd"
  mkdir -p "$S/agents"; printf '{"id": "c-002", "worktree": "%s"}\n' "$cwd" >"$S/agents/c-002.json"
  check >"$T/o" 2>&1; rc=$?
  [[ $rc -eq 0 ]] && grep -q '| c-002 desk-reply permission | loaded | ok |' "$T/o" && ! grep -q 'GAP' "$T/o" &&
    pass "6. ... and do_spl_dispatch_check shows no GAP row" || fail "6. check after the rotation: rc=$rc $(grep GAP "$T/o")"
done
rm -rf "$S/agents" "$P/100"; agent 100 c-002
# a test workspace's desk is no dispatcher gap (the sweep's shared list)
mkdir -p "$ST/desk/w12live1/box-desk"; touch "$ST/desk/w12live1/box-desk/pinned"
echo 'w12live1  # a dev proof' >"$S/dispatch/test-workspaces"
check >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '| c-002 desks | 2/2 workspaces | ok |' "$T/o" &&
  pass "6. a workspace on the test-workspaces list is left out" || fail "6. test list: rc=$rc $(cat "$T/o")"
rm -f "$S/dispatch/test-workspaces"
check >"$T/o" 2>&1
grep -q 'c-002 desks | 2/3, missing: w12live1' "$T/o" &&
  pass "6. off the list it is a seat gap (the control)" || fail "6. control: $(grep desks "$T/o")"
rm -rf "$ST/desk/w12live1"

# --- 7. each gap fails the check -----------------------------------------------------------
gap() { # <label> <expected verdict regex> -- env...
  local label="$1" re="$2"; shift 2
  check "$@" >"$T/o" 2>&1; local rc=$?
  [[ $rc -ne 0 ]] && grep -qE "$re" "$T/o" && pass "7. $label" || fail "7. $label: rc=$rc $(cat "$T/o")"
}
mv "$P/200" "$T/p200"; gap "no failover process" 'c-003 process .*GAP not running'; mv "$T/p200" "$P/200"
agent 100 c-002 default; gap "permission mode not auto" 'c-002 permission mode \| default \| GAP'; agent 100 c-002
agent 100 c-002 auto claude-other-1; gap "model mismatch" 'c-002 model \| claude-other-1 \| GAP' DISPATCH_MODEL=claude-opus; agent 100 c-002
rm -rf "$ST/desk/w2/box-desk/spool/c-002"; gap "missing seat" 'c-002 desks \| 1/2, missing: w2'; seat c-002 w2
mkdir -p "$S/c-003/inbox"; for i in 1 2 3; do touch "$S/c-003/inbox/m$i.json"; done
gap "unread over the max" 'c-003 unread \| 3 \| GAP' DISPATCH_UNREAD_MAX=2; rm -rf "$S/c-003/inbox"
echo "c-002 $(( $(date +%s) - 500 ))" >"$S/dispatch/lease"; gap "stale lease" 'lease \| c-002, 50[0-9]s old \| GAP stale'
echo "CLE-77 $(date +%s)" >"$S/dispatch/lease"; gap "holder not a dispatcher" 'GAP holder is not a dispatcher'
echo "c-002 $(date +%s)" >"$S/dispatch/lease"
touch "$R-wt/c-002/.claude/settings.local.json"; gap "settings not loaded" 'c-002 desk-reply permission .*GAP relaunch'
touch -d '2025-12-31 00:00:00' "$R-wt/c-002/.claude/settings.local.json"
cp "$SUBS/w2.txt" "$T/w2.keep"
check >"$T/o" 2>&1
grep -qF '| w2 #team | OD seats 3/3 | ok |' "$T/o" && grep -qF '| w2 OD seats | every fleet OD seat seated | ok |' "$T/o" &&
  pass "7. every OD seat in a channel, the orchestrator included, is ok (owner 2026-10-03)" || fail "7. full channel: $(grep 'w2' "$T/o")"
grep -v 'sub|team|box-desk|c-001' "$T/w2.keep" >"$SUBS/w2.txt"
gap "the orchestrator missing from a channel" '\| w2 #team \| OD seats 2/3, missing: c-001@box-desk \| GAP do_spl_dispatch_subscribe'
grep -v 'sub|lobby|box-desk|c-003' "$T/w2.keep" >"$SUBS/w2.txt"
gap "a dispatcher missing from a channel" '\| w2 #lobby \| OD seats 2/3, missing: c-003@box-desk \| GAP'
grep -v 'c-003' "$T/w2.keep" >"$SUBS/w2.txt"
gap "an OD seat the workspace does not seat" '\| w2 OD seats \| unseated: c-003@box-desk \| GAP seat it'
cp "$T/w2.keep" "$SUBS/w2.txt"
echo 'hum|6|2' >>"$SUBS/w2.txt"
gap "people post, the desk receives nothing (CLE-77876)" '\| w2 inbound \| 6 human posts in 120 min, 0 inbound files .*\| GAP SILENT \|'
gap "unsigned human posts (CLE-77876)" '\| w2 inbound \| 2 of 6 human posts .*\| GAP UNSIGNED \|'
# 2026-10-03 (sat): the fleet lease held on another box - that box's desk gets
# the posts, this one's is silent by design: no SILENT GAP, UNSIGNED still is
echo 'hum|6|0' >"$T/hum"; cp "$T/w2.keep" "$SUBS/w2.txt"; cat "$T/hum" >>"$SUBS/w2.txt"
echo "c-002@other-box $(date +%s)" >"$S/dispatch/lease"; check >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qF '| w2 inbound | this box'"'"'s desk is not the dispatch desk | ok (held by c-002@other-box) |' "$T/o" && ! grep -q 'SILENT' "$T/o" &&
  pass "7. lease held on another box: the silent desk here is ok, no GAP" || fail "7. remote holder: rc=$rc $(grep -E 'inbound|GAP' "$T/o")"
cp "$T/w2.keep" "$SUBS/w2.txt"; echo 'hum|6|2' >>"$SUBS/w2.txt"
gap "lease held elsewhere: UNSIGNED still fires" '\| w2 inbound \| 2 of 6 human posts .*\| GAP UNSIGNED \|'
cp "$T/w2.keep" "$SUBS/w2.txt"; cat "$T/hum" >>"$SUBS/w2.txt"
echo "c-002@box-desk $(date +%s)" >"$S/dispatch/lease"
gap "lease held on this box (<ID>@<box>): SILENT still fires" '\| w2 inbound \| 6 human posts in 120 min, 0 inbound files .*\| GAP SILENT \|'
echo "c-002 $(date +%s)" >"$S/dispatch/lease"
cp "$T/w2.keep" "$SUBS/w2.txt"
# CLE-77918: a hub / WUI input unserved past the grace is a GAP row; the
# served/oldest commits are its value, so the tick keys it on env+component
LAGCMD='if [ "$ENV" = prd ]; then echo "prd hub lagging served=ef4803e5 sha=0e72d9e0 n=5 oldest=af06b13e age=54m grace=${GRACE_MINUTES}m url=https://x/version"; else echo "$ENV hub current served=a"; fi; echo "$ENV wui current served=a"'
gap "prd hub unserved past the grace (CLE-77918)" '\| deploy lag prd hub \| served=ef4803e5 sha=0e72d9e0 n=5 oldest=af06b13e age=54m grace=30m \| GAP trunk input not served after 30 min' DISPATCH_LAG_CMD="$LAGCMD"
grep -qE '\| deploy lag dev hub \| current served=a \| ok \|' "$T/o" && ! grep -q 'url=' "$T/o" &&
  pass "7. dev current stays ok next to it; the probe url is not in the row" || fail "7. lag rows: $(grep 'deploy lag' "$T/o")"
check DISPATCH_LAG_CMD='echo "$ENV hub unknown url=x reason=unreachable"; echo "$ENV wui current"' >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qE '\| deploy lag prd hub \| unknown reason=unreachable \| cannot tell \|' "$T/o" &&
  pass "7. an unreadable endpoint is 'cannot tell', never a GAP" || fail "7. unknown: rc=$rc $(grep 'deploy lag' "$T/o")"
check DISPATCH_DEPLOY_LAG=0 >"$T/o" 2>&1
grep -q 'deploy lag' "$T/o" && fail "7. DISPATCH_DEPLOY_LAG=0 still printed lag rows" || pass "7. DISPATCH_DEPLOY_LAG=0 skips the lag rows"
kill "$H2" 2>/dev/null; wait "$H2" 2>/dev/null; sleep 0.2; gap "watch loop down" 'lease watch loop \| not running \| GAP'
kill "$H1" 2>/dev/null; wait "$H1" 2>/dev/null
mv "$S/dispatch/unanswered.last" "$T/last.keep"; gap "the unanswered sweep never ran" 'unanswered sweep \| never ran \| GAP'
# spec 060 FR-072: the dispatcher rotation row
echo $(( $(date +%s) - 20000 )) >"$S/dispatch/rotate.dispatch.last"
gap "the dispatcher rotation is 3 h late (FR-072)" 'dispatch rotation \| last done 200[0-9][0-9]s ago \| GAP over 10800s'
echo ROTATE_DISPATCH=0 >"$S/dispatch/rotate.conf"; check >"$T/o" 2>&1
grep -q '| dispatch rotation | switched off (rotate.conf) | ok |' "$T/o" && pass "7. rotation switched off: no rotation GAP" || fail "7. switch: $(grep 'dispatch rotation' "$T/o")"
rm -f "$S/dispatch/rotate.conf" "$S/dispatch/rotate.dispatch.last"
gap "the dispatcher rotation never ran (FR-072)" 'dispatch rotation \| never ran \| GAP'

# --- 9. the desk-reply rule matches the taught command ------------------------------------------
b="$S/dispatch/briefs/brief-dispatcher-c-002.md"
taught="$(grep -o '`sudo -u boxuser env ENV=prd [^`]*do_spl_desk_reply`' "$b" | sed -n 1p)"
[[ "$taught" == *"DESK_AGENT=c-002 "*"DESK_BODY_FILE=<file> "* && "$taught" != *'$('* && "$taught" != *'&&'* ]] &&
  grep -qF "You post from \`$R-wt/c-002/csi-spl-orc\`" "$b" &&
  pass "9. the brief teaches one command, body from a file, run from the seat's own worktree" || fail "9. taught: '$taught' $(grep -n do_spl_desk_reply "$b")"
nine() { check DISPATCH_CHECK_SUBS=0 DISPATCH_SWEEP=0 DISPATCH_DEPLOY_LAG=0 >"$T/o" 2>&1; grep 'desk-reply permission' "$T/o"; }
nine | grep '| c-002 desk-reply permission | loaded | ok |' >/dev/null &&
  pass "9. the rule matches the taught command: ok" || fail "9. match: $(grep desk-reply "$T/o")"
# the control: the compound form c-002 was refused on (cd outside the worktree, body via $(cat))
cp "$b" "$T/b.keep"
python3 - "$b" <<'PY2'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r"`sudo -u boxuser env ENV=prd [^`]*do_spl_desk_reply`",
           lambda m: '`cd /x/csi-spl-orc && sudo -u boxuser env ENV=prd TENANT_ID=<workspace> DESK_AGENT=c-002 DRY_RUN=0 DESK_BODY="$(cat <file>)" ./run -a do_spl_desk_reply`', s)
open(sys.argv[1], "w").write(s)
PY2
nine | grep -E '\| c-002 desk-reply permission \| .*\| GAP the taught command is not one command the rule allows' >/dev/null &&
  pass "9. control: a compound taught command -> GAP" || fail "9. compound: $(grep desk-reply "$T/o")"
cp "$T/b.keep" "$b"
# a rule that matches no taught command (another seat's id)
cp "$R-wt/c-002/.claude/settings.local.json" "$T/s.keep"
sed -i 's/DESK_AGENT=c-002/DESK_AGENT=c-003/' "$R-wt/c-002/.claude/settings.local.json"
touch -d '2025-12-31 00:00:00' "$R-wt/c-002/.claude/settings.local.json"
nine | grep -E '\| c-002 desk-reply permission \| .*\| GAP the taught command is not one command the rule allows' >/dev/null &&
  pass "9. a rule that matches no taught command -> GAP" || fail "9. rule: $(grep desk-reply "$T/o")"
cp "$T/s.keep" "$R-wt/c-002/.claude/settings.local.json"; touch -d '2025-12-31 00:00:00' "$R-wt/c-002/.claude/settings.local.json"

# --- 8. setup step 11: the sweep cron ----------------------------------------------------------
rm -f "$T/crontab"
setup >"$T/o" 2>&1
grep -q '^    +2-59/10 \* \* \* \* ENV=prd .*unanswered-sweep-cron.sh .*# csi-spl:unanswered-sweep$' "$T/o" && [[ ! -e "$T/crontab" ]] &&
  pass "8. the dry run shows the sweep cron line, writes nothing" || fail "8. dry: $(cat "$T/o")"
setup DRY_RUN=0 LEASE_RUN=/bin/true >"$T/o" 2>&1; setup DRY_RUN=0 LEASE_RUN=/bin/true >>"$T/o" 2>&1
[[ "$(grep -c '# csi-spl:unanswered-sweep$' "$T/crontab" 2>/dev/null)" == 1 ]] &&
  pass "8. DRY_RUN=0 installs the sweep cron once (idempotent)" || fail "8. crontab: $(cat "$T/crontab" 2>/dev/null) $(tail -5 "$T/o")"
setup DISPATCH_SWEEP=0 >"$T/o" 2>&1
grep -q 'unanswered-sweep' "$T/o" && fail "8. DISPATCH_SWEEP=0 still ran step 11" || pass "8. DISPATCH_SWEEP=0 skips step 11"

echo "dispatch-setup-check: $fails failure(s)"
[[ $fails -eq 0 ]]
