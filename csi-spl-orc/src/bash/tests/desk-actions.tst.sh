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
#      DESK_TASK before it reads anything; DESK_BODY_FILE carries the body
#   8. do_spl_desk_post (specs/038) refuses a bad channel / kind / body / file
#  10. do_spl_desk_edit (specs/032 §10) refuses a bad MSG_ID / empty body /
#      both body sources, then runs `spool edit --msg-id --as` and names a
#      not_author refusal as another box's message
#  12. do_spl_topic_archive (CLE-77869) refuses a bad TOPIC / MODE / agent,
#      sends nothing in a dry run, then runs `spool archive --task --as`
#      (+ --unarchive) and names the hub's issue_topic / not_allowed refusals
#  13. do_spl_react (CLE-77895) refuses a bad TOPIC / MSG / EMOJI / MODE /
#      agent, sends nothing in a dry run, then runs `spool react --task
#      [--msg] --emoji --as` (+ --remove) after a `--list` read, prints
#      RESULT added/already/removed/absent/failed; MODE=check only lists
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
#  11. do_spl_desk_down (SPL-1004): a DESK_AGENT run refuses while OTHER
#      agents share the live sidecar, names them and stops nothing; the
#      last agent on the box, and DESK_ALL=1, still stop it. CONTROL: the
#      fake sidecar reads as alive to spl_desk_alive before the runs
#   6. spl_desk_detach leaves the caller's descriptors alone: a daemon started
#      inside a command substitution must not hold it open. That regression hung
#      `./run` after every step of do_spl_desk_up had passed (2026-09-21)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux

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
for bad in "DESK_KIND=shout" "DESK_TO=CLE-00" "DESK_TO=HUM-1'--" "DESK_TASK=not-a-uuid" "DESK_BODY=" \
           "DESK_FILES=$T/no-such-file"; do
  if SNIPPET=do_spl_desk_reply in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY='hi' DRY_RUN=0 "$bad" \
       >"$T/o" 2>&1; then
    fail "do_spl_desk_reply refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_desk_reply refuses $bad" ||
      fail "do_spl_desk_reply refuses $bad without saying why: $(cat "$T/o")"
  fi
done

# 2026-10-03: the dispatchers' one-command form reads the body from
# DESK_BODY_FILE; both sources, or an unreadable file, are refused.
echo 'hi from a file' >"$T/body.md"
SNIPPET=do_spl_desk_reply in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY_FILE="$T/body.md" >"$T/o" 2>&1
grep -q 'OK DRY_RUN nothing was sent' "$T/o" && pass "do_spl_desk_reply takes the body from DESK_BODY_FILE" ||
  fail "do_spl_desk_reply DESK_BODY_FILE: $(cat "$T/o")"
for bad in "DESK_BODY=hi DESK_BODY_FILE=$T/body.md" "DESK_BODY_FILE=$T/no-such-file"; do
  # shellcheck disable=SC2086
  if SNIPPET=do_spl_desk_reply in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 $bad >"$T/o" 2>&1; then
    fail "do_spl_desk_reply refuses $bad: $(cat "$T/o")"
  else
    grep -q 'FATAL.*DESK_BODY' "$T/o" && pass "do_spl_desk_reply refuses $bad" || fail "do_spl_desk_reply refuses $bad without saying why: $(cat "$T/o")"
  fi
done

# SPL-950: the probe's channel mode names the channel in its dry run, and a
# bad channel id is a FATAL before anything is sent.
SNIPPET=do_spl_desk_probe in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_CHANNEL=spool-hub-devel >"$T/o" 2>&1
grep -q 'thread reply' "$T/o" && pass "do_spl_desk_probe DESK_CHANNEL: the dry run posts a thread reply" ||
  fail "do_spl_desk_probe DESK_CHANNEL: no thread-reply dry run: $(cat "$T/o")"
if SNIPPET=do_spl_desk_probe in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_CHANNEL="Dev'--" >"$T/o" 2>&1; then
  fail "do_spl_desk_probe accepts a bad DESK_CHANNEL: $(cat "$T/o")"
else
  grep -q 'DESK_CHANNEL must' "$T/o" && pass "do_spl_desk_probe refuses a bad DESK_CHANNEL" ||
    fail "do_spl_desk_probe refuses a bad DESK_CHANNEL without saying why: $(cat "$T/o")"
fi

# SPL-952: blocker and msg pass the kind check (the dry run then stops later).
for good in blocker msg; do
  SNIPPET=do_spl_desk_reply in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY='hi' DESK_KIND=$good >"$T/o" 2>&1 || true
  grep -q 'DESK_KIND must' "$T/o" && fail "do_spl_desk_reply refuses DESK_KIND=$good: $(cat "$T/o")" ||
    pass "do_spl_desk_reply accepts DESK_KIND=$good"
  SNIPPET=do_spl_desk_post in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 DESK_BODY='hi' DESK_CHANNEL=ops DESK_KIND=$good >"$T/o" 2>&1 || true
  grep -q 'DESK_KIND must' "$T/o" && fail "do_spl_desk_post refuses DESK_KIND=$good: $(cat "$T/o")" ||
    pass "do_spl_desk_post accepts DESK_KIND=$good"
done

# SPL-952: a sidecar whose spool binary was rebuilt under it is stale.
cp "$(command -v sleep)" "$T/fake-spool" && chmod +x "$T/fake-spool"
"$T/fake-spool" 30 & stale_pid=$!
cp "$(command -v sleep)" "$T/kept-spool" && chmod +x "$T/kept-spool"
"$T/kept-spool" 30 & kept_pid=$!
sleep 0.2
SNIPPET="spl_desk_sidecar_stale $kept_pid" in_orc >/dev/null 2>&1 &&
  fail "CONTROL a sidecar on an unchanged binary read as stale" || pass "CONTROL a sidecar on an unchanged binary is not stale"
