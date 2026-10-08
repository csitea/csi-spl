#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the box-restart pair on fixtures (a fake /proc, ps, registry,
# desk-cron clone and spool-send) in a mktemp dir.
#   1. do_spl_box_restart_prepare: the dry run (default) plans the snapshot and
#      the notes and writes, fetches and sends nothing; an MCP child is not a
#      second session; an id with no registry row is not listed
#   2. DRY_RUN=0 checks the desk-cron out at origin/master, writes the
#      snapshot and sends one note per live agent but the sender; no sender
#      is refused
#   3. do_spl_box_restart_check: every id back once passes; a missing id
#      (control) and a doubled id fail; --resume is counted, the wd BOOT line
#      shown; no snapshot fails
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool" P="$T/proc" D="$T/desk" O="$T/origin.git"
mkdir -p "$SP/dispatch" "$P" "$T/bin"
printf 'c-901\tclaude\t%%1\t/x\t20261008T000000Z\nc-902\tclaude\t%%2\t/x\t20261008T000000Z\tc-001\nc-903\tclaude\t%%3\t/x\t20261008T000000Z\n' >"$SP/registry.tsv"
touch "$SP/dispatch/wd.c-901" "$SP/dispatch/wd.c-902"
# proc PID ID - a fake /proc/<pid>/environ carrying SPOOL_AGENT_ID=<id>
proc() { mkdir -p "$P/$1"; printf 'HOME=/x\0SPOOL_AGENT_ID=%s\0' "$2" >"$P/$1/environ"; }
boot() { echo "btime $1" >"$P/stat"; }
boot 1000
cat >"$T/ps" <<'EOF'
100 1 claude claude --dangerously-skip-permissions
101 100 node node mcp-server
200 1 bash bash launcher
201 200 claude claude --dangerously-skip-permissions
300 1 claude claude
EOF
proc 100 c-901; proc 101 c-901; proc 200 c-902; proc 201 c-902; proc 300 c-999

gq() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
W="$O.work"; F=csi-spl-orc/src/bash/run/spl-watchdog.func.sh
gq init "$W"; mkdir -p "$W/${F%/*}"; printf 'spl_wd_boot_pass\nspl_wd_boot_pass\n' >"$W/$F"
gq -C "$W" add -A; gq -C "$W" commit -m one; gq clone --bare "$W" "$O"; gq clone "$O" "$D"
echo x >>"$W/$F"; gq -C "$W" commit -am two; gq -C "$W" push "$O" master
head0="$(git -C "$D" rev-parse HEAD)"; head1="$(git -C "$W" rev-parse HEAD)"

printf '#!/bin/sh\necho "send $*" >>"%s"\n' "$T/sent.log" >"$T/bin/send"; chmod +x "$T/bin/send"
run() {
  local s="$1"; shift
  SNIPPET="$s" in_orc SPOOL_ROOT="$SP" LEASE_PROC_ROOT="$P" BOX_RESTART_PS_CMD="cat $T/ps" BOX_RESTART_DESK="$D" \
    BOX_RESTART_SEND="$T/bin/send" BOX_RESTART_NOW=20261008T120000Z SPOOL_AGENT_ID=c-901 "$@" 2>&1
}

# ---- 1. the dry run -------------------------------------------------------------
out="$(run do_spl_box_restart_prepare)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$SP/dispatch/box-restart" ] && [ ! -e "$T/sent.log" ] && [ "$(git -C "$D" rev-parse HEAD)" = "$head0" ] \
  && pass "1. the dry run writes, fetches and sends nothing" || fail "1. dry run (rc $rc: $out)"
grep -qP '^  agent\tc-901\t100\t%1$' <<<"$out" && grep -qP '^  agent\tc-902\t201\t%2$' <<<"$out" \
  && [ "$(grep -c '  agent' <<<"$out")" = 2 ] && pass "1. one line per live registry id (pid, pane); no MCP child, no unregistered id" || fail "1. agents ($out)"
grep -q 'PLAN note to c-902' <<<"$out" && ! grep -q 'note to c-901' <<<"$out" && pass "1. the notes are planned, never to the sender" || fail "1. notes ($out)"
grep -qP '^  wd\tc-901 c-902$' <<<"$out" && grep -qP '^  btime\t1000$' <<<"$out" && pass "1. btime and the wd verdict list" || fail "1. btime/wd ($out)"

# ---- 2. DRY_RUN=0 -----------------------------------------------------------------
S="$SP/dispatch/box-restart/20261008T120000Z.before"
out="$(run do_spl_box_restart_prepare DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$D" rev-parse HEAD)" = "$head1" ] && [ -z "$(git -C "$D" symbolic-ref -q HEAD)" ] \
  && pass "2. the desk-cron is detached at origin/master" || fail "2. desk (rc $rc: $out)"
[ "$(grep -c '^agent' "$S" 2>/dev/null)" = 2 ] && grep -qP '^desk_sha\t' "$S" && grep -qP '^wd_boot_pass\t2$' "$S" \
  && pass "2. the snapshot is written" || fail "2. snapshot ($(cat "$S" 2>&1))"
[ "$(wc -l <"$T/sent.log")" = 1 ] && grep -q -- '--from c-901 --to c-902 --kind note' "$T/sent.log" \
  && pass "2. one note, to the live agent but the sender" || fail "2. sent ($(cat "$T/sent.log" 2>&1))"
out="$(run do_spl_box_restart_prepare DRY_RUN=0 SPOOL_AGENT_ID= BOX_RESTART_NOW=20261008T110000Z)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no sender' <<<"$out" && pass "2. no sender is refused" || fail "2. no sender (rc $rc: $out)"
rm -f "$SP/dispatch/box-restart/20261008T110000Z.before"

# ---- 3. the check -----------------------------------------------------------------
boot 2000
echo "2026 wd BOOT 2026-10-08T12:05:00Z done: 2 restart(s) started (cause reboot)" >"$SP/dispatch/wd.log"
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 0 ] && grep -q 'btime changed: 1000 -> 2000' <<<"$out" && [ "$(grep -c ' back$' <<<"$out")" = 2 ] \
  && pass "3. every id back once: exit 0" || fail "3. all back (rc $rc: $out)"
grep -q 'BOOT .* done: 2 restart' <<<"$out" && grep -q -- '--resume processes: 0' <<<"$out" && pass "3. the wd BOOT line and the --resume count" || fail "3. boot/resume ($out)"
sed -i '/^20[01] /d' "$T/ps"
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 1 ] && grep -qE '^c-902 .*MISSING$' <<<"$out" && grep -q 'ids missing: c-902$' <<<"$out" \
  && pass "3. control: a missing id turns the check red" || fail "3. missing (rc $rc: $out)"
echo "201 1 claude claude --resume abc" >>"$T/ps"; echo "202 1 claude claude" >>"$T/ps"; proc 202 c-902
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 1 ] && grep -qE '^c-902 .*DOUBLED \(2 processes\)$' <<<"$out" && grep -q -- '--resume processes: 1' <<<"$out" \
  && pass "3. a doubled id turns it red; --resume is counted" || fail "3. doubled (rc $rc: $out)"
rm -rf "$SP/dispatch/box-restart"
out="$(run do_spl_box_restart_check)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no snapshot' <<<"$out" && pass "3. no snapshot: exit 1" || fail "3. no snapshot (rc $rc: $out)"

echo "box-restart: ${fails} failure(s)"
[ "$fails" -eq 0 ]
