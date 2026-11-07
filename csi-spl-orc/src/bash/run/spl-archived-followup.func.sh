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
# @description     no `answer` label, not a standing seat's own issue, and every
# @description     other discussion it links is archived too. Never for the
# @description     workspace's default discussion
# @description   a queue row the placer declined because of the archive in the
# @description     last hour (do_spl_spawn_place)
# @description Each such topic gets ONE new discussion in its channel, as the
# @description dispatch lease holder, naming the archived topic and listing what
# @description was left; each issue is linked to it, then unlinked from the
# @description archived one, so a re-run finds nothing more. <state dir>/journal.tsv
# @description keeps the new discussion of a topic, so a crash between the post
# @description and the links never posts twice. A post that fails is named in ONE
# @description blocker to the orchestrator, and retried next run. Test workspaces
# @description are skipped. In fleet mode only the dispatch lease holder's machine
# @description acts. Dry run unless DRY_RUN=0: the plan, nothing posted or linked.
# @param ENV (optional) - dev or prd, default lease.conf LEASE_ENV
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param ARCHIVED_FOLLOWUP_STATE_DIR (optional) - since, journal.tsv, failed.keys; default <spool root>/dispatch/archived-followup
# @param ARCHIVED_FOLLOWUP_ROWS_FILE (optional, tests) - read the rows from this file, not the hub DB
# @param ARCHIVED_FOLLOWUP_POST_CMD (optional, tests) - replaces do_spl_desk_post: TENANT_ID, DESK_AGENT, DESK_CHANNEL, DESK_BODY_FILE in its env, prints its JSON line
# @param ARCHIVED_FOLLOWUP_LINK_CMD (optional, tests) - replaces do_spl_issue_link: TENANT_ID, DESK_AGENT, ISSUE_REF, ISSUE_DISCUSSION, MODE in its env
# @param ARCHIVED_FOLLOWUP_SEND (optional, tests) - the sender script, default spool-send.sh
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
  if (( ! dry )) && spl_lease_remote; then do_log "INFO the fleet's dispatch lease is held by $LH: this machine follows up nothing"; return 0; fi
  AFU_AGENT="$(spl_lease_holder_id)"
  [[ -n "$AFU_AGENT" && "$AFU_AGENT" != none ]] || { do_log "INFO nobody holds the dispatch lease: nothing followed up"; return 0; }
  tmp="$(mktemp -d)" || return 1
  if ! spl_afu_rows "$tmp/rows" "$since"; then rm -rf "$tmp"; return 1; fi
  AFU_DONE=" "
  while IFS=$'\t' read -r tenant topic; do
    [[ -n "$topic" ]] || continue
    spl_test_workspace "$tenant" && continue
    spl_afu_topic "$tmp" "$tenant" "$topic" "$dir" "$dry" || rc=1
  done < <(cut -f2,3 "$tmp/rows" | sort -u)
  key="$(cut -f2,3 "$tmp/rows" | sort -u | grep -c .)"
  do_log "OK $key archived topic(s) with work left since $since"
  rm -rf "$tmp"
  return "$rc"
}

