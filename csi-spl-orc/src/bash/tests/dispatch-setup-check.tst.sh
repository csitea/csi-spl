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
#   6. check: a complete box reports no gap and exits 0
#   7. check: each gap fails it - no process, not auto, missing seat, unread
#      over the max, stale lease, holder not a dispatcher, a loop down,
#      settings not loaded, model mismatch
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

P="$T/proc" S="$T/spool" ST="$T/state" R="$T/repo"
mkdir -p "$P" "$S" "$ST" "$T/home"
# the hub DB as fixture files: both dispatchers in every channel, CLE-001 in none
SUBS="$T/subs"; mkdir -p "$SUBS"
for w in w1 w2; do
  printf 'chan|lobby\nchan|team\nsub|lobby|box-desk|CLE-002|invite\nsub|lobby|box-desk|CLE-003|invite\nsub|team|box-desk|CLE-002|invite\nsub|team|box-desk|CLE-003|invite\n' >"$SUBS/$w.txt"
done
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
    DISPATCH_BOX_USER=boxuser ENV=prd HOME="$T/home" LEASE_ALLOW_STALE=1 DISPATCH_SUBS_DIR="$SUBS" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/src/bash/run/spl-dispatch-*.func.sh; do source "$f"; done
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
[[ "$(grep -c '^PLAN desk ' "$T/o")" == 4 ]] && grep -q 'TENANT_ID=w2 DESK_AGENT=CLE-003' "$T/o" &&
  pass "1. a desk per dispatcher per workspace" || fail "1. desks: $(grep desk "$T/o")"
grep -q 'spawn-window.sh claude CLE-002 .* dispatcher-master' "$T/o" &&
  pass "1. the master is spawned with its fixed id" || fail "1. spawn line: $(grep spawn "$T/o")"

# --- 2. complete box ---------------------------------------------------------------------
for id in CLE-002 CLE-003; do seat $id w1; seat $id w2; done
agent 100 CLE-002; agent 200 CLE-003
# DRY_RUN=0 writes the file steps; the ensure runs a stub instead of real loops
setup DRY_RUN=0 LEASE_RUN=/bin/true >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$S/dispatch/lease.conf" && "$(stat -c %a "$S/dispatch/posts")" == 2777 && -f "$R-wt/CLE-003/.claude/settings.local.json" ]] &&
  grep -qx '.claude/settings.local.json' "$R/.git/info/exclude" &&
  pass "2. DRY_RUN=0 writes posts dir, lease.conf, briefs, settings, exclude" || fail "2. live: rc=$rc $(cat "$T/o")"
grep -q 'sudo -u boxuser env ENV=prd \* ./run -a do_spl_desk_reply' "$R-wt/CLE-002/.claude/settings.local.json" &&
  pass "2. the settings allow desk replies only" || fail "2. settings: $(cat "$R-wt/CLE-002/.claude/settings.local.json")"
for id in CLE-002 CLE-003; do touch -d '2025-12-31 00:00:00' "$R-wt/$id/.claude/settings.local.json"; done
setup >"$T/o" 2>&1
grep -v '^PLAN lease-loops' "$T/o" | grep -q '^PLAN' &&
  fail "2. a complete box still plans: $(grep '^PLAN' "$T/o")" || pass "2. a re-run on a complete box plans nothing but the ensure"
grep -q '^RELAUNCH' "$T/o" && fail "2. RELAUNCH on older settings" || pass "2. settings older than the session: no RELAUNCH"

# --- 3. settings newer than the session ----------------------------------------------
touch "$R-wt/CLE-003/.claude/settings.local.json"
setup >"$T/o" 2>&1
grep -q '^RELAUNCH CLE-003 pid=200' "$T/o" && [[ -d "$P/200" ]] &&
  pass "3. settings written after the start -> RELAUNCH reported, nothing killed" || fail "3. $(cat "$T/o")"
touch -d '2025-12-31 00:00:00' "$R-wt/CLE-003/.claude/settings.local.json"

# --- 4. rendered brief -----------------------------------------------------------------
b="$S/dispatch/briefs/brief-dispatcher-CLE-002.md"
grep -q 'You are \*\*CLE-002\*\*, the \*\*master dispatcher' "$b" && grep -q 'w1, w2' "$b" && grep -q 'sudo -u boxuser env ENV=prd' "$b" &&
  ! grep -qE '\{(ID|ROLE|PEER|ORCH|MASTER|FAILOVER|SPOOL_ROOT|POSTS_DIR|ENV|TENANTS|ORC|BOX_USER|LEASE_RULE|FIRST_STEP)\}' "$b" &&
  pass "4. the brief is rendered with ids, workspaces and the box user" || fail "4. brief: $(head -5 "$b")"

