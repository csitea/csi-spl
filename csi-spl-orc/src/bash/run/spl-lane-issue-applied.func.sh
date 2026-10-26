#!/bin/bash
#------------------------------------------------------------------------------
# The apply-only end of do_spl_lane_issue (spl-lane-issue.func.sh, SPL-3471):
# LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done LANE_APPLIED_EVIDENCE="owner=<owner
# msg uuid> accepted=<ACCEPTED msg uuid>". A lane whose work is an apply (a
# terraform step, an IAM grant, a prd action) lands no commit, so no commit
# can close its key and /exit-clean refused it (c-754, SPL-3375, 2026-10-25:
# the orchestrator set the issue done by hand). Both ids are checked first,
# also in a dry run, and a refusal changes nothing:
#   owner     the hub's messages row (do_spl_db_message_show, read-only) is
#             from a human, HUM-<n>
#   accepted  the hub's row is addressed to this lane, from a role seat
#             (spl_is_role_seat) or a human, never the lane itself, and its
#             body (read through the desk, hub-tail of the row's topic) starts
#             with ACCEPTED. A same-box ACCEPTED never reaches the hub
#             (measured prd t1 2026-10-26: 2 of 2 same-box dispatcher -> lane
#             ACCEPTED absent, a cross-box result present): then the lane's
#             inbox/archive copy counts only when the sender's outbox holds
#             the same msg_id with the same body.
# Then: status done, one comment naming both ids, and lifetime/issue-end
# `done\t<why>\t<utc>\tapplied\towner=<uuid> accepted=<uuid>`, which li_gate
# (li_end_record) passes.
#------------------------------------------------------------------------------

