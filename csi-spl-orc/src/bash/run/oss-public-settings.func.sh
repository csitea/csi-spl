#!/bin/bash
#------------------------------------------------------------------------------
# @description Harden the settings of the repo going PUBLIC (spec 044 / SPL-64,
# @description CLE-35070: one repo, everything public, the self-hosted runners
# @description never reachable from a pull request) and prove them. The settings
# @description marked (public) are accepted by GitHub only once the repo is
# @description public, so run it again right after the visibility flip.
# @description   1. no workflow of it triggers on pull_request_target, and no job
# @description      of a pull_request-triggered workflow runs on self-hosted
# @description      (read from the default branch; deploy secrets stay in Actions
# @description      secrets, which GitHub never hands to a fork's run)
# @description   2. the default GITHUB_TOKEN is read-only and cannot approve PRs
# @description   3. (public) a workflow run from a fork pull request needs a
# @description      maintainer's approval for EVERY outside contributor
# @description   4. (public) private vulnerability reporting, secret scanning and
# @description      push protection on
# @description   5. no self-hosted runner is registered on the repo itself, and
# @description      OSS_RUNNER_GROUP (when set) is limited to this repo and to
# @description      named workflows at refs/heads/<default branch> only
# @description Prints one line per check (OK / FAIL / PENDING-PUBLIC). Exit 0 =
# @description every applicable check holds, 1 = one does not.
# @description Dry run unless DRY_RUN=0: then it only READS and reports.
# @param OSS_PUBLIC_REPO - required: <owner>/<repo> of the public product repo
# @param OSS_RUNNER_GROUP (optional) - the org runner group the self-hosted runners are in
# @param DRY_RUN (optional) - 1 (default) or 0
# @example OSS_PUBLIC_REPO=<owner>/<app> OSS_RUNNER_GROUP=<group> ./run -a do_oss_public_settings
#------------------------------------------------------------------------------
do_oss_public_settings() {
  do_require_bin gh || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local pub="${OSS_PUBLIC_REPO:-}" re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
  [[ "$pub" =~ $re ]] || { do_log "FATAL OSS_PUBLIC_REPO must be <owner>/<repo> (no default)"; return 1; }
  local private; private="$(gh api "repos/$pub" --jq .private)" || { do_log "FATAL cannot read $pub"; return 1; }
  local bad=0 x
  _oss_ok() { do_log "OK $*"; }
  _oss_bad() { do_log "ERROR FAIL $*"; bad=1; }

  # 1. no pull_request_target, no pull_request job on self-hosted
  local wf body branch; branch="$(gh api "repos/$pub" --jq .default_branch)"
  for wf in $(gh api "repos/$pub/contents/.github/workflows?ref=$branch" --jq '.[].name'); do
    body="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$pub/contents/.github/workflows/$wf?ref=$branch")" || { _oss_bad "cannot read $wf"; continue; }
    grep -qE '^[[:space:]]*pull_request_target[[:space:]]*:?' <<<"$body" && _oss_bad "$wf triggers on pull_request_target"
    grep -qE '^[[:space:]]*pull_request[[:space:]]*:?' <<<"$body" && grep -q 'self-hosted' <<<"$body" \
      && _oss_bad "$wf runs on pull_request AND names a self-hosted runner"
  done
  ((bad)) || _oss_ok "no workflow on $branch reaches a self-hosted runner from a pull request, none uses pull_request_target"

  # 2. the default token
  ((dry)) || gh api -X PUT "repos/$pub/actions/permissions/workflow" -f default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=false >/dev/null || _oss_bad "cannot set the default workflow permissions"
  x="$(gh api "repos/$pub/actions/permissions/workflow" --jq '"\(.default_workflow_permissions) \(.can_approve_pull_request_reviews)"')"
  [[ "$x" == "read false" ]] && _oss_ok "default GITHUB_TOKEN read-only, cannot approve PRs" || _oss_bad "default workflow permissions: $x"

  # 3. + 4. only on a public repo
  if [[ "$private" == true ]]; then
    do_log "INFO PENDING-PUBLIC fork-PR approval for all outside contributors; private vulnerability reporting; secret scanning + push protection ($pub is private: re-run after the flip)"
  else
    ((dry)) || gh api -X PUT "repos/$pub/actions/permissions/fork-pr-contributor-approval" \
      -f approval_policy=all_external_contributors >/dev/null || _oss_bad "cannot set the fork PR approval policy"
    x="$(gh api "repos/$pub/actions/permissions/fork-pr-contributor-approval" --jq .approval_policy 2>/dev/null)"
    [[ "$x" == all_external_contributors ]] && _oss_ok "a fork PR's workflows wait for approval (all outside contributors)" || _oss_bad "fork PR approval policy: ${x:-unreadable}"
    ((dry)) || gh api -X PUT "repos/$pub/private-vulnerability-reporting" >/dev/null || _oss_bad "cannot enable private vulnerability reporting"
    x="$(gh api "repos/$pub/private-vulnerability-reporting" --jq .enabled 2>/dev/null)"
    [[ "$x" == true ]] && _oss_ok "private vulnerability reporting on" || _oss_bad "private vulnerability reporting: ${x:-unreadable}"
    ((dry)) || gh api -X PATCH "repos/$pub" --input - >/dev/null <<'EOF' || _oss_bad "cannot enable secret scanning"
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
EOF
    x="$(gh api "repos/$pub" --jq '"\(.security_and_analysis.secret_scanning.status) \(.security_and_analysis.secret_scanning_push_protection.status)"')"
    [[ "$x" == "enabled enabled" ]] && _oss_ok "secret scanning + push protection on" || _oss_bad "secret scanning: $x"
  fi

  # 5. runners
  x="$(gh api "repos/$pub/actions/runners" --jq .total_count)"
  [[ "$x" == 0 ]] && _oss_ok "no self-hosted runner registered on $pub itself" || _oss_bad "$x self-hosted runner(s) still registered on $pub (do_oss_runners_move)"
  if [[ -n "${OSS_RUNNER_GROUP:-}" ]]; then
    local org="${pub%%/*}" gid rid bad_wf
    gid="$(gh api "orgs/$org/actions/runner-groups" --jq ".runner_groups[]|select(.name==\"$OSS_RUNNER_GROUP\")|.id")"
    rid="$(gh api "repos/$pub" --jq .id)"
    if [[ -z "$gid" ]]; then _oss_bad "no runner group $OSS_RUNNER_GROUP in $org"
    else
      x="$(gh api "orgs/$org/actions/runner-groups/$gid" --jq '"\(.visibility) \(.restricted_to_workflows)"')"
      [[ "$x" == "selected true" ]] && _oss_ok "runner group $OSS_RUNNER_GROUP: selected repos + selected workflows" || _oss_bad "runner group $OSS_RUNNER_GROUP is '$x', want 'selected true'"
      x="$(gh api "orgs/$org/actions/runner-groups/$gid/repositories" --jq '[.repositories[].id]|join(" ")')"
      [[ "$x" == "$rid" ]] && _oss_ok "runner group $OSS_RUNNER_GROUP serves $pub only" || _oss_bad "runner group $OSS_RUNNER_GROUP repos: $x"
      bad_wf="$(gh api "orgs/$org/actions/runner-groups/$gid" --jq ".selected_workflows[]|select(endswith(\"@refs/heads/$branch\")|not)")"
      [[ -z "$bad_wf" ]] && _oss_ok "runner group $OSS_RUNNER_GROUP: every allowed workflow is pinned to refs/heads/$branch" || _oss_bad "unpinned workflows: $bad_wf"
      x="$(gh api "orgs/$org/actions/runner-groups/$gid/runners" --jq '[.runners[]|select(.status=="online")|.name]|join(" ")')"
      do_log "INFO runner group $OSS_RUNNER_GROUP online: ${x:-none}"
    fi
  fi

  ((bad)) && { do_log "FATAL $pub settings are not all as required"; return 1; }
  do_log "OK $pub settings hold$( [[ "$private" == true ]] && echo ' (public-only checks pending)')"
}
