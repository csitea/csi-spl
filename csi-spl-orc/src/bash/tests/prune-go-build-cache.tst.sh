#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_prune_go_build_cache removes only stale Go build-cache files.
#   1. a fixture cache with an old file and a fresh file: only the old one goes
#   2. a directory that is not a Go cache: untouched, non-zero exit
#   3. DRY_RUN=1 changes nothing
#   4. the gate is per cache: two caches on two fake filesystems, only the
#      one at/over the percent is pruned; an unreadable user is a WARN; the
#      default users include the CI runner user when it exists
#   The gate (hourly minute, or filesystem at/over the percent) and the cron
#   line are covered with the same fixtures. No real cache, crontab or sudo:
#   df, sudo and getent are stubs, and SPOOL_TEST=1 refuses live discovery.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

run_prune() {
  # $1 dir  $2 DRY_RUN  $3 extra env assignments (a single string, optional)
  # GO_CACHE_USERS is empty on purpose: a bug that ignores GO_CACHE_DIRS must
  # not discover the live users and prune their caches.
  # shellcheck disable=SC2086
  env SPOOL_TEST=1 GO_CACHE_DIRS="$1" GO_CACHE_USERS="" GO_CACHE_LOCK=0 DRY_RUN="$2" \
    GO_CACHE_MAX_AGE_MIN="${GO_CACHE_MAX_AGE_MIN:-10}" ${3:-} \
    bash -c '
      set -uo pipefail
      do_log() {
        [[ "${CLOBBER_LOG:-0}" == 1 ]] && { type_of_msg="${1%% *}"; action="${*:2:1}"; rest_of_msg=x; msg=x; log_dir=x; log_file=x; }
        printf "%s\n" "$*"
      }
      do_require_bin() { command -v "$1" >/dev/null; }
      source "'"$PROJ_ROOT"'/src/bash/run/prune-go-build-cache.func.sh"
      do_prune_go_build_cache'
}

mk_cache() {
  local d="$1"
  mkdir -p "$d/00/aa" "$d/ff/bb"
  printf 'cached build artifacts\n' >"$d/README"
  printf 'old\n' >"$d/00/aa/old"
  printf 'new\n' >"$d/ff/bb/new"
  printf 'keep-me\n' >"$d/trim.txt"
  touch -d '30 minutes ago' "$d/00/aa/old" "$d/trim.txt"
  touch -d '1 minute ago' "$d/ff/bb/new"
}

# 1. old + fresh ---------------------------------------------------------------
C="$T/cache"
mk_cache "$C"
out="$(run_prune "$C" 0)"; rc=$?
if [[ $rc -eq 0 && ! -e "$C/00/aa/old" && -f "$C/ff/bb/new" && -f "$C/trim.txt" && -f "$C/README" \
  && "$out" == *'PLAN user='*'files=1 bytes=4'* && "$out" == *'BEFORE '* && "$out" == *'AFTER '* \
  && "$out" == *'fs_free='* && "$out" == *'removed 1 file(s), 4 bytes'* ]]; then
  pass "only the old depth-2 file is removed; the fresh file, README and a depth-1 file stay; before/after bytes and free space are printed"
else
  fail "prune (rc=$rc): $out"
fi

# 2. not a Go cache ------------------------------------------------------------
B="$T/not-a-cache"
mkdir -p "$B/00"
printf 'leave\n' >"$B/00/leave"
touch -d '30 minutes ago' "$B/00/leave"
out="$(run_prune "$B" 0)"; rc=$?
[[ $rc -ne 0 && -f "$B/00/leave" && "$out" == *'not a Go build cache'* && "$out" == *'nothing deleted'* ]] &&
  pass "a directory that is not a Go cache is untouched and the exit is non-zero" ||
  fail "not a cache (rc=$rc): $out / leave=$(cat "$B/00/leave" 2>/dev/null)"

S="$T/symlink-bucket"
mkdir -p "$S/ff" "$T/elsewhere/aa"
printf 'cached build artifacts\n' >"$S/README"
ln -s "$T/elsewhere" "$S/00"
printf 'old\n' >"$T/elsewhere/aa/old"
touch -d '30 minutes ago' "$T/elsewhere/aa/old"
out="$(run_prune "$S" 0)"; rc=$?
[[ $rc -ne 0 && -f "$T/elsewhere/aa/old" ]] &&
  pass "a bucket that is a symlink is not a cache: the target is untouched" ||
  fail "symlink bucket (rc=$rc): $out"

