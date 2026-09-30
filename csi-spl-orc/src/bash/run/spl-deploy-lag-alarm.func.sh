#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1254: the deploy-lag alarm. Run do_check_deploy_lag for an
# @description env, and post to #spool-hub-ops ONLY on a verdict EDGE, so the
# @description channel gets one alarm per lag episode and one recovery, never a
# @description post every 10 minutes while it stays lagging. Per env+component
# @description (hub, wui) the served-vs-trunk verdict is folded to ok
# @description (current/pending) or lag (lagging); unknown is left alone so a
# @description flapping endpoint does not flap the channel. The last folded
# @description verdict per key is kept in a state file; a change ok->lag posts a
# @description blocker, lag->ok posts a recovery note, same->same is silent.
# @description Stateless CI passes the restored state in and reads it back out
# @description (the workflow caches it); the box cron keeps it on disk.
# @description The post goes through do_spl_desk_post, so it is DRY_RUN=1 (prints
# @description what it would post) until a seated ops desk exists and DRY_RUN=0.
# @param ENV - required: dev or prd
# @param TENANT_ID - required to actually post: the tenant the ops desk is in
# @param DESK_AGENT - required to actually post: the CI ops agent id
# @param DESK_BOX (optional) - default box-desk; the seated ops box
# @param DESK_CHANNEL (optional) - default spool-hub-ops
# @param GRACE_MINUTES (optional) - passed to do_check_deploy_lag (default 45)
# @param OPS_STATE_FILE (optional) - the per-key verdict state (default
# @param   $XDG_CACHE_HOME/csi-spl/deploy-lag-alarm.state)
# @param OPS_LAG_CMD (optional, testing) - the lag-check command; default the
# @param   real './run -a do_check_deploy_lag'. Must print '<env> <component>
# @param   <verdict> <details...>' lines.
# @param OPS_POST_FN (optional, testing) - the post function; default
# @param   do_spl_desk_post. Reads DESK_* from the environment.
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DESK_AGENT=SPL-CI DESK_BOX=box-ci DRY_RUN=0 ./run -a do_spl_deploy_lag_alarm
#------------------------------------------------------------------------------
do_spl_deploy_lag_alarm() {
  local env="${ENV:-}"
  [[ -n "$env" ]] || { do_log "FATAL ENV is required (dev or prd)"; return 2; }
  local state="${OPS_STATE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/deploy-lag-alarm.state}"
  local chan="${DESK_CHANNEL:-spool-hub-ops}"
  local post_fn="${OPS_POST_FN:-do_spl_desk_post}"
  mkdir -p "$(dirname "$state")" 2>/dev/null || true
  [[ -f "$state" ]] || : >"$state"

  # Collect the per-component verdicts. The default command is the real action;
  # a test injects its own. We only read stdout, never its exit code, because we
  # act per-component, not on the worst-of.
  local out
  if [[ -n "${OPS_LAG_CMD:-}" ]]; then
    out="$(ENV="$env" GRACE_MINUTES="${GRACE_MINUTES:-45}" bash -c "$OPS_LAG_CMD" 2>/dev/null)"
  else
    out="$(ENV="$env" GRACE_MINUTES="${GRACE_MINUTES:-45}" do_check_deploy_lag 2>/dev/null)"
  fi

  local posted=0 line comp verdict rest key fold prev
  while IFS= read -r line; do
    # <env> <component> <verdict> <details...>
    [[ "$line" =~ ^"$env"[[:space:]]+([a-z]+)[[:space:]]+([a-z]+)[[:space:]]*(.*)$ ]] || continue
    comp="${BASH_REMATCH[1]}"; verdict="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    case "$verdict" in
      lagging)          fold=lag ;;
      current|pending)  fold=ok  ;;
      *)                continue ;;   # unknown: never flap the channel
    esac
    key="${env}/${comp}"
    prev="$(sed -n "s|^${key}=||p" "$state" | tail -1)"
    [[ -z "$prev" ]] && prev=ok      # first sight of a key is treated as ok
    if [[ "$fold" == "$prev" ]]; then continue; fi   # no edge -> silent

    local kind body
    if [[ "$fold" == lag ]]; then
      kind=blocker
      body=":rotating_light: **Deploy lag** — \`${env}\` **${comp}** is lagging. ${rest}"
    else
      kind=note
      body=":white_check_mark: **Recovered** — \`${env}\` **${comp}** is current again. ${rest}"
    fi
    do_log "INFO ops-alarm: ${key} ${prev} -> ${fold}: posting a ${kind} to #${chan}"
    DESK_CHANNEL="$chan" DESK_KIND="$kind" DESK_BODY="$body" "$post_fn" || {
      do_log "FATAL ops-alarm: post for ${key} FAILED -- state not advanced so the next run retries"
      return 1
    }
    posted=$((posted + 1))
    # advance the state only after a successful post
    { grep -v "^${key}=" "$state" 2>/dev/null; printf '%s=%s\n' "$key" "$fold"; } >"$state.tmp" && mv "$state.tmp" "$state"
  done <<< "$out"

  do_log "INFO ops-alarm: ${env} done, ${posted} edge post(s)"
  return 0
}
