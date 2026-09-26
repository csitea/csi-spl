#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the desk actions (CLE-3434) - seating a terminal agent at a cloud
#          tenant - validate their ids, stay offline in a dry run, and pick the
#          right message to answer. No cloud call, no tmux, no spool binary.
#   1. spl_desk_validate: tenant slug, box id (box-wui reserved), agent id
#      (the BOX prefix is forbidden). CONTROL: the good triple passes
#   2. the dry runs of do_spl_desk_up / _reply / _down / _probe make no gcloud,
#      curl, docker or spool call. CONTROL: the stub log records one when made
#   3. do_spl_desk_reply refuses a bad kind, a non-HUM DESK_TO and a non-uuid
#      DESK_TASK before it reads anything
#   8. do_spl_desk_post (specs/038) refuses a bad channel / kind / body / file
#   9. do_spl_issue_* (specs/039) refuse bad fields, send only the set ones
#      before it reads anything, sends `spool send --channel` with the
#      normalized channel and the put files' ids, and names a non-member
#      refusal (unknown_channel) as such
#   4. spl_desk_pick: a box sender is never answered; ONE waiting human
#      conversation is answered; SEVERAL are refused (exit 4) and listed rather
#      than guessed - answering "the newest human" let a second person's
#      messages steal the topic an answer was meant for; the answered
#      watermark makes already-answered messages stop counting; DESK_TO /
#      DESK_TASK override; both together open a topic we hold no message of
#   5. spl_desk_verdict tells "the sidecar is alive" apart from "the hub has a
#      session for it" - the two facts whose gap is SILENT: a hub redeploy
#      leaves the box blocked on a dead socket with a healthy-looking process
#      and no log line. stranded / down / unpinned / agent-missing / ok, and a
#      repair that refuses the verdicts a restart cannot fix
#   7. the PROMPT leg: a desk where every other leg is green and SPOOL_POKE=0
#      reads MUTED, not ok - the state two owner DMs sat unread in on
#      2026-09-22 while every check said healthy - and the mute is per AGENT,
#      because SPOOL_POKE belongs to the one sidecar the whole box shares
#   6. spl_desk_detach leaves the caller's descriptors alone: a daemon started
#      inside a command substitution must not hold it open. That regression hung
#      `./run` after every step of do_spl_desk_up had passed (2026-09-21)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
for b in gcloud curl docker cloud-sql-proxy spool tmux; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. the id rules ---------------------------------------------------------------
SNIPPET='spl_desk_validate t1 box-desk CLE-00' in_orc >/dev/null 2>&1 &&
  pass "a good tenant/box/agent triple passes" || fail "the good triple was refused"
while read -r desc tenant box agent; do
  [ -n "$desc" ] || continue
  if SNIPPET="spl_desk_validate '$tenant' '$box' '$agent'" in_orc >"$T/o" 2>&1; then
    fail "refuses $desc: $(cat "$T/o")"
  else
    pass "refuses $desc"
  fi
done <<'ROWS'
an-empty-tenant . box-desk CLE-00
an-upper-case-tenant T1 box-desk CLE-00
a-tenant-with-a-quote t1'-- box-desk CLE-00
the-reserved-box t1 box-wui CLE-00
an-upper-case-box t1 BOX-DESK CLE-00
a-lower-case-agent t1 box-desk cle-00
the-BOX-agent-prefix t1 box-desk BOX-1
an-agent-with-no-number t1 box-desk CLE
ROWS

# --- 2. the dry runs are offline ---------------------------------------------------
: >"$T/calls.log"
for a in do_spl_desk_up do_spl_desk_reply do_spl_desk_post do_spl_desk_down do_spl_desk_probe; do
  SNIPPET="$a" in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY='hello' DESK_CHANNEL=spool-hub-devel \
    ROOT_KEY_JSON=/nonexistent.json >"$T/o" 2>&1
  grep -q 'DRY_RUN' "$T/o" && pass "$a: the dry run says what it would do" ||
    fail "$a: no DRY_RUN line: $(cat "$T/o")"
