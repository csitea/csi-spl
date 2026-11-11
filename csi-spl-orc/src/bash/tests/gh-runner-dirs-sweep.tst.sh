#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gh_runner_dirs_sweep on a fixture root, sudo and systemctl
#          stubbed, /proc real:
#          - fail fast: a bad DRY_RUN, GH_RUNNER_DIRS_AGE_D 0, a root of /
#          - only an old, deregistered runner install with no unit and no
#            holder is planned; a dir and a symlink to one (link and target)
#          - KEEP: .runner, .credentials*, a unit, a recent file (a recent
#            dir mtime alone does not keep it), a process
#            with its cwd inside, a dir that is not a runner install
#          - a unit of a longer name (o.big-r-a) does not keep r-a
#          - the dry run removes nothing; DRY_RUN=0 removes the planned ones
#            only, the symlink and its target both
#          - a failed /proc read keeps everything (held)
#          - control: with the hold check removed, the held runner is planned
#          - fails closed (SPL-5251): sudo -n unusable -> FATAL before any
#            verdict, nothing removed; a sudo failure on one dir's .runner
#            test, .credentials find, recent-file find or du -> KEEP
#            unreadable, never REMOVE, the other dirs unchanged
#          - a parent the dir's owner cannot write (root 755 on a box): the
#            owner empties the dir, root rmdirs it, the run counts it; a dir
#            left behind is a WARN with the MB really freed, and rc 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
F="$PROJ_ROOT/src/bash/run/gh-runner-dirs-sweep.func.sh"
bash -n "$F" || { echo "FAIL: bash -n"; exit 1; }

T=$(mktemp -d); hp=""
trap '[[ -n "$hp" ]] && kill "$hp" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# the sudo stub. SUDO_DOWN: every call fails (rc 1, no output). UNREADABLE:
# a call that names that path fails the same way, only when it also names
# UNREADABLE_CMD (when set). LOCKED: dirs only root may write; a root call
# (no -u) gets them u+w for its run. ROOT_RMDIR_FAIL: a root rmdir fails.
cat >"$T/bin/sudo" <<'EOF2'
#!/usr/bin/env bash
[[ -n "${SUDO_DOWN:-}" ]] && exit 1
if [[ -n "${UNREADABLE:-}" && "$*" == *"$UNREADABLE"* && "$*" == *"${UNREADABLE_CMD:-}"* ]]; then exit 1; fi
[[ "$1" == -n ]] && shift
[[ "$1" == -u ]] && { shift 2; exec "$@"; }
[[ "$1" == rmdir && -n "${ROOT_RMDIR_FAIL:-}" ]] && exit 1
[[ -n "${LOCKED:-}" ]] || exec "$@"
# shellcheck disable=SC2086
chmod u+w $LOCKED; "$@"; rc=$?; chmod u-w $LOCKED; exit "$rc"
EOF2
cat >"$T/bin/systemctl" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" == list-unit-files ]] && cat "$UNITS_FILE"
EOF2
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" UNITS_FILE="$T/units"
printf '%s\n' "actions.runner.o.r-unit.service disabled enabled" "actions.runner.o.big-r-a.service enabled enabled" >"$UNITS_FILE"

# runner <dir> - a runner install, all its files 30 days old
runner() { mkdir -p "$1/bin" "$1/_work"; : >"$1/run.sh"; : >"$1/config.sh"; : >"$1/bin/Runner.Listener"; : >"$1/_work/f"; }
old() { find "$1" -exec touch -h -d '30 days ago' {} +; }
fixture() {
  chmod -R u+w "$T/root" "$T/data" 2>/dev/null
  rm -rf "$T/root" "$T/data"; mkdir -p "$T/root" "$T/data"
  runner "$T/root/r-a"; runner "$T/data/r-link"; ln -s "$T/data/r-link" "$T/root/r-link"
  runner "$T/root/r-reg"; : >"$T/root/r-reg/.runner"
  runner "$T/root/r-cred"; : >"$T/root/r-cred/.credentials_rsaparams"
  runner "$T/root/r-unit"; runner "$T/root/r-new"; runner "$T/root/r-held"
  mkdir -p "$T/root/other"; : >"$T/root/other/run.sh"
  old "$T/root"; old "$T/data"; : >"$T/root/r-new/_work/today"; touch "$T/root/r-a/_work"
}
act() {
  ( do_log() { echo "$*"; }
    # shellcheck source=../run/gh-runner-dirs-sweep.func.sh
    source "$F"
    if [[ -n "${NO_HOLD:-}" ]]; then ghrd_held() { return 1; }; fi
    if [[ -n "${PROC_FAIL:-}" ]]; then ghrd_procs() { return 1; }; fi
    GH_RUNNER_DIRS_ROOT="${ROOT:-$T/root}" do_gh_runner_dirs_sweep ) >"$T/out" 2>&1
}
has() { grep -qE "$1" "$T/out"; }

DRY_RUN=2 act && no "DRY_RUN=2 must fail" || ok "a bad DRY_RUN fails fast"
GH_RUNNER_DIRS_AGE_D=0 act && no "age 0 must fail" || ok "GH_RUNNER_DIRS_AGE_D 0 fails fast"
ROOT=/ act && no "root / must fail" || ok "a root of / is refused"