rm -f "$T/fake-spool"
SNIPPET="spl_desk_sidecar_stale $stale_pid" in_orc >/dev/null 2>&1 &&
  pass "a sidecar whose binary was replaced is stale" || fail "a sidecar whose binary was replaced was not seen as stale"
SNIPPET="spl_desk_sidecar_stale not-a-pid" in_orc >/dev/null 2>&1 &&
  fail "a non-pid read as stale" || pass "a non-pid is not stale"
kill "$stale_pid" "$kept_pid" 2>/dev/null || true

# --- 4. which message gets answered ------------------------------------------------
# spl_desk_pick reads the recv JSON from a FILE by path (never an argv word): a
# desk's inbox is never drained, so a busy one (CLE-001) whose JSON went on argv
# overran ARG_MAX and python never ran - "Argument list too long", the pick
# empty, a waiting topic lost (measured 2026-09-29). Every call names a file.
U1=0f8fad5b-d9cb-469f-a165-70867728950e
U2=1a2b3c4d-5e6f-4a8b-9c0d-1e2f3a4b5c6d
cat >"$T/msgs.json" <<JSON
[{"msg_id":"m1","task_id":"$U1","ts":"2026-09-21T10:00:00Z","from":"HUM-9","body":"first"},
 {"msg_id":"m2","task_id":"$U2","ts":"2026-09-21T12:00:00Z","from":"HUM-4","body":"newest  human"},
 {"msg_id":"m3","task_id":"$U1","ts":"2026-09-21T13:00:00Z","from":"EZB-1","body":"a box, never answered"}]
JSON
# Two humans in two topics: a guess here is what put an answer meant for the
# owner into a probe account's topic while the owner watched (2026-09-21).
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' '' '' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 4 ]] && pass "two waiting conversations are REFUSED, not guessed (exit 4)" ||
  fail "two conversations did not exit 4 (rc=$rc): $out"
[[ "$out" == *"DESK_TO=HUM-9 DESK_TASK=$U1"* && "$out" == *"DESK_TO=HUM-4 DESK_TASK=$U2"* ]] &&
  pass "…and both are named, with the flags to choose one" || fail "the refusal does not name both: $out"
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' '' '' '' 1" in_orc 2>&1)
[[ "$out" == "HUM-4	$U2	m2	newest  human" || "$out" == "HUM-4	$U2	m2	newest human" ]] &&
  pass "DESK_ANY=1 takes the newest human anyway" || fail "DESK_ANY: $out"
# One conversation only: answered without asking.
cat >"$T/one.json" <<JSON
[{"msg_id":"m1","task_id":"$U1","ts":"2026-09-21T10:00:00Z","from":"HUM-9","body":"first"},
 {"msg_id":"m9","task_id":"$U1","ts":"2026-09-21T11:00:00Z","from":"HUM-9","body":"and again"}]
JSON
out=$(SNIPPET="spl_desk_pick '$T/one.json' '' '' '' 0" in_orc 2>&1)
[[ "$out" == "HUM-9	$U1	m9	and again" ]] && pass "one waiting conversation is answered, at its newest message" ||
  fail "single conversation: $out"
# The watermark: what we already answered stops counting, so the second human
# becomes the only one waiting and is answered without a question.
printf '{"to":"HUM-9","task":"%s","ts":"2026-09-21T10:30:00Z"}' "$U1" >"$T/answered"
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' '' '' '$T/answered' 0" in_orc 2>&1)
[[ "$out" == "HUM-4	$U2	m2"* ]] && pass "the answered watermark leaves one conversation waiting" ||
  fail "watermark: $out"
printf '{"to":"HUM-9","task":"%s","ts":"2026-09-21T23:00:00Z"}' "$U1" >"$T/answered"
SNIPPET="spl_desk_pick '$T/msgs.json' '' '' '$T/answered' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "nothing newer than the last answer is exit 3" || fail "stale watermark did not exit 3"
rm -f "$T/answered"
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' 'HUM-9' '' '' 0" in_orc 2>&1)
[[ "$out" == "HUM-9	$U1	m1	first" ]] && pass "DESK_TO narrows it to that human" || fail "pick by to: $out"
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' '' '$U1' '' 0" in_orc 2>&1)
[[ "$out" == HUM-9* ]] && pass "DESK_TASK narrows it to that topic" || fail "pick by task: $out"
printf '[{"msg_id":"m3","task_id":"%s","ts":"2026-09-21T13:00:00Z","from":"EZB-1","body":"box"}]' "$U1" >"$T/boxonly.json"
SNIPPET="spl_desk_pick '$T/boxonly.json' '' '' '' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "a box-only inbox is nothing to answer (exit 3)" || fail "box-only inbox did not exit 3"
printf '[]' >"$T/empty.json"
SNIPPET="spl_desk_pick '$T/empty.json' '' '' '' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "an empty inbox is nothing to answer (exit 3)" || fail "empty inbox did not exit 3"
printf 'not json' >"$T/notjson.json"
SNIPPET="spl_desk_pick '$T/notjson.json' '' '' '' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "unreadable recv output is nothing to answer (exit 3)" || fail "bad json did not exit 3"
SNIPPET="spl_desk_pick '$T/no-such.json' '' '' '' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "a missing recv file is nothing to answer (exit 3)" || fail "missing recv file did not exit 3"
out=$(SNIPPET="spl_desk_pick '$T/empty.json' 'HUM-9' '$U2' '' 0" in_orc 2>&1)
[[ "$out" == "HUM-9	$U2		" ]] && pass "both overrides open a topic we hold no message of" ||
  fail "both overrides: $out"

# Owner rule (prd t1 topic b280b0e8, 2026-09-29): a NAMED topic is answered
# even when no human line is NEWER than the last answer - the whole point of
# the fix. CONTROL below shows the old "waiting" gate would have exit 3'd it.
printf '{"to":"HUM-9","task":"%s","ts":"2026-09-21T23:00:00Z"}' "$U1" >"$T/answered"
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' '' '$U1' '$T/answered' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "HUM-9	$U1	m1	first" ]] &&
  pass "a named DESK_TASK is answered though nothing is newer than the last answer" ||
  fail "named topic with a stale watermark (rc=$rc): $out"
