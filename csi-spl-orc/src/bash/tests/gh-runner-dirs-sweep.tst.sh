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
trap '[[ -n "$hp" ]] && kill "$hp" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/sudo" <<'EOF2'
#!/usr/bin/env bash
[[ "$1" == -n ]] && shift
[[ "$1" == -u ]] && shift 2
exec "$@"
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

echo "=== gh-runner-dirs-sweep: $fails failure(s)"
[[ "$fails" -eq 0 ]]