# 3. DRY_RUN -------------------------------------------------------------------
D="$T/dry"
mk_cache "$D"
out="$(run_prune "$D" 1)"; rc=$?
[[ $rc -eq 0 && -f "$D/00/aa/old" && -f "$D/ff/bb/new" && "$out" == *'dry_run=1'* && "$out" == *'would be removed'* && "$out" == *'unchanged'* ]] &&
  pass "DRY_RUN prints the plan and changes nothing" ||
  fail "dry run (rc=$rc): $out"

# gate: under the percent and not the hourly minute -> nothing removed --------
G="$T/gate"
mk_cache "$G"
out="$(run_prune "$G" 0 "GO_CACHE_GATE=1 GO_CACHE_USED_PCT=10 GO_CACHE_NOW_MIN=30 GO_CACHE_PRUNE_AT_PCT=85")"; rc=$?
[[ $rc -eq 0 && -f "$G/00/aa/old" && "$out" == *'skip:'* ]] &&
  pass "under 85% and not minute 0: nothing removed" ||
  fail "gate skip (rc=$rc): $out"

out="$(run_prune "$G" 0 "GO_CACHE_GATE=1 GO_CACHE_USED_PCT=90 GO_CACHE_NOW_MIN=30")"; rc=$?
[[ $rc -eq 0 && ! -e "$G/00/aa/old" && -f "$G/ff/bb/new" ]] &&
  pass "at or over 85% on a 5-min tick: the old file goes" ||
  fail "gate pressure (rc=$rc): $out"

mk_cache "$G"
out="$(run_prune "$G" 0 "GO_CACHE_GATE=1 GO_CACHE_USED_PCT=10 GO_CACHE_NOW_MIN=0")"; rc=$?
[[ $rc -eq 0 && ! -e "$G/00/aa/old" ]] &&
  pass "the hourly tick prunes even when the filesystem is under the percent" ||
  fail "gate hourly (rc=$rc): $out"

# bad settings refuse before any delete ----------------------------------------
out="$(run_prune "$G" 2)"; rc=$?
[[ $rc -ne 0 && -f "$G/ff/bb/new" && "$out" == FATAL* ]] &&
  pass "a bad DRY_RUN is refused" ||
  fail "bad dry (rc=$rc): $out"

# per-cache gate: two caches on two fake filesystems ---------------------------
# A stubbed df puts any path under FAKE_FULL on a 93% "/fake/root" and the rest
# on a 23% "/fake/data": only the cache on the full filesystem is pruned.
mkdir -p "$T/stub"
cat >"$T/stub/df" <<'STUB'
#!/usr/bin/env bash
d="${*: -1}"
echo "Filesystem 1-blocks Used Available Capacity Mounted on"
case "$d" in
  "$FAKE_FULL"*) echo "fake-root 1000 930 70 93% /fake/root" ;;
  *) echo "fake-data 1000 230 770 23% /fake/data" ;;
esac
STUB
chmod +x "$T/stub/df"
F1="$T/full/cache"; F2="$T/roomy/cache"
mk_cache "$F1"; mk_cache "$F2"
out="$(run_prune "$F1 $F2" 0 "PATH=$T/stub:$PATH FAKE_FULL=$T/full GO_CACHE_GATE=1 GO_CACHE_NOW_MIN=30 GO_CACHE_PRUNE_AT_PCT=85" 2>&1)"; rc=$?
[[ $rc -eq 0 && ! -e "$F1/00/aa/old" && -f "$F2/00/aa/old" && -f "$F1/ff/bb/new" \
  && "$out" == *"CACHE user=$(id -un) path=$F1 fs=/fake/root used_pct=93 threshold=85 action=prune"* \
  && "$out" == *"CACHE user=$(id -un) path=$F2 fs=/fake/data used_pct=23 threshold=85 action=skip"* ]] &&
  pass "each cache is gated by ITS filesystem: the 93% one is pruned, the 23% one is not; one CACHE line each" ||
  fail "per-cache gate (rc=$rc): $out"

# ./run's do_log assigns unscoped globals (action, msg, log_dir, ...): a
# do_log that clobbers them must not turn a skip into a prune.
mk_cache "$F1"
out="$(run_prune "$F1 $F2" 0 "PATH=$T/stub:$PATH FAKE_FULL=$T/full GO_CACHE_GATE=1 GO_CACHE_NOW_MIN=30 CLOBBER_LOG=1" 2>&1)"; rc=$?
[[ $rc -eq 0 && ! -e "$F1/00/aa/old" && -f "$F2/00/aa/old" ]] &&
  pass "a do_log that sets globals (as ./run's does) still leaves the roomy cache alone" ||
  fail "clobbering do_log (rc=$rc): $out"

