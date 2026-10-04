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
# @description   6. (spec 072 A60) a trunk ruleset on the default branch: no
# @description      force-push, no deletion, a pull request needs one approving
# @description      review and wf 11's checks; repo admins (the fleet's push
# @description      identity) and OSS_TRUSTED_TEAM (trusted contributors, who
# @description      develop on trunk) bypass it. Everyone else forks and opens
# @description      a pull request. Written only with DRY_RUN=0 AND
# @description      OSS_SET_RULESET=1: an outward-facing setting, owner's go.
# @description Prints one line per check (OK / FAIL / PENDING-PUBLIC). Exit 0 =
# @description every applicable check holds, 1 = one does not.
# @description Dry run unless DRY_RUN=0: then it only READS and reports.
# @param OSS_PUBLIC_REPO - required: <owner>/<repo> of the public product repo
# @param OSS_RUNNER_GROUP (optional) - the org runner group the self-hosted runners are in
# @param OSS_TRUSTED_TEAM (optional) - org team slug whose members bypass the trunk ruleset
# @param OSS_RULESET_NAME (optional) - the ruleset's name, default "trunk"
# @param OSS_SET_RULESET (optional) - 1 writes the trunk ruleset (needs DRY_RUN=0)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example OSS_PUBLIC_REPO=<owner>/<app> OSS_RUNNER_GROUP=<group> ./run -a do_oss_public_settings
# @example DRY_RUN=0 OSS_SET_RULESET=1 OSS_PUBLIC_REPO=<owner>/<app> OSS_TRUSTED_TEAM=<team> ./run -a do_oss_public_settings
#------------------------------------------------------------------------------
# The checks a pull request must pass for the trunk ruleset: wf 11's one job
# "gate" calls wf 10, so each check run is "gate / <wf 10 job name>". The
# matrix e2e shards and gate-health (runs only on a failure) are left out.
# oss-public-settings.tst.sh fails when one of these stops matching wf 10/11.
oss_ruleset_checks() {
  printf '%s\n' \
    "gate / hub: gofmt, go vet, go test, smoke, Postgres + GCS gates" \
    "gate / wui: unit tests + typecheck" \
    "gate / iac: tfvars parity, step contracts, terraform validate" \
    "gate / orc: hermetic action tests (stubbed gcloud/curl/docker)" \
    "gate / cnf: conf-validator exit codes" \
    "gate / spool source carries no ysg-box reference" \
    "gate / sec: gitleaks, trivy config, checkov (read-only)" \
    "gate / distribution-hygiene sweep over the tree"
}

# <name> <team id or empty> - the ruleset body. RepositoryRole 5 = admin;
# integration 15368 = GitHub Actions, so only an Actions run satisfies a check.
oss_ruleset_body() {
  jq -n --arg name "$1" --arg team "${2:-}" --argjson checks "$(oss_ruleset_checks | jq -R . | jq -s .)" '{
    name: $name, target: "branch", enforcement: "active",
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    bypass_actors: ([{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]
      + (if $team == "" then [] else [{actor_id: ($team|tonumber), actor_type: "Team", bypass_mode: "always"}] end)),
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "pull_request", parameters: {required_approving_review_count: 1,
        dismiss_stale_reviews_on_push: true, require_code_owner_review: false,
        require_last_push_approval: false, required_review_thread_resolution: false}},
      {type: "required_status_checks", parameters: {strict_required_status_checks_policy: false,
        required_status_checks: ($checks | map({context: ., integration_id: 15368}))}}]}'
}

