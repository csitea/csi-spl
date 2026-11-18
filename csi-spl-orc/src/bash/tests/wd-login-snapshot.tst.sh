#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the login probe read from a watchdog code snapshot (SPL-5919).
# The watchdog runs each desk-cron sha from <wd>/code/<sha>/ (a git archive
# plus .sha; spl-wd-self-update.func.sh); its self-check fails a sha on any
# bash error line (SPL_WD_UPD_ERR_RE). 2026-11-18: every new sha was
# quarantined on "spl-agent-login-check.func.sh: line 250: <wd>/../var/code/
# <sha>/agent-login-check/probe: No such file or directory": the probe was
# read under the SNAPSHOT tree, and the redirect order let the error out.
# A fixture box: a main checkout and its desk-cron worktree (starter.src),
# a snapshot of this tree's orc code at <wd>/code/<sha>/, a limit-stamped
# seat, the probe read the way spl_wd_limit_healed reads it:
#   1. no probe anywhere: nothing on stderr (no self-check error), not healed
#   2. the state dir from the snapshot is the box's LIVE dir, derived from
#      the desk-cron checkout, not one under the snapshot tree
#   3. a live probe "ok" after the stamp heals the seat (SPL-5617) from the
#      snapshot; one older than the stamp does not
#   4. DESK_CRON_SRC wins over starter.src; LOGIN_STATE_DIR wins over both
#   5. controls: the same code outside a snapshot (no .sha) keys the dir by
#      its own tree; a snapshot with no starter.src keeps that rule and is
#      still silent
#   6. no dispatch lease file: the alert target is "orchestrator", silently
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ERR_RE="$(sed -n "s/^SPL_WD_UPD_ERR_RE='\(.*\)'$/\1/p" "$PROJ_ROOT/src/bash/run/spl-wd-self-update.func.sh")"
[[ -n "$ERR_RE" ]] || { fail "SPL_WD_UPD_ERR_RE not found in spl-wd-self-update.func.sh"; exit 1; }

SHA=0123456789abcdef0123456789abcdef01234567
ORC="$(basename "$PROJ_ROOT")"
MAIN="$T/opt/org/app"; DESK="$T/opt/org/app-desk-cron"
mkdir -p "$MAIN/.git/worktrees/app-desk-cron" "$DESK"
echo "gitdir: $MAIN/.git/worktrees/app-desk-cron" >"$DESK/.git"
LIVE="$T/var/org/app/agent-login-check"
WD="$T/spool/dispatch/wd"; SNAP="$WD/code/$SHA"
SNAPVAR="$T/spool/dispatch/var/code/$SHA/agent-login-check"
mkdir -p "$SNAP/$ORC/src/bash" "$WD"
cp -a "$PROJ_ROOT/lib" "$SNAP/$ORC/"
cp -a "$PROJ_ROOT/src/bash/run" "$SNAP/$ORC/src/bash/"
echo "$SHA" >"$SNAP/.sha"
echo "$DESK" >"$WD/starter.src"
STAMP="$WD/c-985.limit"; : >"$STAMP"; ST="$(stat -c %Y "$STAMP")"

# in_tree TOP SNIPPET [VAR=val...]: SNIPPET in a fresh bash, PROJ_PATH and
# APP_PATH set as run.sh sets them for TOP's ./run, nothing else derived
in_tree() {
  local top="$1" snip="$2"; shift 2
  env -u SPL_VAR_APP_DIR -u SPL_ORG_DIR -u SPL_WT_ROOT -u SPL_DESK_DIR -u LOGIN_STATE_DIR \
    -u DESK_CRON_SRC -u SPL_RUN_PATHS_TOP PROJ_PATH="$top/$ORC" APP_PATH="$top" "$@" \
    bash -c "set -uo pipefail; source '$top/$ORC/src/bash/run/spl-agent-login-check.func.sh'; $snip"
}
healed() { in_tree "$SNAP" "spl_lc_login_ok_after $ST \$(( $ST + ${1:-60} ))" "${@:2}"; }
probe() { mkdir -p "$1"; echo "$2 $3 probe" >"$1/probe"; }

