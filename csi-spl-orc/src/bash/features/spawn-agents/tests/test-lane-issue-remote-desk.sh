#!/usr/bin/env bash
# test-lane-issue-remote-desk.sh — SPL-5093: a lane placed on one box whose
# brief's workspace has its desk on ANOTHER box gets its issue through that
# box (spawn-remote.sh issue-request), instead of spawn-window's exit 12
# "FATAL no desk for ...". Two spool roots stand for the boxes: A (home, the
# placing box) and B (sat, the desk's box); the hub leg is SPOOL_FLEET_RELAY_CMD.
# SPAWN_REMOTE_ISSUE_CMD stands in for do_spl_lane_issue on the desk's box.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
unset LEASE_MACHINE LANE_FLEET SPAWN_BOX SPAWN_REMOTE_CMD SPAWN_PLACE_MAP_CMD SPAWN_DRY_RUN SPAWN_BOX_PICK_CMD \
  SPAWN_ISSUE SPAWN_ISSUE_CREATE SPAWN_ISSUE_CMD SPAWN_REUSE_ID SPAWN_LANE_TOPIC REPORT_TO SPOOL_DESK_BOX
export SPAWN_BOX_PICK=0 SPOOL_MISTRAL_MAX_PRICE=1 MISTRAL_BIN=/opt/x/vibe
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>' SPAWN_START_CHECK=0
SR="$T_SCRIPTS/spawn-remote.sh"
A="$T_TMP/machine-a" B="$T_TMP/machine-b"
for id in c-001 c-005; do mkdir -p "$A/$id/inbox" "$B/$id/inbox"; done
mkdir -p "$A/dispatch" "$B/dispatch"
printf 'SPOOL_DESK_BOX=home\n' >"$A/box.env"
printf 'SPOOL_DESK_BOX=sat\n' >"$B/box.env"
printf 'LEASE_ORCH=c-001\n' | tee "$A/dispatch/lease.conf" >"$B/dispatch/lease.conf"
printf 'c-001@sat 1790995313\n' | tee "$A/dispatch/lease.orch" >"$B/dispatch/lease.orch"
R="$T_TMP/repo"
g() { git -C "$R" -c user.name='FirstName LastName' -c user.email=dev@example.com "$@"; }
git init -q --bare "$T_TMP/origin.git"; git init -q -b master "$R"
g commit -q --allow-empty -m init; g remote add origin "$T_TMP/origin.git"; g push -q origin master 2>/dev/null
printf 'acme\tprd\tacme-site\t%s\t-\thttps://site.example.com\tc-005\tsat\n' "$R" | tee "$A/workspace-repos.tsv" >"$B/workspace-repos.tsv"
printf '# Brief: fix the widget\n\nWorkspace: acme\n\n## Task\nDo it.\n' >"$T_TMP/ws.md"
cat >"$T_TMP/fake-hub" <<EOF
#!/usr/bin/env bash
from="" to="" kind="" body="" task="" tobox=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --from) from="\$2" ;; --to) to="\$2" ;; --kind) kind="\$2" ;;
    --body) body="\$2" ;; --task) task="\$2" ;; --to-box) tobox="\$2" ;;
  esac
  shift 2
done
[ -z "\${FAKE_DROP:-}" ] || [ "\$tobox" != home ] || { echo '{"delivery":"sent","msg_id":"m","task_id":"t","ts":"x"}'; exit 0; }
case "\$tobox" in home) root="$A" ;; sat) root="$B" ;; *) echo "cannot resolve to_box" >&2; exit 3 ;; esac
id="\$(python3 -c 'import uuid; print(uuid.uuid4())')"
jq -n --arg m "\$id" --arg t "\${task:-\$id}" --arg f "\$from@\$FAKE_FROM_BOX" --arg to "\$to" \
  --arg k "\$kind" --arg b "\$body" '{v:1, msg_id:\$m, task_id:\$t, ts:"x", from:\$f, to:\$to, kind:\$k, body:\$b, files:[]}' \
  >"\$root/\$to/inbox/\$id.json"
