#!/usr/bin/env bash
# Purpose: playwright-artifacts-sweep.sh on fixture dirs in a mktemp root
# (never the real /tmp; PW_ART_SUDO=0, this user's processes only):
#   - the refusals: a bad DRY_RUN, PW_ART_AGE_H 0, a root that is no dir
#   - planned: an idle playwright-artifacts-* dir (its file old too)
#   - KEEP fresh: a new dir; an old dir with one new file in it
#   - KEEP in-use: an idle dir that a process has as its cwd
#   - KEEP symlink: a playwright-artifacts-* link to an idle dir
#   - a dir of another name is never listed
#   - the dry run removes nothing; DRY_RUN=0 removes the planned one only
#   - red controls: with each keep check cut from a copy of the script, the
#     dir it guarded is planned (the age check: the fresh dir is planned)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/playwright-artifacts-sweep.sh"
T="$(mktemp -d)"
trap 'kill "${hp:-}" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
bash -n "$SCRIPT" || { echo "FAIL bash -n"; exit 1; }
R="$T/root"; P="$R/playwright-artifacts"
old="$(date -d '30 hours ago' +%Y%m%d%H%M.%S)"

# art <dir> old|new [new-file]: a fixture dir with one file, both aged
art() {
  mkdir -p "$1"; echo x >"$1/page.pdf"
  if [[ "$2" == old ]]; then touch -t "$old" "$1/page.pdf"; fi
  if [[ "${3:-}" == new-file ]]; then echo y >"$1/new.pdf"; fi
  if [[ "$2" == old ]]; then touch -t "$old" "$1"; fi
}
art "$P-idle" old; art "$P-fresh" new; art "$P-newfile" old new-file; art "$P-held" old
art "$T/elsewhere" old; ln -s "$T/elsewhere" "$P-link"; touch -h -t "$old" "$P-link"; art "$R/other-idle" old
(cd "$P-held" && exec sleep 600) & hp=$!
for _ in $(seq 1 200); do [[ "$(readlink "/proc/$hp/cwd" 2>/dev/null)" == "$P-held" ]] && break; sleep 0.05; done
[[ "$(readlink "/proc/$hp/cwd" 2>/dev/null)" == "$P-held" ]] || { echo "FAIL fixture: the holder never entered $P-held"; exit 1; }

run() { env PW_ART_SUDO=0 PW_ART_ROOT="$R" "$@" bash "${S:-$SCRIPT}" >"$T/out" 2>&1; }
has() { grep -qE -- "$1" "$T/out"; }

run DRY_RUN=2; [[ $? == 2 ]] && has REFUSE && pass "1. a bad DRY_RUN is refused" || fail "1. DRY_RUN=2 ($(cat "$T/out"))"
run PW_ART_AGE_H=0; [[ $? == 2 ]] && has REFUSE && pass "1. PW_ART_AGE_H=0 is refused" || fail "1. age 0 ($(cat "$T/out"))"
env PW_ART_SUDO=0 PW_ART_ROOT="$T/nope" bash "$SCRIPT" >"$T/out" 2>&1
[[ $? == 2 ]] && has REFUSE && pass "1. a root that is no dir is refused" || fail "1. no root ($(cat "$T/out"))"

run; rc=$?
[[ $rc == 0 ]] && pass "2. dry run exits 0" || fail "2. dry run rc=$rc ($(tail -3 "$T/out"))"
has "PLAN remove [0-9]+MB $P-idle idle=(29|30|31)h$" && pass "2. an idle dir is planned" || fail "2. idle ($(grep -- -idle "$T/out"))"
for e in "fresh [0-9]+MB $P-fresh" "fresh [0-9]+MB $P-newfile" "in-use [0-9]+MB $P-held" "symlink -MB $P-link"; do
  has "KEEP $e$" && pass "3. KEEP ${e%% *} ${e##*/}" || fail "3. KEEP $e ($(grep "${e##* }" "$T/out"))"
done
has "other-idle" && fail "3. a dir of another name is listed" || pass "3. a dir of another name is not listed"
has "DONE would-remove=1 \([0-9]+ MB\) kept=4 " && pass "2. the dry run counts 1, kept 4" || fail "2. count ($(tail -1 "$T/out"))"
[[ -d "$P-idle" ]] && pass "2. the dry run removed nothing" || fail "2. the dry run removed $P-idle"

# control <label> <sed -E script> <dir>: with that check cut from a copy of
# the script, the dir it guarded is planned
control() {
  sed -E "$2" "$SCRIPT" >"$T/ctl.sh"
  if cmp -s "$SCRIPT" "$T/ctl.sh"; then fail "4. control $1: pattern matched nothing"; return; fi
  S="$T/ctl.sh" run
  has "PLAN remove [0-9]+MB $3 " && pass "4. control: without the $1 check, ${3##*/} is planned" || fail "4. control $1 ($(grep -- "$3" "$T/out"))"
}
control age '/why="fresh"/d' "$P-fresh"
control newest-file 's/find "\$p" -printf/find "$p" -maxdepth 0 -printf/' "$P-newfile"
control in-use '/why="in-use"; return; \}$/d' "$P-held"
control symlink 's/if \[\[ -L "\$p" \]\]; then why="symlink"/if false; then :/' "$P-link"

run DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && pass "5. real run exits 0" || fail "5. real run rc=$rc ($(tail -3 "$T/out"))"
[[ ! -e "$P-idle" ]] && has "DO remove [0-9]+MB $P-idle idle=" && pass "5. the idle dir is removed" || fail "5. idle not removed ($(cat "$T/out"))"
for d in "$P-fresh" "$P-newfile" "$P-held" "$T/elsewhere" "$R/other-idle"; do
  [[ -f "$d/page.pdf" ]] || fail "5. kept dir $d lost its file"
done
[[ -L "$P-link" && -f "$P-newfile/new.pdf" ]] && pass "5. every kept dir is still there" || fail "5. a kept dir changed"
has "DONE removed=1 \([0-9]+ MB\) kept=4 " && pass "5. the real run counts 1" || fail "5. count ($(tail -1 "$T/out"))"

echo "playwright-artifacts-sweep: ${fails} failure(s)"
[[ "$fails" -eq 0 ]]
