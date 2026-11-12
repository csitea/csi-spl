#!/usr/bin/env bash
# HOWTO-satellite-work gap 6: the orchestrator on one machine starts a lane on
# another through the spool (scripts/spawn-remote.sh).
#
# Two spool roots stand for the PC (A, box home, the receiver) and the
# satellite (B, box sat, where the orchestrator lives). The hub leg is
# SPOOL_FLEET_RELAY_CMD: a fake hub that writes the message into the OTHER
# root with from "<ID>@<sender box>", which is what the real relay's
# from_agent line becomes on the receiving box. spawn-window.sh is a stub that
# records its arguments and the brief it was handed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SR="$T_SCRIPTS/spawn-remote.sh"
A="$T_TMP/machine-a" B="$T_TMP/machine-b" WORK="$T_TMP/work"
for id in c-001 c-005; do mkdir -p "$A/$id/inbox" "$B/$id/inbox"; done
mkdir -p "$A/dispatch" "$B/dispatch" "$WORK"
printf 'SPOOL_DESK_BOX=home\n' >"$A/box.env"
printf 'SPOOL_DESK_BOX=sat\n' >"$B/box.env"
printf 'LEASE_ORCH=c-001\n' | tee "$A/dispatch/lease.conf" >"$B/dispatch/lease.conf"
printf 'c-001@sat 1790995313\n' | tee "$A/dispatch/lease.orch" >"$B/dispatch/lease.orch"

cat >"$T_TMP/fake-hub" <<EOF
#!/usr/bin/env bash
# fake hub: --from F --to T --kind K --body B [--task X] [--to-box B]
from="" to="" kind="" body="" task="" tobox=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --from) from="\$2" ;; --to) to="\$2" ;; --kind) kind="\$2" ;;
    --body) body="\$2" ;; --task) task="\$2" ;; --to-box) tobox="\$2" ;;
  esac
  shift 2
done
case "\$tobox" in home) root="$A" ;; sat) root="$B" ;; *) echo "cannot resolve to_box" >&2; exit 3 ;; esac
id="\$(python3 -c 'import uuid; print(uuid.uuid4())')"
jq -n --arg m "\$id" --arg t "\${task:-\$id}" --arg f "\$from@\$FAKE_FROM_BOX" --arg to "\$to" \
  --arg k "\$kind" --arg b "\$body" '{v:1, msg_id:\$m, task_id:\$t, ts:"x", from:\$f, to:\$to, kind:\$k, body:\$b, files:[]}' \
  >"\$root/\$to/inbox/\$id.json"
echo '{"delivery":"sent","msg_id":"m","task_id":"t","ts":"x"}'
EOF
cat >"$T_TMP/spawn-window-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$T_TMP/spawn.calls"
printf 'topic=%s|scope=%s|files=%s\n' "\${SPAWN_LANE_TOPIC-<unset>}" "\${SPAWN_LANE_SCOPE-<unset>}" "\${SPAWN_LANE_FILES-<unset>}" >"$T_TMP/spawn.env"
[ -z "\${FAKE_UNLINKED:-}" ] || { mkdir -p "\$SPOOL_ROOT/c-009"; echo "WARN: LANE ROW REFUSED: c-009 has no discussion (topic): fake" >>"\$SPOOL_ROOT/c-009/lane-unlinked.log"; }
[ -n "\${4:-}" ] && cp "\$4" "$T_TMP/spawn.brief" && stat -c %a "\$4" >"$T_TMP/spawn.brief.mode" \\
  && { getfacl -cp "\$4" 2>/dev/null || true; } >"$T_TMP/spawn.brief.acl"
