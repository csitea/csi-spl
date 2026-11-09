#!/bin/bash
#------------------------------------------------------------------------------
# @description What an archived discussion left undone goes on in a new
# @description discussion, by code (SPL-4955; owner HUM-10, msg 51465f86: "if
# @description there is somethign else to be done to create an additional
# @description discussion to complete the tasks on the archived discussion if
# @description there were any"). One read-only operator-scope query lists, for
# @description each topic archived since this box's first run (forward-only:
# @description the older archives are left alone):
# @description   an unfinished issue: linked to the topic, status eval, todo, wip,
# @description     blocked or onhold, not archived, not level 1 (epic, feature),
# @description     no `answer` label, not a standing seat's or a reviewer seat's own
# @description     issue, and every other discussion it links is archived too.
# @description     Never for the workspace's default discussion
# @description   a queue row the placer declined because of the archive in the
# @description     last hour (do_spl_spawn_place), bound by its discussion or by
# @description     its topic, in full or as 8 hex or dispatch-<topic8>
# @description Each such topic gets ONE new discussion in its channel, as the
# @description dispatch lease holder's id, naming the archived topic and listing
# @description what was left; each issue is linked to it, then unlinked from the
# @description archived one, so a re-run finds nothing more. <state dir>/journal.tsv
# @description keeps the new discussion of a topic, so a crash between the post
# @description and the links never posts twice; a row declined after that post is
# @description added to that discussion once (rows.seen). A post that fails is
# @description named in ONE blocker to the orchestrator, and retried next run.
# @description Test workspaces are skipped.
# @description One box acts for a topic: the holder's, when the hub's roster has the
# @description holder's id on it in that workspace, else the first box by name that
# @description has. The desk may be under another user's state root of that box, 0700
# @description (measured 2026-11-07 on one box: t1 under the box user's, two others
# @description only under the agent user's): the box finds the user whose root holds
# @description the live seat (a non-empty pinned, not a stub) and runs the post, the
# @description reply and the links as that user.
# @description With no such box, or no desk on the box the roster names under any
# @description user, the holder's machine or that box names it in ONE blocker and
# @description posts nothing (a desk is seated with the workspace's root key).
# @description A channel the box map holds (channel-rules.tsv: no-auto-post, also a
# @description workspace's * row, or a sole seat that is not the holder here, or a map
# @description that cannot be read, or a malformed column 7): no post, no reply, no
# @description link change, ONE blocker that lists what was left, with its own key, so
# @description an earlier blocker of the topic does not swallow it (SPL-4955; nothing
# @description posts on its own there). A map that is missing or cannot be read is
# @description an ALARM in the log and in the blocker (SPL-5146). A topic already
# @description followed up has a blocker that names its follow-up.
# @description Dry run unless DRY_RUN=0: the plan, nothing posted or linked.
# @param ENV (optional) - dev or prd, default lease.conf LEASE_ENV
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param ARCHIVED_FOLLOWUP_STATE_DIR (optional) - since, journal.tsv, rows.seen, failed.keys; default <spool root>/dispatch/archived-followup
# @param ARCHIVED_FOLLOWUP_ROWS_FILE (optional, tests) - read the rows from this file, not the hub DB
# @param ARCHIVED_FOLLOWUP_POST_CMD (optional, tests) - replaces do_spl_desk_post: TENANT_ID, DESK_AGENT, DESK_CHANNEL, DESK_BODY_FILE in its env, prints its JSON line
# @param ARCHIVED_FOLLOWUP_REPLY_CMD (optional, tests) - replaces do_spl_desk_reply: TENANT_ID, DESK_AGENT, DESK_TASK, DESK_TO, DESK_BODY_FILE in its env
# @param ARCHIVED_FOLLOWUP_LINK_CMD (optional, tests) - replaces do_spl_issue_link: TENANT_ID, DESK_AGENT, ISSUE_REF, ISSUE_DISCUSSION, MODE in its env
# @param ARCHIVED_FOLLOWUP_SEND (optional, tests) - the sender script, default spool-send.sh
# @param SPL_DESK_AS_CMD (optional, tests) - replaces `sudo -n -u`, as in spl_desk_moved_to
# @example ./run -a do_spl_archived_followup
# @example DRY_RUN=0 ./run -a do_spl_archived_followup
#------------------------------------------------------------------------------
do_spl_archived_followup() {
  local dry=1 dir since tmp key rc=0 tenant topic
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_lease_init ro || return 1
  spl_lease_conf
  export ENV="${ENV:-${LEASE_ENV:-}}"
  dir="${ARCHIVED_FOLLOWUP_STATE_DIR:-$LEASE_DIR/archived-followup}"
  if [[ ! -s "$dir/since" ]]; then
    ((dry)) && { do_log "INFO DRY_RUN first run on this box: it would start from now, nothing older is followed up"; return 0; }
    mkdir -p "$dir" && date -u +%Y-%m-%dT%H:%M:%SZ >"$dir/since" || { do_log "FATAL cannot write $dir/since"; return 1; }
    do_log "OK first run on this box: archives from $(cat "$dir/since") on are followed up, nothing older"
    return 0
  fi
  since="$(cat "$dir/since")"
  LH=""; spl_lease_read || true
  AFU_AGENT="$(spl_lease_holder_id)"
  [[ -n "$AFU_AGENT" && "$AFU_AGENT" != none ]] || { do_log "INFO nobody holds the dispatch lease: nothing followed up"; return 0; }
  AFU_BOX="${LEASE_MACHINE:-$(spl_desk_box_default)}"
  AFU_HOLDER_BOX="$AFU_BOX"
  [[ "$LH" == *@* ]] && AFU_HOLDER_BOX="${LH##*@}"
  tmp="$(mktemp -d)" || return 1
  if ! spl_afu_rows "$tmp/rows" "$since"; then
    rm -rf "$tmp"
    spl_lease_remote && { do_log "WARN this box could not read the archived topics; the holder's box $AFU_HOLDER_BOX reports its own"; return 0; }
    return 1
  fi
  AFU_DONE=" "
  while IFS=$'\t' read -r tenant topic; do
    [[ -n "$topic" ]] || continue
    spl_test_workspace "$tenant" && continue
    spl_afu_topic "$tmp" "$tenant" "$topic" "$dir" "$dry" || rc=1
  done < <(cut -f2,3 "$tmp/rows" | sort -u)
  key="$(cut -f2,3 "$tmp/rows" | sort -u | grep -c .)"
  do_log "OK $key archived topic(s) read since $since"
  rm -rf "$tmp"
  return "$rc"
}