done
[[ ! -s "$T/calls.log" ]] && pass "no gcloud, curl, docker, spool or tmux call in any dry run" ||
  fail "a dry run called out: $(cat "$T/calls.log")"
# CONTROL: the stub log does record a call when one is made.
( PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" gcloud version >/dev/null 2>&1 )
[[ -s "$T/calls.log" ]] && pass "CONTROL the stub log records a real call" || fail "CONTROL the stub log stayed empty"

# --- 3. the reply leg's own arguments ----------------------------------------------
for bad in "DESK_KIND=shout" "DESK_TO=CLE-00" "DESK_TO=HUM-1'--" "DESK_TASK=not-a-uuid" "DESK_BODY="; do
  if SNIPPET=do_spl_desk_reply in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY='hi' DRY_RUN=0 "$bad" \
       >"$T/o" 2>&1; then
    fail "do_spl_desk_reply refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_desk_reply refuses $bad" ||
      fail "do_spl_desk_reply refuses $bad without saying why: $(cat "$T/o")"
  fi
done

# --- 4. which message gets answered ------------------------------------------------
U1=0f8fad5b-d9cb-469f-a165-70867728950e
U2=1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d
msgs=$(cat <<JSON
[{"msg_id":"m1","task_id":"$U1","ts":"2026-09-21T10:00:00Z","from":"HUM-9","body":"first"},
 {"msg_id":"m2","task_id":"$U2","ts":"2026-09-21T12:00:00Z","from":"HUM-4","body":"newest  human"},
 {"msg_id":"m3","task_id":"$U1","ts":"2026-09-21T13:00:00Z","from":"EZB-1","body":"a box, never answered"}]
JSON
)
# Two humans in two topics: a guess here is what put an answer meant for the
# owner into a probe account's topic while the owner watched (2026-09-21).
out=$(SNIPPET="spl_desk_pick '$msgs' '' '' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 4 ]] && pass "two waiting conversations are REFUSED, not guessed (exit 4)" ||
  fail "two conversations did not exit 4 (rc=$rc): $out"
[[ "$out" == *"DESK_TO=HUM-9 DESK_TASK=$U1"* && "$out" == *"DESK_TO=HUM-4 DESK_TASK=$U2"* ]] &&
  pass "…and both are named, with the flags to choose one" || fail "the refusal does not name both: $out"
out=$(SNIPPET="spl_desk_pick '$msgs' '' '' '' 1" in_orc 2>&1)
[[ "$out" == "HUM-4	$U2	m2	newest  human" || "$out" == "HUM-4	$U2	m2	newest human" ]] &&
  pass "DESK_ANY=1 takes the newest human anyway" || fail "DESK_ANY: $out"
# One conversation only: answered without asking.
one='[{"msg_id":"m1","task_id":"'$U1'","ts":"2026-09-21T10:00:00Z","from":"HUM-9","body":"first"},
     {"msg_id":"m9","task_id":"'$U1'","ts":"2026-09-21T11:00:00Z","from":"HUM-9","body":"and again"}]'
out=$(SNIPPET="spl_desk_pick '$one' '' '' '' 0" in_orc 2>&1)
[[ "$out" == "HUM-9	$U1	m9	and again" ]] && pass "one waiting conversation is answered, at its newest message" ||
  fail "single conversation: $out"
# The watermark: what we already answered stops counting, so the second human
# becomes the only one waiting and is answered without a question.
printf '{"to":"HUM-9","task":"%s","ts":"2026-09-21T10:30:00Z"}' "$U1" >"$T/answered"
out=$(SNIPPET="spl_desk_pick '$msgs' '' '' '$T/answered' 0" in_orc 2>&1)
[[ "$out" == "HUM-4	$U2	m2"* ]] && pass "the answered watermark leaves one conversation waiting" ||
  fail "watermark: $out"
printf '{"to":"HUM-9","task":"%s","ts":"2026-09-21T23:00:00Z"}' "$U1" >"$T/answered"
SNIPPET="spl_desk_pick '$msgs' '' '' '$T/answered' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "nothing newer than the last answer is exit 3" || fail "stale watermark did not exit 3"
rm -f "$T/answered"
out=$(SNIPPET="spl_desk_pick '$msgs' 'HUM-9' '' '' 0" in_orc 2>&1)
[[ "$out" == "HUM-9	$U1	m1	first" ]] && pass "DESK_TO narrows it to that human" || fail "pick by to: $out"
out=$(SNIPPET="spl_desk_pick '$msgs' '' '$U1' '' 0" in_orc 2>&1)
[[ "$out" == HUM-9* ]] && pass "DESK_TASK narrows it to that topic" || fail "pick by task: $out"
boxonly='[{"msg_id":"m3","task_id":"'$U1'","ts":"2026-09-21T13:00:00Z","from":"EZB-1","body":"box"}]'
SNIPPET="spl_desk_pick '$boxonly' '' '' '' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "a box-only inbox is nothing to answer (exit 3)" || fail "box-only inbox did not exit 3"
SNIPPET="spl_desk_pick '[]' '' '' '' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "an empty inbox is nothing to answer (exit 3)" || fail "empty inbox did not exit 3"
SNIPPET="spl_desk_pick 'not json' '' '' '' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "unreadable recv output is nothing to answer (exit 3)" || fail "bad json did not exit 3"
out=$(SNIPPET="spl_desk_pick '[]' 'HUM-9' '$U2' '' 0" in_orc 2>&1)
[[ "$out" == "HUM-9	$U2		" ]] && pass "both overrides open a topic we hold no message of" ||
  fail "both overrides: $out"

# --- 5. is the desk REACHABLE, or only apparently so? -------------------------------
# The live shape this came from (dev, 2026-09-21): sidecar alive 17 minutes,
# hub answering online:false, 8 accepted messages that never arrived.
ros() {  # ONLINE LISTED [BOX]
  printf '{"boxes":[{"box_id":"%s","online":%s,"revoked":false,"last_hello_at":"2026-09-21T13:10:51Z","agents":[%s]}]}' \
    "${3:-box-desk}" "$1" "$([ "$2" = 1 ] && echo '"CLE-00"' || echo '')"
}
v_of() { SNIPPET="spl_desk_verdict '$1' box-desk CLE-00 $2 ${3:-}" in_orc 2>&1 | cut -f1; }

[[ "$(v_of "$(ros true 1)" 1)"  == ok ]]            && pass "alive + hub session = ok"            || fail "ok: $(v_of "$(ros true 1)" 1)"
[[ "$(v_of "$(ros false 1)" 1)" == stranded ]]      && pass "alive + hub says OFFLINE = stranded"  || fail "stranded: $(v_of "$(ros false 1)" 1)"
[[ "$(v_of "$(ros true 1)" 0)"  == down ]]          && pass "no sidecar = down"                    || fail "down: $(v_of "$(ros true 1)" 0)"
[[ "$(v_of "$(ros true 0)" 1)"  == agent-missing ]] && pass "box online, agent not announced"      || fail "agent-missing: $(v_of "$(ros true 0)" 1)"
[[ "$(v_of "$(ros true 1 box-other)" 1)" == unpinned ]] && pass "the hub does not know this box"   || fail "unpinned: $(v_of "$(ros true 1 box-other)" 1)"
[[ "$(v_of '{"boxes":[]}' 1)" == unpinned ]] && pass "an empty roster is unpinned, not ok"         || fail "empty roster: $(v_of '{"boxes":[]}' 1)"
# A revoked pin must not read as a live session.
[[ "$(v_of '{"boxes":[{"box_id":"box-desk","online":true,"revoked":true,"agents":["CLE-00"]}]}' 1)" == stranded ]] &&
  pass "a REVOKED box is not reachable, whatever online says" || fail "revoked box did not read as unreachable"
# MUTED: every leg green and the prompt leg off. This is the state a check
# used to call "ok" while the agent was never told anything - measured
# 2026-09-22, two owner DMs unread in an inbox that every dashboard said was
# healthy. It is worse than "down", because "down" is visible.
[[ "$(v_of "$(ros true 1)" 1 0)" == muted ]] && pass "green everywhere + SPOOL_POKE=0 = muted" ||
  fail "muted: $(v_of "$(ros true 1)" 1 0)"
[[ "$(v_of "$(ros true 1)" 1 1)" == ok ]] && pass "…and with the poke ON it is ok again" ||
  fail "poke=1 did not read ok: $(v_of "$(ros true 1)" 1 1)"
[[ "$(v_of "$(ros true 1)" 1)"  == ok ]] && pass "an UNKNOWN poke state is not called muted" ||
  fail "unknown poke read as muted"
# A muted desk is a restart the action must be willing to make, unlike unpinned.
out=$(SNIPPET="spl_desk_repair muted 1 t1 box-desk CLE-00" in_orc 2>&1)
[[ "$out" == *"DRY_RUN would"* ]] && pass "a muted desk IS something a restart fixes" || fail "muted repair refused: $out"

# The marker the notifier reads: per AGENT, because SPOOL_POKE is per BOX. One
# sidecar serves every seat, so the only knob that existed muted all of them.
MD="$T/mute/spool/CLE-00"; mkdir -p "$MD"
SNIPPET="spl_desk_mute '$T/mute' CLE-00 0" in_orc >/dev/null 2>&1
[[ -e "$MD/.no-poke" ]] && pass "DESK_POKE=0 writes the per-agent .no-poke marker" || fail "no marker written"
SNIPPET="spl_desk_mute '$T/mute' CLE-00 1" in_orc >/dev/null 2>&1
[[ ! -e "$MD/.no-poke" ]] && pass "DESK_POKE=1 takes it away again" || fail "the marker survived DESK_POKE=1"
# CONTROL: muting one seat must not touch another.
mkdir -p "$T/mute/spool/CLE-77"
SNIPPET="spl_desk_mute '$T/mute' CLE-00 0" in_orc >/dev/null 2>&1
[[ -e "$MD/.no-poke" && ! -e "$T/mute/spool/CLE-77/.no-poke" ]] &&
  pass "CONTROL muting one seat leaves every other seat poked" || fail "muting one seat affected another"

SNIPPET="spl_desk_verdict 'not json' box-desk CLE-00 1" in_orc >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "an unreadable roster is an error, not a verdict" || fail "bad roster json did not fail"

# The repair refuses what a restart cannot fix, and refuses without DESK_REPAIR.
out=$(SNIPPET="spl_desk_repair stranded 0 t1 box-desk CLE-00" in_orc 2>&1)
[[ "$out" == *"not repairing"* ]] && pass "no repair unless DESK_REPAIR=1" || fail "repair gate: $out"
out=$(SNIPPET="spl_desk_repair unpinned 1 t1 box-desk CLE-00" in_orc DRY_RUN=0 2>&1)
[[ "$out" == *"not something a restart fixes"* ]] && pass "an unpinned box is not restarted blindly" || fail "unpinned repair: $out"
out=$(SNIPPET="spl_desk_repair stranded 1 t1 box-desk CLE-00" in_orc 2>&1)
[[ "$out" == *"DRY_RUN would"* ]] && pass "a repair is a dry run until DRY_RUN=0" || fail "repair dry run: $out"
out=$(SNIPPET="spl_desk_repair ok 1 t1 box-desk CLE-00" in_orc DRY_RUN=0 2>&1)
[[ -z "$out" ]] && pass "a healthy desk is never restarted" || fail "ok was repaired: $out"

# A healthy sidecar can still be running code older than the checkout: a desk
# restarted a minute before a fix lands is reachable AND stale, and re-measuring
# "the fix does not work" against it is the cost (2026-09-21, the keepalive).
# Compared by CONTENT: every agent shares $SPL_STATE_DIR/bin/spool and any
# action that builds rewrites it, so mtime says stale almost always and means
# nothing.
printf 'same' >"$T/a"; printf 'same' >"$T/b"; printf 'other' >"$T/c"
touch -d '1 hour ago' "$T/a"      # a and b differ in mtime, not in bytes
SNIPPET="spl_desk_same_file '$T/a' '$T/b'" in_orc >/dev/null 2>&1
[[ $? -eq 0 ]] && pass "identical bytes are the same file, whatever the mtime" || fail "same bytes read as different"
SNIPPET="spl_desk_same_file '$T/a' '$T/c'" in_orc >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "different bytes are a different build" || fail "different bytes read as same"
SNIPPET="spl_desk_same_file '$T/a' '$T/missing'" in_orc >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "an unreadable side is unknown (2), not a false match" || fail "missing file did not read as unknown"
SNIPPET="spl_desk_stale_build 999999" in_orc >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "a pid that is not running is not a stale-build claim" || fail "dead pid read as stale"
SNIPPET="spl_desk_stale_build notapid" in_orc >/dev/null 2>&1
[[ $? -ne 0 ]] && pass "a malformed pid is refused" || fail "a malformed pid was accepted"

# The check's own dry run stays offline and reads the roster from a file.
: >"$T/calls.log"
printf '%s' "$(ros false 1)" >"$T/roster.json"
out=$(SNIPPET=do_spl_desk_check in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_ROSTER_JSON="$T/roster.json" 2>&1)
[[ "$out" == *'"verdict": "stranded"'* || "$out" == *'"verdict": "down"'* ]] &&
  pass "do_spl_desk_check prints a JSON verdict" || fail "desk_check output: $out"
[[ ! -s "$T/calls.log" ]] && pass "do_spl_desk_check makes no gcloud/curl/spool call" ||
  fail "desk_check called out: $(cat "$T/calls.log")"

# A roster read that FAILS must say why. It used to print nothing at all: the
# action exited 1 with three framework lines and no reason, and the real answer
# - a 429 from six agents competing for the member login - only appeared by
# running roster-show.py by hand. A health check that cannot say why it failed
# is the same defect as a desk that cannot say why a message did not arrive.
out=$(SNIPPET=do_spl_desk_check in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 \
        DESK_ROSTER_JSON=/nonexistent-roster.json 2>&1)
[[ $? -ne 0 ]] && pass "an unreadable roster fails the check" || fail "an unreadable roster passed"
[[ "$out" == *"cannot read"* ]] && pass "…and SAYS it could not read it" ||
  fail "the roster failure is silent: $out"
[[ "$out" == *"/nonexistent-roster.json"* ]] && pass "…naming what it tried to read" ||
  fail "the failure names nothing: $out"

# --- 6. the detach does not hold the caller's descriptors --------------------------
# The regression: `pid="$(spl_desk_sidecar ...)"` never returned, because the
# daemon inherited run.sh's logging pipes and the reader never saw EOF.
out=$(SNIPPET='
  log="$SPL_STATE_DIR/detach.log"; mkdir -p "$SPL_STATE_DIR"
  got="$( spl_desk_detach "$log" sleep 30; echo "started $!" )"
  echo "$got"' in_orc timeout 20 bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"' 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == started\ * ]]; then
  pass "a detached daemon does not hold a command substitution open"
