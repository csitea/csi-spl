#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_prune_go_build_cache removes only stale Go build-cache files,
#   and trims a cache that is over GO_CACHE_CAP_GB even when every file is fresh.
#   1. a fixture cache with an old file and a fresh file: only the old one goes
#   2. a directory that is not a Go cache: untouched, non-zero exit
#   3. DRY_RUN=1 changes nothing
#   4. the gate is per cache: two caches on two fake filesystems, only the
#      one at/over the percent is pruned; an unreadable user is a WARN; the
#      default users include the CI runner user when it exists
#   5. size cap: all files fresh and over the cap -> oldest gone, size <= cap;
#      under the cap -> nothing; a busy go test -> no `go clean -cache`;
#      DRY_RUN deletes nothing. Cap 0 is the control that (5a) can fail.
#   6. per-lane caches (go-build-<lane> next to a user cache): a dead lane's
#      idle cache is removed whole; a live lane's, a recent one, a dir that
#      is not a Go cache, a name with no lane id and a symlink are kept; the
#      dry run removes nothing; RED CONTROL: no registry -> nothing removed
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

# 5. size cap: fresh files, oldest first, never a full go clean -------------
# Three sparse 500000000-byte files plus a 23-byte README and an 8-byte
# depth-1 file (du -sb 1500000031). Cap 1 GiB is 1073741824, so the excess
# is one file: the oldest goes, the other two stay, and the tree is <= the cap.
# Age is 100000 min, so the age rule matches nothing. GO_CACHE_CAP_GB=0 is
# the control: the same tree is not trimmed, so (5a) can fail.
CAPB=$((1024 * 1024 * 1024))
mk_sized() {
  local d="$1"
  mkdir -p "$d/00" "$d/ff"
  printf 'cached build artifacts\n' >"$d/README"
  printf 'depth-1\n' >"$d/keep"
  truncate -s 500000000 "$d/00/old" "$d/ff/mid" "$d/ff/new"
  touch -d '5 minutes ago' "$d/00/old"
  touch -d '3 minutes ago' "$d/ff/mid"
  touch -d '1 minute ago' "$d/ff/new"
}
# 0 when the oldest file is gone, the newer two and the depth-1 file stay,
# and du -sb is at or under 1 GiB. This is the (5a) assertion.
trimmed_to_1g() {
  local d="$1" sz
  [[ ! -e "$d/00/old" && -f "$d/ff/mid" && -f "$d/ff/new" && -f "$d/keep" && -f "$d/README" ]] || return 1
  sz="$(du -sb "$d" | awk 'NR==1 { print $1 }')"
  [[ "$sz" =~ ^[0-9]+$ ]] && (( sz <= CAPB ))
}

S5="$T/cap-over"
mk_sized "$S5"
printf 'outside\n' >"$T/outside-keep"
out="$(run_prune "$S5" 0 "GO_CACHE_MAX_AGE_MIN=100000 GO_CACHE_CAP_GB=1")"; rc=$?
if [[ $rc -eq 0 ]] && trimmed_to_1g "$S5" && [[ -f "$T/outside-keep" \
  && "$out" == *'PLAN user='*'files=1 bytes=500000000 cap_gb=1 dry_run=0'* ]]; then
  pass "over the cap, all files fresh: the oldest goes first, the cache is <= 1 GiB, nothing outside it is touched"
else
  fail "cap trim (rc=$rc du=$(du -sb "$S5" | awk '{print $1}')): $out"
fi

S0="$T/cap-off"
mk_sized "$S0"
out="$(run_prune "$S0" 0 "GO_CACHE_MAX_AGE_MIN=100000 GO_CACHE_CAP_GB=0")"; rc=$?
if [[ $rc -eq 0 && -f "$S0/00/old" && -f "$S0/ff/mid" && -f "$S0/ff/new" ]] && ! trimmed_to_1g "$S0"; then
  pass "CONTROL: GO_CACHE_CAP_GB=0 leaves the fresh over-size cache, so the (5a) check can fail"
else
  fail "cap off control (rc=$rc): $out"
fi

SU="$T/cap-under"
mk_sized "$SU"
truncate -s 1000 "$SU/00/old" "$SU/ff/mid" "$SU/ff/new"
out="$(run_prune "$SU" 0 "GO_CACHE_MAX_AGE_MIN=100000 GO_CACHE_CAP_GB=1")"; rc=$?
[[ $rc -eq 0 && -f "$SU/00/old" && -f "$SU/ff/mid" && -f "$SU/ff/new" && -f "$SU/keep" \
  && "$out" == *'PLAN user='*'files=0 bytes=0 cap_gb=1'* ]] &&
  pass "under the cap: nothing touched" ||
  fail "cap under (rc=$rc): $out"

SD="$T/cap-dry"
mk_sized "$SD"
out="$(run_prune "$SD" 1 "GO_CACHE_MAX_AGE_MIN=100000 GO_CACHE_CAP_GB=1")"; rc=$?
[[ $rc -eq 0 && -f "$SD/00/old" && -f "$SD/ff/mid" && -f "$SD/ff/new" \
  && "$out" == *'PLAN user='*'files=1 bytes=500000000 cap_gb=1 dry_run=1'* \
  && "$out" == *'would be removed'* ]] &&
  pass "DRY_RUN prints the cap plan and deletes nothing" ||
  fail "cap dry (rc=$rc): $out"