# CONTROL: the SAME inbox and watermark, with NO topic named, is exit 3.
SNIPPET="spl_desk_pick '$T/msgs.json' '' '' '$T/answered' 0" in_orc >/dev/null 2>&1
[[ $? -eq 3 ]] && pass "CONTROL the same inbox with no DESK_TASK falls to exit 3 (the bug's shape)" ||
  fail "CONTROL no-topic path did not exit 3"
rm -f "$T/answered"
# A named topic whose only messages are a box's (no human) cannot be addressed
# without DESK_TO: exit 5, naming the flag - never a silent guess.
out=$(SNIPPET="spl_desk_pick '$T/boxonly.json' '' '$U1' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 5 && "$out" == *"DESK_TO"* ]] && pass "a named topic with no human message asks for DESK_TO (exit 5)" ||
  fail "named topic no-human (rc=$rc): $out"
# …and DESK_TO settles it, message in the inbox or not.
out=$(SNIPPET="spl_desk_pick '$T/boxonly.json' 'HUM-2' '$U1' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "HUM-2	$U1		" ]] && pass "DESK_TO + DESK_TASK answers the named topic regardless" ||
  fail "named topic + DESK_TO (rc=$rc): $out"

# An 8-hex DESK_TASK is a topic-id prefix, resolved against the inbox.
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' '' '${U1:0:8}' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "HUM-9	$U1	m1	first" ]] && pass "an 8-hex DESK_TASK prefix resolves to the full topic" ||
  fail "prefix resolve (rc=$rc): $out"
# Ambiguous prefix: two topics share it -> exit 5, both named.
cat >"$T/ambig.json" <<JSON
[{"msg_id":"a1","task_id":"deadbeef-1111-4111-8111-111111111111","ts":"2026-09-21T10:00:00Z","from":"HUM-9","body":"one"},
 {"msg_id":"a2","task_id":"deadbeef-2222-4222-8222-222222222222","ts":"2026-09-21T11:00:00Z","from":"HUM-9","body":"two"}]
JSON
out=$(SNIPPET="spl_desk_pick '$T/ambig.json' '' 'deadbeef' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 5 && "$out" == *"ambiguous"* && "$out" == *deadbeef-1111* && "$out" == *deadbeef-2222* ]] &&
  pass "an ambiguous DESK_TASK prefix is refused, both topics named (exit 5)" ||
  fail "ambiguous prefix (rc=$rc): $out"
out=$(SNIPPET="spl_desk_pick '$T/msgs.json' '' 'cafef00d' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 5 && "$out" == *"no topic"* ]] && pass "a DESK_TASK prefix matching nothing is refused (exit 5)" ||
  fail "unknown prefix (rc=$rc): $out"

# THE ARG_MAX CONTROL: a recv JSON far larger than ARG_MAX still picks, because
# it is read from a file by path. On this box getconf ARG_MAX is ~2 MB; the file
# is ~8 MB of padded box messages plus the one waiting human. Passed as an argv
# word (the old code) this is "Argument list too long" and python never runs.
python3 - "$U1" "$U2" >"$T/huge.json" <<'GEN'
import json, sys
u1, u2 = sys.argv[1], sys.argv[2]
pad = "x" * 4000
rows = [{"msg_id": "b%d" % i, "task_id": u1, "ts": "2026-09-21T10:00:00Z",
         "from": "EZB-1", "body": pad} for i in range(2000)]
rows.append({"msg_id": "hz", "task_id": u2, "ts": "2026-09-21T12:00:00Z",
             "from": "HUM-4", "body": "answer me"})
print(json.dumps(rows))
GEN
argmax=$(getconf ARG_MAX 2>/dev/null || echo 0)
hugesz=$(wc -c <"$T/huge.json")
[[ "$hugesz" -gt "$argmax" ]] && pass "CONTROL the recv JSON ($hugesz bytes) exceeds ARG_MAX ($argmax)" ||
  fail "CONTROL the fixture is not larger than ARG_MAX ($hugesz vs $argmax)"
out=$(SNIPPET="spl_desk_pick '$T/huge.json' '' '' '' 0" in_orc 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == "HUM-4	$U2	hz	answer me" ]] &&
  pass "an inbox larger than ARG_MAX still picks (the JSON is read from the file)" ||
  fail "huge inbox from file (rc=$rc): $out"
# CONTROL: the same JSON passed as an argv word (the pre-fix call shape) fails.
out=$(SNIPPET="python3 -c 'import sys; print(len(sys.argv))' \"\$(cat '$T/huge.json')\"" in_orc 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "CONTROL that same JSON as an argv word is 'Argument list too long' (the old bug)" ||
  fail "CONTROL argv did not overflow (rc=$rc): $out"

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
           "DESK_FILES=$T/no-such-file" "DESK_TYPED_BY=CLE-01" "DESK_TYPED_BY=HUM-1;x"; do
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
: >"$T/fake.log"
out=$(SNIPPET="$POST" in_orc FAKE="$T/fakespool" FAKE_LOG="$T/fake.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_CHANNEL=lobby DESK_BODY='hi' DESK_TYPED_BY=HUM-10 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx -- "send --from CLE-00 --channel lobby --kind note --body hi --typed-by HUM-10" "$T/fake.log" &&
  [[ "$out" == *'"typed_by": "HUM-10"'* ]] &&
  pass "DESK_TYPED_BY rides as spool send --typed-by (specs/036) and is printed" ||
  fail "typed post (rc=$rc): $out / $(cat "$T/fake.log")"
out=$(SNIPPET="$POST" in_orc FAKE="$T/fakespool" FAKE_LOG="$T/fake.log" FAKE_REFUSE=1 TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_CHANNEL=ops DESK_BODY='let me in' DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not a member of #ops"* ]] && pass "a non-member refusal is named as one" ||
  fail "non-member refusal (rc=$rc): $out"

# SPL-956: a reply carries attachments too (a proof screenshot in the owner's
# topic). The fake spool's recv hands back ONE waiting human conversation.
cat >"$T/fakereply" <<'FAKE'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
case "$1" in
  recv) echo '[{"msg_id":"m1","task_id":"0f8fad5b-d9cb-469f-a165-70867728950e","ts":"2026-09-26T10:00:00Z","from":"HUM-9","body":"proof?"}]' ;;
  put-file) echo '{"bytes":1,"file_id":"beef","kind":"file","name":"a","sha256":"beef"}' ;;
  send) echo '{"delivery":"sent","msg_id":"m2","task_id":"t1","ts":"2026-09-26T10:01:00Z"}' ;;
esac
FAKE
chmod +x "$T/fakereply"; : >"$T/fake.log"
REPLY='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_desk_reply'
out=$(SNIPPET="$REPLY" in_orc FAKE="$T/fakereply" FAKE_LOG="$T/fake.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_BODY='here' DESK_FILES="$T/att.txt $T/att.txt" DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx -- "send --from CLE-00 --to HUM-9 --task 0f8fad5b-d9cb-469f-a165-70867728950e --to-box box-wui --kind note --body here --file-id beef --file-id beef" "$T/fake.log" &&
  pass "do_spl_desk_reply DESK_FILES: each file is put, its id rides on the answer" ||
  fail "reply with files (rc=$rc): $out / $(cat "$T/fake.log")"
# CONTROL: no DESK_FILES, no put-file and no --file-id.
: >"$T/fake.log"; rm -f "$T/state/dev/desk/t1/box-desk/answered"
SNIPPET="$REPLY" in_orc FAKE="$T/fakereply" FAKE_LOG="$T/fake.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_BODY='here' DRY_RUN=0 >/dev/null 2>&1
grep -q -- '^send ' "$T/fake.log" && ! grep -qE -- 'put-file|--file-id' "$T/fake.log" &&
  pass "CONTROL a reply without DESK_FILES attaches nothing" || fail "CONTROL plain reply: $(cat "$T/fake.log")"

# SPL-1183 (owner rule, prd t1 topic b280b0e8, 2026-09-29): a full DESK_TASK +
# DESK_TO answers into THAT topic with NO inbox read at all - a busy desk whose
# undrained inbox overran ARG_MAX could not reply into a named topic before.
B280=b280b0e8-3dd7-4164-bc94-bfdd7261e0f5
: >"$T/fake.log"; rm -f "$T/state/dev/desk/t1/box-desk/answered"
out=$(SNIPPET="$REPLY" in_orc FAKE="$T/fakereply" FAKE_LOG="$T/fake.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_TO=HUM-10 DESK_TASK="$B280" DESK_BODY='status update' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx -- "send --from CLE-00 --to HUM-10 --task $B280 --to-box box-wui --kind note --body status update" "$T/fake.log" &&
  ! grep -q -- '^recv' "$T/fake.log" &&
  pass "DESK_TO + full DESK_TASK posts into that topic and never reads the inbox (ARG_MAX-proof)" ||
  fail "named topic straight-send (rc=$rc): $out / $(cat "$T/fake.log")"
# A full DESK_TASK without DESK_TO reads the inbox and addresses the topic's
# human opener (HUM-9 in the fake recv), still into the named topic.
: >"$T/fake.log"
out=$(SNIPPET="$REPLY" in_orc FAKE="$T/fakereply" FAKE_LOG="$T/fake.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_TASK=0f8fad5b-d9cb-469f-a165-70867728950e DESK_BODY='re' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx -- "send --from CLE-00 --to HUM-9 --task 0f8fad5b-d9cb-469f-a165-70867728950e --to-box box-wui --kind note --body re" "$T/fake.log" &&
  pass "a full DESK_TASK with no DESK_TO answers the topic's human opener" ||
  fail "named topic, opener resolved (rc=$rc): $out / $(cat "$T/fake.log")"
# An 8-hex DESK_TASK prefix is accepted and resolved against the inbox topic.
: >"$T/fake.log"
out=$(SNIPPET="$REPLY" in_orc FAKE="$T/fakereply" FAKE_LOG="$T/fake.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  DESK_TASK=0f8fad5b DESK_BODY='re' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx -- "send --from CLE-00 --to HUM-9 --task 0f8fad5b-d9cb-469f-a165-70867728950e --to-box box-wui --kind note --body re" "$T/fake.log" &&
  pass "an 8-hex DESK_TASK prefix is accepted and resolved to the full topic" ||
  fail "prefix reply (rc=$rc): $out / $(cat "$T/fake.log")"

# --- 9. the issue leg (specs/039 FR-008) -------------------------------------------
cat >"$T/fakeissue" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
[ -n "${FAKE_REFUSE:-}" ] && { echo 'spool: hub refused: from_not_announced (CLE-00 is not an agent announced by box-desk)' >&2; exit 78; }
echo '{"issue":{"key":"SPL-7","status":"todo"}}'
FAKE
chmod +x "$T/fakeissue"; : >"$T/issue.log"
ISS='spl_host_spool() { SPL_SPOOL="$FAKE"; }; '
for a in do_spl_issue_create do_spl_issue_update do_spl_issue_comment do_spl_issue_list do_spl_issue_delete; do
  SNIPPET="$a" in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_TITLE=t ISSUE_EPIC=SPL-1 ISSUE_REF=SPL-7 ISSUE_BODY=b ISSUE_STATUS=todo >"$T/o" 2>&1
  grep -q 'DRY_RUN' "$T/o" && pass "$a: the dry run says what it would do" || fail "$a: no DRY_RUN line: $(cat "$T/o")"
done
# rdb 0061 (SPL-966): 05-blocked and 06-onhold are statuses an agent may set.
for st in blocked onhold; do
  SNIPPET=do_spl_issue_update in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 ISSUE_REF=SPL-7 ISSUE_STATUS=$st >"$T/o" 2>&1
  grep -q 'DRY_RUN' "$T/o" && ! grep -q FATAL "$T/o" && pass "do_spl_issue_update takes ISSUE_STATUS=$st" || fail "ISSUE_STATUS=$st refused: $(cat "$T/o")"
done
for bad in "do_spl_issue_create ISSUE_TITLE=" "do_spl_issue_create ISSUE_PRIORITY=9" "do_spl_issue_create ISSUE_PRIORITY=0" "do_spl_issue_create ISSUE_LEVEL=6" "do_spl_issue_create ISSUE_LEVEL=0" \
           "do_spl_issue_create ISSUE_STATUS=doing" "do_spl_issue_update ISSUE_REF=nope" "do_spl_issue_update ISSUE_REF=SPL-7" \
           "do_spl_issue_comment ISSUE_BODY=" "do_spl_issue_comment ISSUE_REF=SPL-0" "do_spl_issue_delete ISSUE_REF=nope" "do_spl_issue_delete ISSUE_REF=" \
           "do_spl_issue_create ISSUE_KIND=story" "do_spl_issue_create ISSUE_EPIC=epic-one"; do
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
# W16 (spec 047): an issue needs no epic; the action sends it without one.
if SNIPPET="${ISS}do_spl_issue_create" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
     ISSUE_TITLE=lone DRY_RUN=0 >"$T/o" 2>&1 && [[ -s "$T/issue.log" ]] && ! grep -q -- '--epic' "$T/issue.log"; then
  pass "do_spl_issue_create files an issue without an epic"
else
  fail "do_spl_issue_create without an epic: $(cat "$T/o") $(cat "$T/issue.log")"
fi
: >"$T/issue.log"
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
out=$(SNIPPET="${ISS}do_spl_issue_create" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_TITLE='Rotate the key' ISSUE_EPIC=SPL-17 ISSUE_PRIORITY=2 ISSUE_LEVEL=2 ISSUE_DEADLINE=2026-10-01T15:00:00Z DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"key": "SPL-7"'* && "$out" == *'"op": "create"'* ]] && pass "do_spl_issue_create files through the desk's spool" ||
  fail "do_spl_issue_create (rc=$rc): $out"
tail -1 "$T/issue.log" | grep '^issue|create|--as|CLE-00|' >/dev/null && tail -1 "$T/issue.log" | grep '|--title|Rotate the key|' >/dev/null &&
  tail -1 "$T/issue.log" | grep '|--priority|2|' >/dev/null && tail -1 "$T/issue.log" | grep '|--level|2|' >/dev/null &&
  tail -1 "$T/issue.log" | grep '|--deadline|2026-10-01T15:00:00Z|' >/dev/null && tail -1 "$T/issue.log" | grep '|--epic|SPL-17|' >/dev/null &&
  pass "…as spool issue create --as with each set field, the epic included" ||
  fail "create args: $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_update" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 ISSUE_STATUS=in_progress ISSUE_ASSIGNEE= DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/issue.log" | grep -x 'issue|update|--as|CLE-00|--ref|SPL-7|--status|in_progress|--assignee||' >/dev/null &&
  pass "do_spl_issue_update sends only the SET fields; an empty one clears" || fail "update (rc=$rc): $out / $(tail -1 "$T/issue.log")"
# SPL-1130: a multi-line description stays ONE argv word, and the flags after it
# still reach spool (a newline-delimited stream dropped --priority and --epic).
: >"$T/issue.log"
out=$(SNIPPET="${ISS}do_spl_issue_create" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_TITLE=t ISSUE_DESCRIPTION=$'line1\n\nline2' ISSUE_PRIORITY=1 ISSUE_EPIC=SPL-10 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$(cat "$T/issue.log")" == $'issue|create|--as|CLE-00|--title|t|--description|line1\n\nline2|--priority|1|--epic|SPL-10|' ]] &&
  pass "do_spl_issue_create keeps a multi-line description whole and the flags after it" ||
  fail "multi-line create (rc=$rc): $out / $(cat "$T/issue.log")"
: >"$T/issue.log"
out=$(SNIPPET="${ISS}do_spl_issue_update" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 ISSUE_DESCRIPTION=$'a\n\nb\n' ISSUE_STATUS=wip DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$(cat "$T/issue.log")" == $'issue|update|--as|CLE-00|--ref|SPL-7|--description|a\n\nb\n|--status|wip|' ]] &&
  pass "do_spl_issue_update keeps a multi-line description (trailing newline too) and the flags after it" ||
  fail "multi-line update (rc=$rc): $out / $(cat "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_comment" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 ISSUE_BODY='dev done; prd next' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/issue.log" | grep -x 'issue|comment|--as|CLE-00|--ref|SPL-7|--body|dev done; prd next|' >/dev/null &&
  pass "do_spl_issue_comment posts the progress" || fail "comment (rc=$rc): $out / $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_delete" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"op": "delete"'* ]] && tail -1 "$T/issue.log" | grep -x 'issue|delete|--as|CLE-00|--ref|SPL-7|' >/dev/null &&
  pass "do_spl_issue_delete sends spool issue delete --as --ref" || fail "delete (rc=$rc): $out / $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_list" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" TENANT_ID=t1 DESK_AGENT=CLE-00 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/issue.log" | grep -x 'issue|list|--as|CLE-00|--assignee|me|--status|eval,todo,wip,blocked,onhold,qas|' >/dev/null &&
  pass "do_spl_issue_list defaults to my open issues" || fail "list (rc=$rc): $out / $(tail -1 "$T/issue.log")"
out=$(SNIPPET="${ISS}do_spl_issue_comment" in_orc FAKE="$T/fakeissue" FAKE_LOG="$T/issue.log" FAKE_REFUSE=1 TENANT_ID=t1 DESK_AGENT=CLE-00 \
  ISSUE_REF=SPL-7 ISSUE_BODY=x DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *FATAL*from_not_announced* ]] && pass "a hub refusal is a FATAL with the hub's token" || fail "refusal (rc=$rc): $out"

# --- 10. the edit leg (specs/032 §10) -----------------------------------------------
EDIT_ID=0f8fad5b-d9cb-469f-a165-70867728950e
echo '| a | b |' >"$T/new.md"; : >"$T/empty.md"
cat >"$T/fakeedit" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
[ -n "${FAKE_REFUSE:-}" ] && { echo 'spool: hub refused: not_author (only the box that sent a message may edit it)' >&2; exit 78; }
echo '{"msg_id":"0f8fad5b-d9cb-469f-a165-70867728950e","task_id":"t1","from":"CLE-00","revision":2}'
FAKE
chmod +x "$T/fakeedit"; : >"$T/edit.log"
EDIT='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_desk_edit'
SNIPPET=do_spl_desk_edit in_orc TENANT_ID=t1 DESK_AGENT=CLE-00 MSG_ID=$EDIT_ID DESK_BODY=x >"$T/o" 2>&1
grep -q 'DRY_RUN' "$T/o" && pass "do_spl_desk_edit: the dry run says what it would do" || fail "edit dry run: $(cat "$T/o")"
for bad in "MSG_ID=" "MSG_ID=NOT-A-UUID" "MSG_ID=0F8FAD5B-D9CB-469F-A165-70867728950E" "DESK_BODY=" "DESK_BODY=  " \
           "DESK_BODY_FILE=$T/new.md" "DESK_BODY_FILE=$T/no-such.md" "DESK_AGENT=box-desk"; do
  if SNIPPET="$EDIT" in_orc FAKE="$T/fakeedit" FAKE_LOG="$T/edit.log" TENANT_ID=t1 DESK_AGENT=CLE-00 MSG_ID=$EDIT_ID \
       DESK_BODY=x DRY_RUN=0 "$bad" >"$T/o" 2>&1; then
    fail "do_spl_desk_edit refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_desk_edit refuses $bad" || fail "do_spl_desk_edit refuses $bad without saying why: $(cat "$T/o")"
  fi
done
if SNIPPET="$EDIT" in_orc FAKE="$T/fakeedit" FAKE_LOG="$T/edit.log" TENANT_ID=t1 DESK_AGENT=CLE-00 MSG_ID=$EDIT_ID \
     DESK_BODY_FILE="$T/empty.md" DRY_RUN=0 >"$T/o" 2>&1; then fail "do_spl_desk_edit refuses an empty DESK_BODY_FILE"
else pass "do_spl_desk_edit refuses an empty DESK_BODY_FILE"; fi
[[ ! -s "$T/edit.log" ]] && pass "CONTROL no refused edit reached spool" || fail "a refused edit ran spool: $(cat "$T/edit.log")"
out=$(SNIPPET="$EDIT" in_orc FAKE="$T/fakeedit" FAKE_LOG="$T/edit.log" TENANT_ID=t1 DESK_AGENT=CLE-00 MSG_ID=$EDIT_ID \
  DESK_BODY_FILE="$T/new.md" DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"revision": 2'* ]] && tail -1 "$T/edit.log" | grep -x "edit|--msg-id|$EDIT_ID|--as|CLE-00|--body-file|$T/new.md|" >/dev/null &&
  pass "do_spl_desk_edit runs spool edit --msg-id --as --body-file and prints the revision" ||
  fail "edit (rc=$rc): $out / $(tail -1 "$T/edit.log")"
out=$(SNIPPET="$EDIT" in_orc FAKE="$T/fakeedit" FAKE_LOG="$T/edit.log" TENANT_ID=t1 DESK_AGENT=CLE-00 MSG_ID=$EDIT_ID \
  DESK_BODY='new text' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/edit.log" | grep -x "edit|--msg-id|$EDIT_ID|--as|CLE-00|--body|new text|" >/dev/null &&
  pass "do_spl_desk_edit DESK_BODY rides as --body" || fail "edit --body (rc=$rc): $out / $(tail -1 "$T/edit.log")"
out=$(SNIPPET="$EDIT" in_orc FAKE="$T/fakeedit" FAKE_LOG="$T/edit.log" FAKE_REFUSE=1 TENANT_ID=t1 DESK_AGENT=CLE-00 MSG_ID=$EDIT_ID \
  DESK_BODY=x DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"only the box that sent a message can edit it"* ]] && pass "a not_author refusal is named as another box's message" ||
  fail "not_author refusal (rc=$rc): $out"

# --- 12. the topic archive leg (CLE-77869) ----------------------------------------
ARC_TOPIC=e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f
cat >"$T/fakearchive" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
[ -n "${FAKE_REFUSE:-}" ] && { echo "spool: hub refused: $FAKE_REFUSE (refused)" >&2; exit 78; }
echo '{"msg_id":"0f8fad5b-d9cb-469f-a165-70867728950e","task_id":"e2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f","archived":true,"archived_by":"CLE-00"}'
FAKE
chmod +x "$T/fakearchive"; : >"$T/archive.log"
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
ARC='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_topic_archive'
out=$(SNIPPET="$ARC" in_orc FAKE="$T/fakearchive" FAKE_LOG="$T/archive.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$ARC_TOPIC 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *DRY_RUN*"archive topic $ARC_TOPIC"* && ! -s "$T/archive.log" ]] &&
  pass "do_spl_topic_archive: the dry run says what it would do and sends nothing" || fail "archive dry run (rc=$rc): $out"
for bad in "TOPIC=" "TOPIC=NOT-A-UUID" "TOPIC=E2C3FBAD-C8DF-42D3-8233-2D7E8D5A0C2F" "MODE=delete" "DESK_AGENT=box-desk" "TENANT_ID=T1"; do
  if SNIPPET="$ARC" in_orc FAKE="$T/fakearchive" FAKE_LOG="$T/archive.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$ARC_TOPIC \
       DRY_RUN=0 "$bad" >"$T/o" 2>&1; then
    fail "do_spl_topic_archive refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_topic_archive refuses $bad" || fail "do_spl_topic_archive refuses $bad without saying why: $(cat "$T/o")"
  fi
done
[[ ! -s "$T/archive.log" ]] && pass "CONTROL no refused archive reached spool" || fail "a refused archive ran spool: $(cat "$T/archive.log")"
out=$(SNIPPET="$ARC" in_orc FAKE="$T/fakearchive" FAKE_LOG="$T/archive.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$ARC_TOPIC DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"archived": true'* && "$out" == *'"mode": "archive"'* ]] &&
  tail -1 "$T/archive.log" | grep -x "archive|--task|$ARC_TOPIC|--as|CLE-00|" >/dev/null &&
  pass "do_spl_topic_archive runs spool archive --task --as and prints the hub's answer" ||
  fail "archive (rc=$rc): $out / $(tail -1 "$T/archive.log")"
out=$(SNIPPET="$ARC" in_orc FAKE="$T/fakearchive" FAKE_LOG="$T/archive.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$ARC_TOPIC MODE=unarchive DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/archive.log" | grep -x "archive|--task|$ARC_TOPIC|--as|CLE-00|--unarchive|" >/dev/null &&
  pass "MODE=unarchive rides as --unarchive" || fail "unarchive (rc=$rc): $out / $(tail -1 "$T/archive.log")"
for tok in "issue_topic:archived with its issue" "not_allowed:Who can archive topics" "not_found:never delivered to the desk"; do
  out=$(SNIPPET="$ARC" in_orc FAKE="$T/fakearchive" FAKE_LOG="$T/archive.log" FAKE_REFUSE="${tok%%:*}" TENANT_ID=t1 DESK_AGENT=CLE-00 \
    TOPIC=$ARC_TOPIC DRY_RUN=0 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"${tok#*:}"* ]] && pass "a ${tok%%:*} refusal is named" || fail "${tok%%:*} refusal (rc=$rc): $out"
done

# --- 13. the reaction leg (CLE-77895) ----------------------------------------------
RX_TOPIC=b2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f
RX_MSG=1f8fad5b-d9cb-469f-a165-70867728950e
cat >"$T/fakereact" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
case "$*" in *--list*)
  [ -n "${FAKE_LIST_REFUSE:-}" ] && { echo "spool: hub refused: $FAKE_LIST_REFUSE (refused)" >&2; exit 78; }
  echo "{\"msg_id\":\"0f8fad5b-d9cb-469f-a165-70867728950e\",\"task_id\":\"b2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f\",\"reactions\":${FAKE_BEFORE:-[]}}"; exit 0;;
esac
[ -n "${FAKE_REFUSE:-}" ] && { echo "spool: hub refused: $FAKE_REFUSE (refused)" >&2; exit 78; }
case "$*" in *--remove*) R='[]';; *) R='[{"emoji":"⏸️","actors":["CLE-00"]}]';; esac
echo "{\"msg_id\":\"0f8fad5b-d9cb-469f-a165-70867728950e\",\"task_id\":\"b2c3fbad-c8df-42d3-8233-2d7e8d5a0c2f\",\"reactions\":$R}"
FAKE
chmod +x "$T/fakereact"; : >"$T/react.log"
RX='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_react'
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *DRY_RUN*"add ⏸️ on the opening message of topic $RX_TOPIC"* && ! -s "$T/react.log" ]] &&
  pass "do_spl_react: the dry run says what it would do and sends nothing" || fail "react dry run (rc=$rc): $out"
for bad in "TOPIC=" "TOPIC=NOT-A-UUID" "TOPIC=B2C3FBAD-C8DF-42D3-8233-2D7E8D5A0C2F" "MSG=nope" "EMOJI=" "EMOJI=⏸️ ✅" "MODE=toggle" \
           "DESK_AGENT=box-desk" "TENANT_ID=T1"; do
  if SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ \
       DRY_RUN=0 "$bad" >"$T/o" 2>&1; then
    fail "do_spl_react refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "do_spl_react refuses $bad" || fail "do_spl_react refuses $bad without saying why: $(cat "$T/o")"
  fi
done
[[ ! -s "$T/react.log" ]] && pass "CONTROL no refused reaction reached spool" || fail "a refused reaction ran spool: $(cat "$T/react.log")"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"emoji": "⏸️"'* && "$out" == *'"mode": "add"'* && "$out" == *'"actors": ["CLE-00"]'* &&
   "$out" == *$'\n'"RESULT added emoji=⏸️ msg=0f8fad5b-d9cb-469f-a165-70867728950e task=$RX_TOPIC by=CLE-00"* ]] &&
  tail -2 "$T/react.log" | sed -n 1p | grep -x "react|--task|$RX_TOPIC|--list|--as|CLE-00|" >/dev/null &&
  tail -1 "$T/react.log" | grep -x "react|--task|$RX_TOPIC|--emoji|⏸️|--as|CLE-00|" >/dev/null &&
  pass "do_spl_react reads the mark, runs spool react --task --emoji --as, prints RESULT added" ||
  fail "react (rc=$rc): $out / $(tail -2 "$T/react.log")"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" FAKE_BEFORE='[{"emoji":"⏸️","actors":["CLE-00"]}]' TENANT_ID=t1 \
  DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸ DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"RESULT already emoji=⏸"* ]] && pass "a mark that was there reads RESULT already (bare ⏸ matches ⏸️)" ||
  fail "already (rc=$rc): $out"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" FAKE_LIST_REFUSE="bad_frame react_op must be add or remove" TENANT_ID=t1 \
  DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"RESULT added"* ]] && pass "a hub without the list op still adds and says RESULT added" ||
  fail "old hub add (rc=$rc): $out"
: >"$T/react.log"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" FAKE_BEFORE='[{"emoji":"⏸️","actors":["CLE-00","HUM-1"]}]' TENANT_ID=t1 \
  DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ MODE=check 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"RESULT present emoji=⏸️ msg=0f8fad5b-d9cb-469f-a165-70867728950e task=$RX_TOPIC by=CLE-00,HUM-1"* ]] &&
  [[ "$(wc -l <"$T/react.log")" -eq 1 ]] && grep -q -- "--list" "$T/react.log" &&
  pass "MODE=check (default DRY_RUN) only lists and says RESULT present" || fail "check (rc=$rc): $out / $(cat "$T/react.log")"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ MODE=check 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"RESULT absent emoji=⏸️"*"by=-"* ]] && pass "MODE=check on an unmarked message says RESULT absent" || fail "check absent (rc=$rc): $out"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" FAKE_LIST_REFUSE=not_found TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ MODE=check 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"RESULT failed"* && "$out" == *"never delivered to the desk"* ]] && pass "a refused check says RESULT failed and why" || fail "check refused (rc=$rc): $out"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" TENANT_ID=t1 DESK_AGENT=CLE-00 TOPIC= MSG=$RX_MSG EMOJI=✅ MODE=remove DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"RESULT absent emoji=✅"* ]] && tail -1 "$T/react.log" | grep -x "react|--msg|$RX_MSG|--emoji|✅|--as|CLE-00|--remove|" >/dev/null &&
  pass "MSG alone and MODE=remove ride as --msg / --remove (nothing was there: RESULT absent)" || fail "react by msg (rc=$rc): $out / $(tail -1 "$T/react.log")"
out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" FAKE_BEFORE='[{"emoji":"⏸️","actors":["CLE-00"]}]' TENANT_ID=t1 \
  DESK_AGENT=CLE-00 TOPIC=$RX_TOPIC EMOJI=⏸️ MODE=remove DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"RESULT removed emoji=⏸️"*"by=-"* ]] && pass "removing a mark that was there says RESULT removed" || fail "removed (rc=$rc): $out"
for tok in "bad_emoji:the picker offers" "not_found:never delivered to the desk" "not_a_card:name the one with MSG"; do
  out=$(SNIPPET="$RX" in_orc FAKE="$T/fakereact" FAKE_LOG="$T/react.log" FAKE_REFUSE="${tok%%:*}" TENANT_ID=t1 DESK_AGENT=CLE-00 \
    TOPIC=$RX_TOPIC EMOJI=⏸️ DRY_RUN=0 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"${tok#*:}"* && "$out" == *"RESULT failed"* ]] && pass "a ${tok%%:*} refusal is named (RESULT failed)" ||
    fail "${tok%%:*} refusal (rc=$rc): $out"