else
  fail "spl_desk_detach hung or failed (rc=$rc): $out"
fi
kid=${out#started }
[[ "$kid" =~ ^[0-9]+$ ]] && { kill "$kid" 2>/dev/null; kill $(pgrep -P "$kid" 2>/dev/null) 2>/dev/null; } || true
pkill -f 'sleep 30' >/dev/null 2>&1 || true

# --- 8. the post leg (specs/038) ----------------------------------------------------
for bad in "DESK_CHANNEL=" "DESK_CHANNEL=no spaces" "DESK_CHANNEL=x;rm" "DESK_KIND=reject" "DESK_BODY=" \
           "DESK_FILES=$T/no-such-file"; do
  if SNIPPET=do_spl_desk_post in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY='hi' DESK_CHANNEL=ops DRY_RUN=0 "$bad" \
       >"$T/o" 2>&1; then
    fail "do_spl_desk_post refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_desk_post refuses $bad" ||
      fail "do_spl_desk_post refuses $bad without saying why: $(cat "$T/o")"
  fi
done
# A fake spool that records its arguments: put-file answers a file_id, send
# answers a delivery - or, with FAKE_REFUSE, the hub's non-member refusal.
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
cat >"$T/fakespool" <<'FAKE'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case "$1" in
  put-file) echo '{"bytes":1,"file_id":"f00d","kind":"file","name":"a","sha256":"f00d"}' ;;
  send) [ -n "${FAKE_REFUSE:-}" ] && { echo 'spool: hub refused: unknown_channel (no channel ops in this tenant)' >&2; exit 78; }
        echo '{"delivery":"sent","msg_id":"m1","task_id":"t1","ts":"2026-09-25T00:00:00Z"}' ;;