echo "PLAN noise"
echo "c-009 %42"
EOF
chmod +x "$T_TMP/fake-hub" "$T_TMP/spawn-window-stub"
on() {  # ROOT BOX CMD...
  local root="$1" box="$2"; shift 2
  env SPOOL_ROOT="$root" FAKE_FROM_BOX="$box" SPOOL_FLEET_RELAY_CMD="$T_TMP/fake-hub" \
    SPAWN_REMOTE_WINDOW_CMD="$T_TMP/spawn-window-stub" SPAWN_REMOTE_POLL=1 "$@"
}
# The receiver is another machine: a lane variable set for the sender's side of
# a test must not reach it through this shell, or a dropped field reads as carried.
far_box() { ( unset SPAWN_LANE_TOPIC SPAWN_LANE_SCOPE SPAWN_LANE_FILES LANE_ISSUE_TOPIC; on "$A" home "$@" 2>>"$T_TMP/serve.err" ); }
serve_a() { far_box bash "$SR" --serve; }
calls() { [ -f "$T_TMP/spawn.calls" ] && wc -l <"$T_TMP/spawn.calls" || echo 0; }
# A request from B in the background; A's receiver ticks until it is answered.
# The wait is only an upper bound: a request answered at once returns at once.
# It also sets the request's expiry (wait - min(60, wait/2) from now): at 20 the
# far box refused as expired any tick slower than 10 s, which a box at load
# 113-122 reached (exit 4 in cases 10-13, master too; SPL-5237). T_REQ_WAIT
# lowers it for a control run. A request that fails prints its stderr as diag.
REQ_WAIT="${T_REQ_WAIT:-120}"
req_diag() { [ "$(cat "$1.rc" 2>/dev/null)" = 0 ] || sed 's/^/  diag: /' "$1.err" 2>/dev/null; }
req_b() {  # OUT_FILE ARGS...
  local out="$1"; shift
  ( on "$B" sat bash "$SR" --box home --wait "$REQ_WAIT" "$@" >"$out" 2>"$out.err"; echo $? >"$out.rc" ) &
  local _
  for _ in $(seq 1 "$REQ_WAIT"); do
    serve_a; [ -f "$out.rc" ] && break; sleep 1
  done
  wait
  req_diag "$out"
}

