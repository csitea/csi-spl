#!/bin/bash
#------------------------------------------------------------------------------
# @description A lane's issue, by code (owner HUM-10, t1 5ea2e615 msg 346238a8:
# @description "the concrete decision on what needs to be done and the tracking
# @description of the statuses must be reflected in the issues"). The rule:
# @description csi-spl-doc/doc/md/lane-issue-and-docs.md.
# @description   LANE_ISSUE_OP=place (the spawn path, spawn-core.inc.sh): link the
# @description     brief's `Issue: <KEY>` (or LANE_ISSUE_KEY) to the lane: status
# @description     wip, assignee the lane, a comment; no key: create the issue,
# @description     title = the brief's heading, description = its text up to
# @description     the first `## ` + the topic link, under the spec 135 section
# @description     7.1 card (`## Source` + `## Restart`, owner Q4A); the key is
# @description     then posted back in the topic. Writes the key to
# @description     <spool root>/<id>/lifetime/issue and an `Issue:` line into
# @description     lifetime/brief.md.
# @description     A filed issue needs a spec and an epic (owner HUM-10, t1
# @description     7a98c2d1 msg 5863d0d6: no issue without an epic and a git
# @description     spec): the brief's `Spec:` line (else its first
# @description     csi-spl-doc/specs/NNN-<slug>), a folder on origin/master,
# @description     and its `Epic: <KEY>` line, else the spec's pin ("Epic
# @description     SPL-74" in spec.md), else the tenant's one epic titled
# @description     "Spec NNN - ..." (the spec import's mapping). Missing:
# @description     refused in one FATAL line, nothing filed.
# @description     A brief line `Kind: answer` (or LANE_ISSUE_ANSWER=1) labels
# @description     a filed issue `answer`: an evaluation or an answer to the owner.
# @description   LANE_ISSUE_OP=discussion (whoever takes a discussion, at its
# @description     first answer; owner Q1A, spec 135 section 9): files the
# @description     discussion's issue, status eval, assignee AGENT_ID, title
# @description     LANE_ISSUE_TITLE, description LANE_ISSUE_TEXT + the topic
# @description     link, under the same card; `answer` label with
# @description     LANE_ISSUE_ANSWER=1; LANE_ISSUE_SPEC and LANE_ISSUE_EPIC as
# @description     the brief's lines above. Acks, chatter and announcements file
# @description     none. Prints the key and posts it back in the topic.
# @description   LANE_ISSUE_OP=end (the lane, when it ends without landing):
# @description     status LANE_ISSUE_STATUS (diss, onhold or blocked), a comment
# @description     with LANE_ISSUE_REASON, and lifetime/issue-end. The lane is
# @description     the actor when its box's desk seats and announces it, else
# @description     the desk acts and the comment names the lane (SPL-2287);
# @description     a lane the hub refuses from_not_announced is retried once
# @description     as the desk. The comment goes BEFORE the status change: the
# @description     close of an epic's last open issue auto-closes the epic
# @description     (SPL-1729), whose cascade archives this issue in the same
# @description     transaction, and a later comment answered not_found
# @description     (SPL-3064). An issue already at the target status (done
# @description     too) is ended: one OK line, no hub write, issue-end written.
# @description   LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done (SPL-2229: the lane's
# @description     work landed in ANOTHER repo, so no csi-spl commit can close
# @description     its key): LANE_LANDED_REPO=<name> LANE_LANDED_SHA=<sha>. The
# @description     name resolves ONLY through the cnf (spl_landed_repo: a
# @description     `name` of env.box.landed_repos, SPL-2420, or the basename
# @description     of a `src_dir` in csi-spl-cnf/csi-spl/all.env.yaml or
# @description     <ENV>.env.yaml, or the `repo` of a row of the workspace
# @description     box map, SPL-3794), never a lane-given path or URL; its clone
# @description     must be on this box (else refused, naming the cnf's box);
# @description     it is fetched (as its owner, or SPOOL_BOX_USER), then the
# @description     sha must pass `git merge-base --is-ancestor <sha>
# @description     origin/<trunk>` (the cnf's trunk, else origin/HEAD, else
# @description     master, else main). A `github: <owner>/<repo>` row with
# @description     no src_dir (SPL-4471: a clone no git may touch) is read
# @description     on GitHub only, from any box: `gh api` commits/<sha> and
# @description     compare/<trunk>...<sha> "behind" or "identical". Rows
# @description     also come from the box-side SPOOL_LANDED_REPOS_FILE
# @description     (default $SPOOL_ROOT/landed-repos.yaml, never in git,
# @description     the cnf's shape): a repo whose name stays out of the tree.
# @description     Then: status done, a comment naming
# @description     repo + sha, and lifetime/issue-end with both, which li_gate
# @description     passes. Anything else is refused in one line, nothing changed.
# @description     Landed is not live: the dispatcher's ACCEPTED still checks the
# @description     served build; this only replaces the orchestrator's hand-set
# @description     done (the SPL-1813 path, which stays).
# @description   LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done (SPL-3471: an apply-only
# @description     lane, a terraform apply, an IAM grant or a prd action, lands no
# @description     commit): LANE_APPLIED_EVIDENCE="owner=<owner msg uuid>
# @description     accepted=<ACCEPTED msg uuid>". The owner msg must be on the
# @description     hub from a human (HUM-<n>); the ACCEPTED msg addressed to
# @description     this lane, from a role seat or a human (never the lane), its
# @description     body starting with ACCEPTED (spl-lane-issue-applied.func.sh,
# @description     which also says how a same-box ACCEPTED is checked). Then:
# @description     status done, one comment naming both ids, lifetime/issue-end
# @description     that li_gate passes. Anything else: one line, nothing changed.
# @description   A workspace lane (a `Workspace: <tenant>` brief line with a row
# @description     in the box map $SPOOL_ROOT/workspace-repos.tsv,
# @description     workspace-repo.inc.sh): its issue is filed, linked and ended
# @description     IN THAT WORKSPACE, as the map's desk agent (owner HUM-10 msgs
# @description     ca8a036d, dbead7a1: visible to all its members and agents),
# @description     under the brief's own Epic: line if any, with no csi-spl spec
# @description     check, and the key is not posted back in its topic (the
# @description     issue links it). lifetime/issue-tenant records the workspace
# @description     for the end and the exit gate; the closer closes it on
# @description     landing in the workspace's repo (ISSUE_CLOSE_WORKSPACE).
# @description     A Workspace: line with no map row: refused, nothing filed.
# @description Landing moves the issue on (the landed-fix rule: a commit on
# @description master that cites the key). Dry run unless DRY_RUN=0.
# @param AGENT_ID - required: the lane's spool id, e.g. c-123
# @param LANE_ISSUE_OP (optional) - place (default) | discussion | end
# @param BRIEF (optional, place) - the brief file; default <spool root>/<id>/lifetime/brief.md
# @param LANE_ISSUE_KEY (optional, place) - an existing key to link, e.g. SPL-123; default the brief's Issue: line
# @param LANE_ISSUE_SPEC (place: default the brief's; required, discussion) - the spec folder, csi-spl-doc/specs/NNN-<slug>, on origin/master
# @param LANE_ISSUE_EPIC (optional, place/discussion) - the level-1 epic key; default the brief's Epic: line, the spec's pin, the hub's "Spec NNN - ..." epic
# @param LANE_ISSUE_TOPIC (optional, place) - the discussion's topic id or its 8-hex short id; default the first one after "topic" (or "dispatch-") in the brief. The issue links it (SPL-1593, rdb 0194); none, or one the hub cannot resolve to exactly one topic of the tenant, links the tenant's default discussion and logs one WARN line naming the brief - a placement never fails on the link
# @param LANE_ISSUE_POST (optional, place/discussion) - 0: do not post a filed key back in its topic (default 1)
# @param LANE_ISSUE_ANSWER (optional, place/discussion) - 1: label the filed issue `answer` (an evaluation, an answer to the owner)
# @param LANE_ISSUE_TITLE (required, discussion) - what the work is
# @param LANE_ISSUE_TEXT (optional, discussion) - the owner's words that ask for it
# @param LANE_ISSUE_STATUS (optional, end) - diss (default) | onhold | blocked | done (landed in another repo, or applied)
# @param LANE_ISSUE_REASON (required, end; optional with done) - why the lane ends without landing
# @param LANE_LANDED_REPO (required, end done in another repo) - the repo's cnf name, e.g. csi-rel or dvn-web
# @param LANE_LANDED_SHA (required, end done in another repo) - the landed commit, 7-40 hex
# @param LANE_APPLIED_EVIDENCE (required, end done applied) - "owner=<owner msg uuid> accepted=<ACCEPTED msg uuid>"
# @param LANE_APPLIED_OWNER_TENANT (optional, end done applied) - the workspace whose hub holds the owner msg, e.g. csitea; default TENANT_ID (the ACCEPTED is always read in TENANT_ID)
# @param ENV TENANT_ID (optional) - default LEASE_ENV / LEASE_TENANT of <spool root>/dispatch/lease.conf
# @param DESK_AGENT (optional) - the seated desk that files it; default the first seated of LEASE_MASTER, LEASE_ORCH, LEASE_FAILOVER
# @param DESK_BOX (optional) - default this box's desk box
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example AGENT_ID=c-123 BRIEF=/var/spool-hub/dispatch/x/brief.md DRY_RUN=0 ./run -a do_spl_lane_issue
# @example AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=<uuid> LANE_ISSUE_TITLE='Evaluate the runner VM' LANE_ISSUE_ANSWER=1 DRY_RUN=0 ./run -a do_spl_lane_issue
# @example AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_REASON='superseded by c-130' DRY_RUN=0 ./run -a do_spl_lane_issue
# @example AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done LANE_LANDED_REPO=dvn-web LANE_LANDED_SHA=9c74186 DRY_RUN=0 ./run -a do_spl_lane_issue
# @example AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_STATUS=done LANE_APPLIED_EVIDENCE='owner=<uuid> accepted=<uuid>' DRY_RUN=0 ./run -a do_spl_lane_issue
#------------------------------------------------------------------------------
do_spl_lane_issue() {
  # shellcheck source=../features/spawn-agents/lib/lane-issue.inc.sh
  . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" || return 1
  local root="${SPOOL_ROOT:-/var/spool-hub}" id="${AGENT_ID:-}" op="${LANE_ISSUE_OP:-place}" dry=1
  [[ "$id" =~ ^[A-Za-z]{1,3}-[0-9]{2,5}$ ]] || { do_log "FATAL AGENT_ID must be a lane's spool id like c-123, got: '$id'"; return 1; }
  [[ "$op" =~ ^(place|discussion|end)$ ]] || { do_log "FATAL LANE_ISSUE_OP must be place, discussion or end, got: '$op'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  SLI_LIFE="$(spl_lane_issue_life "$root" "$id")"
  spl_lane_issue_ws "$root" "$id" "$op" || return 1
  spl_lane_issue_desk "$root" "$dry" || return 1
  "spl_lane_issue_$op" "$root" "$id" "$dry"
}

# spl_lane_issue_life ROOT ID -> the lane's lifetime dir, which an end reads
# its key from and writes issue-end to: <root>/<id>/lifetime while the lane's
# spool dir exists, else the newest retired generation's
# <root>/.retired/<id>.<spawned-utc>[.<n>]/lifetime. A close
# (tmux-close-window.sh --retire, agent-id-retire.sh) moves the dir there, and
# an end after it found no key (c-168 closed before its exit-clean,
# 2026-10-29: SPL-4274 was ended through a hand-made spool root; SPL-4320). A
# live dir always wins, so a reused id never ends an older generation's issue,
# and <root>/<id> is never recreated.
spl_lane_issue_life() {
  local g
  if [[ ! -d "$1/$2" ]]; then
    g="$(for g in "$1/.retired/$2".*; do [[ -d "$g/lifetime" ]] && printf '%s\n' "${g##*/}"; done | LC_ALL=C sort -t. -k2,2 -k3,3n | tail -1)"
    [[ -n "$g" ]] && { printf '%s\n' "$1/.retired/$g/lifetime"; return 0; }
  fi
  printf '%s\n' "$1/$2/lifetime"
}

# spl_lane_issue_key LIFE -> the key of the lane whose lifetime dir is LIFE.
spl_lane_issue_key() {
  local d="${1%/lifetime}"
  li_key_of_agent "${d%/*}" "${d##*/}"
}

# spl_lane_issue_ws ROOT ID OP: a workspace lane (workspace-repo.inc.sh) acts
# in its workspace. Place reads the brief's Workspace: line, end the lane's
# lifetime/issue-tenant (in SLI_LIFE); the map row sets ENV, TENANT_ID,
# DESK_AGENT and DESK_BOX (SLI_WS = the tenant, SLI_WS_ROW = the row). A lane
# of the lease's tenant sets SLI_WS empty. A workspace without a valid map row: FATAL.
spl_lane_issue_ws() {
  local root="$1" id="$2" op="$3" t="" row rc=0
  SLI_WS="" SLI_WS_ROW=""
  case "$op" in
    place) t="$(wr_tenant_of_brief "${BRIEF:-$root/$id/lifetime/brief.md}")" ;;
    end) [[ -s "$SLI_LIFE/issue-tenant" ]] && t="$(cut -f1 "$SLI_LIFE/issue-tenant" | sed -n 1p)" ;;
  esac
  [[ -n "$t" ]] || return 0
  row="$(wr_row "$t")" || rc=$?
  if (( rc != 0 )); then
    (( rc == 1 )) && do_log "FATAL refused, nothing filed: lane $id works in workspace $t, which has no row in the box map $(wr_map) (tenant, env, repo, clone, trunk, live url, desk agent, desk box; csi-spl-doc/doc/md/lane-issue-and-docs.md section 5)"
    return 1
  fi
  SLI_WS="$t" SLI_WS_ROW="$row"
  ENV="$(wr_field "$row" 1)" TENANT_ID="$t" DESK_AGENT="$(wr_field "$row" 6)" DESK_BOX="$(wr_field "$row" 7)"
  export ENV TENANT_ID DESK_AGENT DESK_BOX
}