# spl_afu_topic TMP TENANT TOPIC DIR DRY: one archived topic's new discussion
# and its issues' move. An issue moved for another topic this run is left out.
spl_afu_topic() {
  local tmp="$1" tenant="$2" topic="$3" dir="$4" dry="$5" new ref rc=0 line seated poster why
  awk -F'\t' -v t="$tenant" -v k="$topic" '$2 == t && $3 == k' "$tmp/rows" >"$tmp/one"
  : >"$tmp/keep"
  while IFS= read -r line; do
    ref="$(cut -f6 <<<"$line")"
    if [[ "$line" == issue$'\t'* && "$AFU_DONE" == *" $tenant:$ref "* ]]; then continue; fi
    if [[ "$line" == row$'\t'* ]] && grep -qxF "$tenant"$'\t'"$topic"$'\t'"$ref" "$dir/rows.seen" 2>/dev/null; then continue; fi
    printf '%s\n' "$line" >>"$tmp/keep"
  done <"$tmp/one"
  [[ -s "$tmp/keep" ]] || return 0
  seated="$(cut -f9 "$tmp/keep" | sed -n 1p)"
  poster="$(spl_afu_poster_box "$seated")"
  if [[ "$poster" != "$AFU_BOX" ]]; then
    do_log "INFO $tenant topic $topic: box $poster follows it up (roster of $AFU_AGENT in $tenant: ${seated:-no box})"
    return 0
  fi
  new="$(awk -F'\t' -v t="$tenant" -v k="$topic" '$1 == t && $2 == k { n = $3 } END { print n }' "$dir/journal.tsv" 2>/dev/null)"
  if why="$(spl_afu_channel_held "$tenant" "$(cut -f4 "$tmp/keep" | sed -n 1p)")"; then
    if ((dry)); then do_log "WOULD name $tenant topic $topic in a blocker, no post: $why"; return 0; fi
    spl_afu_blocker "$tenant" "$topic" "$dir" "$why" "$(spl_afu_held_body "$tenant" "$topic" "$new" "$why" "$tmp/keep")"
    return 0
  fi
  if ! spl_afu_desk_seated "$tenant"; then
    why="no desk for $AFU_AGENT on $AFU_BOX in $tenant under any user of this box, a stub with no pinned key is none (roster: ${seated:-no box}): do_spl_desk_up seats one with the workspace's root key"
    if ((dry)); then do_log "WOULD name $tenant topic $topic in a blocker: $why"; return 0; fi
    spl_afu_blocker "$tenant" "$topic" "$dir" "$why"
    return 0
  fi
  if ((dry)); then
    do_log "WOULD follow up $tenant topic $topic from $AFU_BOX${AFU_DESK_USER:+ as $AFU_DESK_USER} in ${new:-a new discussion}:"$'\n'"$(cut -f1,6-8 "$tmp/keep")"
    return 0
  fi
  if [[ -z "$new" ]]; then
    new="$(spl_afu_post "$tmp" "$tenant" "$topic")" || { spl_afu_blocker "$tenant" "$topic" "$dir" "$new"; return 1; }
    printf '%s\t%s\t%s\n' "$tenant" "$topic" "$new" >>"$dir/journal.tsv" || do_log "WARN journal not written: $topic -> $new"
    do_log "OK $tenant topic $topic: its work left goes on in $new"
    spl_afu_rows_seen "$tmp/keep" "$dir"
  elif grep -q $'^row\t' "$tmp/keep"; then
    spl_afu_late_rows "$tmp" "$tenant" "$topic" "$new" "$dir" || rc=1
  fi
  while IFS= read -r line; do
    ref="$(cut -f6 <<<"$line")"
    AFU_DONE+="$tenant:$ref "
    if spl_afu_link "$tenant" "$ref" "$new" link && spl_afu_link "$tenant" "$ref" "$topic" unlink; then
      do_log "OK $ref moved from $topic to $new"
    else
      do_log "WARN $ref was not moved to $new: the next run tries again"; rc=1
    fi
  done < <(grep $'^issue\t' "$tmp/keep")
  return "$rc"
}