esac
FAKE
chmod +x "$T/fakespool"; echo x >"$T/att.txt"; : >"$T/fake.log"
POST='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_desk_post'
out=$(SNIPPET="$POST" in_orc FAKE="$T/fakespool" FAKE_LOG="$T/fake.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_CHANNEL='#Spool-Hub-Devel' DESK_BODY='0.5.6 is out' DESK_FILES="$T/att.txt" DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "do_spl_desk_post posts through the desk's spool" || fail "do_spl_desk_post (rc=$rc): $out"
grep -qx -- "send --from CLE-00 --channel spool-hub-devel --kind note --body 0.5.6 is out --file-id f00d" "$T/fake.log" &&
  pass "…as spool send --channel with the normalized channel and the file id" ||
  fail "the send was not a channel post: $(cat "$T/fake.log")"
[[ "$out" == *'"channel": "spool-hub-devel"'* && "$out" == *'"delivery": "sent"'* ]] &&
  pass "…and prints the channel and the hub's delivery" || fail "post output: $out"
# CONTROL: nothing in the post leg adds a --to or --to-box (a broadcast has
# no single recipient; the hub would route a to_box instead of the channel).
! grep -qE -- '--to(-box)? ' "$T/fake.log" && pass "CONTROL no --to / --to-box on a channel post" ||
  fail "a channel post named a recipient: $(cat "$T/fake.log")"
out=$(SNIPPET="$POST" in_orc FAKE="$T/fakespool" FAKE_LOG="$T/fake.log" FAKE_REFUSE=1 TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_CHANNEL=ops DESK_BODY='let me in' DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not a member of #ops"* ]] && pass "a non-member refusal is named as one" ||
  fail "non-member refusal (rc=$rc): $out"

# --- 9. the issue leg (specs/039 FR-008) -------------------------------------------
cat >"$T/fakeissue" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
[ -n "${FAKE_REFUSE:-}" ] && { echo 'spool: hub refused: from_not_announced (CLE-00 is not an agent announced by box-desk)' >&2; exit 78; }
echo '{"issue":{"key":"SPL-7","status":"todo"}}'
FAKE
chmod +x "$T/fakeissue"; : >"$T/issue.log"
ISS='spl_host_spool() { SPL_SPOOL="$FAKE"; }; '
for a in do_spl_issue_create do_spl_issue_update do_spl_issue_comment do_spl_issue_list; do
  SNIPPET="$a" in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_TITLE=t ISSUE_EPIC=SPL-1 ISSUE_REF=SPL-7 ISSUE_BODY=b ISSUE_STATUS=todo >"$T/o" 2>&1
  grep -q 'DRY_RUN' "$T/o" && pass "$a: the dry run says what it would do" || fail "$a: no DRY_RUN line: $(cat "$T/o")"
done
for bad in "do_spl_issue_create ISSUE_TITLE=" "do_spl_issue_create ISSUE_PRIORITY=9" "do_spl_issue_create ISSUE_LEVEL=6" \
           "do_spl_issue_create ISSUE_STATUS=doing" "do_spl_issue_update ISSUE_REF=nope" "do_spl_issue_update ISSUE_REF=SPL-7" \
           "do_spl_issue_comment ISSUE_BODY=" "do_spl_issue_comment ISSUE_REF=SPL-0" \
           "do_spl_issue_create ISSUE_EPIC=" "do_spl_issue_create ISSUE_KIND=story" "do_spl_issue_create ISSUE_EPIC=epic-one"; do
  read -r a kv <<<"$bad"
  title=ISSUE_NONE=1; epic=ISSUE_NONE2=1 # an update with no field set is a refusal too
  [[ $a == do_spl_issue_create ]] && title=ISSUE_TITLE=t && epic=ISSUE_EPIC=SPL-1
  if SNIPPET="$ISS$a" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 "$title" "$epic" \
       ISSUE_REF=SPL-7 ISSUE_BODY=b DRY_RUN=0 "$kv" >"$T/o" 2>&1; then
    fail "$a refuses $kv: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "$a refuses $kv" || fail "$a refuses $kv without saying why: $(cat "$T/o")"
  fi
done
[[ ! -s "$T/issue.log" ]] && pass "CONTROL no refused call reached spool" || fail "a refused call ran spool: $(cat "$T/issue.log")"
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
out=$(SNIPPET="${ISS}do_spl_issue_create" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_TITLE='Rotate the key' ISSUE_EPIC=SPL-17 ISSUE_PRIORITY=2 ISSUE_LEVEL=3 ISSUE_DEADLINE=2026-10-01T15:00:00Z DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"key": "SPL-7"'* && "$out" == *'"op": "create"'* ]] && pass "do_spl_issue_create files through the desk's spool" ||
  fail "do_spl_issue_create (rc=$rc): $out"
tail -1 "$T/issue.log" | grep -q '^issue|create|--as|CLE-00|' && tail -1 "$T/issue.log" | grep -q '|--title|Rotate the key|' &&
  tail -1 "$T/issue.log" | grep -q '|--priority|2|' && tail -1 "$T/issue.log" | grep -q '|--level|3|' &&
  tail -1 "$T/issue.log" | grep -q '|--deadline|2026-10-01T15:00:00Z|' && tail -1 "$T/issue.log" | grep -q '|--epic|SPL-17|' &&
  pass "…as spool issue create --as with each set field, the epic included" ||
  fail "create args: $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_update" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 ISSUE_STATUS=in_progress ISSUE_ASSIGNEE= DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/issue.log" | grep -qx 'issue|update|--as|CLE-00|--ref|SPL-7|--status|in_progress|--assignee||' &&
  pass "do_spl_issue_update sends only the SET fields; an empty one clears" || fail "update (rc=$rc): $out / $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_comment" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 ISSUE_BODY='dev done; prd next' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/issue.log" | grep -qx 'issue|comment|--as|CLE-00|--ref|SPL-7|--body|dev done; prd next|' &&
  pass "do_spl_issue_comment posts the progress" || fail "comment (rc=$rc): $out / $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_list" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/issue.log" | grep -qx 'issue|list|--as|CLE-00|--assignee|me|--status|backlog,todo,in_progress,in_review|' &&
  pass "do_spl_issue_list defaults to my open issues" || fail "list (rc=$rc): $out / $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_comment" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" FAKE_REFUSE=1 TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 ISSUE_BODY=x DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *FATAL*from_not_announced* ]] && pass "a hub refusal is a FATAL with the hub's token" || fail "refusal (rc=$rc): $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-actions.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