# spl_lane_issue_desk ROOT DRY: ENV, TENANT_ID and DESK_AGENT from the fleet
# lease when unset; the desk must be seated on this box (a live run only).
spl_lane_issue_desk() {
  local conf="$1/dispatch/lease.conf" a box
  _sli_conf() { sed -n "s/^$1=\([A-Za-z0-9_.-]*\)\$/\1/p" "$conf" 2>/dev/null | tail -1; }
  ENV="${ENV:-$(_sli_conf LEASE_ENV)}"; TENANT_ID="${TENANT_ID:-$(_sli_conf LEASE_TENANT)}"
  [[ -n "$ENV" && -n "$TENANT_ID" ]] || { do_log "FATAL set ENV and TENANT_ID (no LEASE_ENV / LEASE_TENANT in $conf)"; return 1; }
  export ENV TENANT_ID
  SLI_BOX="${DESK_BOX:-$(spl_desk_box_default)}"
  if [[ -z "${DESK_AGENT:-}" ]]; then
    do_spl_desk_cnf >/dev/null || return 1
    box="$SLI_BOX"
    local d="$SPL_STATE_DIR/desk/$TENANT_ID/$box/spool" first=""
    # The lease's seats first, then any other agent of the desk: the first
    # one the desk sidecar announces (SPL-1707), else the first seated.
    for a in $(_sli_conf LEASE_MASTER) $(_sli_conf LEASE_ORCH) $(_sli_conf LEASE_FAILOVER) \
             $(find "$d" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[A-Za-z]{1,3}-[0-9]{2,5}$' | sort); do
      [[ -d "$d/$a" ]] || continue
      first="${first:-$a}"
      spl_lane_issue_announced "$1" "$box" "$a" && { DESK_AGENT="$a"; break; }
    done
    if [[ -z "${DESK_AGENT:-}" ]]; then DESK_AGENT="$first"
    elif [[ "$DESK_AGENT" != "$first" ]]; then
      do_log "WARN the $box desk does not announce $first (the run report says it does not run, no lease mirror seats it on $box): filing as $DESK_AGENT" >&2
    fi
  fi
  if [[ -z "${DESK_AGENT:-}" ]]; then
    (( $2 )) && { DESK_AGENT="<a seated desk>"; return 0; }
    do_log "FATAL no seated desk of the lease (LEASE_MASTER, LEASE_ORCH, LEASE_FAILOVER) on this box in $TENANT_ID: set DESK_AGENT, or seat one with do_spl_desk_up"
    return 1
  fi
  export DESK_AGENT
}

# spl_lane_issue_announced FLEET_ROOT BOX ID: the desk sidecar on BOX announces
# ID, by its own rule (hubclient agent_run.go + agent_drop.go). With a fresh
# run report (FLEET_ROOT/dispatch/agent-run.tsv, at most 5 min old): an id it
# says runs, one a rotation holds, or a role seat (spl_is_role_seat) a lease mirror
# names on BOX; an older or no report drops nothing. A hub cli session acts
# only as an agent its box announced: on 2026-10-13 a satellite box's role seats were on a
# usage-limit screen, the lease moved to another box, that desk left c-002 out, and
# every spawn there was refused from_not_announced at this step.
spl_lane_issue_announced() {
  local fleet="$1" box="$2" id="$3" rep="$1/dispatch/agent-run.tsv" st f
  [[ -f "$rep" ]] || return 0
  (( $(date +%s) - $(stat -c %Y "$rep" 2>/dev/null || echo 0) <= 300 )) || return 0
  st="$(awk -F'\t' -v id="$id" '$1 == id { v = $2 "\t" $3 } END { print v }' "$rep")"
  [[ "$st" == run || "$st" == run$'\t'* || "$st" == $'stop\theld:'* ]] && return 0
  declare -F spl_is_role_seat >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_role_seat "$id" || return 1
  for f in lease lease.orch; do
    [[ "$(awk 'NR == 1 { print $1 }' "$fleet/dispatch/$f" 2>/dev/null)" == "$id@$box" ]] && return 0
  done
  return 1
}

# spl_lane_issue_hub OP ARGS: the hub call, or the plan line in a dry run.
spl_lane_issue_hub() {
  if (( SLI_DRY )); then do_log "INFO DRY_RUN would: spool issue $* (as $DESK_AGENT, $ENV/$TENANT_ID)" >&2; return 0; fi
  spl_desk_issue_run "$@"
}

# spl_lane_issue_assign OP ARGS: the call with --assignee the lane ($id of
# the caller). The hub takes only agents its roster announces (checkAssignee),
# and a box may not announce its lanes: then the desk that placed it, and the
# lane stays named in the description and the placement comment.
spl_lane_issue_assign() {
  local out rc=0
  (( SLI_DRY )) && { spl_lane_issue_hub "$@" --assignee "$id"; return; }
  out="$(RUN_STDOUT_IS_DATA=1 spl_lane_issue_hub "$@" --assignee "$id" 2>&1)" || rc=$?
  if (( rc != 0 )) && [[ "$out" == *bad_assignee* ]]; then
    do_log "WARN the hub's roster does not announce $id: assigning $DESK_AGENT@$SLI_BOX, the desk that placed it" >&2
    rc=0; out="$(RUN_STDOUT_IS_DATA=1 spl_lane_issue_hub "$@" --assignee "$DESK_AGENT@$SLI_BOX" 2>&1)" || rc=$?
  fi
  (( rc == 0 )) || { do_log "FATAL spool issue $1 for $id: $out" >&2; return 1; }
  printf '%s\n' "$out"
}

spl_lane_issue_place() {
  local root="$1" id="$2" life="$1/$2/lifetime" brief key topic title desc out rc=0
  SLI_DRY="$3"
  brief="${BRIEF:-$life/brief.md}"
  key="${LANE_ISSUE_KEY:-$(li_key_from_brief "$brief")}"
  topic="${LANE_ISSUE_TOPIC:-$(spl_lane_issue_topic "$brief")}"
  if [[ -n "$key" ]]; then
    [[ "$key" =~ ^${LI_KEY_RE}$ ]] || { do_log "FATAL LANE_ISSUE_KEY must be an issue key like SPL-12, got: '$key'"; return 1; }
    spl_lane_issue_assign update --ref "$key" --status wip >/dev/null || return 1
    spl_lane_issue_hub comment --ref "$key" --body "Lane $id placed on $key, status wip.${topic:+ Topic: $(spl_lane_issue_link "$topic")}" >/dev/null || return 1
  else
    [[ -r "$brief" ]] || { do_log "FATAL no issue key and no readable brief to file one from ($brief): pass LANE_ISSUE_KEY=<KEY> or BRIEF=<file>"; return 1; }
    if [[ -n "${SLI_WS:-}" ]]; then
      SLI_SPEC="${LANE_ISSUE_SPEC:-}" SLI_EPIC="${LANE_ISSUE_EPIC:-$(li_epic_from_brief "$brief")}"
    else
      spl_lane_issue_guard "${LANE_ISSUE_SPEC:-$(li_spec_from_file "$brief")}" "${LANE_ISSUE_EPIC:-$(li_epic_from_brief "$brief")}" || return 1
    fi
    title="$(grep -m1 -E '^#+ ' "$brief" | sed -E 's/^#+ +//; s/^Brief: *//' | cut -c1-200)"
    [[ -n "$title" ]] || { do_log "FATAL the brief $brief has no heading to title the issue with"; return 1; }
    [[ -n "$topic" ]] || {
      topic="$(spl_lane_issue_default_topic)"
      do_log "WARN brief $brief names no topic: the issue links the default discussion $topic of $TENANT_ID (SPL-1593)" >&2
    }
    desc="$(mktemp)"
    { spl_lane_issue_card '<new>' "$topic" "$brief" 'the lane starts from its brief'
      awk 'NR > 1 && /^## / { exit } NR > 1 { n += length($0) + 1; if (n > 1500) exit; print }' "$brief"
      printf '\n- Lane: %s\n' "$id"
      [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f-]{27}$ ]] && printf -- '- Topic: %s\n' "$(spl_lane_issue_link "$topic")"
    } >"$desc"
    grep -qiE '^Kind:[[:space:]]*answer[[:space:]]*$' "$brief" && LANE_ISSUE_ANSWER=1
    out="$(spl_lane_issue_file wip "$title" "$desc" "$brief")" || rc=$?
    key="${out%%$'\t'*}"; [[ -n "${out#*$'\t'}" ]] && topic="${out#*$'\t'}"
    (( rc == 0 )) && spl_lane_issue_keyed "$key" "$desc" "$topic" && spl_lane_issue_post "$key" "$topic" "$title"
    rm -f "$desc"
    (( rc == 0 )) || return 1
  fi
  if (( SLI_DRY )); then do_log "OK DRY_RUN $id -> issue $key (wip); nothing written. Re-run with DRY_RUN=0."; return 0; fi
  mkdir -p "$life" && printf '%s\n' "$key" >"$life/issue" || { do_log "FATAL cannot write $life/issue"; return 1; }
  chmod 0664 "$life/issue" 2>/dev/null
  if [[ -n "${SLI_WS:-}" ]]; then
    printf '%s\t%s\n' "$SLI_WS" "$ENV" >"$life/issue-tenant" || { do_log "FATAL cannot write $life/issue-tenant"; return 1; }
    chmod 0664 "$life/issue-tenant" 2>/dev/null
  fi
  if [[ -w "$life/brief.md" ]] && ! li_key_from_brief "$life/brief.md" >/dev/null; then printf '\nIssue: %s\n' "$key" >>"$life/brief.md"; fi
  do_log "OK $id carries issue $key (wip)${SLI_WS:+ in workspace $SLI_WS}"
}