# spl_afu_poster_box SEATED -> the one box that acts for a topic. SEATED: the
# boxes of the hub's roster with the holder's id in the workspace, sorted, so
# every box reads the same answer. None: the holder's, which names it.
spl_afu_poster_box() {
  if [[ -z "$1" || ",$1," == *",$AFU_HOLDER_BOX,"* ]]; then printf '%s' "$AFU_HOLDER_BOX"
  else printf '%s' "${1%%,*}"; fi
}

# spl_afu_channel_held TENANT CHANNEL: 0 and why, when nothing posts on its own in
# that channel (the box map, channel-rules.inc.sh). 1 = free. Fails closed.
spl_afu_channel_held() {
  local rc seat fault
  declare -F cr_no_auto_post >/dev/null ||
    source "$PROJ_PATH/src/bash/features/spawn-agents/lib/channel-rules.inc.sh" ||
    { echo "the channel rules lib cannot be read"; return 0; }
  rc=0; cr_no_auto_post "$1" "$2" || rc=$?
  (( rc == 0 )) && { echo "the box map holds #$2 of $1 from automatic posts"; return 0; }
  if (( rc == 2 )); then
    fault="$(cr_map_fault)"
    if [[ -n "$fault" ]]; then echo "ALARM this box's channel rules map, $(cr_map), is $fault, so #$2 of $1 reads as held"
    else echo "this box cannot tell the rule of #$2 of $1 from its channel rules map, $(cr_map)"; fi
    return 0
  fi
  rc=0; seat="$(cr_sole_seat "$1" "$2" 2>/dev/null)" || rc=$?
  (( rc == 2 )) && { echo "cannot tell the sole seat of #$2 of $1"; return 0; }
  (( rc == 0 )) && [[ "$seat" != "$AFU_AGENT@$AFU_BOX" ]] && { echo "#$2 of $1 has a sole seat, $seat"; return 0; }
  return 1
}

# spl_afu_held_body TENANT TOPIC NEW WHY ROWS: the blocker of a held topic. NEW:
# the follow-up it already has, which gets nothing more.
spl_afu_held_body() {
  local head="left work, and no follow-up is posted"
  [[ -z "$3" ]] || head="already has its follow-up, /t/$3, and what it left since is not added there"
  printf '%s' "**BLOCKER** archived discussion /t/$2 ($1) $head: $4. Nothing was posted or linked, and this is not repeated. What was left, for a person or the channel's seat to carry: $(spl_afu_left "$5"). Action do_spl_archived_followup (SPL-4955)."
}

# spl_afu_left ROWS: what a topic left, on one line, at most 20 items.
spl_afu_left() {
  awk -F'\t' 'NR <= 20 { printf "%s%s (%s): %s", (NR > 1 ? "; " : ""), $6, $7, substr($8, 1, 120) } END { if (NR > 20) printf "; and %d more", NR - 20 }' "$1"
}