# 1. no probe anywhere: silent, not healed
err="$(healed 60 2>&1 >/dev/null)"; rc=$?
[[ -z "$err" ]] && pass "1 no probe: nothing on stderr" || fail "1 no probe: stderr: $err"
grep -qE "$ERR_RE" <<<"$err" && fail "1 no probe: a self-check error line: $err" || pass "1 no probe: no self-check error line"
(( rc == 1 )) && pass "1 no probe: not healed" || fail "1 no probe: rc $rc, want 1"

# 2. the state dir from the snapshot is the live one
got="$(in_tree "$SNAP" '_lc_state_dir' 2>&1)"
[[ "$got" == "$LIVE" ]] && pass "2 snapshot state dir = the live $LIVE" || fail "2 snapshot state dir: got '$got', want '$LIVE' (not $SNAPVAR)"
got="$(in_tree "$SNAP" "source '$SNAP/$ORC/lib/bash/funcs/spl-run-paths.func.sh'; spl_run_paths; _lc_state_dir" 2>&1)"
[[ "$got" == "$LIVE" ]] && pass "2 an earlier spl_run_paths in the process does not key it by the snapshot" || fail "2 after spl_run_paths: got '$got'"

# 3. the live probe heals the seat from the snapshot
probe "$LIVE" $(( ST + 30 )) ok
err="$(healed 60 2>&1 >/dev/null)"; rc=$?
(( rc == 0 )) && [[ -z "$err" ]] && pass "3 live probe ok after the stamp: healed" || fail "3 live probe ok: rc $rc, stderr '$err'"
probe "$LIVE" $(( ST - 30 )) ok
healed 60 >/dev/null 2>&1 && fail "3 a probe older than the stamp healed" || pass "3 a probe older than the stamp: not healed"
probe "$SNAPVAR" $(( ST + 30 )) ok
healed 60 >/dev/null 2>&1 && fail "3 a probe under the snapshot tree healed" || pass "3 a probe under the snapshot tree is not read"
rm -rf "$SNAPVAR" "$LIVE"

# 4. overrides
OTHER="$T/opt/org2/app2"; mkdir -p "$OTHER/.git"
got="$(in_tree "$SNAP" '_lc_state_dir' DESK_CRON_SRC="$OTHER" 2>&1)"
[[ "$got" == "$T/var/org2/app2/agent-login-check" ]] && pass "4 DESK_CRON_SRC wins over starter.src" || fail "4 DESK_CRON_SRC: got '$got'"
got="$(in_tree "$SNAP" '_lc_state_dir' LOGIN_STATE_DIR="$T/x/y" 2>&1)"
[[ "$got" == "$T/x/y" ]] && pass "4 LOGIN_STATE_DIR wins in a snapshot" || fail "4 LOGIN_STATE_DIR: got '$got'"

# 5. controls: no .sha = the tree's own rule; no starter.src = the same, silent
rm -f "$SNAP/.sha"
got="$(in_tree "$SNAP" '_lc_state_dir' 2>&1)"
[[ "$got" == "$SNAPVAR" ]] && pass "5 no .sha: keyed by its own tree, as before" || fail "5 no .sha: got '$got', want '$SNAPVAR'"
echo "$SHA" >"$SNAP/.sha"; rm -f "$WD/starter.src"
got="$(in_tree "$SNAP" '_lc_state_dir' 2>&1)"
[[ "$got" == "$SNAPVAR" ]] && pass "5 no starter.src: keyed by its own tree" || fail "5 no starter.src: got '$got'"
err="$(healed 60 2>&1 >/dev/null)"
[[ -z "$err" ]] && pass "5 no starter.src, no probe: nothing on stderr" || fail "5 no starter.src: stderr: $err"

# 6. no dispatch lease: orchestrator, nothing on stderr
mkdir -p "$T/spool2"
out="$(in_tree "$SNAP" '_lc_alert_to' SPOOL_ROOT="$T/spool2" SPOOL_AGENT_ID_RX='[acgmq]-[0-9]{3}' 2>"$T/err6")"
[[ "$out" == orchestrator && ! -s "$T/err6" ]] && pass "6 no lease: orchestrator, silent" || fail "6 no lease: out '$out', stderr '$(cat "$T/err6")'"

if (( fails == 0 )); then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