# spl_lane_issue_file STATUS TITLE DESC_FILE [BRIEF] -> "<key>\t<topic>" ("<new>"
# in a dry run): created with the lane ($id of the caller) assigned, labelled
# `answer` when LANE_ISSUE_ANSWER=1. <topic> is the discussion the hub linked
# (SPL-1593) from the card's Source line. When the hub resolves none (no such
# topic in the tenant, an ambiguous short id), one WARN line names the brief
# and the create runs once more on the tenant's default discussion: a
# placement never fails on the link (c-002, dispatch-fcf09921 msg c5c7d032).
spl_lane_issue_file() {
  local out key rc=0 def err
  local -a lab=() ep=()
  if [[ "${LANE_ISSUE_ANSWER:-0}" == 1 ]]; then
    spl_lane_issue_label answer || return 1
    lab+=(--labels answer)
  fi
  # A workspace issue may stand alone (no epic in that workspace yet).
  [[ -n "${SLI_EPIC:-}" || -z "${SLI_WS:-}" ]] && ep=(--epic "${SLI_EPIC:-}")
  err="$(mktemp)"
  out="$(spl_lane_issue_assign create --title "$2" --description-file "$3" --status "$1" "${lab[@]}" "${ep[@]}" 2>"$err")" || rc=$?
  if (( rc != 0 )) && [[ -n "${SLI_WS:-}" && ${#ep[@]} -gt 0 ]] && grep -q unknown_parent "$err"; then
    do_log "WARN brief ${4:-<none>}: epic $SLI_EPIC is no epic of workspace $SLI_WS (unknown_parent): the issue is filed without one" >&2
    ep=(); rc=0; out="$(spl_lane_issue_assign create --title "$2" --description-file "$3" --status "$1" "${lab[@]}" 2>"$err")" || rc=$?
  fi
  def="$(spl_lane_issue_default_topic)"
  if (( rc != 0 )) && [[ "$(cat "$err")" =~ (discussion_required|unknown_discussion|ambiguous_discussion) ]] &&
    ! grep -qx "/t/$def" "$3"; then
    do_log "WARN brief ${4:-<none>}: topic $(sed -n '2p' "$3") did not resolve in $TENANT_ID (${BASH_REMATCH[1]}): the issue links the default discussion $def (SPL-1593)" >&2
    sed -i "2s|.*|/t/$def|" "$3"
    rc=0; out="$(spl_lane_issue_assign create --title "$2" --description-file "$3" --status "$1" "${lab[@]}" "${ep[@]}" 2>"$err")" || rc=$?
  fi
  cat "$err" >&2; rm -f "$err"
  (( rc == 0 )) || return 1
  (( SLI_DRY )) && { printf '<new>\t%s\n' "$(sed -n '2s|^/t/||p' "$3")"; return 0; }
  key="$(printf '%s' "$out" | python3 -c 'import json,sys
j = [l for l in sys.stdin.read().splitlines() if l.startswith("{")]
r = json.loads(j[-1]).get("result") or {}
r = r.get("issue", r) if isinstance(r, dict) else {}
r = r if isinstance(r, dict) else {}
ds = [d.get("task_id", "") for d in r.get("discussions") or [] if isinstance(d, dict)]
print(r.get("key", "") + "\t" + (ds[0] if ds else ""))' 2>/dev/null)" || rc=$?
  [[ $rc -eq 0 && "${key%%$'\t'*}" =~ ^${LI_KEY_RE}$ ]] || { do_log "FATAL the hub filed no key for $id: $out" >&2; return 1; }
  printf '%s\n' "$key"
}

# spl_lane_issue_guard SPEC EPIC: no issue without an epic and a git spec
# (li_epic_spec, lane-issue.inc.sh). Sets SLI_SPEC and SLI_EPIC; with no
# epic given or pinned, the tenant's one epic titled "Spec NNN - ..." (the
# mapping of spec-import-issues.py), read from the hub (a dry run plans it).
spl_lane_issue_guard() {
  local out n keys
  out="$(li_epic_spec "$1" "$2")" || return 1
  SLI_SPEC="${out%%$'\t'*}"; SLI_EPIC="${out#*$'\t'}"
  [[ -n "$SLI_EPIC" ]] && return 0
  n="${SLI_SPEC#csi-spl-doc/specs/}"; n="${n:0:3}"
  if (( SLI_DRY )); then
    SLI_EPIC="<the epic titled Spec $n>"
    do_log "INFO DRY_RUN would: look up the epic titled 'Spec $n - ...' on the hub for $SLI_SPEC" >&2
    return 0
  fi
  out="$(RUN_STDOUT_IS_DATA=1 spl_desk_issue_run list --kind epic --status eval,todo,wip,diss,blocked,onhold,qas,done --limit 500 2>&1)" ||
    { do_log "FATAL refused, nothing filed: $LI_EPIC_SPEC_RULE: the epic of $SLI_SPEC could not be read from the hub: $(printf '%s' "$out" | tail -1)" >&2; return 1; }
  keys="$(printf '%s' "$out" | python3 -c 'import json, re, sys
n = sys.argv[1]
j = [l for l in sys.stdin.read().splitlines() if l.startswith("{")]
r = (json.loads(j[-1]).get("result") or {}) if j else {}
r = json.loads(r) if isinstance(r, str) else r
seen = set()
for e in (r.get("epics") or []) + (r.get("issues") or []):
    if isinstance(e, dict) and re.match(r"Spec\s+" + n + r"\b", e.get("title") or "") and e.get("key"):
        seen.add(e["key"])
print(" ".join(sorted(seen)))' "$n" 2>/dev/null)"
  if [[ -z "$keys" || "$keys" == *" "* ]]; then
    [[ -n "$keys" ]] && keys="more than one ($keys)" || keys=no
    do_log "FATAL refused, nothing filed: $LI_EPIC_SPEC_RULE: $SLI_SPEC has $keys epic titled 'Spec $n - ...' on the hub. Add an 'Epic: SPL-<n>' line to the brief (LANE_ISSUE_EPIC)" >&2
    return 1
  fi
  SLI_EPIC="$keys"
}

# spl_lane_issue_topic BRIEF -> the topic the brief names: its first full
# topic id after "topic", else the first 8-hex short id after "topic" or
# "dispatch-" (the hub resolves it inside the tenant), else nothing.
spl_lane_issue_topic() {
  local u='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' t
  t="$(grep -m1 -oiE "topic[^0-9a-f]{0,40}$u" "$1" 2>/dev/null | grep -oiE "$u\$")"
  [[ -n "$t" ]] || t="$(grep -m1 -oiE '(topic[^0-9a-f]{0,40}|dispatch-)[0-9a-f]{8}([^0-9a-f-]|$)' "$1" 2>/dev/null | grep -oiE '[0-9a-f]{8}' | tail -1)"
  printf '%s' "${t,,}"
}

# spl_lane_issue_default_topic -> the tenant's default discussion, the twin
# of rdb 0194 issue_discussion_default: t1 the owner's topic, any other
# tenant its "Issue backlog" topic (owner msgs 62f96f94, e3c349e2).
spl_lane_issue_default_topic() {
  local h
  [[ "$TENANT_ID" == t1 ]] && { printf 'fcf09921-8f21-4518-a117-f8ddb41bfff5'; return 0; }
  h="$(printf 'spool-issue-backlog:%s' "$TENANT_ID" | sha256sum | cut -c1-32)"
  printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# spl_lane_issue_label NAME: the label is in the tenant's catalogue (an
# existing one is fine, the hub answers label_exists).
spl_lane_issue_label() {
  local out rc=0
  out="$(spl_lane_issue_hub label --name "$1" --color '#5b8def' 2>&1)" || rc=$?
  (( rc == 0 )) || [[ "$out" == *exist* || "$out" == *conflict* ]] || { do_log "FATAL label $1: $out" >&2; return 1; }
}

# spl_lane_issue_discussion ROOT ID DRY: the first answer in a discussion files
# its issue (owner Q1A): eval, the taker assigned, the topic linked.
spl_lane_issue_discussion() {
  local id="$2" topic="${LANE_ISSUE_TOPIC:-}" title desc key out rc=0
  SLI_DRY="$3"
  [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL LANE_ISSUE_TOPIC must be the discussion's topic uuid, got: '$topic'"; return 1; }
  title="$(printf '%s' "${LANE_ISSUE_TITLE:-}" | tr '\t\n\r' '   ' | sed 's/^ *//; s/ *$//' | cut -c1-200)"
  [[ -n "$title" ]] || { do_log "FATAL LANE_ISSUE_TITLE must name the work (an evaluation or an answer counts: LANE_ISSUE_ANSWER=1); acks, chatter and announcements file no issue"; return 1; }
  spl_lane_issue_guard "${LANE_ISSUE_SPEC:-}" "${LANE_ISSUE_EPIC:-}" || return 1
  desc="$(mktemp)"
  { spl_lane_issue_card '<new>' "$topic" '' 'the first answer in the topic'
    [[ -n "${LANE_ISSUE_TEXT:-}" ]] && printf '%s\n\n' "$LANE_ISSUE_TEXT"
    printf -- '- Taken by: %s\n- Topic: %s\n' "$id" "$(spl_lane_issue_link "$topic")"
  } >"$desc"
  out="$(spl_lane_issue_file eval "$title" "$desc")" || rc=$?
  key="${out%%$'\t'*}"; [[ -n "${out#*$'\t'}" ]] && topic="${out#*$'\t'}"
  (( rc == 0 )) && spl_lane_issue_keyed "$key" "$desc" "$topic" && spl_lane_issue_post "$key" "$topic" "$title"
  rm -f "$desc"
  (( rc == 0 )) || return 1
  if (( SLI_DRY )); then do_log "OK DRY_RUN topic $topic -> a new issue (eval); nothing filed. Re-run with DRY_RUN=0."; return 0; fi
  printf '%s\n' "$key"
  do_log "OK topic $topic -> issue $key (eval, $id)" >&2
}

spl_lane_issue_end() {
  local root="$1" id="$2" key st="${LANE_ISSUE_STATUS:-diss}" why
  SLI_DRY="$3"
  if [[ "$st" == "done" ]]; then
    if [[ -n "${LANE_APPLIED_EVIDENCE:-}" ]]; then spl_lane_issue_applied "$root" "$id"; else spl_lane_issue_landed "$root" "$id"; fi
    return
  fi
  why="$(printf '%s' "${LANE_ISSUE_REASON:-}" | tr '\t\n\r' '   ' | sed 's/^ *//; s/ *$//')"
  [[ -n "$why" ]] || { do_log "FATAL LANE_ISSUE_REASON must say why $id ends without landing (dropped by its gate, superseded by ...)"; return 1; }
  [[ "$st" =~ ^(diss|onhold|blocked)$ ]] || { do_log "FATAL LANE_ISSUE_STATUS must be diss, onhold, blocked or done (landed in another repo: LANE_LANDED_REPO + LANE_LANDED_SHA; applied: LANE_APPLIED_EVIDENCE), got: '$st'"; return 1; }
  key="$(spl_lane_issue_key "$SLI_LIFE")" || { do_log "FATAL $id carries no issue key ($SLI_LIFE/issue)"; return 1; }
  spl_lane_issue_actor "$root" "$id"
  spl_lane_issue_close "$key" "$st" "Lane $id ended without landing ($st): $why" || return 1
  if (( SLI_DRY )); then do_log "OK DRY_RUN $key -> $st; nothing written. Re-run with DRY_RUN=0."; return 0; fi
  printf '%s\t%s\t%s\n' "$st" "$why" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$SLI_LIFE/issue-end" ||
    { do_log "FATAL cannot write $SLI_LIFE/issue-end"; return 1; }
  do_log "OK $key -> $st: $why"
}

# spl_lane_issue_actor FLEET_ROOT ID: an end books the LANE as the actor of
# its status change where the hub can (SPL-2287: SPL-2236's diss was booked to
# the dispatcher c-002). The hub books the --as agent (issues_agent.go
# agentUpdateIssue -> applyPatch updated_by -> the issue_events trigger) and
# takes only an agent the calling desk's box announces (ws.go senderRefusal),
# i.e. a seat in that desk's own spool (hubclient scanAgents). A lane seated
# there and announced acts itself (DESK_AGENT=ID); otherwise the desk acts and
# SLI_BY, appended to the comment, names whom it booked for: issue_events has
# no note column, so the event itself cannot carry the lane.
spl_lane_issue_actor() {
  SLI_BY="" SLI_DESK="$DESK_AGENT" SLI_LANE="$2"
  [[ -n "${SPL_STATE_DIR:-}" ]] || do_spl_desk_cnf >/dev/null 2>&1
  if [[ -d "${SPL_STATE_DIR:-}/desk/$TENANT_ID/$SLI_BOX/spool/$2" ]] && spl_lane_issue_announced "$1" "$SLI_BOX" "$2"; then
    DESK_AGENT="$2"; return 0
  fi
  SLI_BY=" (booked by desk $DESK_AGENT for lane $2: the hub books only an agent its box announces)"
}

# spl_lane_issue_close KEY STATUS BODY: an end's comment, then its status
# change (SPL-3064). The status change goes last: closing an epic's last open
# issue auto-closes the epic (SPL-1729), and that cascade archives the epic
# AND this issue in the same transaction, after which `comment` (live rows
# only) answers not_found. Measured on prd t1 2026-10-23, n=2: SPL-3056 and
# SPL-3055 diss with archived_at = updated_at, their epics SPL-3038 / SPL-3035
# auto_closed, the lanes' comment refused and lifetime/issue-end never written.
# An issue already at STATUS (`get` answers archived rows too) is ended: one
# OK line and no hub write, so a retry after such a run succeeds.
spl_lane_issue_close() {
  local key="$1" st="$2" body="$3" cur
  if (( ! SLI_DRY )); then
    cur="$(spl_lane_issue_status "$key")"
    if [[ "${cur%% *}" == "$st" ]]; then
      do_log "OK $key is already $st${cur#"$st"}: nothing to change, the end is recorded" >&2
      return 0
    fi
  fi
  spl_lane_issue_act comment --ref "$key" --body "$body" || return 1
  spl_lane_issue_act update --ref "$key" --status "$st"
}

# spl_lane_issue_status KEY -> "<status>", "<status> (archived)", or empty
# when the read fails (the writes then say why).
spl_lane_issue_status() {
  spl_desk_issue_run get --ref "$1" 2>/dev/null | python3 -c 'import json, sys
try:
    i = json.load(sys.stdin)["result"]["issue"]
except Exception:
    sys.exit(0)
print(str(i.get("status", "")) + (" (archived)" if i.get("archived") else ""))' 2>/dev/null
}

# spl_lane_issue_act OP ARGS: one end call as DESK_AGENT, SLI_BY appended to
# a --body. The lane acting itself (spl_lane_issue_actor) and refused
# from_not_announced (the run report said it runs, its box's sidecar had not
# announced it yet: c-174 on 2026-10-23) is retried once as the desk, and the
# comment then names the lane.
spl_lane_issue_act() {
  local out rc=0
  local -a a
  _sli_args() { local j; a=("$@"); for ((j = 0; j < ${#a[@]}; j++)); do [[ "${a[j]}" == --body ]] && a[j + 1]+="$SLI_BY"; done; }
  _sli_args "$@"
  (( SLI_DRY )) && { spl_lane_issue_hub "${a[@]}" >/dev/null; return; }
  out="$(spl_lane_issue_hub "${a[@]}" 2>&1 >/dev/null)" || rc=$?
  if (( rc != 0 )) && [[ "$out" == *from_not_announced* && "$DESK_AGENT" == "${SLI_LANE:-}" && -n "${SLI_DESK:-}" && "$SLI_DESK" != "$DESK_AGENT" ]]; then
    do_log "WARN the hub does not announce $DESK_AGENT yet: $1 as the desk $SLI_DESK" >&2
    DESK_AGENT="$SLI_DESK"
    SLI_BY=" (booked by desk $DESK_AGENT for lane $SLI_LANE: the hub books only an agent its box announces)"
    _sli_args "$@"; rc=0
    out="$(spl_lane_issue_hub "${a[@]}" 2>&1 >/dev/null)" || rc=$?
  fi
  (( rc == 0 )) || { printf '%s\n' "$out" >&2; return 1; }
}

# spl_lane_issue_landed ROOT ID: end done, the work landed in another repo
# (SPL-2229). The check runs first, also in a dry run; a refusal changes nothing.
spl_lane_issue_landed() {
  local root="$1" id="$2" repo="${LANE_LANDED_REPO:-}" sha="${LANE_LANDED_SHA:-}" key clone out full trunk why
  key="$(spl_lane_issue_key "$SLI_LIFE")" || { do_log "FATAL $id carries no issue key ($SLI_LIFE/issue)"; return 1; }
  if [[ -n "${SLI_WS:-}" && "$repo" == "$(wr_field "$SLI_WS_ROW" 2)" ]]; then
    trunk="$(wr_field "$SLI_WS_ROW" 4)"; [[ "$trunk" == - ]] && trunk=""
    clone="$(wr_field "$SLI_WS_ROW" 3)"$'\t'"$trunk"
  else
    clone="$(spl_landed_repo "$repo")" || return 1
  fi
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || { do_log "FATAL LANE_LANDED_SHA must be a commit sha (7-40 lower-case hex), got: '$sha'"; return 1; }
  out="$(spl_lane_issue_on_trunk "$repo" "${clone%%$'\t'*}" "$sha" "${clone#*$'\t'}")" || return 1
  full="${out%%$'\t'*}"; trunk="${out#*$'\t'}"
  why="landed in $repo ${full:0:12} on origin/$trunk"
  [[ -n "${LANE_ISSUE_REASON:-}" ]] && why+=": $(printf '%s' "$LANE_ISSUE_REASON" | tr '\t\n\r' '   ')"
  spl_lane_issue_actor "$root" "$id"
  spl_lane_issue_close "$key" "done" "Lane $id $why (another repo, no csi-spl commit). Landed, not live: the dispatcher's ACCEPTED checks the served build." || return 1
  if (( SLI_DRY )); then do_log "OK DRY_RUN $key -> done ($why); nothing written. Re-run with DRY_RUN=0."; return 0; fi
  printf 'done\t%s\t%s\t%s\t%s\n' "$why" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$repo" "$full" >"$SLI_LIFE/issue-end" ||
    { do_log "FATAL cannot write $SLI_LIFE/issue-end"; return 1; }
  do_log "OK $key -> done: $why"
}

# spl_landed_repo_rows -> "name<TAB>src_dir<TAB>trunk<TAB>box<TAB>src"
# ("-" = unset: read collapses an empty tab field; src = cnf or map) per repo
# the fleet knows (SPL-2420): each env.box.landed_repos entry, and each other
# map with an absolute `src_dir` (a hosted site, named by its basename), from
# all.env.yaml then <ENV>.env.yaml (a later row wins), after the rows of the
# workspace box map (spl_landed_repo_map_rows), so a public row wins a name. A
# landed_repos row with `github: <owner>/<repo>` and no src_dir (SPL-4471) is
# "<name>\tgh:<owner>/<repo>\t<trunk>\t<box>\tgh": read on GitHub only, its
# clone never touched. Last, the GitHub-only rows of the box-side
# SPOOL_LANDED_REPOS_FILE (default $SPOOL_ROOT/landed-repos.yaml; never in
# git, the cnf's env.box.landed_repos shape): a repo whose name the tree must
# not carry. That file is read only when spl_landed_repo_box_file_ok, and a
# row of it never takes a name an earlier row has (one WARN, row dropped): a
# lane must not point a known name at a repo it controls. A test sandbox
# (SPOOL_TEST=1) reads LANE_LANDED_CNF and a set SPOOL_LANDED_REPOS_FILE only,
# else no cnf: never the live clones.
spl_landed_repo_rows() {
  local d f bf
  local -a cnfs=()
  d="${APP_PATH:-$PROJ_PATH/..}/csi-spl-cnf/csi-spl"
  if [[ "${SPOOL_TEST:-}" == 1 ]]; then cnfs=("${LANE_LANDED_CNF:-}"); bf="${SPOOL_LANDED_REPOS_FILE:-}"
  else cnfs=("$d/all.env.yaml" "$d/${ENV:-none}.env.yaml"); bf="${SPOOL_LANDED_REPOS_FILE:-${SPOOL_ROOT:-/var/spool-hub}/landed-repos.yaml}"; fi
  {
    spl_landed_repo_map_rows
    for f in "${cnfs[@]}"; do
      [[ -r "$f" ]] || continue
      yq -r '.. | select(tag == "!!map" and has("src_dir")) |
        [(.name // (.src_dir | split("/") | .[-1])), .src_dir, (.trunk // ""), (.box // ""), "cnf"] | @tsv' "$f" 2>/dev/null
      yq -r '.env.box.landed_repos[]? | select(has("github") and (has("src_dir") | not)) |
        [(.name // ""), "gh:" + .github, (.trunk // ""), (.box // ""), "gh"] | @tsv' "$f" 2>/dev/null
    done
    if [[ -n "$bf" && -r "$bf" ]] && spl_landed_repo_box_file_ok "$bf"; then
      yq -r '.env.box.landed_repos[]? | select(has("github") and (has("src_dir") | not)) |
        [(.name // ""), "gh:" + .github, (.trunk // ""), (.box // ""), "box"] | @tsv' "$bf" 2>/dev/null
    fi
  } | awk -F'\t' -v OFS='\t' '($2 ~ /^\// || ($5 ~ /^(gh|box)$/ && $2 ~ /^gh:[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/)) &&
    $1 ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ && $1 !~ /\.\./ && $2 !~ /\.\./ {
    if ($5 == "box") {
      if ($1 in seen) { print "WARN a row of the box-side landed-repos file takes a name an earlier row has: dropped" > "/dev/stderr"; next }
      $5 = "gh"
    }
    seen[$1] = 1
    if ($3 == "") $3 = "-"; if ($4 == "") $4 = "-"; print }'
}

# spl_landed_repo_box_file_ok FILE: true when FILE is owned by root or by the
# owner of SPOOL_ROOT and is neither group- nor other-writable (SPOOL_ROOT is
# group-writable for every agent: a file any lane can write must not name the
# repo a check reads). Else one WARN on stderr, and FILE adds no rows.
spl_landed_repo_box_file_ok() {
  local own mode root_own
  own="$(stat -L -c %u "$1" 2>/dev/null)" && mode="$(stat -L -c %a "$1" 2>/dev/null)" || return 1
  root_own="$(stat -L -c %u "${SPOOL_ROOT:-/var/spool-hub}" 2>/dev/null)"
  if [[ "$own" == 0 || "$own" == "$root_own" ]] && (( (8#$mode & 8#022) == 0 )); then return 0; fi
  do_log "WARN the box-side landed-repos file $1 is not owned by root or the spool root's owner, or is group/other-writable (mode $mode): ignored, it adds no landed repo" >&2
  return 1
}

# spl_landed_repo_map_rows -> one spl_landed_repo_rows row ("map") per row of
# the workspace box map (SPL-3794, workspace-repo.inc.sh: box-side, never in
# git), read through wr_tenants / wr_row: name = repo, src_dir = clone,
# trunk, box = desk_box (the map's clone is on the box that holds the map, its
# desk's box; measured 2026-10-27, n=1). No map: no rows. A malformed row is
# skipped with one WARN that names no repo. A test sandbox (SPOOL_TEST=1)
# reads SPOOL_WORKSPACE_REPOS_MAP only, never the spool root's map.
spl_landed_repo_map_rows() {
  local ws row
  [[ "${SPOOL_TEST:-}" == 1 && -z "${SPOOL_WORKSPACE_REPOS_MAP:-}" ]] && return 0
  # shellcheck source=../features/spawn-agents/lib/workspace-repo.inc.sh
  declare -F wr_tenants >/dev/null || . "$PROJ_PATH/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh" || return 0
  while read -r ws; do
    row="$(wr_row "$ws" 2>/dev/null)"
    case $? in
      0) printf '%s\t%s\t%s\t%s\tmap\n' "$(wr_field "$row" 2)" "$(wr_field "$row" 3)" "$(wr_field "$row" 4)" "$(wr_field "$row" 7)" ;;
      2) do_log "WARN the workspace box map ($(wr_map)) has a malformed row: skipped, its repo is no landed repo" >&2 ;;
    esac
  done < <(wr_tenants)
}

# spl_landed_repo_shown NAME CLONE [clone] -> how a message names the repo:
# NAME (with " (CLONE)" for "clone"), or "a workspace repo" when CLONE is a
# clone of the workspace box map: a refusal never prints a customer's repo
# name or path (SPL-3794).
spl_landed_repo_shown() {
  if spl_landed_repo_map_rows 2>/dev/null | awk -F'\t' -v c="$2" '$2 == c { f = 1 } END { exit !f }'; then
    printf 'a workspace repo'
  elif [[ "${3:-}" == clone ]]; then printf '%s (%s)' "$1" "$2"
  else printf '%s' "$1"; fi
}

# spl_landed_repo_box -> this box's tag: SPOOL_BOX_TAG, else the spool
# root's box.env, else the short hostname.
spl_landed_repo_box() {
  local v="${SPOOL_BOX_TAG:-}" f="${SPOOL_ROOT:-/var/spool-hub}/box.env"
  [[ -z "$v" && -r "$f" ]] && v="$(sed -n 's/^SPOOL_BOX_TAG=["'\'']\{0,1\}\([A-Za-z0-9._-]*\).*/\1/p' "$f" | tail -n1)"
  printf '%s' "${v:-$(hostname -s)}"
}

# spl_landed_repo NAME -> "<clone>\t<trunk>" of a repo the cnf or the
# workspace box map knows, its clone on THIS box (trunk empty = found on the
# clone); a GitHub-only row gives "gh:<owner>/<repo>\t<trunk>" on any box. The one resolver of do_spl_lane_issue (end done), spl_desk_live_proof
# (LIVE_REPO) and do_spl_done_claim_check. A path, a URL, an unknown name and
# a clone that is not on this box are refused, one FATAL line on stderr: a
# lane must not point the check at a repo it controls. The refusal lists the
# public names only, and counts the map's (SPL-3794).
spl_landed_repo() {
  local name="$1" n p t b s hit="" known="" nws=0 where
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$name" != *..* ]] ||
    { do_log "FATAL LANE_LANDED_REPO must be a repo NAME the cnf knows, not a path or URL, got: '$name'" >&2; return 1; }
  while IFS=$'\t' read -r n p t b s; do
    if [[ "$s" == map ]]; then nws=$((nws + 1)); else known+=" $n"; fi
    [[ "$n" == "$name" ]] && hit="$p"$'\t'"$t"$'\t'"$b"$'\t'"$s"
  done < <(spl_landed_repo_rows)
  (( nws )) && known="${known:- none} and $nws workspace repo(s)"
  [[ -n "$hit" ]] || { do_log "FATAL LANE_LANDED_REPO '$name' is no repo the cnf knows (src_dir names:${known:- none}): refused, nothing changed" >&2; return 1; }
  IFS=$'\t' read -r p t b s <<<"$hit"
  [[ "$t" == - ]] && t=""
  [[ "$s" == gh ]] && { printf '%s\t%s\n' "$p" "$t"; return 0; }
  if [[ ! -d "$p/.git" ]]; then
    if [[ "$s" == map ]]; then
      do_log "FATAL the workspace box map's clone of that repo is not a git repo on this box ($(spl_landed_repo_box)); its desk is on box $b: run it there: refused, nothing changed" >&2
      return 1
    fi
    where="the cnf names no box for it (env.box.landed_repos[].box)"
    [[ "$b" != - ]] && where="its clone is on box $b: run it there"
    do_log "FATAL the cnf's clone of $name, $p, is not a git repo on this box ($(spl_landed_repo_box)); $where: refused, nothing changed" >&2
    return 1
  fi
  printf '%s\t%s\n' "$p" "$t"
}

# spl_landed_repo_git CLONE ARGS...: git in CLONE as its owner, or
# SPOOL_BOX_USER (sudo -n when that is not the caller); SLR_TIMEOUT=<s> caps it.
spl_landed_repo_git() {
  local c="$1" u
  local -a pre=()
  shift
  [[ -n "${SLR_TIMEOUT:-}" ]] && pre=(timeout "$SLR_TIMEOUT")
  u="${SPOOL_BOX_USER:-$(stat -c %U "$c")}"
  [[ "$u" == "$(id -un)" ]] || pre+=(sudo -n -u "$u")
  "${pre[@]}" git -c safe.directory='*' -C "$c" "$@"
}

# spl_landed_repo_trunk NAME CLONE [TRUNK] -> the trunk branch, after a fetch
# of the clone (an unfetched clone answers "not landed"; SLR_NO_FETCH=1 skips
# it): TRUNK (the cnf's),
# else origin/HEAD, master, main. A failed fetch or a missing trunk: one FATAL.
spl_landed_repo_trunk() {
  local name="$1" c="$2" t="${3:-}" b
  [[ "$c" == gh:* ]] && { spl_landed_repo_gh_trunk "$name" "${c#gh:}" "$t"; return; }
  [[ "${SLR_NO_FETCH:-}" == 1 ]] ||
    SLR_TIMEOUT="${LANE_LANDED_FETCH_TIMEOUT:-120}" spl_landed_repo_git "$c" fetch -q origin </dev/null >&2 ||
    { do_log "FATAL cannot fetch $(spl_landed_repo_shown "$name" "$c" clone) as ${SPOOL_BOX_USER:-$(stat -c %U "$c")}: not checked, refused, nothing changed" >&2; return 1; }
  [[ -n "$t" ]] || { t="$(spl_landed_repo_git "$c" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; t="${t#origin/}"; }
  [[ -z "$t" ]] || spl_landed_repo_git "$c" rev-parse -q --verify "refs/remotes/origin/$t" >/dev/null ||
    { do_log "FATAL $(spl_landed_repo_shown "$name" "$c") has no origin/$t: refused, nothing changed" >&2; return 1; }
  for b in master main; do
    [[ -n "$t" ]] || { spl_landed_repo_git "$c" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null && t="$b"; }
  done
  [[ -n "$t" ]] || { do_log "FATAL $(spl_landed_repo_shown "$name" "$c") has no origin/master or origin/main: refused, nothing changed" >&2; return 1; }
  printf '%s\n' "$t"
}

# spl_landed_repo_gh REPO PATH JQ: `gh api repos/<REPO>[/PATH] --jq JQ` as
# the caller, capped by LANE_LANDED_FETCH_TIMEOUT (120 s).
spl_landed_repo_gh() {
  timeout "${LANE_LANDED_FETCH_TIMEOUT:-120}" gh api "repos/$1${2:+/$2}" --jq "$3" </dev/null 2>/dev/null
}

# spl_landed_repo_gh_trunk NAME REPO [TRUNK] -> the trunk of a GitHub-only row
# (SPL-4471): TRUNK, else the repo's default branch; it must exist on GitHub.
spl_landed_repo_gh_trunk() {
  local t="${3:-}"
  [[ -n "$t" ]] || t="$(spl_landed_repo_gh "$2" "" .default_branch)"
  [[ -n "$t" ]] ||
    { do_log "FATAL cannot read $1 on GitHub (gh api repos/$2): not checked, refused, nothing changed" >&2; return 1; }
  [[ "$(spl_landed_repo_gh "$2" "branches/$t" .name)" == "$t" ]] ||
    { do_log "FATAL cannot read origin/$t of $1 on GitHub ($2): no such branch, or gh refused (auth, rate limit): refused, nothing changed" >&2; return 1; }
  printf '%s\n' "$t"
}

# spl_landed_repo_gh_commit REPO SHA -> the full sha of a commit of REPO on
# GitHub, else false.
spl_landed_repo_gh_commit() {
  local full
  full="$(spl_landed_repo_gh "$1" "commits/$2" .sha)" && [[ "$full" =~ ^[0-9a-f]{40}$ && "$full" == "$2"* ]] && printf '%s\n' "$full"
}

# spl_landed_repo_gh_on REPO FULL TRUNK: true when TRUNK contains FULL. The
# compare is base=TRUNK, head=FULL: "behind" (head is an ancestor of base) or
# "identical" is landed; "ahead" or "diverged" is not (a-371, 2026-10-14,
# read "behind" the other way round).
spl_landed_repo_gh_on() {
  [[ "$(spl_landed_repo_gh "$1" "compare/$3...$2" .status)" =~ ^(behind|identical)$ ]]
}

# spl_lane_issue_on_trunk NAME CLONE SHA [TRUNK] -> "<full sha>\t<trunk>":
# fetched first (spl_landed_repo_trunk), then an ancestor of origin/<trunk>;
# a GitHub-only row (CLONE gh:<owner>/<repo>) is read on GitHub instead.
spl_lane_issue_on_trunk() {
  local name="$1" c="$2" sha="$3" t full
  t="$(spl_landed_repo_trunk "$name" "$c" "${4:-}")" || return 1
  if [[ "$c" == gh:* ]]; then
    full="$(spl_landed_repo_gh_commit "${c#gh:}" "$sha")" ||
      { do_log "FATAL $sha is no commit of $name on GitHub (${c#gh:}): refused, nothing changed" >&2; return 1; }
    spl_landed_repo_gh_on "${c#gh:}" "$full" "$t" ||
      { do_log "FATAL $name ${full:0:12} is not on origin/$t (a branch only?): not landed, refused, nothing changed" >&2; return 1; }
    printf '%s\t%s\n' "$full" "$t"
    return 0
  fi
  full="$(spl_landed_repo_git "$c" rev-parse -q --verify "$sha^{commit}" 2>/dev/null)" ||
    { do_log "FATAL $sha is no commit of $(spl_landed_repo_shown "$name" "$c"), even after a fetch: refused, nothing changed" >&2; return 1; }
  spl_landed_repo_git "$c" merge-base --is-ancestor "$full" "refs/remotes/origin/$t" ||
    { do_log "FATAL $(spl_landed_repo_shown "$name" "$c") ${full:0:12} is not on origin/$t (a branch only?): not landed, refused, nothing changed" >&2; return 1; }
  printf '%s\t%s\n' "$full" "$t"
}

# spl_lane_issue_link TOPIC -> the topic's web link, from the desk cnf's WUI.
spl_lane_issue_link() {
  [[ -n "${SPL_WUI_URL:-}" ]] || do_spl_desk_cnf >/dev/null 2>&1
  printf '%s/t/%s' "${SPL_WUI_URL:-}" "$1"
}

# spl_lane_issue_card KEY TOPIC BRIEF NEXT: the card that starts a filed
# issue's description (spec 135 section 7.1, owner Q4A: no column, no
# migration). The lane keeps it current with do_spl_issue_update
# ISSUE_DESCRIPTION_FILE=...; the owner's words follow it.
spl_lane_issue_card() {
  local spec="" avoid="" scope="the topic"
  if [[ -r "$3" ]]; then
    scope="the brief of lane $id"
    spec="${SLI_SPEC:-$(li_spec_from_file "$3")}"
    avoid="$(grep -m1 -iE 'not touch' "$3" | sed -E 's/^[-* ]+//' | cut -c1-200)"
  fi
  printf '## Source\n%s\n\n## Restart\n' "$([[ -n "$2" ]] && echo "/t/$2" || echo none)"
  spec="${spec:-${SLI_SPEC:-}}"
  printf -- '- key: %s\n- spec: %s\n- scope: %s\n- must not touch: %s\n' "$1" "${spec:-none}" "$scope" "${avoid:-see the brief}"
  printf -- '- test: see the brief\n- last citing sha: none\n- next: %s\n- open question: none\n- docs: none yet\n\n' "$4"
}

# spl_lane_issue_keyed KEY DESC_FILE [TOPIC]: the filed issue's card names
# its own key, unknown until the create, and the topic the hub linked (a short
# id resolved). A failure warns: the issue stands.
spl_lane_issue_keyed() {
  (( SLI_DRY )) && return 0
  [[ "${3:-}" =~ ^[0-9a-f]{8}-[0-9a-f-]{27}$ ]] && sed -i "2s|.*|/t/$3|" "$2"
  sed -i "0,/^- key: <new>\$/s//- key: $1/" "$2" &&
    RUN_STDOUT_IS_DATA=1 spl_lane_issue_hub update --ref "$1" --description-file "$2" >/dev/null 2>&1 ||
    do_log "WARN $1 is filed, but its card still says key <new>: spool issue update --ref $1 --description-file <the card>" >&2
  return 0
}

# spl_lane_issue_post KEY TOPIC TITLE: the key, posted back in the topic it
# came from (owner Q4A) by the desk that filed it; LANE_ISSUE_POST=0 skips.
# A failed post warns: the issue stands and the key is printed.
spl_lane_issue_post() {
  [[ "$2" =~ ^[0-9a-f]{8}-[0-9a-f-]{27}$ && "$2" != "$(spl_lane_issue_default_topic)" && "${LANE_ISSUE_POST:-1}" != 0 ]] || return 0
  # A workspace topic is the customer's own talk: the issue links it, the
  # fleet posts nothing there for it.
  [[ -z "${SLI_WS:-}" ]] || { do_log "INFO $1 links topic $2 of workspace $SLI_WS; nothing posted there" >&2; return 0; }
  local body="**Planned, not built yet.** Tracked as **$1**: $3 (lane $id)."
  if (( SLI_DRY )); then do_log "INFO DRY_RUN would: post '$body' in topic $2 (as $DESK_AGENT)" >&2; return 0; fi
  # the filing post names its issue, not an ask: DESK_PLANNED_CHECK=0 (SPL-3525)
  DESK_PLANNED_CHECK=0 DESK_TASK="$2" DESK_BODY="$body" DESK_BOX="$SLI_BOX" DRY_RUN=0 RUN_STDOUT_IS_DATA=1 do_spl_desk_reply >/dev/null 2>&1 ||
    do_log "WARN $1 is filed, but posting it back in topic $2 failed: post it by hand" >&2
  return 0
}