echo '{"delivery":"sent","msg_id":"m","task_id":"t","ts":"x"}'
EOF
# The action on the desk's box: records its env, writes the key into the root it was given.
cat >"$T_TMP/issue-stub" <<EOF
#!/usr/bin/env bash
printf 'root=%s id=%s key=%s topic=%s brief=%s\n' "\$SPOOL_ROOT" "\$AGENT_ID" "\${LANE_ISSUE_KEY:-}" "\${LANE_ISSUE_TOPIC:-}" "\$(cat "\$BRIEF" | head -1)" >>"$T_TMP/issue.calls"
[ -z "\${FAKE_ISSUE_FAIL:-}" ] || { echo "FATAL no desk for c-005 on sat in acme: run do_spl_desk_up first" >&2; exit 1; }
if [ "\${LANE_ISSUE_OP:-}" = end ]; then
  printf 'end id=%s key=%s tenant=%s status=%s reason=%s\n' "\$AGENT_ID" "\$(cat "\$SPOOL_ROOT/\$AGENT_ID/lifetime/issue")" "\$(cut -f1 "\$SPOOL_ROOT/\$AGENT_ID/lifetime/issue-tenant")" "\$LANE_ISSUE_STATUS" "\$LANE_ISSUE_REASON" >>"$T_TMP/issue.ends"
  printf '%s\t%s\t2026-10-01T00:00:00Z\n' "\$LANE_ISSUE_STATUS" "\$LANE_ISSUE_REASON" >"\$SPOOL_ROOT/\$AGENT_ID/lifetime/issue-end"
  exit 0
fi
mkdir -p "\$SPOOL_ROOT/\$AGENT_ID/lifetime"
printf 'ACME-7\n' >"\$SPOOL_ROOT/\$AGENT_ID/lifetime/issue"
printf 'acme\tprd\n' >"\$SPOOL_ROOT/\$AGENT_ID/lifetime/issue-tenant"
EOF
# What today's do_spl_lane_issue says on the placing box.
printf '#!/usr/bin/env bash\necho "FATAL no desk for c-005 on sat in acme: run do_spl_desk_up first"; exit 1\n' >"$T_TMP/run-no-desk"
# The hub's status of a key on the desk's box; FAKE_STATUS=none: the read fails.
printf '#!/usr/bin/env bash\n[ "${FAKE_STATUS:-wip}" = none ] || printf "issue-status\\t%%s\\t%%s\\n" "$1" "${FAKE_STATUS:-wip}"\n' >"$T_TMP/status-stub"
chmod +x "$T_TMP/status-stub"
chmod +x "$T_TMP/fake-hub" "$T_TMP/issue-stub" "$T_TMP/run-no-desk"
on() {  # ROOT BOX CMD...
  local root="$1" box="$2"; shift 2
  env SPOOL_ROOT="$root" SPOOL_BOX_ENV="$root/box.env" SPOOL_DESK_BOX="$box" FAKE_FROM_BOX="$box" \
    SPOOL_FLEET_RELAY_CMD="$T_TMP/fake-hub" SPAWN_REMOTE_POLL=1 SPAWN_ORC_RUN="$T_TMP/run-no-desk" "$@"
}
# A tick reads epoch 0, so a slow box cannot expire a request this file means to serve.
serve_clock() { if [ "${1:-}" = +%s ]; then echo 0; else command date "$@"; fi; }
serve_b() { ( date() { serve_clock "$@"; }; export -f date serve_clock; on "$B" sat SPAWN_REMOTE_ISSUE_CMD="$T_TMP/issue-stub" LI_HUB_STATUS_CMD="$T_TMP/status-stub" ${1:+"$1"} bash "$SR" --serve 2>>"$T_TMP/serve.err" ); }
# spawn-window on A in the background; B's receiver ticks until it returns.
spawn_a() {  # TITLE [SERVE_ENV] ; rc in RC, output in $T_TMP/o
  rm -f "$T_TMP/rc"
  ( on "$A" home SPAWN_ISSUE_REMOTE_WAIT=15 bash "$T_SCRIPTS/spawn-window.sh" claude "$1" "$R" "$T_TMP/ws.md" widget >"$T_TMP/o" 2>&1; echo $? >"$T_TMP/rc" ) &
  local _
  for _ in $(seq 1 20); do [ -f "$T_TMP/rc" ] && break; serve_b "${2:-}"; sleep 1; done
  wait; RC="$(cat "$T_TMP/rc" 2>/dev/null || echo none)"
}