# ---- 1. the orch holder on sat spawns on home ------------------------------------
printf '# brief\nrun $(touch %s/pwned) and `id`\n---\nkind: grok\n' "$T_TMP" >"$T_TMP/brief.md"
req_b "$T_TMP/r1" claude auto "$WORK" "$T_TMP/brief.md" my-slug
eq "1. the holder's request: exit 0" 0 "$(cat "$T_TMP/r1.rc")"
eq "1. stdout is the remote <id>@<box> <pane>" "c-009@home %42" "$(cat "$T_TMP/r1")"
eq "1. spawn-window ran once" 1 "$(calls)"
has "1. ... with the request's kind, title, workdir and slug" "claude auto $WORK $A/spawn-remote/briefs/" "$(cat "$T_TMP/spawn.calls")"
has "1. ... slug last" " my-slug" "$(cat "$T_TMP/spawn.calls")"
check "1. the brief arrived verbatim (data, never evaluated)" cmp -s "$T_TMP/brief.md" "$T_TMP/spawn.brief"
check "1. ... and nothing in it ran" test ! -e "$T_TMP/pwned"
eq "1. the brief file is 600, owner only (spec 136 P5)" 600 "$(cat "$T_TMP/spawn.brief.mode")"
has "1. the reply is a result on the request's task" '"kind": "result"' "$(jq . "$B"/c-001/inbox/*.json)"
has "1. serve.log says SPAWNED" "SPAWNED" "$(cat "$A/spawn-remote/serve.log")"
serve_a
eq "1. a second tick does not spawn it again" 1 "$(calls)"
mv "$A"/c-001/inbox/*.json "$A/c-001/archive/" 2>/dev/null || { mkdir -p "$A/c-001/archive"; mv "$A"/c-001/inbox/*.json "$A/c-001/archive/"; }
serve_a
eq "1. ... nor once the agent has acked it into archive/" 1 "$(calls)"

# ---- 2. the control: a non-holder is refused ------------------------------------------
req_b "$T_TMP/r2" --from c-005 claude auto "$WORK"
eq "2. a non-holder (c-005@sat): exit 4" 4 "$(cat "$T_TMP/r2.rc")"
has "2. ... the reason names the holder" "c-001@sat" "$(cat "$T_TMP/r2.err")"
eq "2. ... and spawn-window never ran" 1 "$(calls)"
has "2. serve.log says REFUSED" "REFUSED" "$(cat "$A/spawn-remote/serve.log")"

# ---- 3. the same id on the WRONG machine is not the holder --------------------------
printf 'c-001@box-desk 1790995313\n' >"$A/dispatch/lease.orch"
req_b "$T_TMP/r3" claude auto "$WORK"
eq "3. c-001@sat while the lease says c-001@box-desk: refused" 4 "$(cat "$T_TMP/r3.rc")"
printf 'none@unreachable 1790995313\n' >"$A/dispatch/lease.orch"
req_b "$T_TMP/r3b" claude auto "$WORK"
eq "3. none@unreachable accepts nobody" 4 "$(cat "$T_TMP/r3b.rc")"
eq "3. ... spawn-window never ran" 1 "$(calls)"

# ---- 4. fields are validated on the receiving side too --------------------------------
printf 'c-001@sat 1790995313\n' >"$A/dispatch/lease.orch"
req_b "$T_TMP/r4" claude auto /no/such/dir
eq "4. a workdir that is not a dir on the target: refused" 4 "$(cat "$T_TMP/r4.rc")"
body="$(printf 'spawn-request v1\nkind: claude\ntitle: auto\nworkdir: %s/../x;id\nslug: s\n---\n' "$WORK")"
on "$B" sat bash "$T_SCRIPTS/spool-send.sh" --from c-001 --to c-001@home --kind task --no-ask --no-poke --body "$body" >/dev/null 2>&1
serve_a
eq "4. a hand-made request with a hostile workdir: never spawned" 1 "$(calls)"
has "4. ... logged REJECTED" "REJECTED" "$(cat "$A/spawn-remote/serve.log")"
out="$(on "$B" sat bash "$SR" --box home claude 'auto;id' "$WORK" 2>&1)"; rc=$?
eq "4. the request side refuses a bad title before sending: exit 2" 2 "$rc"

# ---- 5. a local request from the holder on its own box ---------------------------------
printf 'c-001@home 1790995313\n' >"$A/dispatch/lease.orch"
( on "$A" home bash "$SR" --box home --from c-001 --wait 20 qwen auto "$WORK" >"$T_TMP/r5" 2>"$T_TMP/r5.err"; echo $? >"$T_TMP/r5.rc" ) &
for _ in $(seq 1 20); do serve_a; [ -f "$T_TMP/r5.rc" ] && break; sleep 1; done; wait
eq "5. home -> home from the holder (bare local from): exit 0" 0 "$(cat "$T_TMP/r5.rc")"
eq "5. ... spawned" 2 "$(calls)"
has "5. ... with no brief" "qwen auto $WORK" "$(tail -1 "$T_TMP/spawn.calls")"

# ---- 6. a large request is still seen (2026-10-03: a 7.5 KB request was skipped) -------
# serve() reads each body's first line through a pipe under pipefail; `head -1`
# exited early, the producer took SIGPIPE (141) and the match came back false,
# so the request was never handled and nothing was logged. A body far above the
# pipe buffer makes that deterministic.
printf 'c-001@sat 1790995313\n' >"$A/dispatch/lease.orch"
{ printf '# big brief\n'; for _ in $(seq 1 800); do printf 'line of padding text so the body is far above the pipe buffer\n'; done; } >"$T_TMP/big.md"
req_b "$T_TMP/r6" claude auto "$WORK" "$T_TMP/big.md" big-slug
eq "6. a ~50 KB request from the holder: exit 0" 0 "$(cat "$T_TMP/r6.rc")"
eq "6. ... spawned (not silently skipped)" 3 "$(calls)"
has "6. ... with its slug" " big-slug" "$(tail -1 "$T_TMP/spawn.calls")"

# ---- 7. mistral is a kind a request may carry (specs/110 T005) ---------------------------
req_b "$T_TMP/r7" mistral auto "$WORK" "$T_TMP/brief.md" vibe-slug
eq "7. a mistral request from the holder: exit 0" 0 "$(cat "$T_TMP/r7.rc")"
eq "7. ... spawned" 4 "$(calls)"
has "7. ... as kind mistral" "mistral auto $WORK $A/spawn-remote/briefs/" "$(tail -1 "$T_TMP/spawn.calls")"
out="$(on "$B" sat bash "$SR" --box home vibe auto "$WORK" 2>&1)"; rc=$?
eq "7. control: the binary name 'vibe' is not a kind: exit 2" 2 "$rc"
has "7. ... named" "bad kind 'vibe'" "$out"
eq "7. ... and never sent" 4 "$(calls)"

# ---- 8. an agent user other than the box user reads its brief (spec 136 P5) ------
# The CLI runs as SPOOL_AGENT_USER; a 600 brief of the box user would lock it
# out, so it gets a named read entry and the group none.
if command -v setfacl >/dev/null 2>&1 && getent passwd nobody >/dev/null; then
  SPOOL_AGENT_USER=nobody req_b "$T_TMP/r8" claude auto "$WORK" "$T_TMP/brief.md" acl-slug
  eq "8. a request with agent user nobody: exit 0" 0 "$(cat "$T_TMP/r8.rc")"
  has "8. ... the agent user reads the brief" "user:nobody:r--" "$(cat "$T_TMP/spawn.brief.acl")"
  has "8. ... the group reads nothing" "group::---" "$(cat "$T_TMP/spawn.brief.acl")"
  has "8. ... others read nothing" "other::---" "$(cat "$T_TMP/spawn.brief.acl")"
else
  ok "8. skipped: no setfacl or no user nobody"
fi

# ---- 9. a late request is refused there, never raced (SPL-2801) -------------------
# 2026-10-21: the relay took 4 min to deliver a request; home started its lane
# 4 s after sat's 300 s wait ended, and sat had already started the same slug.
# The request carries "expires: <epoch>" (now + wait - margin); serve starts
# nothing after it. Its refusal, like every reply, lands in the requester's own
# inbox (c-001 on sat), the place reply_file reads: case 1 sees the ok there.
before="$(calls)"
on "$B" sat env SPAWN_REMOTE_MARGIN=1 bash "$SR" --box home --wait 2 claude auto "$WORK" "$T_TMP/brief.md" late-slug \
  >"$T_TMP/r9" 2>"$T_TMP/r9.err"; rc=$?
eq "9. no serve tick within the wait: exit 5, task on stdout" 5 "$rc"
req9="$(grep -l 'slug: late-slug' "$A"/c-001/inbox/*.json | sed -n 1p)"
has "9. the request carries its expiry" "expires: " "$(jq -r .body "$req9")"
serve_a
eq "9. served after the expiry: spawn-window never ran" "$before" "$(calls)"
has "9. ... logged EXPIRED" "EXPIRED" "$(tail -1 "$A/spawn-remote/serve.log")"
rep9="$(grep -l "$(sed -n 's/^task //p' "$T_TMP/r9")" "$B"/c-001/inbox/*.json | sed -n 1p)"
has "9. ... and the requester is told, in its own inbox" "reason: expired at" "$(jq -r .body "$rep9" 2>/dev/null)"
req_b "$T_TMP/r9b" claude auto "$WORK" "$T_TMP/brief.md" on-time-slug
eq "9. CONTROL a request served within its expiry: exit 0" 0 "$(cat "$T_TMP/r9b.rc")"
eq "9. CONTROL ... spawned" "$((before + 1))" "$(calls)"
body="$(printf 'spawn-request v1\nkind: claude\ntitle: auto\nworkdir: %s\nslug: old-sender\n---\n' "$WORK")"
on "$B" sat bash "$T_SCRIPTS/spool-send.sh" --from c-001 --to c-001@home --kind task --no-ask --no-poke --body "$body" >/dev/null 2>&1
serve_a
eq "9. CONTROL a request with no expires line (an older sender) is still served" "$((before + 2))" "$(calls)"
out="$(on "$B" sat env SPAWN_REMOTE_MARGIN=soon bash "$SR" --box home claude auto "$WORK" 2>&1)"; rc=$?
eq "9. a SPAWN_REMOTE_MARGIN that is not seconds: exit 2" 2 "$rc"

# ---- 10. the lane row's topic, scope and files cross the boxes (SPL-5007) ------
# c-023, 2026-11-07: SPAWN_LANE_TOPIC was set on one box, the request did not
# carry it, the far launcher fell back to a brief that names no topic and the
# hub refused the row (spec 153 3.21, 3.23). Its brief is the shape used here.
U=87eaa57b-0795-493c-bf27-8e09fe9c6b04
printf '# Brief: a lane\n\nTopic: dispatch-refactor-r26\nIssue: SPL-1\n' >"$T_TMP/nolink.md"
SPAWN_LANE_TOPIC="$U" SPAWN_LANE_SCOPE='my scope: a b' SPAWN_LANE_FILES='a/b.sh,c/d.sh' req_b "$T_TMP/r10" claude auto "$WORK" "$T_TMP/nolink.md" row-slug
eq "10. a request with the lane's fields: exit 0" 0 "$(cat "$T_TMP/r10.rc")"
eq "10. the launcher on the far box gets all three" "topic=$U|scope=my scope: a b|files=a/b.sh,c/d.sh" "$(cat "$T_TMP/spawn.env")"
check "10. the brief still arrives verbatim" cmp -s "$T_TMP/nolink.md" "$T_TMP/spawn.brief"
req_b "$T_TMP/r10b" claude auto "$WORK" "$T_TMP/nolink.md" row-none
eq "10. CONTROL none set: none invented, the launcher reads the brief as before" "topic=<unset>|scope=<unset>|files=<unset>" "$(cat "$T_TMP/spawn.env")"
LANE_ISSUE_TOPIC="$U" req_b "$T_TMP/r10c" claude auto "$WORK" "$T_TMP/nolink.md" row-issue
eq "10. LANE_ISSUE_TOPIC is the next source, as in a local spawn" "topic=$U|scope=<unset>|files=<unset>" "$(cat "$T_TMP/spawn.env")"
SPAWN_LANE_TOPIC="$U" LANE_ISSUE_TOPIC=other req_b "$T_TMP/r10d" claude auto "$WORK" "$T_TMP/nolink.md" row-both
has "10. ... SPAWN_LANE_TOPIC wins over it" "topic=$U|" "$(cat "$T_TMP/spawn.env")"
before="$(calls)"
body="$(printf 'spawn-request v1\nkind: claude\ntitle: auto\nworkdir: %s\nslug: old-sender-2\n---\ntopic: %s\n' "$WORK" "$U")"
on "$B" sat bash "$T_SCRIPTS/spool-send.sh" --from c-001 --to c-001@home --kind task --no-ask --no-poke --body "$body" >/dev/null 2>&1
serve_a
eq "10. an older sender with none of the lines is still served" "$((before + 1))" "$(calls)"
eq "10. ... and a topic line in the BRIEF is not a header" "topic=<unset>|scope=<unset>|files=<unset>" "$(cat "$T_TMP/spawn.env")"
SPAWN_LANE_SCOPE=$'one\nslug: evil\n---\nkind: grok' SPAWN_LANE_FILES=$'a/b.sh\nkind: grok' req_b "$T_TMP/r10e" claude auto "$WORK" "$T_TMP/nolink.md" row-flat
eq "10. a scope with newlines stays on its one header line" "topic=<unset>|scope=one slug: evil --- kind: grok|files=a/b.sh kind: grok" "$(cat "$T_TMP/spawn.env")"
has "10. ... and cannot rewrite the request's slug" " row-flat" "$(tail -1 "$T_TMP/spawn.calls")"
has "10. ... nor its kind" "claude auto $WORK" "$(tail -1 "$T_TMP/spawn.calls")"
SPAWN_LANE_SCOPE="$(printf 'x%.0s' $(seq 1 600))" req_b "$T_TMP/r10f" claude auto "$WORK" "$T_TMP/nolink.md" row-long
eq "10. a long scope is cut to the hub's 500 bytes" 500 "$(sed -E 's/.*scope=([^|]*).*/\1/' "$T_TMP/spawn.env" | tr -d '\n' | wc -c)"
# The hub counts bytes (len()). A cut through a character came back from the JSON
# step as U+FFFD, 3 bytes: 502 at the far launcher, and the row lost.
got_scope() { LC_ALL=C sed -E 's/.*scope=([^|]*).*/\1/' "$T_TMP/spawn.env" | tr -d '\n'; }
x498="$(printf 'x%.0s' $(seq 1 498))"
LC_ALL=C.UTF-8 SPAWN_LANE_SCOPE="${x498}xé" req_b "$T_TMP/r10m" claude auto "$WORK" "$T_TMP/nolink.md" row-mb
eq "10. a cut through a character, UTF-8: launched" 0 "$(cat "$T_TMP/r10m.rc")"
eq "10. ... and the whole broken character is dropped, no U+FFFD" "${x498}x" "$(got_scope)"
LC_ALL=C SPAWN_LANE_SCOPE="${x498}xé" req_b "$T_TMP/r10n" claude auto "$WORK" "$T_TMP/nolink.md" row-mb-c
eq "10. the same cut, LC_ALL=C: launched" 0 "$(cat "$T_TMP/r10n.rc")"
eq "10. ... with the same scope" "${x498}x" "$(got_scope)"
LC_ALL=C.UTF-8 SPAWN_LANE_SCOPE="${x498}é" req_b "$T_TMP/r10o" claude auto "$WORK" "$T_TMP/nolink.md" row-mb-fit
eq "10. CONTROL a character that fits in the 500 is kept" "${x498}é" "$(got_scope)"
before="$(calls)"
out="$(on "$B" sat env SPAWN_LANE_TOPIC='x;id' bash "$SR" --box home --wait 0 claude auto "$WORK" 2>&1)"; rc=$?
eq "10. a topic the hub would refuse never leaves: exit 2" 2 "$rc"
has "10. ... named" "bad topic" "$out"
for bad in "topic: x;id" "$(printf 'scope: a\033[2Jb')" "$(printf 'files: a\033[2Jb')"; do
  body="$(printf 'spawn-request v1\nkind: claude\ntitle: auto\nworkdir: %s\nslug: hostile\n%s\n---\n' "$WORK" "$bad")"
  on "$B" sat bash "$T_SCRIPTS/spool-send.sh" --from c-001 --to c-001@home --kind task --no-ask --no-poke --body "$body" >/dev/null 2>&1
  serve_a
  eq "10. a hand-made hostile ${bad%%:*} line: never spawned" "$before" "$(calls)"
  has "10. ... logged REJECTED" "REJECTED" "$(tail -1 "$A/spawn-remote/serve.log")"
