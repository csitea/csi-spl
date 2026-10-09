#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_install_service keeps ONE line per env and never touches
#          another env's line. 2026-10-01: a dev install matched the tag
#          `<org>-<app>:desk-reconcile` as a PREFIX, deleted the prd line
#          (`...:desk-reconcile-prd`) and wrote a line without the self-update
#          step - prd stopped reconciling for 7 minutes. `crontab` is a stub
#          over a file; a scratch git repo stands in for the shared checkout.
#   1. the target state (*/3 dev, 1-59/3 prd, self-updating checkout) is a
#      fixed point: installing dev and prd over it changes nothing
#   2. a dev install over the old */5 pair rewrites ONLY the dev line; the prd
#      line and an unrelated line are byte-identical
#   3. a prd install writes the -prd tag, offset 1, the PROBE_* env and
#      cron-prd.out, and leaves the dev line alone
#   4. the dry run prints the before/after diff and writes nothing
#   5. check reads the .sh the line runs, not the `cd <dir>` of the prefix
#   6. remove on dev leaves the prd line
#   7. no self-updating checkout yet: the dry run plans a detached worktree;
#      an explicit DESK_CRON_SRC gets no self-update prefix
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
R="$T/repo" C="$T/repo-desk-cron" L="$T/log" CT="$T/crontab.txt"
git init -q "$R" && git -C "$R" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
mkdir -p "$C/$OA-orc/src/bash/scripts" "$T/stub"
SCRIPT="$C/$OA-orc/src/bash/scripts/desk-reconcile-cron.sh"
printf '#!/bin/sh\nexit 0\n' >"$SCRIPT"; chmod +x "$SCRIPT"
cat >"$T/stub/crontab" <<'EOF'
#!/bin/sh
F="${STUB_CRONTAB:?}"
case "${1:-}" in
  -l) [ -s "$F" ] && cat "$F"; exit 0 ;;
  "") exit 2 ;;
  *)  cat "$1" >"$F"; exit 0 ;;
esac
EOF
chmod +x "$T/stub/crontab"

svc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" SPL_ORG_APP="$OA" STUB_CRONTAB="$CT" PATH="$T/stub:$PATH" \
    TENANT_ID=t1 DESK_CRON_LOG_DIR="$L" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { :; }
    do_spl_desk_install_service' 2>&1
}

PRE="cd $C && git fetch -q origin master && git checkout -q --detach origin/master; "
PD="\$HOME/.local/share/$OA/cloud/prd/m3-e2e/e2e"
DEV3="*/3 * * * * ${PRE}ENV=dev TENANT_ID=t1 DESK_MUTE=c-010 $SCRIPT >> $L/cron.out 2>&1 # $OA:desk-reconcile"
PRD3="1-59/3 * * * * ${PRE}ENV=prd TENANT_ID=t1 DESK_MUTE=c-010 PROBE_EMAIL=\$(cat $PD/human-email) PROBE_PW_FILE=$PD/pw-human $SCRIPT >> $L/cron-prd.out 2>&1 # $OA:desk-reconcile-prd"
OTHER="0 4 * * * /usr/bin/true # someone-elses-job"
# the @reboot twins (desk-reconcile-boot.tst.sh covers them)
DEVB="@reboot ENV=dev TENANT_ID=t1 DESK_MUTE=c-010 $SCRIPT --boot >> $L/cron.out 2>&1 # $OA:desk-reconcile@boot"
PRDB="@reboot ENV=prd TENANT_ID=t1 DESK_MUTE=c-010 PROBE_EMAIL=\$(cat $PD/human-email) PROBE_PW_FILE=$PD/pw-human $SCRIPT --boot >> $L/cron-prd.out 2>&1 # $OA:desk-reconcile-prd@boot"

# --- 1. the target state is a fixed point ---------------------------------------------
printf '%s\n%s\n%s\n%s\n%s\n' "$OTHER" "$DEV3" "$DEVB" "$PRD3" "$PRDB" >"$CT"; cp "$CT" "$T/target"
svc ENV=dev DESK_CRON_EVERY=3 DESK_MUTE=c-010 DRY_RUN=0 >"$T/o"
svc ENV=prd DESK_CRON_EVERY=3 DESK_MUTE=c-010 DRY_RUN=0 >>"$T/o"
sort "$CT" >"$T/a"; sort "$T/target" >"$T/b"
cmp -s "$T/a" "$T/b" && pass "1. the */3 dev + 1-59/3 prd target state is reproduced exactly" ||
  fail "1. drift: $(diff "$T/b" "$T/a") $(cat "$T/o")"