# spl_afu_topic TMP TENANT TOPIC DIR DRY: one archived topic's new discussion
# and its issues' move. An issue moved for another topic this run is left out.
spl_afu_topic() {
  local tmp="$1" tenant="$2" topic="$3" dir="$4" dry="$5" new ref rc=0
  awk -F'\t' -v t="$tenant" -v k="$topic" '$2 == t && $3 == k' "$tmp/rows" >"$tmp/one"
  : >"$tmp/keep"
  while IFS= read -r line; do
    ref="$(cut -f6 <<<"$line")"
    if [[ "$line" == issue$'\t'* && "$AFU_DONE" == *" $tenant:$ref "* ]]; then continue; fi
    printf '%s\n' "$line" >>"$tmp/keep"
  done <"$tmp/one"
  [[ -s "$tmp/keep" ]] || return 0
  new="$(awk -F'\t' -v t="$tenant" -v k="$topic" '$1 == t && $2 == k { n = $3 } END { print n }' "$dir/journal.tsv" 2>/dev/null)"
  if [[ -n "$new" ]] && ! grep -q $'^issue\t' "$tmp/keep"; then return 0; fi
  if ((dry)); then
    do_log "WOULD follow up $tenant topic $topic in ${new:-a new discussion}:"$'\n'"$(cut -f1,6-8 "$tmp/keep")"
    return 0
  fi
  if [[ -z "$new" ]]; then
    new="$(spl_afu_post "$tmp" "$tenant" "$topic")" || { spl_afu_blocker "$tenant" "$topic" "$dir" "$new"; return 1; }
    printf '%s\t%s\t%s\n' "$tenant" "$topic" "$new" >>"$dir/journal.tsv" || do_log "WARN journal not written: $topic -> $new"
    do_log "OK $tenant topic $topic: its work left goes on in $new"
  fi
  while IFS=$'\t' read -r _ _ _ _ _ ref _; do
    AFU_DONE+="$tenant:$ref "
    if spl_afu_link "$tenant" "$ref" "$new" link && spl_afu_link "$tenant" "$ref" "$topic" unlink; then
      do_log "OK $ref moved from $topic to $new"
    else
      do_log "WARN $ref was not moved to $new: the next run tries again"; rc=1
    fi
  done < <(grep $'^issue\t' "$tmp/keep")
  return "$rc"
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
    out="$(cd "$PROJ_PATH" && TENANT_ID="$tenant" DESK_AGENT="$AFU_AGENT" DESK_CHANNEL="$channel" DESK_BODY_FILE="$tmp/body.md" DESK_KIND=note DRY_RUN=0 \
      timeout 120 ./run -a do_spl_desk_post </dev/null 2>&1)"
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
  ( cd "$PROJ_PATH" && TENANT_ID="$1" DESK_AGENT="$AFU_AGENT" ISSUE_REF="$2" ISSUE_DISCUSSION="$3" MODE="$4" DRY_RUN=0 \
      timeout 120 ./run -a do_spl_issue_link </dev/null >/dev/null 2>&1 )
}

# spl_afu_blocker TENANT TOPIC DIR WHY: ONE blocker to the orchestrator per
# topic (failed.keys), so a topic that keeps failing does not repeat every run.
spl_afu_blocker() {
  local k="$1"$'\t'"$2" send="${ARCHIVED_FOLLOWUP_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  do_log "WARN $1 topic $2: no follow-up discussion: $4"
  grep -qxF "$k" "$3/failed.keys" 2>/dev/null && return 0
  if SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$(spl_role_seat 1)" --to orchestrator --kind blocker --task archived-followup \
      --body "**BLOCKER** archived discussion /t/$2 ($1) left work, and its follow-up discussion could not be posted as $AFU_AGENT: $4. The next run tries again; action do_spl_archived_followup (SPL-4955)." >/dev/null 2>&1 8>&- 9>&-; then
    printf '%s\n' "$k" >>"$3/failed.keys"
  else
    do_log "WARN the blocker to the orchestrator was not sent; the next run tries again"
  fi
}

# spl_afu_rows OUT SINCE: kind, tenant, topic, channel, archived at, ref, status,
# text; tab separated, read-only.
spl_afu_rows() {
  if [[ -n "${ARCHIVED_FOLLOWUP_ROWS_FILE:-}" ]]; then
    cp "$ARCHIVED_FOLLOWUP_ROWS_FILE" "$1" || { do_log "FATAL cannot read ARCHIVED_FOLLOWUP_ROWS_FILE $ARCHIVED_FOLLOWUP_ROWS_FILE"; return 1; }
    return 0
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_afu_read "$1" "$2" || { do_log "FATAL could not read the archived topics of $ENV"; return 1; }
}

# The one statement. messages_archived holds only archived rows, so a is small.
_spl_afu_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v since="$2" >/dev/null <<SQL
BEGIN READ ONLY;
SET LOCAL app.rls_scope = 'operator';
\\o $1
WITH a AS MATERIALIZED (
  SELECT tenant_id, task_id, min(archived_at) AS at, max(channel) AS channel FROM messages
   WHERE archived_at > :'since'::timestamptz AND task_id IS NOT NULL GROUP BY 1, 2)
SELECT 'issue', a.tenant_id, a.task_id, coalesce(a.channel, ''), to_char(a.at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
       coalesce(c.prefix, 'SPL') || '-' || i.number, i.status, translate(i.title, E'\t\n\r', '   ')
  FROM a JOIN issue_discussions d ON d.tenant_id = a.tenant_id AND d.task_id = a.task_id
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
       left(f.ask_id, 8), f.state, translate(left(f.summary, 300), E'\t\n\r', '   ')
  FROM a JOIN fleet_asks f ON f.discussion = a.task_id
 WHERE f.state = 'declined' AND f.reason LIKE 'discussion archived%' AND f.updated_at > now() - interval '1 hour';
\\o
COMMIT;
SQL
}