fixture
(cd "$T/root/r-held/_work" && exec sleep 300) & hp=$!
sleep 0.3
act && ok "dry run exits 0" || no "dry run failed: $(tail -2 "$T/out")"
has "PLAN remove [0-9]+MB $T/root/r-a -> $T/root/r-a$" && ok "an old deregistered runner is planned, a fresh dir mtime aside" || no "r-a not planned"
has "PLAN remove [0-9]+MB $T/root/r-link -> $T/data/r-link$" && ok "a symlinked runner is planned at its target" || no "r-link not planned"
has "KEEP registered $T/root/r-reg$" && ok ".runner keeps it" || no "r-reg"
has "KEEP registered $T/root/r-cred$" && ok ".credentials* keeps it" || no "r-cred"
has "KEEP unit $T/root/r-unit$" && ok "a unit file keeps it" || no "r-unit"
has "KEEP recent $T/root/r-new$" && ok "a recent file keeps it" || no "r-new"
has "KEEP held $T/root/r-held$" && ok "a process with its cwd inside keeps it" || no "r-held: $(grep r-held "$T/out")"
has "KEEP not-a-runner $T/root/other$" && ok "a dir that is not a runner install is kept" || no "other"
has "DONE would-remove=2 " && ok "dry run counts 2" || no "count: $(tail -1 "$T/out")"
[[ -d "$T/root/r-a" && -d "$T/data/r-link" && -L "$T/root/r-link" ]] && ok "the dry run removed nothing" || no "dry run removed something"

PROC_FAIL=1 act; has "KEEP held $T/root/r-a$" && has "would-remove=0 " && ok "a failed /proc read keeps everything" || no "proc fail: $(grep r-a "$T/out")"
NO_HOLD=1 act; has "PLAN remove [0-9]+MB $T/root/r-held" && ok "control: with the hold check removed, r-held is planned" || no "control: r-held not planned without the hold check"

DRY_RUN=0 act && ok "real run exits 0" || no "real run failed: $(tail -3 "$T/out")"
[[ ! -e "$T/root/r-a" && ! -e "$T/data/r-link" && ! -L "$T/root/r-link" ]] && ok "real run removed r-a, the link and its target" || no "not removed: $(ls "$T/root" "$T/data")"
for d in r-reg r-cred r-unit r-new r-held other; do [[ -d "$T/root/$d" ]] || no "kept dir $d was removed"; done
ok "every kept dir is still there"
has "DONE removed=2 " && ok "real run counts 2" || no "count: $(tail -1 "$T/out")"
kill "$hp" 2>/dev/null; hp=""
# fixture_nh - the fixture with no r-held: its holder is gone from here on
fixture_nh() { fixture; rm -rf "$T/root/r-held"; }

# fails closed: sudo -n unusable -> FATAL before any verdict
fixture_nh
SUDO_DOWN=1 DRY_RUN=0 act && no "sudo down must fail the run" || ok "sudo -n unusable fails the run"
has "FATAL .*sudo" && ok "it says FATAL ... sudo" || no "no FATAL: $(tail -2 "$T/out")"
has "KEEP |PLAN |REMOVE " && no "a verdict was printed with sudo down" || ok "no verdict before the FATAL"
[[ -d "$T/root/r-a" && -d "$T/data/r-link" && -L "$T/root/r-link" ]] && ok "sudo down removed nothing" || no "sudo down removed something"

# fails closed: one dir unreadable, one sudo read at a time
for c in "test -e" ".credentials" "-newermt" "du "; do
  fixture_nh; runner "$T/root/r-dark"; old "$T/root/r-dark"
  UNREADABLE="$T/root/r-dark" UNREADABLE_CMD="$c" DRY_RUN=0 act
  has "KEEP unreadable $T/root/r-dark$" && [[ -d "$T/root/r-dark" ]] && ok "a sudo failure on '$c' keeps r-dark, unreadable" || no "'$c': $(grep r-dark "$T/out")"
  has "DONE removed=2 " && [[ ! -e "$T/root/r-a" ]] && ok "'$c': the other dirs keep their verdicts" || no "'$c' others: $(tail -1 "$T/out")"
done

# a parent the dir's owner cannot write
fixture_nh; LOCKED="$T/root $T/data"; chmod u-w $LOCKED
LOCKED="$LOCKED" DRY_RUN=0 act && ok "locked parent: the run exits 0" || no "locked parent rc: $(grep -E 'WARN|DONE' "$T/out")"
[[ ! -e "$T/root/r-a" && ! -e "$T/data/r-link" && ! -L "$T/root/r-link" ]] && ok "locked parent: r-a, the link and its target are gone" || no "locked parent left: $(ls "$T/root" "$T/data")"
has "DONE removed=2 " && ok "locked parent: counts 2" || no "locked count: $(tail -1 "$T/out")"
chmod u+w $LOCKED
fixture_nh; head -c 3145728 /dev/zero >"$T/root/r-a/_work/big"; old "$T/root/r-a"; chmod u-w $LOCKED
LOCKED="$LOCKED" ROOT_RMDIR_FAIL=1 DRY_RUN=0 act && no "a dir left behind must fail the run" || ok "a dir left behind fails the run"
fr="$(sed -nE "s|.*WARN could not remove $T/root/r-a -> .*, freed ([0-9]+)MB of [0-9]+MB$|\1|p" "$T/out")"
[[ -n "$fr" ]] && (( fr >= 2 )) && ok "the WARN reports the ${fr} MB really freed" || no "freed: $(grep -E 'WARN|DONE' "$T/out")"
tm="$(sed -nE 's/.*DONE removed=0 \(([0-9]+) MB\) failed=2 .*/\1/p' "$T/out")"
[[ -n "$tm" ]] && (( tm >= fr )) && ok "DONE counts 0 removed, 2 failed, the ${tm} MB freed" || no "done: $(tail -1 "$T/out")"
chmod u+w $LOCKED

echo "=== gh-runner-dirs-sweep: $fails failure(s)"
[[ "$fails" -eq 0 ]]