# --- 5. refusals ---------------------------------------------------------------------------
setup ENV=stg >/dev/null 2>&1 && fail "5. ENV=stg accepted" || pass "5. ENV=stg refused"
setup DISPATCH_MASTER='x;y' >/dev/null 2>&1 && fail "5. bad id accepted" || pass "5. a bad id is refused"
setup DISPATCH_FAILOVER=CLE-002 >/dev/null 2>&1 && fail "5. master == failover accepted" || pass "5. master == failover refused"

# --- 6. check: complete box ---------------------------------------------------------------
echo "CLE-002 $(date +%s)" >"$S/dispatch/lease"
( exec 7>"$S/dispatch/renew.run"; flock 7; sleep 30 ) & H1=$!
( exec 7>"$S/dispatch/watch.run"; flock 7; sleep 30 ) & H2=$!
sleep 0.3
check >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'dispatch check: no gap' "$T/o" && grep -q '| CLE-003 desks | 2/2 workspaces | ok |' "$T/o" &&
  pass "6. a complete box: no gap, exit 0" || fail "6. rc=$rc $(cat "$T/o")"

# --- 7. each gap fails the check -----------------------------------------------------------
gap() { # <label> <expected verdict regex> -- env...
  local label="$1" re="$2"; shift 2
  check "$@" >"$T/o" 2>&1; local rc=$?
  [[ $rc -ne 0 ]] && grep -qE "$re" "$T/o" && pass "7. $label" || fail "7. $label: rc=$rc $(cat "$T/o")"
}
mv "$P/200" "$T/p200"; gap "no failover process" 'CLE-003 process .*GAP not running'; mv "$T/p200" "$P/200"
agent 100 CLE-002 default; gap "permission mode not auto" 'CLE-002 permission mode \| default \| GAP'; agent 100 CLE-002
agent 100 CLE-002 auto claude-other-1; gap "model mismatch" 'CLE-002 model \| claude-other-1 \| GAP' DISPATCH_MODEL=claude-opus; agent 100 CLE-002
rm -rf "$ST/desk/w2/box-desk/spool/CLE-002"; gap "missing seat" 'CLE-002 desks \| 1/2, missing: w2'; seat CLE-002 w2
mkdir -p "$S/CLE-003/inbox"; for i in 1 2 3; do touch "$S/CLE-003/inbox/m$i.json"; done
gap "unread over the max" 'CLE-003 unread \| 3 \| GAP' DISPATCH_UNREAD_MAX=2; rm -rf "$S/CLE-003/inbox"
echo "CLE-002 $(( $(date +%s) - 500 ))" >"$S/dispatch/lease"; gap "stale lease" 'lease \| CLE-002, 50[0-9]s old \| GAP stale'
echo "CLE-77 $(date +%s)" >"$S/dispatch/lease"; gap "holder not a dispatcher" 'GAP holder is not a dispatcher'
echo "CLE-002 $(date +%s)" >"$S/dispatch/lease"
touch "$R-wt/CLE-002/.claude/settings.local.json"; gap "settings not loaded" 'CLE-002 desk-reply permission .*GAP relaunch'
touch -d '2025-12-31 00:00:00' "$R-wt/CLE-002/.claude/settings.local.json"
cp "$SUBS/w2.txt" "$T/w2.keep"; echo 'sub|team|box-desk|CLE-001|invite' >>"$SUBS/w2.txt"
gap "orchestrator subscribed to a channel" '\| w2 #team \| dispatchers y, CLE-001 y \| GAP'
grep -v 'CLE-003' "$T/w2.keep" >"$SUBS/w2.txt"
gap "a dispatcher missing from a channel" '\| w2 #lobby \| dispatchers n, CLE-001 n \| GAP'
cp "$T/w2.keep" "$SUBS/w2.txt"
kill "$H2" 2>/dev/null; wait "$H2" 2>/dev/null; sleep 0.2; gap "watch loop down" 'lease watch loop \| not running \| GAP'
kill "$H1" 2>/dev/null; wait "$H1" 2>/dev/null

echo "dispatch-setup-check: $fails failure(s)"
[[ $fails -eq 0 ]]
