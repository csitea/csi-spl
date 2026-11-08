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
mkdir -p "\$SPOOL_ROOT/\$AGENT_ID/lifetime"
printf 'ACME-7\n' >"\$SPOOL_ROOT/\$AGENT_ID/lifetime/issue"
printf 'acme\tprd\n' >"\$SPOOL_ROOT/\$AGENT_ID/lifetime/issue-tenant"
EOF
# What today's do_spl_lane_issue says on the placing box.
printf '#!/usr/bin/env bash\necho "FATAL no desk for c-005 on sat in acme: run do_spl_desk_up first"; exit 1\n' >"$T_TMP/run-no-desk"
chmod +x "$T_TMP/fake-hub" "$T_TMP/issue-stub" "$T_TMP/run-no-desk"
on() {  # ROOT BOX CMD...
  local root="$1" box="$2"; shift 2
  env SPOOL_ROOT="$root" SPOOL_BOX_ENV="$root/box.env" SPOOL_DESK_BOX="$box" FAKE_FROM_BOX="$box" \
    SPOOL_FLEET_RELAY_CMD="$T_TMP/fake-hub" SPAWN_REMOTE_POLL=1 SPAWN_ORC_RUN="$T_TMP/run-no-desk" "$@"
}
serve_b() { on "$B" sat SPAWN_REMOTE_ISSUE_CMD="$T_TMP/issue-stub" ${1:+"$1"} bash "$SR" --serve 2>>"$T_TMP/serve.err"; }
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
t_done