# spl_afu_desk_seated TENANT: 0 when a user of this box has the holder's desk
# there, in every root of spl_desk_roots. A seat with no pinned key is a stub
# (SPL-4699), the hub refuses it: bad_sig, so it is no desk. AFU_DESK_USER: that
# user when it is not this one; a root the caller cannot enter is read as in
# spl_desk_moved_to.
spl_afu_desk_seated() {
  local me l u d
  local -a as=() roots=() live=()
  AFU_DESK_USER=""
  me="$(id -un)"
  [[ -n "${SPL_STATE_DIR:-}" ]] || do_spl_desk_cnf >/dev/null 2>&1
  read -r -a as <<<"${SPL_DESK_AS_CMD:-sudo -n -u}"
  mapfile -t roots < <(spl_desk_roots)
  for l in "${roots[@]}"; do
    u="${l%%$'\t'*}" d="${l#*$'\t'}/desk/$1/$AFU_BOX"
    live=(test -s "$d/pinned" -a -d "$d/spool/$AFU_AGENT")
    if [[ "$u" == "$me" ]]; then
      "${live[@]}" && return 0
    elif "${live[@]}" 2>/dev/null || "${as[@]}" "$u" "${live[@]}" </dev/null 2>/dev/null; then
      AFU_DESK_USER="$u"; return 0
    fi
  done
  return 1
}

# spl_afu_run ACTION VAR=value...: a desk action, as the user who has the desk.
spl_afu_run() {
  local action="$1" k
  shift
  if [[ -z "${AFU_DESK_USER:-}" ]]; then
    ( cd "$PROJ_PATH" && env "$@" DRY_RUN=0 timeout 120 ./run -a "$action" </dev/null )
    return
  fi
  local -a as=() pass=(HOME="$(getent passwd "$AFU_DESK_USER" 2>/dev/null | cut -d: -f6)" PATH="$PATH" ENV="$ENV")
  read -r -a as <<<"${SPL_DESK_AS_CMD:-sudo -n -u}"
  for k in SPOOL_ROOT SPOOL_TEST SPOOL_BOX_ENV SPL_PRIVATE_CNF; do
    [[ -n "${!k:-}" ]] && pass+=("$k=${!k}")
  done
  "${as[@]}" "$AFU_DESK_USER" -- env "${pass[@]}" "$@" DRY_RUN=0 bash -c 'cd "$1" && exec timeout 120 ./run -a "$2"' _ "$PROJ_PATH" "$action" </dev/null
}

# spl_afu_rows_seen ROWS DIR: its queue rows are listed in the new discussion.
spl_afu_rows_seen() {
  awk -F'\t' -v OFS='\t' '$1 == "row" { print $2, $3, $6 }' "$1" >>"$2/rows.seen" || do_log "WARN rows.seen not written"
}

# spl_afu_late_rows TMP TENANT TOPIC NEW DIR: rows declined after the follow-up
# was posted are added to it, once. A reply names a human: the archived topic's
# last. With none the row stays with the note its sender and the holder had.
spl_afu_late_rows() {
  local tmp="$1" tenant="$2" topic="$3" new="$4" dir="$5" human
  human="$(cut -f10 "$tmp/keep" | sed -n 1p)"
  if [[ -z "$human" ]]; then
    do_log "WARN $tenant topic $topic has no human to answer: its late row reaches only its sender and the holder"
    spl_afu_rows_seen "$tmp/keep" "$dir"
    return 0
  fi
  { printf 'From archived discussion /t/%s.\n' "$topic"; spl_afu_body_rows "$tmp/keep"; } >"$tmp/reply.md"
  if [[ -n "${ARCHIVED_FOLLOWUP_REPLY_CMD:-}" ]]; then
    TENANT_ID="$tenant" DESK_AGENT="$AFU_AGENT" DESK_TASK="$new" DESK_TO="$human" DESK_BODY_FILE="$tmp/reply.md" $ARCHIVED_FOLLOWUP_REPLY_CMD >/dev/null 2>&1
  else
    spl_afu_run do_spl_desk_reply TENANT_ID="$tenant" DESK_AGENT="$AFU_AGENT" DESK_BOX="$AFU_BOX" DESK_TASK="$new" DESK_TO="$human" DESK_BODY="$(cat "$tmp/reply.md")" DESK_KIND=note >/dev/null 2>&1
  fi || { do_log "WARN $tenant topic $topic: its late row was not added to $new: the next run tries again"; return 1; }
  spl_afu_rows_seen "$tmp/keep" "$dir"
  do_log "OK $tenant topic $topic: its late row is added to $new"
}

