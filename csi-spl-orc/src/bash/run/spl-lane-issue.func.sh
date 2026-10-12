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
# @description     A brief line `Kind: answer` (or LANE_ISSUE_ANSWER=1) labels
# @description     a filed issue `answer`: an evaluation or an answer to the owner.
# @description   LANE_ISSUE_OP=discussion (whoever takes a discussion, at its
# @description     first answer; owner Q1A, spec 135 section 9): files the
# @description     discussion's issue, status eval, assignee AGENT_ID, title
# @description     LANE_ISSUE_TITLE, description LANE_ISSUE_TEXT + the topic
# @description     link, under the same card; `answer` label with
# @description     LANE_ISSUE_ANSWER=1. Acks, chatter and announcements file
# @description     none. Prints the key and posts it back in the topic.
# @description   LANE_ISSUE_OP=end (the lane, when it ends without landing):
# @description     status LANE_ISSUE_STATUS (diss, onhold or blocked), a comment
# @description     with LANE_ISSUE_REASON, and lifetime/issue-end.
# @description Landing moves the issue on (the landed-fix rule: a commit on
# @description master that cites the key). Dry run unless DRY_RUN=0.
# @param AGENT_ID - required: the lane's spool id, e.g. c-123
# @param LANE_ISSUE_OP (optional) - place (default) | discussion | end
# @param BRIEF (optional, place) - the brief file; default <spool root>/<id>/lifetime/brief.md
# @param LANE_ISSUE_KEY (optional, place) - an existing key to link, e.g. SPL-123; default the brief's Issue: line
# @param LANE_ISSUE_TOPIC (optional, place) - the discussion's topic id; default the first uuid after "topic" in the brief
# @param LANE_ISSUE_POST (optional, place/discussion) - 0: do not post a filed key back in its topic (default 1)
# @param LANE_ISSUE_ANSWER (optional, place/discussion) - 1: label the filed issue `answer` (an evaluation, an answer to the owner)
# @param LANE_ISSUE_TITLE (required, discussion) - what the work is
# @param LANE_ISSUE_TEXT (optional, discussion) - the owner's words that ask for it
# @param LANE_ISSUE_STATUS (optional, end) - diss (default) | onhold | blocked
# @param LANE_ISSUE_REASON (required, end) - why the lane ends without landing
# @param ENV TENANT_ID (optional) - default LEASE_ENV / LEASE_TENANT of <spool root>/dispatch/lease.conf
# @param DESK_AGENT (optional) - the seated desk that files it; default the first seated of LEASE_MASTER, LEASE_ORCH, LEASE_FAILOVER
# @param DESK_BOX (optional) - default this box's desk box
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example AGENT_ID=c-123 BRIEF=/var/spool-hub/dispatch/x/brief.md DRY_RUN=0 ./run -a do_spl_lane_issue
# @example AGENT_ID=c-002 LANE_ISSUE_OP=discussion LANE_ISSUE_TOPIC=<uuid> LANE_ISSUE_TITLE='Evaluate the runner VM' LANE_ISSUE_ANSWER=1 DRY_RUN=0 ./run -a do_spl_lane_issue
# @example AGENT_ID=c-123 LANE_ISSUE_OP=end LANE_ISSUE_REASON='superseded by c-130' DRY_RUN=0 ./run -a do_spl_lane_issue
#------------------------------------------------------------------------------
do_spl_lane_issue() {
  # shellcheck source=../features/spawn-agents/lib/lane-issue.inc.sh
  . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh" || return 1
  local root="${SPOOL_ROOT:-/var/spool-hub}" id="${AGENT_ID:-}" op="${LANE_ISSUE_OP:-place}" dry=1
  [[ "$id" =~ ^[A-Za-z]{1,3}-[0-9]{2,5}$ ]] || { do_log "FATAL AGENT_ID must be a lane's spool id like c-123, got: '$id'"; return 1; }
  [[ "$op" =~ ^(place|discussion|end)$ ]] || { do_log "FATAL LANE_ISSUE_OP must be place, discussion or end, got: '$op'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_lane_issue_desk "$root" "$dry" || return 1
  "spl_lane_issue_$op" "$root" "$id" "$dry"
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
    for a in $(_sli_conf LEASE_MASTER) $(_sli_conf LEASE_ORCH) $(_sli_conf LEASE_FAILOVER); do
      [[ -d "$SPL_STATE_DIR/desk/$TENANT_ID/$box/spool/$a" ]] && { DESK_AGENT="$a"; break; }
    done
  fi
  if [[ -z "${DESK_AGENT:-}" ]]; then
    (( $2 )) && { DESK_AGENT="<a seated desk>"; return 0; }
    do_log "FATAL no seated desk of the lease (LEASE_MASTER, LEASE_ORCH, LEASE_FAILOVER) on this box in $TENANT_ID: set DESK_AGENT, or seat one with do_spl_desk_up"
    return 1
  fi
  export DESK_AGENT
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
  topic="${LANE_ISSUE_TOPIC:-$(grep -m1 -oiE 'topic[^0-9a-f]{0,40}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$brief" 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f-]{27}$')}"
  if [[ -n "$key" ]]; then
    [[ "$key" =~ ^${LI_KEY_RE}$ ]] || { do_log "FATAL LANE_ISSUE_KEY must be an issue key like SPL-12, got: '$key'"; return 1; }
    spl_lane_issue_assign update --ref "$key" --status wip >/dev/null || return 1
    spl_lane_issue_hub comment --ref "$key" --body "Lane $id placed on $key, status wip.${topic:+ Topic: $(spl_lane_issue_link "$topic")}" >/dev/null || return 1
  else
    [[ -r "$brief" ]] || { do_log "FATAL no issue key and no readable brief to file one from ($brief): pass LANE_ISSUE_KEY=<KEY> or BRIEF=<file>"; return 1; }
    title="$(grep -m1 -E '^#+ ' "$brief" | sed -E 's/^#+ +//; s/^Brief: *//' | cut -c1-200)"
    [[ -n "$title" ]] || { do_log "FATAL the brief $brief has no heading to title the issue with"; return 1; }
    desc="$(mktemp)"
    { spl_lane_issue_card '<new>' "$topic" "$brief" 'the lane starts from its brief'
      awk 'NR > 1 && /^## / { exit } NR > 1 { n += length($0) + 1; if (n > 1500) exit; print }' "$brief"
      printf '\n- Lane: %s\n' "$id"
      [[ -n "$topic" ]] && printf -- '- Topic: %s\n' "$(spl_lane_issue_link "$topic")"
    } >"$desc"
    grep -qiE '^Kind:[[:space:]]*answer[[:space:]]*$' "$brief" && LANE_ISSUE_ANSWER=1
    key="$(spl_lane_issue_file wip "$title" "$desc")" || rc=$?
    (( rc == 0 )) && spl_lane_issue_keyed "$key" "$desc" && spl_lane_issue_post "$key" "$topic" "$title"
    rm -f "$desc"
    (( rc == 0 )) || return 1
  fi
  if (( SLI_DRY )); then do_log "OK DRY_RUN $id -> issue $key (wip); nothing written. Re-run with DRY_RUN=0."; return 0; fi
  mkdir -p "$life" && printf '%s\n' "$key" >"$life/issue" || { do_log "FATAL cannot write $life/issue"; return 1; }
  chmod 0664 "$life/issue" 2>/dev/null
  if [[ -w "$life/brief.md" ]] && ! li_key_from_brief "$life/brief.md" >/dev/null; then printf '\nIssue: %s\n' "$key" >>"$life/brief.md"; fi
  do_log "OK $id carries issue $key (wip)"
}