done

# --- 11. desk_down never takes the other seated agents offline (SPL-1004) ----------
# 2026-09-27 11:47Z: an agent closing its lane ran DESK_AGENT=<itself>
# do_spl_desk_down in csi-rel; the one shared sidecar stopped, every other
# csi-rel agent went offline and a person's post waited 35 min.
DD="$T/state/dev/desk/t1/box-desk"
fake_sidecar() {
  mkdir -p "$DD/spool/.hub"
  bash -c 'sleep 60; :' hub-run </dev/null >/dev/null 2>&1 & echo $! >"$DD/spool/.hub/hub-run.pid"
}
fake_sidecar
for a in CLE-1 CLE-2; do mkdir -p "$DD/spool/$a"; done
SNIPPET="spl_desk_alive '$DD/spool/.hub/hub-run.pid'" in_orc >/dev/null 2>&1 &&
  pass "CONTROL the fake sidecar reads as alive" || fail "CONTROL the fake sidecar does not read as alive"
out=$(SNIPPET=do_spl_desk_down in_orc TENANT_ID=t1 DESK_AGENT=CLE-1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *FATAL*CLE-2* && "$out" != *CLE-1\ CLE-2* ]] &&
  SNIPPET="spl_desk_alive '$DD/spool/.hub/hub-run.pid'" in_orc >/dev/null 2>&1 &&
  pass "desk_down for one agent refuses while CLE-2 shares the sidecar, names it, stops nothing" ||
  fail "desk_down with a co-seated agent (rc=$rc): $out"
