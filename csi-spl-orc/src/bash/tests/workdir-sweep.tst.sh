#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the deferred lane cleanup (SPL-2110; owner HUM-10, t1 37349c9b msg
# ec060ebc: lanes keep their work after the push, the guard deletes "working
# directories older than 24 hours"). The table writer
# (spawn-agents/scripts/workdir-register.sh) and the guard
# (csi-spl-utl/src/bash/scripts/workdir-sweep.sh, ./run -a do_sweep_workdirs),
# on a sandbox origin + repo + worktrees and a planted clock; the live table,
# /tmp and /var/tmp are never touched.
#   0. the table: one row per path (a second add replaces it), drop, refusals
#   1. a fresh (1 h) row is kept; the dry run removes nothing
#   2. a 25 h clean, landed worktree goes through `git worktree remove`, its
#      merged branch with it, the row is dropped (CONTROL: a 23 h one stays)
#   3. a held 25 h scratch dir is kept (CONTROL: unheld, the same dir goes)
#   4. a dirty, unpushed 25 h worktree is kept, the row stays (CONTROL: once
#      clean it goes, and its unmerged branch stays with the commit)
#   5. critical disk (free <= 8%): a 7 h row goes, a 5 h one stays, oldest
#      first, an ALERT line says so (CONTROL: at 50% free the 7 h row stays)
#   6. var-tmp: a 25 h /var/tmp entry goes; a row outside that root stays
#   7. a worktree a new lane took over (another branch) loses its row, not
#      its dir; a vanished dir loses its row
#   8. ./run -a do_sweep_workdirs reads cnf env.box.workdir_sweep.age_h
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
REG="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/workdir-register.sh"
UTL="$APP_ROOT/csi-spl-utl"
SWEEP="$UTL/src/bash/scripts/workdir-sweep.sh"
TB="$T/spool/workdirs.tsv" TMPR="$T/tmp" VT="$T/vartmp"
export WORKDIR_TABLE="$TB" WORKDIR_SWEEP_SUDO=0 WORKDIR_SWEEP_TMP="$TMPR" WORKDIR_SWEEP_VARTMP_ROOT="$VT"
export SPOOL_NOW=2026-10-16T12:00:00Z
mkdir -p "$T/spool" "$TMPR/claude-$(id -u)" "$VT"
ago() { date -u -d "@$(( $(date -u -d "$SPOOL_NOW" +%s) - $1 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ; }
add() { bash "$REG" add --kind "$1" --agent "$2" --box tb --at "$(ago "$3")" ${5:+--branch "$5"} "$4" >/dev/null; }
row() { awk -F'\t' -v p="$1" '$1 == p' "$TB"; }
sweep() { env WORKDIR_SWEEP_FREE_PCT="${FREE:-50}" "$@" bash "$SWEEP" 2>&1; }
gq() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

# sandbox: origin, the main checkout, worktrees <repo>-wt/<id> on <id>-x
gq init --bare "$T/origin.git"; gq clone "$T/origin.git" "$T/repo"
gq -C "$T/repo" commit --allow-empty -m base; gq -C "$T/repo" push origin HEAD:master; gq -C "$T/repo" fetch origin
W="$T/repo-wt"
lane() { gq -C "$T/repo" worktree add -b "$1-x" "$W/$1" origin/master; }
has_branch() { git -C "$T/repo" show-ref --verify --quiet "refs/heads/$1"; }
in_list() { grep -qx "worktree $1" <<<"$(git -C "$T/repo" worktree list --porcelain)"; }

# ---- 0. the table ------------------------------------------------------------
add scratch c-900 2 "$TMPR/claude-$(id -u)/x"; add scratch c-900 1 "$TMPR/claude-$(id -u)/x/"
[ "$(grep -c "claude-$(id -u)/x" "$TB")" = 1 ] && [ "$(row "$TMPR/claude-$(id -u)/x" | cut -f6)" = "$(ago 1)" ] \
  && pass "0. a path is listed once: a second add replaces its row (newest finished_at)" || fail "0. dedup ($(cat "$TB"))"
[ "$(sed -n 1p "$TB")" = "$(printf '# path\tkind\tagent\tbox\tbranch\tfinished_at')" ] && pass "0. the table opens with its header" || fail "0. header ($(sed -n 1p "$TB"))"
bash "$REG" drop "$TMPR/claude-$(id -u)/x"; [ -z "$(row "$TMPR/claude-$(id -u)/x")" ] && pass "0. drop removes the row" || fail "0. drop"
bash "$REG" add --kind junk --agent c-1 /x 2>/dev/null; r1=$?
bash "$REG" add --kind scratch --agent c-1 /a/../etc 2>/dev/null; r2=$?
bash "$REG" add --kind scratch --agent c-1 rel/path 2>/dev/null; r3=$?
[ "$r1$r2$r3" = 222 ] && pass "0. an unknown kind, a .. path and a relative path are refused (exit 2)" || fail "0. refusals ($r1$r2$r3)"

# ---- 1. fresh ----------------------------------------------------------------
lane c-901; add worktree c-901 1 "$W/c-901" c-901-x
out="$(sweep DRY_RUN=0)"
grep -q "KEEP fresh 1h<24h worktree $W/c-901 " <<<"$out" && [ -d "$W/c-901" ] && [ -n "$(row "$W/c-901")" ] \
  && pass "1. a fresh (1 h) row is kept with its dir" || fail "1. fresh ($out)"

# ---- 2. 25 h clean, landed worktree --------------------------------------------
lane c-902; gq -C "$W/c-902" commit --allow-empty -m landed; gq -C "$W/c-902" push origin HEAD:master; gq -C "$T/repo" fetch origin
gq -C "$T/repo" merge --ff-only origin/master
add worktree c-902 25 "$W/c-902" c-902-x
lane c-903; add worktree c-903 23 "$W/c-903" c-903-x
n0="$(find "$T/repo-wt" | wc -l)"
out="$(sweep)"
grep -q "PLAN remove [0-9]*KB worktree $W/c-902 " <<<"$out" && [ "$(find "$T/repo-wt" | wc -l)" = "$n0" ] \
  && pass "2. the dry run (default) plans the 25 h worktree and removes nothing" || fail "2. dry run ($out)"
out="$(sweep DRY_RUN=0)"
[ ! -e "$W/c-902" ] && ! in_list "$W/c-902" && ! has_branch c-902-x && [ -z "$(row "$W/c-902")" ] \
  && grep -q "REMOVE [0-9]*KB worktree $W/c-902 (c-902, 25h) branch c-902-x" <<<"$out" \
  && pass "2. a 25 h clean, landed worktree goes (git worktree remove), its merged branch and its row too" || fail "2. 25 h ($out)"
grep -q "KEEP fresh 23h<24h worktree $W/c-903 " <<<"$out" && [ -d "$W/c-903" ] \
  && pass "2. CONTROL: a 23 h one of the same shape stays" || fail "2. 23 h control ($out)"

# ---- 3. held scratch -----------------------------------------------------------
S="$TMPR/claude-$(id -u)/-repo-wt-c-904"; mkdir -p "$S/sess"; echo x >"$S/sess/f"
add scratch c-904 25 "$S"
( cd "$S/sess" && exec sleep 600 ) >/dev/null 2>&1 & hold=$!
for _ in $(seq 300); do [ "$(readlink "/proc/$hold/cwd")" = "$S/sess" ] && break; sleep 0.1; done
out="$(sweep DRY_RUN=0)"
grep -q "KEEP in-use .* scratch $S " <<<"$out" && [ -f "$S/sess/f" ] && [ -n "$(row "$S")" ] \
  && pass "3. a held 25 h scratch dir is kept (a process works in it)" || fail "3. held ($out)"
kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null
out="$(sweep DRY_RUN=0)"
[ ! -e "$S" ] && [ -z "$(row "$S")" ] && grep -q "REMOVE [0-9]*KB scratch $S " <<<"$out" \
  && pass "3. CONTROL: unheld, the same dir goes with its row" || fail "3. unheld ($out)"

# ---- 4. dirty, unpushed worktree ------------------------------------------------
lane c-905; gq -C "$W/c-905" commit --allow-empty -m unpushed; echo wip >"$W/c-905/wip.txt"
add worktree c-905 25 "$W/c-905" c-905-x
out="$(sweep DRY_RUN=0)"
grep -q "KEEP dirty .* worktree $W/c-905 " <<<"$out" && [ -f "$W/c-905/wip.txt" ] && [ -n "$(row "$W/c-905")" ] \
  && pass "4. a dirty, unpushed 25 h worktree is kept with its row, the log says why" || fail "4. dirty ($out)"
gq -C "$W/c-905" add wip.txt; gq -C "$W/c-905" commit -m wip
out="$(sweep DRY_RUN=0)"
[ ! -e "$W/c-905" ] && has_branch c-905-x && [ "$(git -C "$T/repo" log -1 --format=%s c-905-x)" = wip ] \
  && pass "4. CONTROL: once clean it goes; its unmerged branch stays, with the commit" || fail "4. clean ($out)"

# ---- 5. critical disk ------------------------------------------------------------
for x in a b c; do echo x >"$VT/c-906-$x"; done
add var-tmp c-906 5 "$VT/c-906-a"; add var-tmp c-906 7 "$VT/c-906-b"; add var-tmp c-906 9 "$VT/c-906-c"
out="$(FREE=50 sweep DRY_RUN=0)"
[ -e "$VT/c-906-b" ] && [ -e "$VT/c-906-c" ] && pass "5. CONTROL: at 50% free the 7 h and 9 h rows stay" || fail "5. normal ($out)"
out="$(FREE=8 sweep DRY_RUN=0)"
[ ! -e "$VT/c-906-b" ] && [ ! -e "$VT/c-906-c" ] && [ -e "$VT/c-906-a" ] && grep -q "KEEP fresh 5h<6h var-tmp $VT/c-906-a " <<<"$out" \
  && pass "5. critical (8% free): the 7 h and 9 h rows go, the 5 h one stays" || fail "5. crit ($out)"
grep -q "ALERT critical disk: 8% free (planted) <= 8%: lane workdirs older than 6 h (not 24 h) are removed, oldest first" <<<"$out" \
  && pass "5. the ALERT line names the 6 h limit" || fail "5. alert ($out)"
[ "$(grep -o "REMOVE [0-9]*KB var-tmp $VT/c-906-[bc]" <<<"$out" | sed 's/.*-//' | tr -d '\n')" = cb ] \
  && pass "5. oldest first (9 h before 7 h)" || fail "5. order ($out)"
out="$(FREE=9 sweep)"; grep -q "level=normal" <<<"$out" && ! grep -q ALERT <<<"$out" \
  && pass "5. CONTROL: 9% free is not critical" || fail "5. 9% ($out)"

# ---- 6. var-tmp --------------------------------------------------------------------
mkdir -p "$VT/c-907-base/d" "$T/precious"; echo x >"$VT/c-907-base/d/f"; echo x >"$T/precious/f"
add var-tmp c-907 25 "$VT/c-907-base"; add var-tmp c-907 25 "$T/precious"
out="$(sweep DRY_RUN=0)"
[ ! -e "$VT/c-907-base" ] && pass "6. a 25 h /var/tmp leftover goes" || fail "6. var-tmp ($out)"
[ -f "$T/precious/f" ] && grep -q "KEEP not-a-var-tmp-entry .* $T/precious " <<<"$out" \
  && pass "6. a var-tmp row outside the /var/tmp root stays" || fail "6. outside ($out)"

# ---- 7. reused, gone -------------------------------------------------------------
lane c-908; add worktree c-908 25 "$W/c-908" c-908-old
add scratch c-909 25 "$TMPR/claude-$(id -u)/gone"
out="$(sweep DRY_RUN=0)"
[ -d "$W/c-908" ] && [ -z "$(row "$W/c-908")" ] && grep -q "DROP reused (now on c-908-x, listed on c-908-old) $W/c-908" <<<"$out" \
  && pass "7. a worktree now on another branch keeps its dir and loses its row" || fail "7. reused ($out)"
[ -z "$(row "$TMPR/claude-$(id -u)/gone")" ] && grep -q "DROP gone" <<<"$out" && pass "7. a vanished dir loses its row" || fail "7. gone ($out)"

# ---- 8. the utl action reads cnf -----------------------------------------------------
lane c-910; add worktree c-910 3 "$W/c-910" c-910-x
printf 'env:\n  box:\n    workdir_sweep:\n      age_h: 2\n      crit_age_h: 1\n      crit_free_pct: 8\n' >"$T/cnf.yaml"
out="$(cd "$UTL" && DRY_RUN=0 WORKDIR_SWEEP_CNF="$T/cnf.yaml" WORKDIR_SWEEP_FREE_PCT=50 ./run -a do_sweep_workdirs 2>&1)"
[ ! -e "$W/c-910" ] && grep -q "limit_h=2" <<<"$out" && pass "8. ./run -a do_sweep_workdirs takes age_h from cnf (2 h: the 3 h row goes)" || fail "8. cnf ($out)"

echo "workdir-sweep: $fails failure(s)"
[ "$fails" = 0 ]