# <team id or empty> <default branch>, ruleset JSON on stdin - one line per
# gap, nothing when the ruleset holds
oss_ruleset_gaps() {
  jq -r --arg team "${1:-}" --arg branch "$2" --argjson checks "$(oss_ruleset_checks | jq -R . | jq -s .)" '
    def rule(t): [.rules[]? | select(.type == t)][0];
    (if .enforcement != "active" then "enforcement is \(.enforcement), not active" else empty end),
    (if ((.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH" or . == "refs/heads/\($branch)" or . == "~ALL")) | not
      then "does not target \($branch)" else empty end),
    (if rule("deletion") == null then "deletion is allowed" else empty end),
    (if rule("non_fast_forward") == null then "force-push is allowed" else empty end),
    (if ((rule("pull_request").parameters.required_approving_review_count // 0) < 1)
      then "a pull request needs no approving review" else empty end),
    ([(rule("required_status_checks").parameters.required_status_checks // [])[].context] as $have
      | $checks[] | select(. as $c | $have | index($c) | not) | "check not required: \(.)"),
    (if ([.bypass_actors[]? | select(.actor_type == "RepositoryRole" and .actor_id == 5)] | length) == 0
      then "repo admins (the fleet push identity) cannot bypass" else empty end),
    (if $team != "" and ([.bypass_actors[]? | select(.actor_type == "Team" and (.actor_id|tostring) == $team)] | length) == 0
      then "trusted team \($team) cannot bypass" else empty end)'
}

do_oss_public_settings() {
  do_require_bin gh || return 1
  do_require_bin jq || return 1
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
    grep -qE '^[[:space:]]*pull_request[[:space:]]*:?' <<<"$body" && grep -qE '^[[:space:]]*runs-on:.*self-hosted' <<<"$body" \
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

  # 6. the trunk ruleset (spec 072 A60)
  local rs_name="${OSS_RULESET_NAME:-trunk}" team="" rs_id gaps set_rs=0
  ((dry)) || [[ "${OSS_SET_RULESET:-0}" != 1 ]] || set_rs=1
  if [[ -n "${OSS_TRUSTED_TEAM:-}" ]]; then
    team="$(gh api "orgs/${pub%%/*}/teams/$OSS_TRUSTED_TEAM" --jq .id 2>/dev/null)"
    [[ "$team" =~ ^[0-9]+$ ]] || { _oss_bad "no team $OSS_TRUSTED_TEAM in ${pub%%/*} (OSS_TRUSTED_TEAM)"; team=""; }
  else
    do_log "INFO OSS_TRUSTED_TEAM unset: only repo admins bypass the $rs_name ruleset"
  fi
  rs_id="$(gh api "repos/$pub/rulesets" --jq ".[]|select(.name==\"$rs_name\")|.id")" || { _oss_bad "cannot read the rulesets of $pub"; rs_id=""; }
  if ((set_rs)); then
    if [[ -z "$rs_id" ]]; then
      oss_ruleset_body "$rs_name" "$team" | gh api -X POST "repos/$pub/rulesets" --input - >/dev/null || _oss_bad "cannot create the $rs_name ruleset"
      rs_id="$(gh api "repos/$pub/rulesets" --jq ".[]|select(.name==\"$rs_name\")|.id")"
    else
      oss_ruleset_body "$rs_name" "$team" | gh api -X PUT "repos/$pub/rulesets/$rs_id" --input - >/dev/null || _oss_bad "cannot update the $rs_name ruleset"
    fi
  fi
  if [[ -z "$rs_id" ]]; then
    _oss_bad "no $rs_name ruleset on $branch: force-push, deletion and unreviewed merges are open (DRY_RUN=0 OSS_SET_RULESET=1 writes it)"
  else
    gaps="$(gh api "repos/$pub/rulesets/$rs_id" | oss_ruleset_gaps "$team" "$branch")" || gaps="cannot read ruleset $rs_id"
    if [[ -z "$gaps" ]]; then _oss_ok "master ruleset $rs_name: no force-push, no deletion, 1 review + wf 11 checks on a pull request, admins${team:+ and team $OSS_TRUSTED_TEAM} bypass"
    else while IFS= read -r x; do _oss_bad "$rs_name ruleset: $x"; done <<<"$gaps"; fi
  fi

  ((bad)) && { do_log "FATAL $pub settings are not all as required"; return 1; }
  do_log "OK $pub settings hold$( [[ "$private" == true ]] && echo ' (public-only checks pending)')"
}