# --- 2. a dev install leaves the prd line alone --------------------------------------
DEV5="${DEV3/\*\/3 /*/5 }"; PRD5="${PRD3/1-59\/3 /2-59/5 }"
printf '%s\n%s\n%s\n' "$DEV5" "$PRD5" "$OTHER" >"$CT"
svc ENV=dev DESK_CRON_EVERY=3 DESK_MUTE=c-010 DRY_RUN=0 >"$T/o"
grep -qxF "$PRD5" "$CT" && grep -qxF "$OTHER" "$CT" &&
  pass "2. a dev install keeps the prd line and the unrelated line byte-identical" || fail "2. crontab: $(cat "$CT")"
grep -qxF "$DEV3" "$CT" && [[ "$(grep -c "# $OA:desk-reconcile\$" "$CT")" == 1 ]] &&
  pass "2. ...and rewrites only the dev line, self-update step included" || fail "2. dev line: $(cat "$CT")"

# --- 3. prd install ---------------------------------------------------------------------------
svc ENV=prd DESK_CRON_EVERY=3 DESK_MUTE=c-010 DRY_RUN=0 >"$T/o"
grep -qxF "$PRD3" "$CT" && grep -qxF "$DEV3" "$CT" && [[ "$(wc -l <"$CT")" == 5 ]] &&
  pass "3. a prd install writes the -prd line (offset, PROBE_*, cron-prd.out) and keeps dev" || fail "3. crontab: $(cat "$CT")"

# --- 4. dry run: a diff, no write -----------------------------------------------------------
cp "$CT" "$T/before"
out="$(svc ENV=dev DESK_CRON_EVERY=7 DESK_MUTE=c-010)"
cmp -s "$CT" "$T/before" && [[ "$out" == *"crontab diff (before -> after)"* && "$out" == *"-$DEV3"* && "$out" == *"+*/7 * * * * cd $C"* ]] &&
  pass "4. the dry run shows the before/after diff and writes nothing" || fail "4. out: $out"
out="$(svc ENV=dev DESK_CRON_EVERY=3 DESK_MUTE=c-010)"
[[ "$out" == *"(no change)"* ]] && pass "4. ...and says so when nothing would change" || fail "4. no-change: $out"

# --- 5. check reads the script, not the cd -----------------------------------------------
out="$(svc ENV=prd DESK_CRON_EVERY=3 DESK_MUTE=c-010 DESK_SERVICE_ACTION=check)"; rc=$?
[[ $rc -eq 0 && "$out" == *'"matches": true'* ]] && pass "5. check passes on the installed prd line" || fail "5. rc=$rc $out"
chmod -x "$SCRIPT"
svc ENV=prd DESK_SERVICE_ACTION=check >/dev/null; rc=$?
chmod +x "$SCRIPT"
[[ $rc -ne 0 ]] && pass "5. a non-executable script fails check (the cd dir is not mistaken for it)" || fail "5. check passed on a dead script"

# --- 6. remove dev keeps prd -----------------------------------------------------------------
svc ENV=dev DESK_SERVICE_ACTION=remove DRY_RUN=0 >/dev/null
! grep -qxF "$DEV3" "$CT" && grep -qxF "$PRD3" "$CT" && grep -qxF "$OTHER" "$CT" &&
  pass "6. removing dev leaves prd and the unrelated line" || fail "6. crontab: $(cat "$CT")"

# --- 7. source defaults ------------------------------------------------------------------------
mv "$C" "$T/away"
out="$(svc ENV=dev DESK_CRON_EVERY=3)"; rc=$?
mv "$T/away" "$C"
[[ $rc -eq 0 && "$out" == *"git worktree add --detach $C origin/master"* ]] &&
  pass "7. a missing self-updating checkout is planned as a detached worktree" || fail "7. rc=$rc $out"
out="$(svc ENV=dev DESK_CRON_EVERY=3 DESK_CRON_SRC="$C")"
[[ "$out" == *"+*/3 * * * * ENV=dev"* ]] && pass "7. an explicit DESK_CRON_SRC gets no self-update prefix" || fail "7. explicit: $out"
out="$(svc ENV=dev DESK_CRON_EVERY=3 DESK_CRON_SRC="$C" DESK_CRON_SELF_UPDATE=1)"
[[ "$out" == *"+*/3 * * * * cd $C && git fetch"* ]] && pass "7. ...unless DESK_CRON_SELF_UPDATE=1" || fail "7. forced: $out"

echo "desk-install-service-envs: $fails failure(s)"
[[ $fails -eq 0 ]]
