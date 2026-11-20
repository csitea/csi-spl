#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_claude_login_mode (SPL-5695, spec 060 add-on
# claude-account-failover.md section 4.2) on a temp tree: fake own
# .claude.json, a fake credential helper for the second folder, fake BOX-0
# rows, a stub spool-send. No real login is read.
#   M1. own 91 %, backup 40 % -> backup, one alert
#   M2. backup at 92 % -> stays own, the hold alert once, not every tick
#   M3. on backup: own label changes -> own; own reset passed -> own;
#       own 84 % -> own; own 87 % -> stays backup
#   M4. on backup, the backup probes expired -> forced own
#   M5. enabled false -> a PLAN line only, login-mode unchanged
#   M6. the readers: spl_claude_login_dir / _wk / _scope on a fresh backup
#       line, nothing on own or a stale line
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

NOW=1893400000; RESET=$((NOW + 86400))
ST="$T/state"; mkdir -p "$ST" "$T/spool"
SENT="$T/sent"; : > "$SENT"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> %q\n' "$SENT" > "$T/send.sh"
# the second folder's helper: acct and probe from files the cases set
printf '#!/bin/bash\ncase "$1" in acct) cat %q;; probe) cat %q;; esac\n' "$T/blab" "$T/bprobe" > "$T/cred.sh"
lab() { printf 'acct-%s' "$(printf '%s' "$1" | sha256sum | cut -c1-8)"; }
own() {  # UUID PCT [RESET]
  printf '{"oauthAccount":{"accountUuid":"%s"},"cachedUsageUtilization":{"accountUuid":"%s","fetchedAtMs":%s,"utilization":{"seven_day":{"utilization":%s,"resets_at":"%s"}}}}\n' \
    "$1" "$1" "$(( (NOW - 60) * 1000 ))" "$2" "$(date -u -d "@${3:-$RESET}" +%Y-%m-%dT%H:%M:%SZ)" > "$T/own.json"
}
rows() {  # SCOPE of sat's BOX-0 row
  printf '{"lanes":[{"agent_id":"BOX-0","agent_box":"sat","state":"live","age_s":60,"scope":"%s"}]}\n' "$1" > "$T/rows.json"
}
run() {
  SNIPPET='do_spl_claude_login_mode' in_orc SPOOL_ROOT="$T/spool" SPOOL_AGENT_USER="$(id -un)" LOGIN_AGENT_HOME="$T/home" \
    LOGIN_STATE_DIR="$ST" LOGIN_NOW="$NOW" LOGIN_MODE_OWN_JSON="$T/own.json" LOGIN_MODE_ROWS_CMD="cat $T/rows.json" \
    LOGIN_MODE_HERE=box1 LOGIN_CRED_CMD="bash $T/cred.sh" LOGIN_SEND="$T/send.sh" LOGIN_ALERT_TO=c-002 LOGIN_FROM=c-001 \
    LOGIN_PROBE_EVERY=0 BOX_QUOTA_WEEKLY_MAX_PCT=90 BOX_QUOTA_WEEKLY_MAX_PCT_CLAUDE=90 LOGIN_MODE_ENABLED=true DRY_RUN=0 "$@" 2>&1
}
mode() { awk '{print $2}' "$ST/login-mode" 2>/dev/null; }
BL="$(lab uuid-sat)"; echo "$BL" > "$T/blab"; echo "ok fine" > "$T/bprobe"

own uuid-here 91; rows "mem_kb=1 wk=claude:40 acct=$BL live=c-001"
out="$(run)"; rc=$?
[[ $rc == 0 && "$(mode)" == backup && "$(wc -l < "$SENT")" == 1 ]] && grep -q 'own -> backup' "$SENT" && pass "M1. own 91 %, backup 40 % -> backup, one alert" || fail "M1. rc=$rc mode=$(mode) out=$out sent=$(cat "$SENT")"
read -r _ _ o b op or bp d _ < "$ST/login-mode"
[[ "$o" == "$(lab uuid-here)" && "$b" == "$BL" && "$op" == 91 && "$or" == "$RESET" && "$bp" == 40 && "$d" == "$T/home/.claude-2" ]] && pass "M1. the line: labels, own % and reset, backup %, the second folder" || fail "M1. line: $(cat "$ST/login-mode")"
grep -q uuid- <<<"$(cat "$ST/login-mode" "$SENT"; echo "$out")" && fail "M1. an account id leaked" || pass "M1. labels only, no account id"

rm -f "$ST"/login-mode*; : > "$SENT"; rows "wk=claude:92 acct=$BL live=c-001"
run >/dev/null; run >/dev/null; out="$(run)"
[[ "$(mode)" == own && "$(wc -l < "$SENT")" == 1 && "$out" == *"hold: own at 91%, backup at 92%"* ]] && grep -q 'stays on its own account' "$SENT" &&
  pass "M2. backup at 92 % -> stays own, the hold alert once over 3 ticks" || fail "M2. mode=$(mode) sent=$(cat "$SENT") out=$out"