# 1. The RED of the report: the desk is on another box.
spawn_a c-050
eq "1 desk on another box: the spawn is not refused (RED on master: exit 12)" 0 "$RC"
hasnt "1 ... no 'no desk for' refusal" "no desk for" "$(cat "$T_TMP/o")"
eq "1 ... the key is in <root>/<id>/lifetime/issue" ACME-7 "$(cat "$A/c-050/lifetime/issue" 2>/dev/null)"
eq "1 ... and its workspace in issue-tenant" "acme	prd" "$(cat "$A/c-050/lifetime/issue-tenant" 2>/dev/null)"
has "1 ... the desk's box ran the action for this lane, from the brief text" "id=c-050 key= topic= brief=# Brief: fix the widget" "$(cat "$T_TMP/issue.calls" 2>/dev/null)"
root="$(sed -n 's/^root=\([^ ]*\) .*/\1/p' "$T_TMP/issue.calls" 2>/dev/null | tail -1)"
check "1 ... in a throwaway root, not the desk box's own lane dir" sh -c "[ '$root' != '$B' ] && [ ! -e '$B/c-050' ]"
check "1 ... which is removed after" sh -c "[ -n '$root' ] && [ ! -e '$root' ]"

# 2. The far box cannot place it: still a refusal, with its reason, and the claim released.
spawn_a c-051 FAKE_ISSUE_FAIL=1
eq "2 no box holds the desk: refused, exit 12" 12 "$RC"
has "2 ... the far box's reason reaches the spawner" "no desk for c-005 on sat" "$(cat "$T_TMP/o")"
check "2 ... no key, the claim released" test ! -e "$A/c-051"

# 3. A desk box nobody serves: refused when the wait ends.
printf 'acme\tprd\tacme-site\t%s\t-\thttps://site.example.com\tc-005\tother\n' "$R" >"$A/workspace-repos.tsv"
on "$A" home SPAWN_ISSUE_REMOTE_WAIT=1 bash "$T_SCRIPTS/spawn-window.sh" claude c-052 "$R" "$T_TMP/ws.md" widget >"$T_TMP/o" 2>&1; RC=$?
eq "3 the desk's box is unreachable: refused, exit 12" 12 "$RC"
printf 'acme\tprd\tacme-site\t%s\t-\thttps://site.example.com\tc-005\tsat\n' "$R" >"$A/workspace-repos.tsv"

# 4. The serving side refuses what is not its own to place.
req() {  # FROM_BOX FROM TITLE ; a raw request left in B's inbox, one tick
  local out
  out="$(on "$A" "$1" bash "$SR" --issue --box sat --from "$2" --id "$3" --wait 0 "${4:-$T_TMP/ws.md}" 2>&1)"
  serve_b; printf '%s' "$out"
}
n0="$(wc -l <"$T_TMP/issue.calls")"
req home c-777 c-060 >/dev/null
eq "4 from a non-role seat: the action does not run" "$n0" "$(wc -l <"$T_TMP/issue.calls")"
has "4 ... logged as refused" "REFUSED" "$(cat "$B/spawn-remote/serve.log")"
printf '# Brief: t1 work\n\n## Task\nDo it.\n' >"$T_TMP/nows.md"
req home c-001 c-061 "$T_TMP/nows.md" >/dev/null
eq "4 a brief with no Workspace: the action does not run" "$n0" "$(wc -l <"$T_TMP/issue.calls")"
printf 'acme\tprd\tacme-site\t%s\t-\thttps://site.example.com\tc-005\tother\n' "$R" >"$B/workspace-repos.tsv"
req home c-001 c-062 >/dev/null
eq "4 a workspace whose desk is not this box's: the action does not run" "$n0" "$(wc -l <"$T_TMP/issue.calls")"
printf 'acme\tprd\tacme-site\t%s\t-\thttps://site.example.com\tc-005\tsat\n' "$R" >"$B/workspace-repos.tsv"
req home c-001 c-063 >/dev/null
eq "4 control: the same request from the role seat runs" "$((n0 + 1))" "$(wc -l <"$T_TMP/issue.calls")"

# 5. A desk on this box never takes the hop.
mkdir -p "$B/c-001/x"; rm -f "$T_TMP/issue.calls"
printf 'acme\tprd\tacme-site\t%s\t-\thttps://site.example.com\tc-005\thome\n' "$R" >"$A/workspace-repos.tsv"
on "$A" home bash "$T_SCRIPTS/spawn-window.sh" claude c-053 "$R" "$T_TMP/ws.md" widget >"$T_TMP/o" 2>&1; RC=$?
eq "5 the desk's box is this box: the local refusal stands, exit 12" 12 "$RC"
has "5 ... the local action's own FATAL" "no desk for c-005" "$(cat "$T_TMP/o")"
check "5 ... and no request left for another box" test ! -e "$T_TMP/issue.calls"