mk_cache "$F1"
out="$(run_prune "$F2" 0 "PATH=$T/stub:$PATH FAKE_FULL=$T/full GO_CACHE_GATE=1 GO_CACHE_NOW_MIN=30" 2>&1)"; rc=$?
[[ $rc -eq 0 && -f "$F2/00/aa/old" && "$out" == *'action=skip'* && "$out" == *'OK skip:'* ]] &&
  pass "only roomy caches: nothing removed, one skip line" ||
  fail "all skip (rc=$rc): $out"

# a user whose cache cannot be read: a loud WARN, the others still pruned -----
# A stubbed sudo refuses 'nouser' and answers 'okuser' with a fixture cache, so
# no real user, cache or sudo is touched.
cat >"$T/stub/sudo" <<'STUB'
#!/usr/bin/env bash
u=""
while [ $# -gt 0 ]; do
  case "$1" in -n|-H) shift ;; -u) u="$2"; shift 2 ;; --) shift; break ;; *) break ;; esac
done
[ "$u" = okuser ] || { echo "sudo: unknown user $u" >&2; exit 1; }
case "$*" in *"go env GOCACHE"*) echo "$FAKE_GOCACHE"; exit 0 ;; esac
exec "$@"
STUB
chmod +x "$T/stub/sudo"
U="$T/users/okuser/cache"
mk_cache "$U"
out="$(env SPOOL_TEST=1 GO_CACHE_USERS="nouser okuser" GO_CACHE_LOCK=0 DRY_RUN=0 GO_CACHE_MAX_AGE_MIN=10 \
  PATH="$T/stub:$PATH" FAKE_GOCACHE="$U" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { command -v "$1" >/dev/null; }
    source "'"$PROJ_ROOT"'/src/bash/run/prune-go-build-cache.func.sh"
    do_prune_go_build_cache' 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *'WARN user=nouser cache NOT pruned'* && ! -e "$U/00/aa/old" && -f "$U/ff/bb/new" ]] &&
  pass "an unreadable user is a WARN line and the readable user's cache is still pruned" ||
  fail "warn user (rc=$rc): $out"

out="$(env -u GO_CACHE_USERS -u GO_CACHE_DIRS SPOOL_TEST=1 GO_CACHE_LOCK=0 DRY_RUN=1 bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { command -v "$1" >/dev/null; }
    source "'"$PROJ_ROOT"'/src/bash/run/prune-go-build-cache.func.sh"
    do_prune_go_build_cache' 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *'SPOOL_TEST=1'* ]] &&
  pass "SPOOL_TEST=1 with no named caches refuses to discover the live users" ||
  fail "test guard (rc=$rc): $out"

# the default users include the CI runner user when it exists -----------------
cat >"$T/stub/getent" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  group) echo "spool-agents:x:900:a1,a2" ;;
  passwd) for x in $FAKE_USERS; do [ "$x" = "$2" ] && { echo "$2:x:1:1::/nonexistent:/bin/false"; exit 0; }; done; exit 2 ;;
esac
STUB
chmod +x "$T/stub/getent"
users() {
  env SPOOL_BOX_USER=boxu SPOOL_AGENT_USER=agu PATH="$T/stub:$PATH" "$@" bash -c '
    source "'"$PROJ_ROOT"'/src/bash/run/prune-go-build-cache.func.sh"
    go_cache_discover_users'
}
out="$(users FAKE_USERS="ghrunner" GH_RUNNER_USER=)"
[[ "$out" == "boxu agu a1 a2 ghrunner" ]] &&
  pass "the default users include the runner user (GH_RUNNER_USER default) when it exists" ||
  fail "runner default: '$out'"
out="$(users FAKE_USERS="ci-a" GH_RUNNER_USER="ci-a ci-b")"
[[ "$out" == "boxu agu a1 a2 ci-a" ]] &&
  pass "GH_RUNNER_USER names the runner users; one that does not exist is left out" ||
  fail "runner env: '$out'"
out="$(users FAKE_USERS="")"
[[ "$out" == "boxu agu a1 a2" ]] &&
  pass "no runner user on the box: the default set is unchanged" ||
  fail "no runner: '$out'"