# spl_afu_post TMP TENANT TOPIC -> the new discussion's id. Posts in the
# archived topic's channel; prints why on failure.
spl_afu_post() {
  local tmp="$1" tenant="$2" topic="$3" channel out new
  channel="$(cut -f4 "$tmp/keep" | sed -n 1p)"
  [[ -n "$channel" ]] || { echo "the topic has no channel"; return 1; }
  spl_afu_body "$tmp/keep" "$topic" >"$tmp/body.md"
  if [[ -n "${ARCHIVED_FOLLOWUP_POST_CMD:-}" ]]; then
    out="$(TENANT_ID="$tenant" DESK_AGENT="$AFU_AGENT" DESK_CHANNEL="$channel" DESK_BODY_FILE="$tmp/body.md" $ARCHIVED_FOLLOWUP_POST_CMD 2>&1)"
  else
    out="$(spl_afu_run do_spl_desk_post TENANT_ID="$tenant" DESK_AGENT="$AFU_AGENT" DESK_BOX="$AFU_BOX" DESK_CHANNEL="$channel" DESK_BODY="$(cat "$tmp/body.md")" DESK_KIND=note 2>&1)"
  fi
  new="$(grep -E '^\{' <<<"$out" | tail -1 | jq -r '.send.task_id // empty' 2>/dev/null)"
  [[ "$new" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || { tail -1 <<<"$out" | cut -c1-200; return 1; }
  printf '%s' "$new"
}

# spl_afu_body ROWS TOPIC: the new discussion's text, at most 40 lines of work.
spl_afu_body() {
  printf '## Left over from an archived discussion\n\n'
  printf 'Discussion /t/%s was archived at %s with work not finished. It goes on here.\n' "$2" "$(cut -f5 "$1" | sed -n 1p)"
  if grep -q $'^issue\t' "$1"; then
    printf '\n**Issues moved here**\n\n'
    awk -F'\t' '$1 == "issue" && ++n <= 40 { printf "- %s (%s): %s\n", $6, $7, $8 } END { if (n > 40) printf "- and %d more\n", n - 40 }' "$1"
  fi
  spl_afu_body_rows "$1"
}

spl_afu_body_rows() {
  if grep -q $'^row\t' "$1"; then
    printf '\n**Queued work that was not placed**\n\n'
    awk -F'\t' '$1 == "row" && ++n <= 40 { printf "- ask %s: %s\n", $6, $8 } END { if (n > 40) printf "- and %d more\n", n - 40 }' "$1"
  fi
}

# spl_afu_link TENANT REF DISCUSSION MODE: the hub's issue link or unlink.
spl_afu_link() {
  if [[ -n "${ARCHIVED_FOLLOWUP_LINK_CMD:-}" ]]; then
    TENANT_ID="$1" DESK_AGENT="$AFU_AGENT" ISSUE_REF="$2" ISSUE_DISCUSSION="$3" MODE="$4" $ARCHIVED_FOLLOWUP_LINK_CMD >/dev/null 2>&1
    return
  fi
  spl_afu_run do_spl_issue_link TENANT_ID="$1" DESK_AGENT="$AFU_AGENT" DESK_BOX="$AFU_BOX" ISSUE_REF="$2" ISSUE_DISCUSSION="$3" MODE="$4" >/dev/null 2>&1
}

# spl_afu_blocker TENANT TOPIC DIR WHY [BODY]: ONE blocker to the orchestrator per
# topic (failed.keys), so a topic that keeps failing does not repeat every run. A
# BODY is the held one: it lists what was left, so it has its own key.
spl_afu_blocker() {
  local k="$1"$'\t'"$2" send="${ARCHIVED_FOLLOWUP_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  [[ -z "${5:-}" ]] || k+=$'\theld'
  if [[ -n "${5:-}" ]]; then do_log "WARN $1 topic $2: held, nothing posted or linked: $4"
  else do_log "WARN $1 topic $2: no follow-up discussion: $4"; fi
  grep -qxF "$k" "$3/failed.keys" 2>/dev/null && return 0
  if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$(spl_role_seat 1)" --to orchestrator --kind blocker --task archived-followup \
      --body "${5:-**BLOCKER** archived discussion /t/$2 ($1) left work, and its follow-up discussion could not be posted as $AFU_AGENT: $4. The next run tries again; action do_spl_archived_followup (SPL-4955).}" >/dev/null 2>&1 8>&- 9>&-; then
    printf '%s\n' "$k" >>"$3/failed.keys"
  else
    do_log "WARN the blocker to the orchestrator was not sent; the next run tries again"
  fi
}

# spl_afu_work_left ROWS: drops a reviewer seat's issue. Its brief reviews work
# that has its own issue, so it has nothing to continue (SPL-4238, SPL-4303:
# "Seat brief: R7 review of spec 155"). Only the brief's own heading counts: a
# bug about the review gate is work.
spl_afu_work_left() {
  awk -F'\t' '!($1 == "issue" && tolower($8) ~ /^(seat|lane) brief: *r7 review/)' "$1" >"$1.left" && mv "$1.left" "$1"
}

# spl_afu_rows OUT SINCE: kind, tenant, topic, channel, archived at, ref, status,
# text, the boxes of the roster with the holder's id there, the topic's last
# human; tab separated, read-only.
spl_afu_rows() {
  if [[ -n "${ARCHIVED_FOLLOWUP_ROWS_FILE:-}" ]]; then
    cp "$ARCHIVED_FOLLOWUP_ROWS_FILE" "$1" || { do_log "FATAL cannot read ARCHIVED_FOLLOWUP_ROWS_FILE $ARCHIVED_FOLLOWUP_ROWS_FILE"; return 1; }
    spl_afu_work_left "$1"
    return
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_afu_read "$1" "$2" "$AFU_AGENT" || { do_log "FATAL could not read the archived topics of $ENV"; return 1; }
  spl_afu_work_left "$1"
}

# The one statement. messages_archived holds only archived rows, so a is small.
_spl_afu_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v since="$2" -v agent="$3" >/dev/null <<SQL
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
\\o $1
WITH a AS MATERIALIZED (
  SELECT tenant_id, task_id, min(archived_at) AS at, max(channel) AS channel FROM messages
   WHERE archived_at > :'since'::timestamptz AND task_id IS NOT NULL GROUP BY 1, 2),
b AS MATERIALIZED (
  SELECT a.*, coalesce((SELECT string_agg(r.box_id, ',' ORDER BY r.box_id) FROM roster r WHERE r.tenant_id = a.tenant_id AND r.agent_id = :'agent'), '') AS seated,
         coalesce((SELECT m.from_id FROM messages m WHERE m.tenant_id = a.tenant_id AND m.task_id = a.task_id AND m.from_id LIKE 'HUM-%' ORDER BY m.ts DESC LIMIT 1), '') AS human
    FROM a)
SELECT 'issue', a.tenant_id, a.task_id, coalesce(a.channel, ''), to_char(a.at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
       coalesce(c.prefix, 'SPL') || '-' || i.number, i.status, translate(i.title, E'\t\n\r', '   '), a.seated, a.human
  FROM b a JOIN issue_discussions d ON d.tenant_id = a.tenant_id AND d.task_id = a.task_id
  JOIN issues i ON i.tenant_id = d.tenant_id AND i.number = d.number
  LEFT JOIN issue_counters c ON c.tenant_id = i.tenant_id
 WHERE a.task_id <> issue_discussion_default(a.tenant_id) AND i.archived_at IS NULL
   AND i.status IN ('eval', 'todo', 'wip', 'blocked', 'onhold') AND i.kind NOT IN ('epic', 'feature')
   AND NOT ('answer' = ANY (i.labels))
   AND i.title !~* 'standing .*seat'
   AND NOT EXISTS (SELECT 1 FROM issue_discussions o WHERE o.tenant_id = d.tenant_id AND o.number = d.number AND o.task_id <> d.task_id
        AND NOT EXISTS (SELECT 1 FROM messages z WHERE z.tenant_id = o.tenant_id AND z.task_id = o.task_id AND z.archived_at IS NOT NULL))
UNION ALL
SELECT 'row', a.tenant_id, a.task_id, coalesce(a.channel, ''), to_char(a.at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
       left(f.ask_id, 8), f.state, translate(left(f.summary, 300), E'\t\n\r', '   '), a.seated, a.human
  FROM b a JOIN fleet_asks f ON f.discussion::text IN (a.task_id::text, left(a.task_id::text, 8)) OR f.topic IN (a.task_id::text, 'dispatch-' || left(a.task_id::text, 8))
 WHERE f.state = 'declined' AND f.reason LIKE 'discussion archived%' AND f.updated_at > now() - interval '1 hour';
\\o
COMMIT;
SQL
}
