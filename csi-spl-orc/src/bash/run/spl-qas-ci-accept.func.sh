#!/bin/bash
#------------------------------------------------------------------------------
# @description Accept UI-only qas issues on a passing CI browser proof (owner,
# @description t1 0f2ed820 msg e768eb42: "Yes, passing could be counted as
# @description approved"). The rule, as code:
# @description   1. the proof run: the newest completed workflow-10 run on
# @description      master whose "wui: browser e2e" shards ALL concluded
# @description      success, on a sha that dev AND prd serve (each env's
# @description      /build.json commit contains it)
# @description   2. per qas issue (scripts/qas-ci-accept.py): UI-only = a plain
# @description      issue whose commits (key in the subject scope,
# @description      "feat(wui, SPL-992): ...") touch only <org-app>-wui/, .github/ and
# @description      <org-app>-doc/, all of them in the proof sha; linked = a
# @description      CI browser test (tests/e2e/*.test.mjs, not ci-skip.txt) in
# @description      that tree names the key, or the description has a line
# @description      "ci-proof: <file>.test.mjs"
# @description   3. each match gets a comment naming the run id, the sha and the
# @description      test, then moves to done; every other issue stays in qas
# @description      with its reason in the report
# @description Prints one TSV row per qas issue (key, moved | would-move | kept,
# @description detail) and a summary line. Reads the issue list, gh and
# @description build.json even with DRY_RUN=1; writes only with DRY_RUN=0.
# @param ENV - required: dev or prd, the hub of the issues
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent that comments and moves (the pane's id)
# @param DESK_BOX (optional) - default the box's desk (spl_desk_box_default)
# @param QAS_REF (optional) - the trunk ref the commits are read from, default origin/master
# @param QAS_FETCH (optional) - 1 (default) fetches QAS_REF's remote first, 0 does not
# @param QAS_WORKFLOW (optional) - the CI workflow file, default 10_ci-quality.yml
# @param QAS_RUN_SCAN (optional) - how many recent runs to look through, default 30
# @param QAS_LIVE_ENVS (optional) - the envs that must serve the proof sha, default "dev prd"
# @param QAS_BUILD_URL_DEV QAS_BUILD_URL_PRD (optional) - override https://<env.dns.fqdn>/build.json
# @param GH_TOKEN (optional) - when gh has no login: else read from $HOME/.github/token (spl_brx_gh_auth)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ./run -a do_spl_qas_ci_accept
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 DRY_RUN=0 ./run -a do_spl_qas_ci_accept
#------------------------------------------------------------------------------
do_spl_qas_ci_accept() {
  do_require_bin git gh jq curl python3 || return 1
  local dry=1 oa ref="${QAS_REF:-origin/master}" list plan live run sha
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  oa="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"; oa="${oa%-orc}"
  if [[ "${QAS_FETCH:-1}" == 1 && "$ref" == */* ]]; then
    git -C "$APP_PATH" fetch -q "${ref%%/*}" "${ref#*/}" || { do_log "FATAL git fetch $ref failed"; return 1; }
  fi
  live="$(spl_qas_live_commits "$oa")" || return 1
  spl_brx_gh_auth
  read -r run sha < <(spl_qas_proof_run "$live") || true
  [[ -n "${run:-}" ]] || { do_log "FATAL no completed ${QAS_WORKFLOW:-10_ci-quality.yml} run of the last ${QAS_RUN_SCAN:-30} has every wui browser e2e shard green on a sha live on ${QAS_LIVE_ENVS:-dev prd}: nothing moves"; return 1; }
  do_log "INFO proof run $run sha ${sha:0:12}, live: $(tr '\n' ' ' <<<"$live")"
  list="$(mktemp)"; plan="$(mktemp)"
  spl_issue_list_fetch --status qas --limit 500 >"$list" || { rm -f "$list" "$plan"; return 1; }
  python3 "$PROJ_PATH/src/bash/scripts/qas-ci-accept.py" "$list" "$APP_PATH" "$ref" "$sha" "$oa" >"$plan" ||
    { do_log "FATAL qas-ci-accept.py failed"; rm -f "$list" "$plan"; return 1; }
  rm -f "$list"
  spl_qas_apply "$plan" "$dry" "$run" "$sha" "$live"
  local rc=$?
  rm -f "$plan"
  return $rc
}

# spl_qas_live_commits ORG_APP -> one "<env> <commit>" line per QAS_LIVE_ENVS,
# the commit each env's /build.json serves; it must be in this checkout.
spl_qas_live_commits() {
  local oa="$1" e url var c fqdn
  for e in ${QAS_LIVE_ENVS:-dev prd}; do
    var="QAS_BUILD_URL_${e^^}"
    url="${!var:-}"
    if [[ -z "$url" ]]; then
      fqdn="$(jq -r '.env.dns.fqdn // ""' "$APP_PATH/$oa-cnf/$oa/$e.env.json" 2>/dev/null)"
      [[ -n "$fqdn" ]] || { do_log "FATAL no env.dns.fqdn in $oa-cnf/$oa/$e.env.json" >&2; return 1; }
      url="https://$fqdn/build.json"
    fi
    c="$(curl -fsS --max-time 15 -H "Cache-Control: no-cache" "$url" 2>/dev/null | jq -r '.commit // ""' 2>/dev/null)"
    [[ "$c" =~ ^[0-9a-f]{40}$ ]] || { do_log "FATAL $url serves no commit" >&2; return 1; }
    git -C "$APP_PATH" cat-file -e "$c^{commit}" 2>/dev/null || { do_log "FATAL $e serves $c, not in this checkout: fetch first" >&2; return 1; }
    printf '%s %s\n' "$e" "$c"
  done
}

# spl_qas_proof_run LIVE -> "<run id> <sha>": the newest completed run whose
# sha every live commit contains and whose wui browser e2e shards all passed.
spl_qas_proof_run() {
  local live="$1" id sha c ok verdict
  local runs
  runs="$(cd "$APP_PATH" && gh run list --workflow "${QAS_WORKFLOW:-10_ci-quality.yml}" --branch master \
    --limit "${QAS_RUN_SCAN:-30}" --json databaseId,headSha,status \
    --jq '.[] | select(.status == "completed") | "\(.databaseId) \(.headSha)"')" ||
    { do_log "FATAL gh run list failed" >&2; return 1; }
  while read -r id sha; do
    [[ -n "$id" ]] || continue
    ok=1
    while read -r _ c; do
      git -C "$APP_PATH" merge-base --is-ancestor "$sha" "$c" 2>/dev/null || { ok=0; break; }
    done <<<"$live"
    (( ok )) || continue
    verdict="$(cd "$APP_PATH" && gh api "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100" \
      --jq '[.jobs[] | select(.name | startswith("wui: browser e2e")) | .conclusion] | "\(length) \(map(select(. == "success")) | length)"')" || continue
    read -r n s <<<"$verdict"
    [[ "${n:-0}" -gt 0 && "$n" == "$s" ]] || continue
    printf '%s %s\n' "$id" "$sha"
    return 0
  done <<<"$runs"
  return 1
}

# spl_qas_apply PLAN DRY RUN SHA LIVE: comment + move each "move" row; print
# the report. A failed move is reported and the others still run.
spl_qas_apply() {
  local plan="$1" dry="$2" run="$3" sha="$4" live="$5" key verdict a b moved=0 kept=0 failed=0
  while IFS=$'\t' read -r key verdict a b; do
    [[ -n "$key" ]] || continue
    if [[ "$verdict" != move ]]; then
      printf '%s\tkept\t%s\n' "$key" "$a"; kept=$((kept + 1)); continue
    fi
    if (( dry )); then
      printf '%s\twould-move\trun %s sha %s test %s\n' "$key" "$run" "${sha:0:12}" "$a"; moved=$((moved + 1)); continue
    fi
    if spl_qas_move "$key" "$run" "$sha" "$a" "$b" "$live"; then
      printf '%s\tmoved\trun %s sha %s test %s\n' "$key" "$run" "${sha:0:12}" "$a"; moved=$((moved + 1))
    else
      printf '%s\tkept\tthe move failed (see the log)\n' "$key"; failed=$((failed + 1))
    fi
  done <"$plan"
  do_log "OK qas CI accept: $moved $( ((dry)) && echo would-move || echo moved), $kept kept, $failed failed (run $run, sha ${sha:0:12})"
  (( failed == 0 ))
}

# spl_qas_move KEY RUN SHA TEST COMMIT LIVE: the audit comment, then status done.
spl_qas_move() {
  local key="$1" run="$2" sha="$3" test="$4" commit="$5" live="$6" body
  body="Accepted on a passing CI browser proof (owner rule, t1 0f2ed820 msg e768eb42), by do_spl_qas_ci_accept.

- run: $run (${QAS_WORKFLOW:-10_ci-quality.yml}, every wui browser e2e shard green)
- sha: $sha, live: $(awk '{printf "%s%s %s", (NR > 1 ? ", " : ""), $1, substr($2, 1, 12)}' <<<"$live")
- test: $test
- UI-only: every commit with $key in its subject scope touches only the wui (and docs or CI config); the newest is ${commit:0:12}"
  spl_desk_issue_run comment --ref "$key" --body "$body" >/dev/null || return 1
  spl_desk_issue_run update --ref "$key" --status "done" >/dev/null || return 1
}
