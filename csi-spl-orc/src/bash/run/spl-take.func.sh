#!/bin/bash
#------------------------------------------------------------------------------
# @description Take a human post (SPEC-spool-fleet-roles.md 3): the taker
# @description posts ONE plain line in that topic, to that human, through
# @description do_spl_desk_reply - "Taken by <id>@<box>: <plan>. I post the
# @description result here." - and, in the same call, the optional spool note
# @description to the agents (TAKE_NOTIFY). Before this the take step was a
# @description prompt habit: measured 2026-10-08 (t1 bc1a43e1, n=1) an OD took
# @description a post with a note to the agents only, and the human saw no
# @description reply in the topic until the full answer, much later.
# @description The take line is also the first agent reply in the topic, which
# @description is what makes the taker its owner (spec 3, "The owner record")
# @description and what the unanswered sweep counts as answered.
# @description Idempotent: one take line per (topic, taker). The ledger is
# @description <spool root>/dispatch/take.log ("<epoch> <topic> <id>@<box>
# @description <plan>", tab-separated); a second call for the same pair posts
# @description nothing and exits 0 saying TAKEN-ALREADY. A failed post is not
# @description recorded, so a re-run posts it. Dry run unless DRY_RUN=0.
# @param ENV - required: dev, prd or self (passed on to do_spl_desk_reply)
# @param TENANT_ID - required: the workspace of the topic
# @param DESK_AGENT - required: the taker's agent id (its desk)
# @param DESK_TO - required: the human who wrote the post (HUM-n)
# @param DESK_TASK - required: the full topic uuid
# @param TAKE_PLAN - required: the one-line plan, e.g. "I read the hub logs"
# @param TAKE_BOX (optional) - the taker's box; default this machine's desk box id
# @param TAKE_NOTIFY (optional) - space-separated agent ids told by spool note that DESK_AGENT owns the topic
# @param TAKE_REPLY_CMD (optional) - replaces "<proj>/run -a do_spl_desk_reply" (tests)
# @param TAKE_SEND (optional) - replaces spool-send.sh (tests)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=csitea DESK_AGENT=c-002 DESK_TO=HUM-10 DESK_TASK=<full topic uuid> TAKE_PLAN='I read the hub logs' DRY_RUN=0 ./run -a do_spl_take
#------------------------------------------------------------------------------
do_spl_take() {
  spl_lease_init || return 1
  local agent="${DESK_AGENT:-}" to="${DESK_TO:-}" task="${DESK_TASK:-}" plan="${TAKE_PLAN:-}"
  local box="${TAKE_BOX:-$(spl_desk_box_default)}" f="$LEASE_DIR/take.log"
  [[ "${ENV:-}" =~ ^(dev|prd|self)$ ]] || { do_log "FATAL ENV must be dev, prd or self, got: '${ENV:-}'"; return 1; }
  [[ "${TENANT_ID:-}" =~ ^[A-Za-z0-9_-]+$ ]] || { do_log "FATAL TENANT_ID is required"; return 1; }
  [[ "$agent" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL DESK_AGENT is not an id: '$agent'"; return 1; }
  [[ "$to" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL DESK_TO must be the human who posted (HUM-n), got: '$to'"; return 1; }
  task="${task,,}"
  [[ "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL DESK_TASK must be the full topic uuid, got: '${DESK_TASK:-}'"; return 1; }
  [[ "$box" =~ ^[A-Za-z0-9._-]+$ ]] || { do_log "FATAL TAKE_BOX is not a box id: '$box'"; return 1; }
  plan="$(tr '\t\n\r' '   ' <<<"$plan")"; plan="${plan%% }"; plan="${plan%.}"
  [[ -n "${plan// }" ]] || { do_log "FATAL TAKE_PLAN is required: one line on what you do next"; return 1; }
  (( ${#plan} <= 300 )) || { do_log "FATAL TAKE_PLAN is one line, at most 300 characters (got ${#plan})"; return 1; }
  if [[ "${SPOOL_TEST:-}" == 1 && ( -z "${TAKE_REPLY_CMD:-}" || "$(realpath -m "$LEASE_DIR")" == "$(realpath -m /var/spool-hub/dispatch)" ) ]]; then
    do_log "FATAL SPOOL_TEST=1 needs TAKE_REPLY_CMD and a scratch SPOOL_ROOT: a test never posts for real"; return 96
  fi
  local by="$agent@$box" body
  body="Taken by $by: $plan. I post the result here."
  if spl_take_seen "$f" "$task" "$by"; then
    echo "TAKEN-ALREADY $task by $by: no second take line"; return 0
  fi
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN would post to $to in topic $task ($TENANT_ID): $body"
    [[ -n "${TAKE_NOTIFY:-}" ]] && do_log "INFO DRY_RUN would tell ${TAKE_NOTIFY} by spool note"
    do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to take it."
    return 0
  fi
  local out rc=0
  out="$( (
    flock -w 30 9 || { echo "FATAL could not lock $f.lock"; exit 1; }
    spl_take_seen "$f" "$task" "$by" && { echo "TAKEN-ALREADY $task by $by: no second take line"; exit 3; }
    spl_take_reply "$to" "$task" "$body" >&2 || { echo "FATAL the take line was not posted in $task: nothing recorded, re-run to retry"; exit 1; }
    printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$task" "$by" "$plan" >> "$f" ||
      { echo "FATAL posted, but could not record it in $f"; exit 1; }
    echo "TAKEN $task by $by: $body"
  ) 9> "$f.lock" )" || rc=$?
  echo "$out"
  (( rc == 3 )) && return 0
  (( rc == 0 )) || return 1
  spl_take_notify "$task" "$by" "$to" "$plan"
}

# 0 when the ledger <f> already holds a take of <topic> by <id>@<box>.
spl_take_seen() {
  [[ -f "$1" ]] && awk -F'\t' -v t="$2" -v b="$3" '$2 == t && $3 == b { f = 1 } END { exit !f }' "$1"
}

# The take line, through do_spl_desk_reply (DESK_TO + full DESK_TASK: post
# THERE, no inbox read). The caller's ENV / TENANT_ID / DESK_AGENT / DESK_BOX
# ride along in the environment.
spl_take_reply() {
  local cmd="${TAKE_REPLY_CMD:-$PROJ_PATH/run -a do_spl_desk_reply}"
  # shellcheck disable=SC2086 # a command line, split on purpose
  DESK_TO="$1" DESK_TASK="$2" DESK_BODY="$3" DESK_BODY_FILE="" DESK_KIND=note DRY_RUN=0 \
    timeout "${TAKE_TIMEOUT:-120}" $cmd 9>&-
}

# The spool note to each TAKE_NOTIFY id: who owns the topic now. A failed
# note is a WARN, never a failure: the human already has the take line.
spl_take_notify() {
  local task="$1" by="$2" to="$3" plan="$4" id
  local send="${TAKE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  for id in ${TAKE_NOTIFY:-}; do
    bash "$send" --from "${by%@*}" --to "$id" --kind note --task "$task" \
      --body "TAKEN by $by: $to's post in topic $task; plan: $plan. Do not reply in the topic." >/dev/null 2>&1 ||
      do_log "WARN could not tell $id that $by took $task"
  done
  return 0
}