out=$(SNIPPET=do_spl_desk_down in_orc TENANT_ID=t1 DESK_AGENT=CLE-1 DESK_ALL=1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"was_running": true'* ]] &&
  ! SNIPPET="spl_desk_alive '$DD/spool/.hub/hub-run.pid'" in_orc >/dev/null 2>&1 &&
  pass "DESK_ALL=1 stops the shared sidecar" || fail "DESK_ALL=1 (rc=$rc): $out"
find "$DD/spool" -mindepth 1 -maxdepth 1 -type d ! -name CLE-1 ! -name .hub -exec rm -rf {} +; fake_sidecar
out=$(SNIPPET=do_spl_desk_down in_orc TENANT_ID=t1 DESK_AGENT=CLE-1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"was_running": true'* ]] &&
  pass "the last agent on the box still stops its sidecar" || fail "last agent (rc=$rc): $out"
fake_sidecar
out=$(SNIPPET=do_spl_desk_down in_orc TENANT_ID=t1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *'"was_running": true'* ]] &&
  pass "no DESK_AGENT stops the box as before" || fail "no DESK_AGENT (rc=$rc): $out"
kill "$(cat "$DD/spool/.hub/hub-run.pid")" 2>/dev/null || true

# --- 14. spl_desk_purge_pokes counts the queued pokes it drops (refactor r1 #26) ---
PQ="$T/purge/spool/CLE-9/.pokes"; mkdir -p "$PQ"; : >"$PQ/a.poke"; : >"$PQ/b.poke"
out=$(SNIPPET="spl_desk_purge_pokes '$T/purge' CLE-9 0" in_orc 2>&1)
[[ "$out" == *'dropped 2 queued poke(s) for CLE-9'* && ! -e "$PQ/a.poke" ]] &&
  pass "purge_pokes drops 2 queued pokes and says so" || fail "purge_pokes with 2 pokes: $out"
out=$(SNIPPET="spl_desk_purge_pokes '$T/purge' CLE-9 0" in_orc 2>&1)
[[ "$out" != *dropped* ]] && pass "purge_pokes on an empty queue reports nothing" ||
  fail "purge_pokes on an empty queue: $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all desk-actions.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