done
# By hand, past the sender's cut: 300 characters, 600 bytes.
before="$(calls)"
body="$(printf 'spawn-request v1\nkind: claude\ntitle: auto\nworkdir: %s\nslug: hand-long\nscope: %s\n---\n' "$WORK" "$(printf 'é%.0s' $(seq 1 300))")"
on "$B" sat bash "$T_SCRIPTS/spool-send.sh" --from c-001 --to c-001@home --kind task --no-ask --no-poke --body "$body" >/dev/null 2>&1
LC_ALL=C.UTF-8 serve_a
eq "10. a hand-made scope of 300 characters, 600 bytes: never spawned" "$before" "$(calls)"
has "10. ... logged REJECTED, counted in bytes" "over 500 bytes" "$(tail -1 "$A/spawn-remote/serve.log")"

# The real launcher behind serve, dry: what it would send the hub. spawn-claude.sh
# is the code that fills the row; spawn-window.sh hands it these env vars (its
# envs list, checked below). Red before this change: --topic '' and the WARN.
cat >"$T_TMP/spawn-launcher-dry" <<EOF
#!/usr/bin/env bash
SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$T_SCRIPTS/spawn-claude.sh" c-871 "\$3" "\$4" "\$5" >"$T_TMP/launcher.out" 2>&1
echo "c-871 %43"
EOF
chmod +x "$T_TMP/spawn-launcher-dry"
req_real() {  # OUT_FILE ARGS...
  local out="$1"; shift
  ( on "$B" sat bash "$SR" --box home --wait "$REQ_WAIT" "$@" >"$out" 2>"$out.err"; echo $? >"$out.rc" ) &
  local _
  for _ in $(seq 1 "$REQ_WAIT"); do
    far_box SPAWN_REMOTE_WINDOW_CMD="$T_TMP/spawn-launcher-dry" bash "$SR" --serve
    [ -f "$out.rc" ] && break; sleep 1
  done
  wait
  req_diag "$out"
}
SPAWN_LANE_TOPIC="$U" SPAWN_LANE_FILES='a/b.sh' req_real "$T_TMP/r10g" claude auto "$WORK" "$T_TMP/nolink.md" row-real
has "10. the real launcher's row carries the topic" "--topic '$U'" "$(grep 'lane-map.sh put' "$T_TMP/launcher.out")"
has "10. ... and the files" "--files 'a/b.sh'" "$(grep 'lane-map.sh put' "$T_TMP/launcher.out")"
eq "10. ... and no LANE ROW REFUSED" 0 "$(grep -c 'LANE ROW REFUSED' "$T_TMP/launcher.out")"
req_real "$T_TMP/r10h" claude auto "$WORK" "$T_TMP/nolink.md" row-real2
has "10. CONTROL the same brief, no topic sent: refused, as c-023 was" "LANE ROW REFUSED: c-871 has no discussion (topic)" "$(cat "$T_TMP/launcher.out")"
check "10. spawn-window hands the three to its launcher" grep -q 'SPAWN_LANE_SCOPE SPAWN_LANE_FILES SPAWN_LANE_TOPIC' "$T_SCRIPTS/spawn-window.sh"

