#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1255: on a workflow 20/30 failure, post one blocker to
# @description #spool-hub-ops naming the run, the failing step, the breaking
# @description commit and the AGENT that landed it. A workflow_run-triggered
# @description job passes the run's fields in; this action builds the post and
# @description sends it through do_spl_desk_post (so it is DRY_RUN=1 and inert
# @description until a seated ops desk exists, like SPL-1254).
# @description The agent id is read from the breaking commit's subject -- our
# @description commits carry a CLE-/GRK-/AGY-/QWN-/SPL- tag, e.g.
# @description "fix(orc, CLE-77793): ..." -- and falls back to the commit author
# @description when no tag is present.
# @param FAIL_RUN_URL - required: the failed run's html_url
# @param FAIL_WORKFLOW (optional) - the workflow name (e.g. "20 ci-cd: ...")
# @param FAIL_SHA (optional) - the breaking commit sha
# @param FAIL_COMMIT_SUBJECT (optional) - its first message line (carries the tag)
# @param FAIL_STEP (optional) - the failing job/step name
# @param FAIL_AUTHOR (optional) - the commit author, the fallback "from"
# @param TENANT_ID / DESK_AGENT / DESK_BOX - required to actually post
# @param DESK_CHANNEL (optional) - default spool-hub-ops
# @param OPS_POST_FN (optional, testing) - the poster; default do_spl_desk_post
# @param DRY_RUN (optional) - 1 (default) or 0
# @example FAIL_RUN_URL=https://github.com/o/r/actions/runs/1 FAIL_SHA=abcd1234 FAIL_COMMIT_SUBJECT='fix(hub, CLE-42): x' DRY_RUN=0 ./run -a do_spl_deploy_failure_post
#------------------------------------------------------------------------------

# Print the agent id a commit subject carries, or empty. First match wins.
_spl_agent_from_subject() {  # <subject>
  printf '%s' "${1:-}" | grep -oiE '\b(CLE|GRK|AGY|QWN|SPL)-[0-9]+\b' | head -1 \
    | tr '[:lower:]' '[:upper:]'
}

do_spl_deploy_failure_post() {
  local url="${FAIL_RUN_URL:-}"
  [[ -n "$url" ]] || { do_log "FATAL FAIL_RUN_URL is required"; return 2; }
  local wf="${FAIL_WORKFLOW:-workflow}" sha="${FAIL_SHA:-}" subj="${FAIL_COMMIT_SUBJECT:-}"
  local step="${FAIL_STEP:-}" author="${FAIL_AUTHOR:-}"
  local short="${sha:0:8}" agent
  agent="$(_spl_agent_from_subject "$subj")"
  [[ -n "$agent" ]] || agent="${author:-unknown}"

  local body=":red_circle: **Deploy workflow failed** — [${wf}](${url}) failed"
  body+="${step:+ at step \`${step}\`}."
  body+="${short:+ Breaking commit \`${short}\`}"
  body+="${subj:+: ${subj}}."
  body+=" From: **${agent}**."

  do_log "INFO deploy-failure: posting a blocker to #${DESK_CHANNEL:-spool-hub-ops} (from ${agent})"
  DESK_CHANNEL="${DESK_CHANNEL:-spool-hub-ops}" DESK_KIND=blocker DESK_BODY="$body" \
    "${OPS_POST_FN:-do_spl_desk_post}"
}