rows "wk=claude:40 acct=$BL lm=backup live=c-001"; rm -f "$ST/login-mode.alert"; : > "$SENT"
out="$(run)"
[[ "$(mode)" == own && "$out" == *"is itself on backup"* ]] && pass "M2. the backup's box is itself on backup -> hold" || fail "M2b. out=$out"
rows "live=c-001"; out="$(run)"
[[ "$(mode)" == own && "$out" == *"no reading of the backup account"* ]] && pass "M2. no row carries the backup label -> hold (Q2)" || fail "M2c. out=$out"

to_backup() { rm -f "$ST"/login-mode*; own uuid-here 91; rows "wk=claude:40 acct=$BL live=c-001"; echo "ok" > "$T/bprobe"; run >/dev/null; [[ "$(mode)" == backup ]]; }
to_backup && own uuid-swapped 95 && out="$(run)" && [[ "$(mode)" == own && "$out" == *"the own account changed"* ]] && pass "M3. own label changes -> own" || fail "M3a. out=$out"
to_backup && printf '{"oauthAccount":{"accountUuid":"uuid-here"}}\n' > "$T/own.json" && out="$(run LOGIN_NOW=$((RESET + 1)))" &&
  [[ "$(mode)" == own && "$out" == *"the own reset passed"* ]] && pass "M3. own reset passed (no reading left) -> own" || fail "M3b. out=$out"
to_backup && own uuid-here 84 && out="$(run)" && [[ "$(mode)" == own && "$out" == *"own at 84% (under 85)"* ]] && pass "M3. own 84 % -> own" || fail "M3c. out=$out"
to_backup && own uuid-here 87 && out="$(run)" && [[ "$(mode)" == backup ]] && pass "M3. own 87 % -> stays backup (hysteresis)" || fail "M3d. out=$out"

to_backup && echo "expired login expired" > "$T/bprobe" && out="$(run)" && [[ "$(mode)" == own && "$out" == *"forced: the backup login probes expired"* ]] &&
  pass "M4. the backup probes expired -> forced own" || fail "M4. out=$out"
to_backup && rows "wk=claude:40 acct=acct-00000000 live=c-001" && out="$(run)" && [[ "$(mode)" == own && "$out" == *"forced: no fresh peer row"* ]] &&
  pass "M4. the peer's label no longer matches the second folder -> forced own" || fail "M4b. out=$out"

to_backup; before="$(cat "$ST/login-mode")"; : > "$SENT"; own uuid-here 50
out="$(run LOGIN_MODE_ENABLED=false)"
[[ "$out" == *"login-mode: PLAN backup -> own"*"(claude_login_pool.enabled is false)"* && "$(cat "$ST/login-mode")" == "$before" && ! -s "$SENT" ]] &&
  pass "M5. enabled false -> a PLAN line only, login-mode unchanged, no alert" || fail "M5. out=$out"
out="$(run DRY_RUN=1)"
[[ "$out" == *"(DRY_RUN)"* && "$(cat "$ST/login-mode")" == "$before" ]] && pass "M5. DRY_RUN=1 -> a PLAN line only" || fail "M5b. out=$out"

LIB="$PROJ_ROOT/lib/bash/funcs/spl-claude-login.func.sh"
rd() { LOGIN_STATE_DIR="$ST" LOGIN_NOW="${N:-$NOW}" bash -c "source $LIB; $1"; }
[[ "$(rd spl_claude_login_dir)" == "$T/home/.claude-2" && "$(rd 'spl_claude_login_wk claude:91@5,grok:3')" == "claude:40,grok:3" && "$(rd spl_claude_login_scope)" == " acct=$(lab uuid-here) lm=backup" ]] &&
  pass "M6. a fresh backup line: the second folder, the backup %, acct= and lm=backup" || fail "M6. dir=$(rd spl_claude_login_dir) wk=$(rd 'spl_claude_login_wk claude:91@5,grok:3') scope=$(rd spl_claude_login_scope)"
[[ -z "$(N=$((NOW + 181)) rd spl_claude_login_dir)" && "$(N=$((NOW + 181)) rd 'spl_claude_login_wk claude:91')" == claude:91 ]] && pass "M6. a stale line (181 s) reads as own" || fail "M6. stale"
own uuid-here 84; run >/dev/null
[[ -z "$(rd spl_claude_login_dir)" && "$(rd spl_claude_login_scope)" == " acct=$(lab uuid-here)" ]] && pass "M6. an own line: no folder, acct= only" || fail "M6. own"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
