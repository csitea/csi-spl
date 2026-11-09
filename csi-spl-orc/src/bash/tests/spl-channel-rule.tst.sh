#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_channel_rule (SPL-5146) writes one row of the box map from env
#          and checks a map without changing it; cr_no_auto_post reads a map it
#          cannot read as held, with an alarm. A sandbox: its own SPOOL_ROOT.
# Cases: 1-6 the reader, 7-14 set, 15-21 check.
# RED CONTROLS: without the alarm of cr_no_auto_post 1..3 fail; a * row read
# like a channel row frees 4; awk's rc taken for the column 7 verdict fails 5; a
# set that writes in a dry run fails 7; a set that does not keep the file's mode
# fails 8; with no floor, 18 reads a restored map as fine.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

SP="$T/spool" M="$T/spool/channel-rules.tsv"
DOC="11111111-0000-4000-8000-000000000001"
NEW_AT="202611080000.00" OLD_AT="202611010000.00"
LIB="$PROJ_ROOT/src/bash/features/spawn-agents/lib/channel-rules.inc.sh"
mkdir -p "$SP"
map() { rm -rf "$M"; printf '# tenant\tchannel\n' >"$M"; printf 't1\tops\t%s\tprd\tc-001\t-\tno-auto-post\n' "$DOC" >>"$M"; printf 't1\tfree\t%s\tprd\tc-001\n' "$DOC" >>"$M"; chmod 0640 "$M"; touch -t "$NEW_AT" "$M"; }
# shellcheck source=/dev/null
reader() { ( export SPOOL_ROOT="$SP"; unset SPOOL_CHANNEL_RULES_MAP; source "$LIB"; eval "$1"; cr_no_auto_post "$2" "$3" ) 2>&1; }
act() { SNIPPET="do_spl_channel_rule" in_orc SPOOL_ROOT="$SP" "$@" 2>&1; }
same() { cmp -s "$T/before" "$M" && [[ "$(stat -c '%a %Y' "$M")" == "$(cat "$T/before.st")" ]]; }
keep() { cp "$M" "$T/before"; stat -c '%a %Y' "$M" >"$T/before.st"; }

# --- the reader
rm -rf "$M"; out="$(reader : t1 ops)"; rc=$?
[[ $rc -eq 2 && "$out" == *ALARM*"is missing"* ]] && pass "1 no map: held, an alarm" || fail "1 rc $rc: $out"
# a directory is a map no awk can read, on any awk and for any user
mkdir "$M"; out="$(reader : t1 ops)"; rc=$?
[[ $rc -eq 2 && "$out" == *ALARM*"is unreadable"* && "$out" != *"column 7"* ]] && pass "2 a map that cannot be read: held, an alarm" || fail "2 rc $rc: $out"
rmdir "$M"; : >"$M"; chmod 000 "$M"
if [[ -r "$M" ]]; then pass "3 mode 000 (skipped: this user reads mode 000)"
else out="$(reader : t1 ops)"; rc=$?; [[ $rc -eq 2 && "$out" == *ALARM*"is unreadable"* ]] && pass "3 a mode 000 map: held, an alarm" || fail "3 rc $rc: $out"; fi
rm -f "$M"
printf 'ws\t*\t-\t-\t-\tno-auto-post\n' >"$M"; out="$(reader : ws any)"; rc=$?
[[ $rc -eq 2 && "$out" == *"column 7"* ]] && pass "4 a * row without the word in column 7 holds, malformed (N25)" || fail "4 rc $rc: $out"
map; out="$(reader 'awk() { return 2; }' t1 free)"; rc=$?
[[ $rc -eq 2 && "$out" == *ALARM*"awk"* && "$out" != *"column 7"* ]] && pass "5 awk failing with 2: held, the alarm names awk (N26)" || fail "5 rc $rc: $out"
out="$(reader : t1 free)"; rc=$?; out2="$(reader : t1 nothing)"; rc2=$?; out3="$(reader : t1 ops)"; rc3=$?
[[ $rc -eq 1 && $rc2 -eq 1 && $rc3 -eq 0 && -z "$out$out2$out3" ]] && pass "6 CONTROL: no word and no row stay free, a row holds, no alarm" || fail "6 $rc/$rc2/$rc3: $out $out2 $out3"
: >"$M"; out="$(reader : t1 ops)"; rc=$?
[[ $rc -eq 1 && -z "$out" ]] && pass "6b CONTROL: an empty map has no row, free" || fail "6b rc $rc: $out"