# cron script: calls the action with the gate on, refuses a worktree ----------
SH="$T/shared"
mkdir -p "$SH/csi-spl-orc/src/bash/scripts"
cp "$PROJ_ROOT/src/bash/scripts/prune-go-build-cache-cron.sh" "$SH/csi-spl-orc/src/bash/scripts/"
printf '#!/usr/bin/env bash\nprintf "DRY_RUN=%%s GATE=%%s LOCK=%%s args=%%s\\n" "${DRY_RUN:-}" "${GO_CACHE_GATE:-}" "${GO_CACHE_LOCK_FILE:-}" "$*" >>"%s/calls"\nexit "${RUN_RC:-0}"\n' "$T" >"$SH/csi-spl-orc/run"
chmod +x "$SH/csi-spl-orc/run" "$SH/csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh"
out="$(GO_CACHE_LOG_DIR="$T/log" bash "$SH/csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(cat "$T/calls")" == "DRY_RUN=0 GATE=1 LOCK=$T/log/prune.lock args=-a do_prune_go_build_cache" ]] &&
  pass "the cron script runs the prune with DRY_RUN=0 and the gate on" ||
  fail "cron run (rc=$rc): $out / $(cat "$T/calls" 2>&1)"
: >"$T/calls"
out="$(RUN_RC=1 GO_CACHE_LOG_DIR="$T/log" bash "$SH/csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 1 && "$out" == *'FAIL go build cache prune rc=1'* ]] &&
  pass "a failed prune: exit 1, one FAIL line" ||
  fail "cron fail (rc=$rc): $out"
WT="$T/csi-spl-wt/g-9"; mkdir -p "$WT"
cp -a "$SH/csi-spl-orc" "$WT/"
out="$(bash "$WT/csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh" 2>&1)"; rc=$?
[[ $rc -eq 2 && "$out" == *'agent worktree'* ]] &&
  pass "an agent worktree is refused" ||
  fail "worktree (rc=$rc): $out"

# installer: one tagged */5 line, other lines kept, dry run writes nothing ----
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = -l ]; then cat "$FAKE_CRONTAB" 2>/dev/null; exit 0; fi\ncp "$1" "$FAKE_CRONTAB"\n' >"$T/bin/crontab"
chmod +x "$T/bin/crontab"
printf '%s\n' '# keep me' '*/5 * * * * /x/box-stats-cron.sh >> /l/cron.out 2>&1 # csi-spl:box-stats' >"$T/crontab"
cp "$T/crontab" "$T/crontab.orig"
setup() {
  # shellcheck disable=SC2086
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$PROJ_ROOT" PATH="$T/bin:$PATH" FAKE_CRONTAB="$T/crontab" SPL_ORG_APP=csi-spl \
    DESK_CRON_SRC="$SH" GO_CACHE_CRON_LOG_DIR="$T/log" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    do_require_bin() { return 0; }
    source "'"$PROJ_ROOT"'/src/bash/run/setup-go-cache-prune-cron.func.sh"
    do_setup_go_cache_prune_cron'
}
want="*/5 * * * * $SH/csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh >> $T/log/cron.out 2>&1 # csi-spl:go-cache-prune"
out="$(setup)"; rc=$?
[[ $rc -eq 0 && "$out" == *'DRY_RUN nothing was touched'* && "$out" == *"+$want"* ]] && cmp -s "$T/crontab" "$T/crontab.orig" &&
  pass "dry run: prints the */5 line, writes nothing" ||
  fail "install dry (rc=$rc): $out"
out="$(setup DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c 'csi-spl:go-cache-prune$' "$T/crontab")" -eq 1 && "$(grep -F -x -c "$want" "$T/crontab")" -eq 1 ]] &&
  pass "install: ONE */5 line tagged csi-spl:go-cache-prune" ||
  fail "install (rc=$rc): $out / $(cat "$T/crontab")"
[[ "$(head -2 "$T/crontab")" == "$(cat "$T/crontab.orig")" ]] &&
  pass "the box-stats line and every other line stay byte for byte" ||
  fail "kept: $(cat "$T/crontab")"
out="$(setup DRY_RUN=0 GO_CACHE_CRON_ACTION=remove)"; rc=$?
cmp -s "$T/crontab" "$T/crontab.orig" && [[ $rc -eq 0 ]] &&
  pass "remove takes only its own line" ||
  fail "remove (rc=$rc): $(cat "$T/crontab")"

echo
if [ "$fails" -eq 0 ]; then echo "prune-go-build-cache: all passed"; exit 0; fi
echo "prune-go-build-cache: $fails FAILED"; exit 1