# ---- 11. the spawner hears of a refused row (SPL-5007) ----------------------
# Its only other trace is <id>/lane-unlinked.log on the far box, which the
# spawner's box cannot read. Told on stderr; the "<id>@<box> <pane>" stdout and
# exit 0 stay, because the lane did start.
FAKE_UNLINKED=1 req_b "$T_TMP/r11" claude auto "$WORK" "$T_TMP/brief.md" warn-slug
eq "11. a refused row: still exit 0" 0 "$(cat "$T_TMP/r11.rc")"
eq "11. ... stdout unchanged" "c-009@home %42" "$(cat "$T_TMP/r11")"
has "11. ... and the spawner's stderr says it" "LANE ROW REFUSED: c-009" "$(cat "$T_TMP/r11.err")"
touch -d '2 hours ago' "$A/c-009/lane-unlinked.log"
req_b "$T_TMP/r11b" claude auto "$WORK" "$T_TMP/brief.md" warn-old
eq "11. CONTROL an old line of a former c-009 is not this spawn's" 0 "$(grep -c 'LANE ROW REFUSED' "$T_TMP/r11b.err")"

# ---- 12. a mailbox too big for a shell glob (SPL-5074) -----------------------
# 28225 archived files overflowed "$d"/*.json: rc 126, 0 hits, stderr dropped.
# Names of 240 bytes reach the exec limit with few files, so the case stays fast.
fill_box() {  # DIR
  mkdir -p "$1"
  python3 -c 'import os, sys
for i in range(int(sys.argv[2])):
    open(os.path.join(sys.argv[1], "%0235d.json" % i), "w").close()' "$1" "$(( $(getconf ARG_MAX) / 240 + 1 ))"
}
fill_box "$B/c-001/inbox"
grep -lF some-id "$B"/c-001/inbox/*.json >/dev/null 2>&1; rc=$?
eq "12. CONTROL this inbox is too big for a glob" 126 "$rc"
mkdir "$B/c-001/inbox/a-dir.json"
ln -s "$T_TMP/nowhere" "$B/c-001/inbox/vanished.json"
req_b "$T_TMP/r12" claude auto "$WORK" "$T_TMP/brief.md" big-inbox
eq "12. the reply is found in the big inbox: exit 0" 0 "$(cat "$T_TMP/r12.rc")"
eq "12. ... stdout is the remote id" "c-009@home %42" "$(cat "$T_TMP/r12")"
has "12. a real read error stays visible" "a-dir.json: Is a directory" "$(cat "$T_TMP/r12.err")"
hasnt "12. a message acked mid-scan is no error" "vanished.json" "$(cat "$T_TMP/r12.err")"

# The serve tick only reads the last 24 h, so an older cancel reaches the
# request through task_cancelled alone.
task="$(on "$B" sat bash "$SR" --box home --wait 0 claude auto "$WORK" "$T_TMP/brief.md" big-archive 2>"$T_TMP/r12c.err")"
task="${task#task }"
on "$B" sat bash "$SR" --cancel --box home --task "$task" >/dev/null 2>>"$T_TMP/r12c.err"
fill_box "$A/c-001/archive"
cancel_msg="$(find "$A/c-001/inbox" -name '*.json' -exec grep -qF 'spawn-cancel' {} \; -exec grep -lF -- "$task" {} \;)"
mv "$cancel_msg" "$A/c-001/archive/"
touch -d '2 days ago' "$A/c-001/archive/${cancel_msg##*/}"
n="$(calls)"
serve_a
eq "12. a cancel in a big archive still stops the request" "$n" "$(calls)"
has "12. ... and the log says so" "withdrawn before spawn" "$(cat "$A/spawn-remote/serve.log")"