# --- set
SET=(CHANNEL_RULE_CMD=set CHANNEL_RULE_TENANT=t2 CHANNEL_RULE_CHANNEL=new CHANNEL_RULE_DOC="$DOC" CHANNEL_RULE_ENV=dev CHANNEL_RULE_AGENT=c-002 CHANNEL_RULE_NO_AUTO_POST=1)
WANT="t2	new	$DOC	dev	c-002	-	no-auto-post"
map; keep; out="$(act "${SET[@]}")"; rc=$?
[[ $rc -eq 0 && "$out" == *"PLAN"* ]] && same && pass "7 set is a dry run by default: the file is not touched" || fail "7 rc $rc: $out"
map; cp "$M" "$T/old"; out="$(act "${SET[@]}" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(tail -1 "$M")" == "$WANT" && "$(stat -c %a "$M")" == 640 ]] && cmp -s <(head -3 "$M") "$T/old" && pass "8 set appends the row, the rest and the mode kept" || fail "8 rc $rc: $out // $(cat "$M")"
keep; out="$(act "${SET[@]}" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *"already"* ]] && same && pass "9 the same row again changes nothing" || fail "9 rc $rc: $out"
out="$(act "${SET[@]}" CHANNEL_RULE_ENV=prd DRY_RUN=0)"; rc=$?
[[ $rc -eq 3 && "$out" == *"CHANNEL_RULE_REPLACE"* ]] && same && pass "10 another row for that channel is refused" || fail "10 rc $rc: $out"
out="$(act "${SET[@]}" CHANNEL_RULE_ENV=prd CHANNEL_RULE_REPLACE=1 DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '^t2	new	' "$M")" == 1 && "$(grep -c "^t2	new	$DOC	prd	" "$M")" == 1 ]] && pass "11 CHANNEL_RULE_REPLACE=1 replaces it, one row" || fail "11 rc $rc: $out // $(cat "$M")"
map; keep; out="$(act CHANNEL_RULE_CMD=set CHANNEL_RULE_TENANT=ws CHANNEL_RULE_CHANNEL='*' DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(tail -1 "$M")" == "ws	*	-	-	-	-	no-auto-post" ]] && pass "12 a * row needs only the workspace, and always holds" || fail "12 rc $rc: $out // $(cat "$M")"
map; keep; bad=0
for v in CHANNEL_RULE_TENANT=BAD 'CHANNEL_RULE_CHANNEL=a b' CHANNEL_RULE_DOC=x CHANNEL_RULE_ENV=stg CHANNEL_RULE_AGENT=x CHANNEL_RULE_SOLE=x $'CHANNEL_RULE_TENANT=t\t2'; do
  out="$(act "${SET[@]}" "$v" DRY_RUN=0)"; rc=$?; [[ $rc -eq 1 ]] && same || { bad=1; echo "  $v rc $rc: $out"; }
done
out="$(act CHANNEL_RULE_CMD=set DRY_RUN=0)"; rc=$?; [[ $rc -eq 1 ]] && same || { bad=1; echo "  no env rc $rc: $out"; }
out="$(act "${SET[@]}" CHANNEL_RULE_CMD=nope)"; rc=$?; [[ $rc -eq 1 ]] && same || { bad=1; echo "  cmd rc $rc: $out"; }
((bad == 0)) && pass "13 a bad value, a missing one or a bad command writes nothing" || fail "13"
rm -rf "$M"; out="$(act "${SET[@]}" DRY_RUN=0)"; rc=$?
[[ $rc -eq 2 && ! -e "$M" && "$out" == *"CHANNEL_RULE_CREATE"* ]] && pass "14 a missing map is not created: one row would free the rest" || fail "14 rc $rc: $out"
out="$(act "${SET[@]}" CHANNEL_RULE_CREATE=1 DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(cat "$M")" == "$WANT" && "$(stat -c %a "$M")" == 664 ]] && pass "14b CHANNEL_RULE_CREATE=1 creates it, 0664" || fail "14b rc $rc: $out // $(ls -l "$M")"

# --- check
map; keep; out="$(act)"; rc=$?
[[ $rc -eq 0 && "$out" == *"2 row(s), 1 hold(s)"* ]] && same && pass "15 check is the default, a good map is 0, nothing changes" || fail "15 rc $rc: $out"
rm -rf "$M"; out="$(act)"; rc=$?
[[ $rc -eq 2 && "$out" == *ALARM*"is missing"* && ! -e "$M" ]] && pass "16 check: no map is 2, an alarm, none created" || fail "16 rc $rc: $out"
map; printf 't1\tbad\tnot-a-doc\tprd\tc-001\n' >>"$M"; printf 't1\tops\t%s\tdev\tc-002\n' "$DOC" >>"$M"; touch -t "$NEW_AT" "$M"; keep; out="$(act)"; rc=$?
[[ $rc -eq 2 && "$out" == *"line 4"* && "$out" == *"line 5"*"second row"* ]] && same && pass "17 check: a malformed and a duplicate row are 2, by line" || fail "17 rc $rc: $out"
map; touch -t "$OLD_AT" "$M"; keep; out="$(act)"; rc=$?
[[ $rc -eq 3 && "$out" == *"older than"* ]] && same && pass "18 check: a map from before the floor is 3, unchanged" || fail "18 rc $rc: $out"
out="$(act CHANNEL_RULE_CHECK_NOT_BEFORE=2026-10-01T00:00:00Z)"; rc=$?
[[ $rc -eq 0 ]] && pass "18b CONTROL: the same file after an earlier floor is 0" || fail "18b rc $rc: $out"
map; sed -i '/no-auto-post/d' "$M"; touch -t "$NEW_AT" "$M"; keep; out="$(act)"; rc=$?
[[ $rc -eq 3 && "$out" == *"holds nothing"* ]] && same && pass "19 check: a new map that holds nothing is 3" || fail "19 rc $rc: $out"
map; keep; out="$(act CHANNEL_RULE_CHECK_WANT='t1 ops,t3 gone')"; rc=$?
[[ $rc -eq 3 && "$out" == *"t3 #gone"* && "$out" != *"t1 #ops"* ]] && same && pass "20 check: a wanted hold that is not there is 3, named" || fail "20 rc $rc: $out"
out="$(act CHANNEL_RULE_CHECK_WANT='t1 ops')"; rc=$?
[[ $rc -eq 0 ]] && pass "20b CONTROL: every wanted hold there is 0" || fail "20b rc $rc: $out"
out="$(act CHANNEL_RULE_CHECK_NOT_BEFORE=yesterday-ish)"; rc=$?
[[ $rc -eq 1 ]] && same && pass "21 check: a floor that is no date is refused" || fail "21 rc $rc: $out"

echo "spl-channel-rule: $fails failure(s)"
[[ $fails -eq 0 ]]
