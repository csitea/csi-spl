#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_registry_dead_sweep on a throwaway spool root and repo.
#   1. bad DRY_RUN / REG_SWEEP_AGE_H are refused
#   2. the controls are kept: a role seat, a live process, a tmux window, a
#      dirty worktree, an unpushed worktree HEAD, an unpushed <id>-* branch
#      of a gone workdir, a recent heartbeat
#   3. a gone workdir and a clean, landed, idle worktree are retired
#   4. the default dry run changes nothing
#   5. DRY_RUN=0 retires only those two through do_spl_agent_id_retire
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool"; W="$T/wt"; TM="$T/tm.sock"
mkdir -p "$R" "$W"
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
g init --bare "$T/origin.git"
g clone "$T/origin.git" "$T/repo"
g -C "$T/repo" commit --allow-empty -m base
g -C "$T/repo" push origin master
for i in 903 904 905 906; do g -C "$T/repo" worktree add -b "c-$i-lane" "$W/c-$i" origin/master; done
echo dirt >"$W/c-903/dirt.txt"
g -C "$W/c-904" commit --allow-empty -m unpushed
g -C "$T/repo" branch c-907-lane master
g -C "$T/repo" commit --allow-empty -m unpushed-907 && g -C "$T/repo" branch -f c-907-lane HEAD && g -C "$T/repo" reset --hard origin/master
mkdir -p "$R/c-905" "$R/c-906" "$R/c-908"
touch -d '3 days ago' "$R/c-905/heartbeat.json"
touch "$R/c-906/heartbeat.json"
{
  printf 'c-001\tclaude\t%%1\t%s\t20261002T080000Z\n' "$W/gone-001"
  printf 'c-901\tclaude\t%%2\t%s\t20261002T080000Z\n' "$W/gone-901"
  printf 'c-902\tclaude\t%%3\t%s\t20261002T080000Z\n' "$W/gone-902"
  printf 'c-903\tclaude\t%%4\t%s\t20261002T080000Z\n' "$W/c-903"
  printf 'c-904\tclaude\t%%5\t%s\t20261002T080000Z\n' "$W/c-904"
  printf 'c-905\tclaude\t%%6\t%s\t20261002T080000Z\n' "$W/c-905"
  printf 'c-906\tclaude\t%%7\t%s\t20261002T080000Z\n' "$W/c-906"
  printf 'c-907\tclaude\t%%8\t%s\t20261002T080000Z\n' "$W/gone-907"
  printf 'c-908\tclaude\t%%9\t%s\t20261002T080000Z\trequester\n' "$W/gone-908"
} >"$R/registry.tsv"

env SPOOL_AGENT_ID=c-901 sleep 120 & live=$!
tmux -S "$TM" new-session -d -s sweep -n 'tag: c-902 lane' 'sleep 120'
trap 'kill "$live" 2>/dev/null; tmux -S "$TM" kill-server 2>/dev/null; rm -rf "$T"' EXIT
orc_stub 1 sudo

run() {
  SNIPPET='do_spl_registry_dead_sweep' in_orc SPOOL_ROOT="$R" SPOOL_TMUX_SOCKET="$TM" \
    REG_SWEEP_REPO="$T/repo" RETIRE_LANE=0 RETIRE_DESKS=0 RETIRE_WORKTREE=0 "$@" 2>&1
}

out="$(run DRY_RUN=2)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && pass "1. a bad DRY_RUN is refused" || fail "1. bad DRY_RUN (rc $rc: $out)"
out="$(run REG_SWEEP_AGE_H=0)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'REG_SWEEP_AGE_H must be' <<<"$out" && pass "1. a bad REG_SWEEP_AGE_H is refused" || fail "1. bad age (rc $rc: $out)"

before="$(md5sum "$R/registry.tsv"; find "$R" | sort)"
out="$(run)"; rc=$?
[ "$rc" -eq 0 ] && pass "4. the dry run exits 0" || fail "4. dry run rc $rc ($out)"
chk() { grep -q "^$1$" <<<"$out" && pass "$2" || fail "$2 (no '$1' in: $out)"; }
chk 'keep c-001: role seat' "2. a role seat is kept"
chk 'keep c-901: a process carries SPOOL_AGENT_ID=c-901' "2. a live process is kept"
chk 'keep c-902: a tmux window carries c-902' "2. a tmux window is kept"
chk "keep c-903: dirty worktree $W/c-903" "2. a dirty worktree is kept"
chk 'keep c-904: unpushed: branch c-904-lane is not on origin/master' "2. an unpushed worktree HEAD is kept"
chk 'keep c-906: verdict or heartbeat within 24h' "2. a recent heartbeat is kept"
chk 'keep c-907: unpushed: branch c-907-lane is not on origin/master' "2. an unpushed branch of a gone workdir is kept"
chk "retire c-908: workdir gone ($W/gone-908)" "3. a gone workdir is retired"
chk 'retire c-905: clean, on origin/master, idle 24h+' "3. a clean, landed, idle worktree is retired"
grep -q 'DONE would-retire=2 kept=7 refused=0' <<<"$out" && pass "4. the dry run counts 2 / 7" || fail "4. counts ($out)"
[ "$before" == "$(md5sum "$R/registry.tsv"; find "$R" | sort)" ] && pass "4. ...and changes nothing" || fail "4. the dry run changed the spool root"

out="$(run DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'DONE retired=2 kept=7 refused=0' <<<"$out" && pass "5. DRY_RUN=0 retires 2" || fail "5. apply (rc $rc: $out)"
left="$(cut -f1 "$R/registry.tsv" | tr '\n' ' ')"
[ "$left" == "c-001 c-901 c-902 c-903 c-904 c-906 c-907 " ] && pass "5. the kept rows stay in registry.tsv" || fail "5. registry left: $left"
[ "$(cut -f1 "$R/registry.retired.tsv" | tr '\n' ' ')" == "c-905 c-908 " ] && [ -d "$R/.retired/c-905.20261002T080000Z" ] \
  && pass "5. the retired rows went through do_spl_agent_id_retire" || fail "5. retired: $(cat "$R/registry.retired.tsv" 2>/dev/null)"
[ -d "$W/c-905" ] && pass "5. the worktree itself is left to the retire script" || fail "5. the worktree went away"

echo "spl-registry-dead-sweep: ${fails} failure(s)"
[ "$fails" -eq 0 ]