# 6. R7 W2 + W4: only a retry after a lost reply links the key already filed.
printf 'acme\tprd\tacme-site\t%s\t-\thttps://site.example.com\tc-005\tsat\n' "$R" >"$A/workspace-repos.tsv"
issue_a() {  # TITLE BRIEF WAIT [SERVE_ENV] ; rc in RC
  rm -f "$T_TMP/rc"
  ( on "$A" home SPAWN_REMOTE_MARGIN=0 bash "$SR" --issue --box sat --from c-001 --id "$1" --wait "$3" "$2" >"$T_TMP/o" 2>&1; echo $? >"$T_TMP/rc" ) &
  local _
  for _ in $(seq 1 20); do sleep 1; [ -f "$T_TMP/rc" ] && break; serve_b "${4:-}"; done
  wait; RC="$(cat "$T_TMP/rc" 2>/dev/null || echo none)"
  serve_b "${4:-}"  # the caller may give up before any tick: its request is in the inbox by now
}
calls() { cat "$T_TMP/issue.calls" 2>/dev/null; }
printf '# Brief: once only\n\nWorkspace: acme\n' >"$T_TMP/once.md"
rm -f "$T_TMP/issue.calls"
issue_a c-070 "$T_TMP/once.md" 3 FAKE_DROP=1
eq "6 the reply is lost: the caller times out" 5 "$RC"
has "6 ... after the far box filed one" "id=c-070 key= " "$(calls)"
issue_a c-071 "$T_TMP/once.md" 15
eq "6 the retry: rc 0" 0 "$RC"
has "6 ... links the key already filed" "id=c-071 key=ACME-7 " "$(calls)"
issue_a c-072 "$T_TMP/once.md" 15
has "6 a second lane after a delivered key files its own (W4)" "id=c-072 key= " "$(calls)"
printf '# Brief: closed meanwhile\n\nWorkspace: acme\n' >"$T_TMP/closed.md"
issue_a c-073 "$T_TMP/closed.md" 3 FAKE_DROP=1
issue_a c-074 "$T_TMP/closed.md" 15 FAKE_STATUS=done
has "6 the key went done since: not reopened, a new one is filed (W4)" "id=c-074 key= " "$(calls)"
printf '# Brief: unreadable\n\nWorkspace: acme\n' >"$T_TMP/unread.md"
issue_a c-075 "$T_TMP/unread.md" 3 FAKE_DROP=1
n1="$(calls | wc -l)"
issue_a c-076 "$T_TMP/unread.md" 15 FAKE_STATUS=none
eq "6 the hub cannot be read: refused" 4 "$RC"
eq "6 ... the action does not run" "$n1" "$(calls | wc -l)"
printf '# Brief: side by side\n\nWorkspace: acme\n' >"$T_TMP/both.md"
for i in 77 78; do
  ( on "$A" home SPAWN_REMOTE_MARGIN=0 bash "$SR" --issue --box sat --from c-001 --id "c-0$i" --wait 5 "$T_TMP/both.md" >/dev/null 2>&1 ) &
  for _ in $(seq 1 50); do [ "$(grep -l "Brief: side by side" "$B"/c-001/inbox/*.json 2>/dev/null | wc -l)" = "$(( i - 76 ))" ] && break; sleep 0.2; done
done
eq "6 two requests waiting at once carry different tokens (W4)" 2 "$(jq -r 'select(.body|contains("Brief: side by side")).body' "$B"/c-001/inbox/*.json | sed -n 's/^token: //p' | sort -u | wc -l)"
wait

# 7. R7 W1: a lane on the placing box ends its issue through the desk's box.
end_a() {  # ID STATUS REASON [SERVE_ENV]; rc in RC
  local life="$A/$1/lifetime"; mkdir -p "$life"; rm -f "$T_TMP/rc" "$life/issue-end"
  ( on "$A" home SPOOL_AGENT_ID= SPAWN_ISSUE_REMOTE_WAIT=15 bash "$SR" --issue-end --box sat --id "$1" --key "${END_KEY:-ACME-7}" --tenant acme --life "$life" --status "$2" --reason "$3" >"$T_TMP/o" 2>&1; echo $? >"$T_TMP/rc" ) &
  local _
  for _ in $(seq 1 20); do [ -f "$T_TMP/rc" ] && break; serve_b "${4:-}"; sleep 1; done
  wait; RC="$(cat "$T_TMP/rc" 2>/dev/null || echo none)"
}
# A real placement on the desk's box binds each lane to its key.
for i in 80 82 84 86; do req home c-001 "c-0$i" >/dev/null; done
end_a c-080 diss 'superseded by c-081'
eq "7 the end through the desk's box: rc 0" 0 "$RC"
has "7 ... the far action got the key, workspace, status and reason" "end id=c-080 key=ACME-7 tenant=acme status=diss reason=superseded by c-081" "$(cat "$T_TMP/issue.ends" 2>/dev/null)"
eq "7 ... li_gate's issue-end is on the placing box" "diss	superseded by c-081	2026-10-01T00:00:00Z" "$(cat "$A/c-080/lifetime/issue-end" 2>/dev/null)"
end_a c-082 diss why FAKE_ISSUE_FAIL=1
eq "7 the far action fails: refused" 4 "$RC"
check "7 ... and no issue-end" test ! -e "$A/c-082/lifetime/issue-end"
on "$A" home bash "$SR" --issue-end --box sat --id c-083 --key ACME-7 --tenant acme --life "$A/c-080/lifetime" --status 'x;y' --reason r >/dev/null 2>&1; RC=$?
eq "7 a bad status never leaves" 2 "$RC"