SLA_UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# spl_lane_issue_applied ROOT ID: end done on an owner go + an ACCEPTED.
spl_lane_issue_applied() {
  local root="$1" id="$2" ev="${LANE_APPLIED_EVIDENCE:-}" key own acc row from v why
  [[ -z "${LANE_LANDED_REPO:-}${LANE_LANDED_SHA:-}" ]] ||
    { do_log "FATAL give LANE_APPLIED_EVIDENCE or LANE_LANDED_REPO + LANE_LANDED_SHA, not both: refused, nothing changed"; return 1; }
  [[ "$ev" =~ ^owner=($SLA_UUID_RE)\ accepted=($SLA_UUID_RE)$ ]] ||
    { do_log "FATAL LANE_APPLIED_EVIDENCE must be 'owner=<owner msg uuid> accepted=<ACCEPTED msg uuid>' (full lower-case uuids), got: '$ev': refused, nothing changed"; return 1; }
  own="${BASH_REMATCH[1]}" acc="${BASH_REMATCH[2]}"
  [[ "$own" != "$acc" ]] || { do_log "FATAL the owner msg and the ACCEPTED msg are one message ($own): refused, nothing changed"; return 1; }
  key="$(li_key_of_agent "$root" "$id")" || { do_log "FATAL $id carries no issue key ($root/$id/lifetime/issue)"; return 1; }
  row="$(spl_lane_issue_hub_row "$own")" || { do_log "FATAL the owner msg $own is not on the hub of $ENV/$TENANT_ID (or the read failed): refused, nothing changed"; return 1; }
  from="$(jq -r '.from_id // ""' <<<"$row")"
  [[ "$from" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL the owner msg $own is from '$from', not a human (HUM-<n>): refused, nothing changed"; return 1; }
  v="$(spl_lane_issue_accepted "$root" "$id" "$acc")" || return 1
  why="applied, no commit: owner go ${own:0:8} ($from), ACCEPTED ${acc:0:8} from ${v%%$'\t'*} (${v#*$'\t'})"
  [[ -n "${LANE_ISSUE_REASON:-}" ]] && why+=": $(printf '%s' "$LANE_ISSUE_REASON" | tr '\t\n\r' '   ')"
  spl_lane_issue_actor "$root" "$id"
  spl_lane_issue_close "$key" "done" "Lane $id $why. Owner msg $own, ACCEPTED msg $acc." || return 1
  if (( SLI_DRY )); then do_log "OK DRY_RUN $key -> done ($why); nothing written. Re-run with DRY_RUN=0."; return 0; fi
  printf 'done\t%s\t%s\tapplied\towner=%s accepted=%s\n' "$why" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$own" "$acc" >"$root/$id/lifetime/issue-end" ||
    { do_log "FATAL cannot write $root/$id/lifetime/issue-end"; return 1; }
  do_log "OK $key -> done: $why"
}

# spl_lane_issue_accepted ROOT ID MSG -> "<sender>\t<where checked>": MSG is an
# ACCEPTED to lane ID from a role seat or a human. One FATAL line otherwise.
spl_lane_issue_accepted() {
  local root="$1" id="$2" m="$3" row rc=0 from to task body
  row="$(spl_lane_issue_hub_row "$m")" || rc=$?
  if (( rc == 2 )); then
    spl_lane_issue_accepted_local "$root" "$id" "$m"; return
  fi
  (( rc == 0 )) || { do_log "FATAL the hub of $ENV/$TENANT_ID could not be read for the ACCEPTED msg $m: refused, nothing changed" >&2; return 1; }
  from="$(jq -r '.from_id // ""' <<<"$row")" to="$(jq -r '.to_id // ""' <<<"$row")" task="$(jq -r '.task_id // ""' <<<"$row")"
  spl_lane_issue_acceptor "$id" "$m" "${from%@*}" "${to%@*}" || return 1
  body="$(spl_lane_issue_hub_body "$task" "$m")" ||
    { do_log "FATAL the body of the ACCEPTED msg $m (topic $task) could not be read through the $SLI_BOX desk: refused, nothing changed" >&2; return 1; }
  spl_lane_issue_is_accepted "$body" || { do_log "FATAL the msg $m does not start with ACCEPTED: refused, nothing changed" >&2; return 1; }
  printf '%s\tchecked on the hub\n' "${from%@*}"
}

# spl_lane_issue_acceptor ID MSG FROM TO: MSG went to lane ID, from a role
# seat or a human, never from the lane itself.
spl_lane_issue_acceptor() {
  [[ "$4" == "$1" ]] || { do_log "FATAL the ACCEPTED msg $2 is addressed to '$4', not to $1: refused, nothing changed" >&2; return 1; }
  [[ "$3" != "$1" ]] || { do_log "FATAL the ACCEPTED msg $2 is from $1 itself: a lane never accepts its own work: refused, nothing changed" >&2; return 1; }
  declare -F spl_is_role_seat >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_role_seat "$3" || [[ "$3" =~ ^HUM-[0-9]+$ ]] ||
    { do_log "FATAL the ACCEPTED msg $2 is from '$3', not a role seat (dispatch, orchestrator) or a human: refused, nothing changed" >&2; return 1; }
}

# spl_lane_issue_is_accepted BODY: the body starts with ACCEPTED, after the
# hub's `from_agent: <id>@<box>` line of a cross-box message and the leading
# blanks and markdown marks the exit gate skips too (kill-your-self-report.sh).
spl_lane_issue_is_accepted() {
  python3 -c 'import re, sys
b = sys.argv[1]
b = re.sub(r"\Afrom_agent: \S+\n", "", b)
b = re.sub(r"\A[\s*_#>`]+", "", b)
sys.exit(0 if b.startswith("ACCEPTED") else 1)' "$1"
}

# spl_lane_issue_hub_row MSG -> the hub's messages row of MSG (one JSON line,
# no body); rc 2 = the hub has no such message, 1 = the read failed.
spl_lane_issue_hub_row() {
  local out rc=0
  out="$(MSG_ID="$1" RUN_STDOUT_IS_DATA=1 do_spl_db_message_show 2>/dev/null)" || rc=$?
  (( rc == 0 )) || return "$(( rc == 2 ? 2 : 1 ))"
  out="$(grep -m1 '^{' <<<"$out")"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# spl_lane_issue_hub_body TASK MSG -> MSG's body as the hub serves it to this
# box's desk (hub-tail of TASK).
spl_lane_issue_hub_body() {
  local out
  spl_desk_issue_once >&2 || return 1
  out="$(spl_desk_spool "$SPL_STATE_DIR/desk/$TENANT_ID/$SLI_BOX" "$SLI_BOX" "$TENANT_ID" "$SPL_HUB_URL" -- hub-tail --task "$1" --json 2>/dev/null)" || return 1
  python3 -c 'import json, sys
for l in sys.stdin:
    try:
        m = json.loads(l)
    except ValueError:
        continue
    if isinstance(m, dict) and m.get("msg_id") == sys.argv[1]:
        sys.stdout.write(m.get("body") or "")
        sys.exit(0)
sys.exit(1)' "$2" <<<"$out"
}

# spl_lane_issue_accepted_local ROOT ID MSG: a same-box ACCEPTED, which the hub
# never carries: the lane's inbox/archive copy, matched by the sender's outbox.
spl_lane_issue_accepted_local() {
  local out from to same body
  out="$(python3 -c 'import glob, json, os, sys
root, lane, mid = sys.argv[1:]
def find(dirs):
    for d in dirs:
        for f in glob.glob(os.path.join(d, "*.json")):
            try:
                m = json.load(open(f, encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if isinstance(m, dict) and m.get("msg_id") == mid:
                return m
    return None
bare = lambda v: str(v or "").split("@")[0]
m = find([os.path.join(root, lane, "inbox"), os.path.join(root, lane, "archive")])
if not m:
    print("none")
    sys.exit(0)
frm, to = bare(m.get("from")), bare(m.get("to"))
o = find([os.path.join(root, frm, "outbox")]) if frm and "/" not in frm and frm != lane else None
same = bool(o) and o.get("body") == m.get("body") and bare(o.get("to")) == to
print("\t".join([frm, to, "1" if same else "0", (m.get("body") or "").replace("\\", "\\\\").replace("\n", "\\n").replace("\t", " ")]))' "$1" "$2" "$3" 2>/dev/null)"
  [[ -n "$out" && "$out" != none ]] ||
    { do_log "FATAL the ACCEPTED msg $3 is neither on the hub of $ENV/$TENANT_ID nor in $1/$2/{inbox,archive}: refused, nothing changed" >&2; return 1; }
  IFS=$'\t' read -r from to same body <<<"$out"
  spl_lane_issue_acceptor "$2" "$3" "$from" "$to" || return 1
  [[ "$same" == 1 ]] ||
    { do_log "FATAL the ACCEPTED msg $3 in $1/$2 has no matching copy in $1/$from/outbox: refused, nothing changed" >&2; return 1; }
  spl_lane_issue_is_accepted "$(printf '%b' "$body")" || { do_log "FATAL the msg $3 does not start with ACCEPTED: refused, nothing changed" >&2; return 1; }
  printf '%s\tsame box, not on the hub: checked in the spool, the sender outbox matches\n' "$from"
}