# spl_lane_issue_file STATUS TITLE DESC_FILE -> the new key ("<new>" in a dry
# run): created with the lane ($id of the caller) assigned, labelled `answer`
# when LANE_ISSUE_ANSWER=1.
spl_lane_issue_file() {
  local out key rc=0
  local -a lab=()
  if [[ "${LANE_ISSUE_ANSWER:-0}" == 1 ]]; then
    spl_lane_issue_label answer || return 1
    lab=(--labels answer)
  fi
  out="$(spl_lane_issue_assign create --title "$2" --description-file "$3" --status "$1" "${lab[@]}")" || return 1
  (( SLI_DRY )) && { echo "<new>"; return 0; }
  key="$(printf '%s' "$out" | python3 -c 'import json,sys
j = [l for l in sys.stdin.read().splitlines() if l.startswith("{")]
r = json.loads(j[-1]).get("result") or {}
r = r.get("issue", r) if isinstance(r, dict) else {}
print(r.get("key", "") if isinstance(r, dict) else "")' 2>/dev/null)" || rc=$?
  [[ $rc -eq 0 && "$key" =~ ^${LI_KEY_RE}$ ]] || { do_log "FATAL the hub filed no key for $id: $out" >&2; return 1; }
  printf '%s\n' "$key"
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
  local id="$2" topic="${LANE_ISSUE_TOPIC:-}" title desc key rc=0
  SLI_DRY="$3"
  [[ "$topic" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL LANE_ISSUE_TOPIC must be the discussion's topic uuid, got: '$topic'"; return 1; }
  title="$(printf '%s' "${LANE_ISSUE_TITLE:-}" | tr '\t\n\r' '   ' | sed 's/^ *//; s/ *$//' | cut -c1-200)"
  [[ -n "$title" ]] || { do_log "FATAL LANE_ISSUE_TITLE must name the work (an evaluation or an answer counts: LANE_ISSUE_ANSWER=1); acks, chatter and announcements file no issue"; return 1; }
  desc="$(mktemp)"
  { spl_lane_issue_card '<new>' "$topic" '' 'the first answer in the topic'
    [[ -n "${LANE_ISSUE_TEXT:-}" ]] && printf '%s\n\n' "$LANE_ISSUE_TEXT"
    printf -- '- Taken by: %s\n- Topic: %s\n' "$id" "$(spl_lane_issue_link "$topic")"
  } >"$desc"
  key="$(spl_lane_issue_file eval "$title" "$desc")" || rc=$?
  (( rc == 0 )) && spl_lane_issue_keyed "$key" "$desc" && spl_lane_issue_post "$key" "$topic" "$title"
  rm -f "$desc"
  (( rc == 0 )) || return 1
  if (( SLI_DRY )); then do_log "OK DRY_RUN topic $topic -> a new issue (eval); nothing filed. Re-run with DRY_RUN=0."; return 0; fi
  printf '%s\n' "$key"
  do_log "OK topic $topic -> issue $key (eval, $id)" >&2
}

spl_lane_issue_end() {
  local root="$1" id="$2" key st="${LANE_ISSUE_STATUS:-diss}" why
  SLI_DRY="$3"
  why="$(printf '%s' "${LANE_ISSUE_REASON:-}" | tr '\t\n\r' '   ' | sed 's/^ *//; s/ *$//')"
  [[ -n "$why" ]] || { do_log "FATAL LANE_ISSUE_REASON must say why $id ends without landing (dropped by its gate, superseded by ...)"; return 1; }
  [[ "$st" =~ ^(diss|onhold|blocked)$ ]] || { do_log "FATAL LANE_ISSUE_STATUS must be diss, onhold or blocked, got: '$st'"; return 1; }
  key="$(li_key_of_agent "$root" "$id")" || { do_log "FATAL $id carries no issue key ($root/$id/lifetime/issue)"; return 1; }
  spl_lane_issue_hub update --ref "$key" --status "$st" >/dev/null || return 1
  spl_lane_issue_hub comment --ref "$key" --body "Lane $id ended without landing ($st): $why" >/dev/null || return 1
  if (( SLI_DRY )); then do_log "OK DRY_RUN $key -> $st; nothing written. Re-run with DRY_RUN=0."; return 0; fi
  printf '%s\t%s\t%s\n' "$st" "$why" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$root/$id/lifetime/issue-end" ||
    { do_log "FATAL cannot write $root/$id/lifetime/issue-end"; return 1; }
  do_log "OK $key -> $st: $why"
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
    spec="$(grep -m1 -oE 'csi-spl-doc/specs/[0-9]{3}-[a-z0-9-]+(/spec\.md)?' "$3")"
    avoid="$(grep -m1 -iE 'not touch' "$3" | sed -E 's/^[-* ]+//' | cut -c1-200)"
  fi
  printf '## Source\n%s\n\n## Restart\n' "$([[ -n "$2" ]] && echo "/t/$2" || echo none)"
  printf -- '- key: %s\n- spec: %s\n- scope: %s\n- must not touch: %s\n' "$1" "${spec:-none}" "$scope" "${avoid:-see the brief}"
  printf -- '- test: see the brief\n- last citing sha: none\n- next: %s\n- open question: none\n- docs: none yet\n\n' "$4"
}

# spl_lane_issue_keyed KEY DESC_FILE: the filed issue's card names its own
# key, unknown until the create. A failure warns: the issue stands.
spl_lane_issue_keyed() {
  (( SLI_DRY )) && return 0
  sed -i "0,/^- key: <new>\$/s//- key: $1/" "$2" &&
    RUN_STDOUT_IS_DATA=1 spl_lane_issue_hub update --ref "$1" --description-file "$2" >/dev/null 2>&1 ||
    do_log "WARN $1 is filed, but its card still says key <new>: spool issue update --ref $1 --description-file <the card>" >&2
  return 0
}

# spl_lane_issue_post KEY TOPIC TITLE: the key, posted back in the topic it
# came from (owner Q4A) by the desk that filed it; LANE_ISSUE_POST=0 skips.
# A failed post warns: the issue stands and the key is printed.
spl_lane_issue_post() {
  [[ -n "$2" && "${LANE_ISSUE_POST:-1}" != 0 ]] || return 0
  local body="Tracked as **$1**: $3 (lane $id)."
  if (( SLI_DRY )); then do_log "INFO DRY_RUN would: post '$body' in topic $2 (as $DESK_AGENT)" >&2; return 0; fi
  DESK_TASK="$2" DESK_BODY="$body" DESK_BOX="$SLI_BOX" DRY_RUN=0 RUN_STDOUT_IS_DATA=1 do_spl_desk_reply >/dev/null 2>&1 ||
    do_log "WARN $1 is filed, but posting it back in topic $2 failed: post it by hand" >&2
  return 0
}