n2="$(wc -l <"$T_TMP/issue.ends")"
END_KEY=ACME-999 end_a c-086 diss 'a wrong key'
eq "7 W5 an end with another key than the lane's: refused" 4 "$RC"
has "7 W5 ... naming both keys" "ACME-999 is not the issue this box placed for lane c-086 (ACME-7)" "$(cat "$T_TMP/o")"
eq "7 W5 ... the action does not run" "$n2" "$(wc -l <"$T_TMP/issue.ends")"
end_a c-099 diss 'never placed'
eq "7 W5 an end for a lane this box never placed: refused" 4 "$RC"
has "7 W5 ... with the reason" "no record of placing an issue for lane c-099" "$(cat "$T_TMP/o")"
eq "7 W5 ... the action does not run" "$n2" "$(wc -l <"$T_TMP/issue.ends")"
check "7 W5 ... and no issue-end" test ! -e "$A/c-099/lifetime/issue-end"

# 7b. The real action on the placing box takes that path (R7's probe: FATAL no desk).
life="$A/c-084/lifetime"; mkdir -p "$life"; printf 'ACME-7\n' >"$life/issue"; printf 'acme\tprd\n' >"$life/issue-tenant"
rm -f "$T_TMP/rc"
( on "$A" home SPOOL_AGENT_ID= SPOOL_TEST=1 SPAWN_ISSUE_REMOTE_WAIT=15 AGENT_ID=c-084 LANE_ISSUE_OP=end LANE_ISSUE_REASON='dropped by its gate' DRY_RUN=0 \
    bash "$T_SCRIPTS/../../../../../run" -a do_spl_lane_issue >"$T_TMP/o" 2>&1; echo $? >"$T_TMP/rc" ) &
for _ in $(seq 1 25); do [ -f "$T_TMP/rc" ] && break; serve_b; sleep 1; done
wait; RC="$(cat "$T_TMP/rc" 2>/dev/null || echo none)"
eq "7b do_spl_lane_issue end with the desk on another box: rc 0" 0 "$RC"
hasnt "7b ... no 'no desk for'" "no desk for" "$(cat "$T_TMP/o")"
eq "7b ... issue-end written where li_gate reads it" "diss	dropped by its gate	2026-10-01T00:00:00Z" "$(cat "$life/issue-end" 2>/dev/null)"

# 8. R7 W3: li_desk_elsewhere stays quiet on stdout and does not guess.
elsewhere() { ( SPOOL_DESK_BOX="$1" SPOOL_BOX_ENV=/nonexistent; export SPOOL_DESK_BOX SPOOL_BOX_ENV; . "$T_SCRIPTS/../lib/lane-issue.inc.sh"; [ -n "${2:-}" ] && eval "$2"; li_desk_elsewhere prd acme "${3:-sat}" ); }
OUT="$(elsewhere home 'li_desk_root_user() { return 1; }')"; rc=$?
eq "8 another box, no local root: elsewhere" 0 "$rc"
OUT="$(elsewhere home 'li_desk_root_user() { printf deskuser; return 0; }')"; rc=$?
eq "8 a local root holds it: not elsewhere" 1 "$rc"
eq "8 ... and prints nothing" "" "$OUT"
elsewhere home 'li_desk_root_user() { return 2; }' >/dev/null; rc=$?
eq "8 the roots could not be read: not elsewhere" 1 "$rc"
elsewhere '' 'li_desk_root_user() { return 1; }' >/dev/null; rc=$?
eq "8 a box with no name of its own (box-desk): not elsewhere" 1 "$rc"
t_done