mkdir -p "$T/busy"
cat >"$T/busy/ps" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "/usr/local/go/bin/go test ./..."
STUB
cat >"$T/busy/go" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GO_STUB_LOG:?}"
exit 0
STUB
chmod +x "$T/busy/ps" "$T/busy/go"
SB="$T/cap-busy"
mk_sized "$SB"
: >"$T/go.log"
out="$(run_prune "$SB" 0 "GO_CACHE_MAX_AGE_MIN=100000 GO_CACHE_CAP_GB=1 PATH=$T/busy:$PATH GO_STUB_LOG=$T/go.log")"; rc=$?
if [[ $rc -eq 0 ]] && trimmed_to_1g "$SB" && [[ "$out" == *'no go clean -cache'* ]] && ! grep -q 'clean' "$T/go.log"; then
  pass "a busy go test: oldest files trimmed to the cap, go clean -cache is not run"
else
  fail "cap busy (rc=$rc log=$(cat "$T/go.log" 2>/dev/null)): $out"
fi

out="$(run_prune "$SB" 0 "GO_CACHE_CAP_GB=no")"; rc=$?
[[ $rc -ne 0 && -f "$SB/ff/new" && "$out" == *'GO_CACHE_CAP_GB'* && "$out" == FATAL* ]] &&
  pass "a bad GO_CACHE_CAP_GB is refused" ||
  fail "bad cap (rc=$rc): $out"

# 6. per-lane caches ---------------------------------------------------------
LP="$T/lanes" LM="$T/lanes/go-build"
mk_lanes() {
  rm -rf "$LP" "$T/lane-outside"
  mk_cache "$LM"
  local l
  for l in go-build-c901 go-build-c902 go-build-m-903 go-build-other; do
    mk_cache "$LP/$l"
    truncate -s 1000 "$LP/$l/00/aa/old"
    find "$LP/$l" -exec touch -h -d '3 days ago' {} +
  done
  touch "$LP/go-build-m-903/ff/bb/new"
  mkdir -p "$LP/go-build-c904/00"; printf 'x\n' >"$LP/go-build-c904/00/f"
  find "$LP/go-build-c904" -exec touch -h -d '3 days ago' {} +
  mk_cache "$T/lane-outside"; touch -d '3 days ago' "$T/lane-outside/00/aa/old" "$T/lane-outside/ff/bb/new"
  ln -s "$T/lane-outside" "$LP/go-build-c905"
}
mk_lanes
out="$(run_prune "$LM" 1 "GO_CACHE_LANE_PARENTS=$LP GO_CACHE_LIVE_IDS=c-902@sat")"; rc=$?
[[ $rc -eq 0 && -d "$LP/go-build-c901" && "$out" == *"PLAN lane-cache user=$(id -un) lane=c-901 files=4 "*"path=$LP/go-build-c901 dry_run=1"* ]] &&
  pass "6. the dry run plans the dead lane's idle cache and removes nothing" ||
  fail "6. lane dry run (rc=$rc): $out"
out="$(run_prune "$LM" 0 "GO_CACHE_LANE_PARENTS=$LP GO_CACHE_LIVE_IDS=c-902@sat")"; rc=$?
[[ $rc -eq 0 && ! -e "$LP/go-build-c901" && -f "$LM/README" ]] &&
  pass "6. DRY_RUN=0 removes the dead lane's idle cache whole, the user cache stays" ||
  fail "6. lane remove (rc=$rc): $out"
[[ -f "$LP/go-build-c902/00/aa/old" && "$out" == *"KEEP live-lane c-902 $LP/go-build-c902"* ]] &&
  pass "6. a live lane's cache is kept untouched" || fail "6. live lane: $out"
[[ -f "$LP/go-build-m-903/00/aa/old" && "$out" == *"KEEP recent $LP/go-build-m-903"* ]] &&
  pass "6. a dead lane's cache with a fresh file is kept" || fail "6. recent: $out"
[[ -f "$LP/go-build-c904/00/f" && "$out" == *"KEEP not-a-go-cache $LP/go-build-c904"* ]] &&
  pass "6. a go-build-<lane> dir that is not a Go cache is kept" || fail "6. not a cache: $out"
[[ -f "$LP/go-build-other/00/aa/old" && -L "$LP/go-build-c905" && -f "$T/lane-outside/00/aa/old" ]] &&
  pass "6. a name with no lane id and a symlink (and its target) are untouched" || fail "6. other / symlink: $out"
mk_lanes
out="$(run_prune "$LM" 0 "GO_CACHE_LANE_PARENTS=$LP SPOOL_ROOT=$T/no-spool")"; rc=$?
[[ $rc -eq 0 && -f "$LP/go-build-c901/00/aa/old" && "$out" == *'WARN lane caches NOT pruned: cannot read the lane registry'* ]] &&
  pass "6. RED CONTROL: no readable registry -> no lane cache is removed" ||
  fail "6. no registry (rc=$rc): $out"
mkdir -p "$T/spool6"; printf 'c-901\tclaude\t%%1\t/x\t20261019T000000Z\n' >"$T/spool6/registry.tsv"
out="$(run_prune "$LM" 0 "GO_CACHE_LANE_PARENTS=$LP SPOOL_ROOT=$T/spool6 SPOOL_TMUX_SOCKET=$T/no-tmux")"; rc=$?
[[ $rc -eq 0 && -f "$LP/go-build-c901/00/aa/old" && ! -e "$LP/go-build-c902" && "$out" == *"KEEP live-lane c-901"* ]] &&
  pass "6. a lane in registry.tsv is live (kept); one not in it is removed" ||
  fail "6. registry (rc=$rc): $out"

echo
if [ "$fails" -eq 0 ]; then echo "prune-go-build-cache: all passed"; exit 0; fi
echo "prune-go-build-cache: $fails FAILED"; exit 1
