#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the desk reconcile cron follows the desk user (spec 069 section 8.5
#          row B6). With SPOOL_DESK_USER naming another user than the caller,
#          do_spl_desk_install_service writes the 4 marked lines (dev + prd,
#          tick + @reboot) into THAT user's crontab and takes them out of the
#          caller's; unset, or naming the caller, nothing changes. `crontab`
#          and `sudo` are stubs over one file per user; the caller is
#          `id -un`, the desk user a name that exists only in the stub.
#   1. unset: the 4 lines land in the caller's crontab, sudo is never called
#   2. SPOOL_DESK_USER = the caller: the same, no sudo
#   3. SPOOL_DESK_USER = B (env): 0 marked lines left in the caller's crontab,
#      4 in B's, the same bytes; an unrelated line stays (the red control)
#   4. the same from the box config (SPOOL_BOX_ENV)
#   5. dry run: both diffs printed, nothing written
#   6. check reads B's crontab and warns while the caller still holds a line
#   7. remove takes the lines out of both crontabs
#   8. DESK_CRON_PROBE_DIR sets the probe-login location; a bad one is refused
#   9. --print-crontab names the desk user's crontab on stderr, stdout stays
#      the one line
#  10. PATH carries go under a cron PATH and another user's empty home
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
ME="$(id -un)" B="desk-b"
R="$T/repo" C="$T/repo-desk-cron" L="$T/log" CTD="$T/crontabs"
git init -q "$R" && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
mkdir -p "$C/$OA-orc/src/bash/scripts" "$T/stub" "$CTD"
SCRIPT="$C/$OA-orc/src/bash/scripts/desk-reconcile-cron.sh"
printf '#!/bin/sh\nexit 0\n' >"$SCRIPT"; chmod +x "$SCRIPT"
# crontab: one file per user; -u picks the user, else STUB_ME (the caller)
cat >"$T/stub/crontab" <<'EOF'
#!/bin/sh
u="${STUB_ME:?}"
[ "${1:-}" = -u ] && { u="$2"; shift 2; }
F="${STUB_CRONTABS:?}/$u"
case "${1:-}" in
  -l) [ -s "$F" ] && cat "$F"; exit 0 ;;
  "") exit 2 ;;
  -)  cat >"$F"; exit 0 ;;
  *)  cat "$1" >"$F"; exit 0 ;;
esac
EOF
# sudo -n -u <user> <cmd...>: runs <cmd> as that user (STUB_ME), logs the call
cat >"$T/stub/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >>"${STUB_SUDO_LOG:?}"
u=root
while [ "$#" -gt 0 ]; do
  case "$1" in -n) shift ;; -u) u="$2"; shift 2 ;; *) break ;; esac
done
STUB_ME="$u" exec "$@"
EOF
chmod +x "$T/stub/crontab" "$T/stub/sudo"
: >"$T/no-box.env"