# ---- 13. a cancel check that cannot read the mailbox spawns nothing (SPL-5237) --
# A failed read counted as "not cancelled": a withdrawn request still started a
# lane. Now the tick stops, says so, and leaves the request to the next tick.
cancelled_req() {  # SLUG ; prints the task id of a request withdrawn at once
  local t
  t="$(on "$B" sat bash "$SR" --box home --wait 0 claude auto "$WORK" "$T_TMP/brief.md" "$1" 2>>"$T_TMP/r13.err")"
  t="${t#task }"
  on "$B" sat bash "$SR" --cancel --box home --task "$t" >/dev/null 2>>"$T_TMP/r13.err"
  printf '%s' "$t"
}
req_msg() {  # TASK ; the request's msg_id on A
  jq -r --arg t "$1" 'select(.task_id == $t and (.body | contains("spawn-request v1"))) | .msg_id' \
    "$A"/c-001/inbox/*.json 2>/dev/null
}
if [ "$(id -u)" -eq 0 ]; then
  echo "skip - 13. root reads a mode-000 file: run as a plain user"
else
  rm -rf "$A/c-001/archive"; mkdir -p "$A/c-001/archive"; TAB=$'\t'
  for where in file archive state; do
    task="$(cancelled_req "unread-$where")"
    cancel_msg="$(grep -lF -- "$task" "$A"/c-001/inbox/*.json | xargs grep -lF -- 'spawn-cancel')"
    if [ "$where" = file ]; then
      locked="$cancel_msg" mode=600
    elif [ "$where" = archive ]; then
      mv "$cancel_msg" "$A/c-001/archive/"; locked="$A/c-001/archive" mode=700
    else
      # The cancel was noted on an earlier tick and its message is gone:
      # spawn-remote/cancelled is the only place that holds it.
      jq -r '.msg_id' "$cancel_msg" >>"$A/spawn-remote/seen"; rm -f "$cancel_msg"
      echo "$task" >>"$A/spawn-remote/cancelled"; locked="$A/spawn-remote/cancelled" mode=600
    fi
    msg="$(req_msg "$task")"
    chmod 000 "$locked"
    n="$(calls)"; : >"$T_TMP/serve.err"
    serve_a
    eq "13. $where mode 000: the withdrawn request spawns nothing" "$n" "$(calls)"
    has "13. ... the tick says why on stderr" "UNREADABLE $msg" "$(cat "$T_TMP/serve.err")"
    has "13. ... and in its log" "UNREADABLE$TAB$msg" "$(cat "$A/spawn-remote/serve.log")"
    check "13. ... the request stays retriable (not marked seen)" \
      bash -c '! grep -qxF -- "$1" "$2"' _ "$msg" "$A/spawn-remote/seen"
    chmod "$mode" "$locked"
    serve_a
    eq "13. ... readable again: the cancel still wins" "$n" "$(calls)"
    has "13. ... and the log says so" "CANCELLED$TAB$msg" "$(cat "$A/spawn-remote/serve.log")"
  done
  n="$(calls)"
  req_b "$T_TMP/r13" claude auto "$WORK" "$T_TMP/brief.md" readable-no-cancel
  eq "13. CONTROL a readable mailbox with no cancel still spawns once" "$((n + 1))" "$(calls)"
  eq "13. CONTROL ... and answers the id" "c-009@home %42" "$(cat "$T_TMP/r13")"
fi

# ---- 14. unsee never empties seen (SPL-5237, R7 W1) ----------------------------
# A failed rewrite of seen (a full disk) truncated it, so every request of the
# last 24 h was handled again. Now seen stays as it was and unsee says so.
# shellcheck disable=SC2034,SC2317 # STATE and say are read by the eval'd unsee
unsee_run() {  # STATE MSG_ID [ulimit -f]
  ( STATE="$1"; say() { echo "spawn-remote: $*" >&2; }
    eval "$(sed -n '/^unsee() {/,/^}/p' "$SR")"
    [ -z "${3:-}" ] || ulimit -f "$3"
    unsee "$2" )
}
U="$T_TMP/u14"; mkdir -p "$U"; printf 'old-1\nmsg-14\nold-2\n' >"$U/seen"
unsee_run "$U" msg-14 2>"$T_TMP/u14.err"; rc=$?
eq "14. unsee drops only its msg_id" "0 old-1 old-2" "$rc $(tr '\n' ' ' <"$U/seen" | sed 's/ $//')"
printf 'old-1\nmsg-14\nold-2\n' >"$U/seen"
# stderr through a pipe: the size limit kills a write to a file, not to a pipe.
unsee_run "$U" msg-14 0 2>&1 >/dev/null | cat >"$T_TMP/u14.err"; rc="${PIPESTATUS[0]}"
eq "14. a failed write leaves seen as it was" "1 old-1 msg-14 old-2" "$rc $(tr '\n' ' ' <"$U/seen" | sed 's/ $//')"
has "14. ... says so on stderr" "cannot unmark msg-14" "$(cat "$T_TMP/u14.err")"
eq "14. ... and leaves no temp file" "seen" "$(ls "$U")"

# ---- 15. codex is a kind a request may carry (SPL-5343) ------------------------
# spawn-window took codex, spawn-remote's valid_args did not: a codex row placed
# on another box failed "bad kind codex" (exit 8) and went back to the queue.
# Both sides now read the one list, SPOOL_SPAWN_KINDS (lib/spool-env.inc.sh).
n="$(calls)"
req_b "$T_TMP/r15" codex auto "$WORK" "$T_TMP/brief.md" codex-slug
eq "15. a codex request from the holder: exit 0" 0 "$(cat "$T_TMP/r15.rc")"
eq "15. ... spawned on the far box" "$((n + 1))" "$(calls)"
has "15. ... as kind codex" "codex auto $WORK $A/spawn-remote/briefs/" "$(tail -1 "$T_TMP/spawn.calls")"
kinds="$(bash -c '. "$1"; printf %s "${SPOOL_SPAWN_KINDS:-}"' _ "$T_SCRIPTS/../lib/spool-env.inc.sh" 2>/dev/null)"
has "15. the one kind list names codex" " codex" " $kinds"
for f in spawn-remote.sh spawn-window.sh; do
  use="$(grep -m1 -oE '<claude\|[a-z|]+>' "$T_SCRIPTS/$f")"
  eq "15. $f usage names the list's kinds" "<${kinds// /|}>" "$use"
done
for k in $kinds; do check "15. kind $k has its launcher" test -r "$T_SCRIPTS/spawn-$k.sh"; done

t_done