svc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" SPL_ORG_APP="$OA" STUB_CRONTABS="$CTD" STUB_ME="$ME" \
    STUB_SUDO_LOG="$T/sudo.log" PATH="$T/stub:$PATH" SPOOL_TEST=1 SPOOL_BOX_ENV="$T/no-box.env" \
    TENANT_ID=t1 DESK_CRON_LOG_DIR="$L" DESK_CRON_EVERY=3 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { :; }
    do_spl_desk_install_service' 2>&1
}
both() { svc ENV=dev DRY_RUN=0 "$@" && svc ENV=prd DRY_RUN=0 "$@"; }
marked() { if [ -s "$CTD/$1" ]; then grep -c "# $OA:desk-reconcile" "$CTD/$1"; else echo 0; fi; }
reset() { rm -f "$CTD"/* "$T/sudo.log"; }
OTHER="0 4 * * * /usr/bin/true # someone-elses-job"

# --- 1. unset: today's crontab, no hop ---------------------------------------------
reset; printf '%s\n' "$OTHER" >"$CTD/$ME"
both >"$T/o"
[[ "$(marked "$ME")" == 4 && "$(marked "$B")" == 0 && ! -e "$T/sudo.log" ]] &&
  pass "1. unset: 4 marked lines in the caller's crontab, none elsewhere, no sudo" ||
  fail "1. me=$(marked "$ME") b=$(marked "$B") sudo=$(cat "$T/sudo.log" 2>/dev/null) $(cat "$T/o")"
cp "$CTD/$ME" "$T/today"

# --- 2. the caller named: the same --------------------------------------------------
reset; printf '%s\n' "$OTHER" >"$CTD/$ME"
both SPOOL_DESK_USER="$ME" >"$T/o"
cmp -s "$CTD/$ME" "$T/today" && [[ ! -e "$T/sudo.log" ]] &&
  pass "2. SPOOL_DESK_USER = the caller writes the same bytes, no sudo" || fail "2. $(diff "$T/today" "$CTD/$ME") $(cat "$T/o")"

# --- 3. the red control: B named ----------------------------------------------------
reset; cp "$T/today" "$CTD/$ME"
both SPOOL_DESK_USER="$B" >"$T/o"
[[ "$(marked "$ME")" == 0 && "$(marked "$B")" == 4 ]] &&
  pass "3. SPOOL_DESK_USER=$B: 0 marked lines left in the caller's crontab, 4 in $B's" ||
  fail "3. me=$(marked "$ME") b=$(marked "$B") $(cat "$T/o")"
grep -qxF "$OTHER" "$CTD/$ME" && pass "3. ...the caller's unrelated line stays" || fail "3. lost: $(cat "$CTD/$ME")"
diff <(grep "# $OA:desk-reconcile" "$T/today" | sort) <(sort "$CTD/$B" 2>/dev/null) >/dev/null &&
  pass "3. ...$B's lines are the caller's lines, byte for byte" || fail "3. lines differ: $(diff <(grep "# $OA:" "$T/today" | sort) <(sort "$CTD/$B" 2>/dev/null))"
grep -q -- "-u $B crontab" "$T/sudo.log" 2>/dev/null && pass "3. ...through sudo -u $B" || fail "3. sudo: $(cat "$T/sudo.log" 2>/dev/null)"
both SPOOL_DESK_USER="$B" >"$T/o"
[[ "$(marked "$ME")" == 0 && "$(marked "$B")" == 4 ]] && pass "3. ...and a second install is a fixed point" ||
  fail "3. re-install: me=$(marked "$ME") b=$(marked "$B")"

# --- 4. from the box config -----------------------------------------------------------
reset; cp "$T/today" "$CTD/$ME"; printf 'SPOOL_DESK_USER=%s\n' "$B" >"$T/box.env"
both SPOOL_BOX_ENV="$T/box.env" >"$T/o"
[[ "$(marked "$ME")" == 0 && "$(marked "$B")" == 4 ]] && pass "4. SPOOL_DESK_USER from the box config: same move" ||
  fail "4. me=$(marked "$ME") b=$(marked "$B") $(cat "$T/o")"

# --- 5. dry run --------------------------------------------------------------------------
reset; cp "$T/today" "$CTD/$ME"
out="$(svc ENV=dev SPOOL_DESK_USER="$B")"
cmp -s "$CTD/$ME" "$T/today" && [[ ! -e "$CTD/$B" ]] && [[ "$out" == *"crontab of $B"* && "$out" == *"+*/3 * * * *"* && "$out" == *"-*/3 * * * *"* ]] &&
  pass "5. the dry run prints $B's add and the caller's removal, writes nothing" || fail "5. $out"

# --- 6. check ----------------------------------------------------------------------------
reset; cp "$T/today" "$CTD/$ME"; svc ENV=dev SPOOL_DESK_USER="$B" DRY_RUN=0 >/dev/null
out="$(svc ENV=dev SPOOL_DESK_USER="$B" DESK_SERVICE_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *'"matches": true'* && "$out" != *WARN*"crontab of $ME"* ]] &&
  pass "6. check reads $B's crontab" || fail "6. rc=$rc $out"
cp "$T/today" "$CTD/$ME"
out="$(svc ENV=dev SPOOL_DESK_USER="$B" DESK_SERVICE_ACTION=check)"
[[ "$out" == *WARN*"crontab of $ME"* ]] && pass "6. ...and warns while the caller still holds a marked line" || fail "6. no warn: $out"

# --- 7. remove ---------------------------------------------------------------------------
svc ENV=dev SPOOL_DESK_USER="$B" DESK_SERVICE_ACTION=remove DRY_RUN=0 >/dev/null
[[ "$(grep -c "# $OA:desk-reconcile\(@boot\)\?$" "$CTD/$ME")" == 0 && "$(grep -c "# $OA:desk-reconcile\(@boot\)\?$" "$CTD/$B")" == 0 ]] &&
  grep -q "# $OA:desk-reconcile-prd$" "$CTD/$ME" &&
  pass "7. remove dev takes the dev lines out of both crontabs and keeps prd" || fail "7. me: $(cat "$CTD/$ME") b: $(cat "$CTD/$B")"

# --- 8. the probe-login location from env ----------------------------------------------
reset
out="$(svc ENV=prd DESK_CRON_PROBE_DIR='$HOME/probe/e2e')"
[[ "$out" == *'PROBE_EMAIL=$(cat $HOME/probe/e2e/human-email) PROBE_PW_FILE=$HOME/probe/e2e/pw-human'* ]] &&
  pass "8. DESK_CRON_PROBE_DIR sets the probe-login location" || fail "8. $out"
out="$(svc ENV=prd DESK_CRON_PROBE_DIR='/x; rm -rf /')"; rc=$?
[[ $rc -ne 0 && "$out" == *"DESK_CRON_PROBE_DIR"* ]] && pass "8. ...and a path with shell text is refused" || fail "8. rc=$rc $out"

# --- 9. --print-crontab ------------------------------------------------------------------
CO="$T/co/$OA-orc"
mkdir -p "$CO/src/bash/scripts" "$CO/lib/bash/funcs"
cp "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" "$CO/src/bash/scripts/"
cp "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh" "$CO/lib/bash/funcs/"
printf '#!/bin/sh\n' >"$CO/run"; chmod +x "$CO/run"
pc() { env SPOOL_TEST=1 SPOOL_BOX_ENV="$T/no-box.env" DESK_TRUNK_CHECK=0 "$@" bash "$CO/src/bash/scripts/desk-reconcile-cron.sh" --print-crontab 2>"$T/err"; }
out="$(pc)"; rc=$?
[[ $rc -eq 0 && "$(wc -l <<<"$out")" == 1 && "$out" == *"# $OA:desk-reconcile" && ! -s "$T/err" ]] &&
  pass "9. unset: --print-crontab prints the one line, nothing on stderr" || fail "9. rc=$rc $out / $(cat "$T/err")"
out="$(pc SPOOL_DESK_USER="$B")"; rc=$?
[[ $rc -eq 0 && "$(wc -l <<<"$out")" == 1 && "$out" == *"# $OA:desk-reconcile" && "$(cat "$T/err")" == *"crontab of $B"* ]] &&
  pass "9. SPOOL_DESK_USER=$B: stdout stays the line, stderr names $B's crontab" || fail "9. rc=$rc $out / $(cat "$T/err")"

# --- 10. PATH carries go -----------------------------------------------------------------
mkdir -p "$T/home-b"
if compgen -G '/usr/local/go*/bin/go' >/dev/null; then
  out=$(env -i PATH=/usr/bin:/bin HOME="$T/home-b" DESK_CRON_TOOLS=go \
          bash "$PROJ_ROOT/src/bash/scripts/desk-reconcile-cron.sh" --check-tools 2>&1); rc=$?
  [[ $rc -eq 0 ]] && pass "10. go resolves under a cron PATH and the desk user's empty home" || fail "10. rc=$rc $out"
else
  echo "SKIP: 10. no /usr/local/go* on this runner (the box toolchain root)"
fi

echo "desk-install-service-user: $fails failure(s)"
[[ $fails -eq 0 ]]
