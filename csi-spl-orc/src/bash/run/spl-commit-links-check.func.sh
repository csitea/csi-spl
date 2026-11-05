#!/bin/bash
#------------------------------------------------------------------------------
# @description The commit-links gate (SPL-4789): every commit of a range
# @description names at least one issue key, and at least one of its keys is
# @description an issue of the owning workspace that links at least one
# @description discussion other than that workspace's default backlog topic.
# @description Owner HUM-10, t1 ef94396b (msg 61bf7791): a commit "must add
# @description at least 1 link for an issue , which was used to justify the
# @description work of the commit and at least 1 discussion where this issue
# @description originated from"; msg dd164168: after this feature lands "the
# @description usage of the unknown hsould be forbidden".
# @description A key is <prefix>-<n> as a whole word, anywhere in the message
# @description (the subject scope `feat(orc, SPL-12): ...`, a `Closes:` or
# @description `Refs:` trailer). The workspace and prefix are cnf
# @description env.hub.commit_issue_tenant / commit_issue_prefix.
# @description Hub-checked through POST /v1/operator/commit-links as the env's
# @description project SA (one call per run). Without a key file for that env
# @description on this box, or from a hub revision without the route, only the
# @description form is checked (a key is named) and the
# @description summary says NOT hub-checked: CI (workflow 25) is the hard gate.
# @description A hub that does not answer fails the check, except with
# @description COMMIT_LINKS_HARD=0 (the pre-push hook): there it WARNs and
# @description checks the form only, and CI checks the links.
# @description Merge commits are skipped (trunk is linear). Prints one line:
# @description   COMMIT_LINKS_CHECK hub=<env|none> range=<a..b> commits=<n> ok=<n> fail=<n>
# @description Exit: 0 every commit passes, 3 one or more refused (each FATAL
# @description names the sha, the missing link and the fix), 1 bad input or
# @description the hub read failed.
# @param COMMIT_LINKS_RANGE (optional) - the commits, default origin/master..HEAD
# @param COMMIT_LINKS_REPO (optional) - the checkout, default $APP_PATH
# @param COMMIT_LINKS_HUB (optional) - dev, prd or none; default prd when this box holds its SA key, else none
# @param COMMIT_LINKS_TENANT (optional) - the issue workspace, default cnf env.hub.commit_issue_tenant
# @param COMMIT_LINKS_PREFIX (optional) - its key prefix, default cnf env.hub.commit_issue_prefix
# @param COMMIT_LINKS_HARD (optional) - 1 (default) a failed hub read fails the check; 0 it WARNs and checks the form only
# @example ./run -a do_spl_commit_links_check
# @example COMMIT_LINKS_RANGE=HEAD~5..HEAD COMMIT_LINKS_HUB=none ./run -a do_spl_commit_links_check
#------------------------------------------------------------------------------
do_spl_commit_links_check() {
  do_require_bin git jq || return 1
  local repo="${COMMIT_LINKS_REPO:-$APP_PATH}" range="${COMMIT_LINKS_RANGE:-origin/master..HEAD}" hub tenant prefix
  hub="$(_spl_cl_hub)" || return 1
  tenant="${COMMIT_LINKS_TENANT:-$(_spl_cl_cnf "$repo" commit_issue_tenant)}"
  prefix="${COMMIT_LINKS_PREFIX:-$(_spl_cl_cnf "$repo" commit_issue_prefix)}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] ||
    { do_log "FATAL no issue workspace: set cnf env.hub.commit_issue_tenant or COMMIT_LINKS_TENANT (got '$tenant')"; return 1; }
  [[ "$prefix" =~ ^[A-Z][A-Z0-9]{0,9}$ ]] ||
    { do_log "FATAL no issue key prefix: set cnf env.hub.commit_issue_prefix or COMMIT_LINKS_PREFIX (got '$prefix')"; return 1; }
  git -C "$repo" rev-list -n0 "$range" >/dev/null 2>&1 || { do_log "FATAL COMMIT_LINKS_RANGE is not a range of $repo: '$range'"; return 1; }
  local -a shas=()
  mapfile -t shas < <(git -C "$repo" rev-list --no-merges --reverse "$range")
  local -A keys=()
  local s k all=""
  for s in "${shas[@]}"; do
    keys[$s]="$(git -C "$repo" log -1 --format=%B "$s" | _spl_cl_keys "$prefix")"
    for k in ${keys[$s]}; do all+="$k"$'\n'; done
  done
  local links='{}'
  if [[ "$hub" != none && -n "$all" ]]; then
    local rc=0
    links="$(_spl_cl_hub_links "$hub" "$tenant" "$(sort -u <<<"$all" | grep .)")" || rc=$?
    case "$rc" in
      0) ;;
      4) do_log "WARN the $hub hub has no /v1/operator/commit-links yet (older revision): the form only"; hub=none links='{}' ;;
      *) [[ "${COMMIT_LINKS_HARD:-1}" == 0 ]] || return 1
         do_log "WARN the $hub hub did not answer (rc $rc): the form only, CI checks the links"; hub=none links='{}' ;;
    esac
  fi
  _spl_cl_verdicts "$repo" "$hub" "$tenant" "$prefix" "$range" "$links" "${shas[@]}"
}

# _spl_cl_verdicts <repo> <hub> <tenant> <prefix> <range> <links json> <sha...>:
# one FATAL per refused commit, the summary line; rc 0 or 3. Reads the
# caller's keys map.
_spl_cl_verdicts() {
  local repo="$1" hub="$2" tenant="$3" prefix="$4" range="$5" links="$6" s why ok=0 bad=0
  shift 6
  for s in "$@"; do
    if why="$(_spl_cl_why "$hub" "$tenant" "$prefix" "${keys[$s]}" "$links")"; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
      do_log "FATAL commit ${s:0:9} \"$(git -C "$repo" log -1 --format=%s "$s" | cut -c1-90)\": $why"
    fi
  done
  local nh=""
  [[ "$hub" == none ]] && nh=" (NOT hub-checked: no prd SA key on this box, COMMIT_LINKS_HUB=none, an older hub or no hub answer; CI checks the links)"
  echo "COMMIT_LINKS_CHECK hub=$hub range=$range commits=$# ok=$ok fail=$bad$nh"
  ((bad == 0)) && return 0
  do_log "INFO the rule and the fixes: csi-spl-doc/specs/016-spool-testability/commit-links.md section 3"
  return 3
}

# _spl_cl_why <hub> <tenant> <prefix> <keys> <links json>: rc 0 the commit
# passes; else the reason and the fix on stdout, rc 1.
_spl_cl_why() {
  local hub="$1" tenant="$2" prefix="$3" ks="$4" links="$5" k f n miss="" nod=""
  if [[ -z "$ks" ]]; then
    echo "names no $prefix-<n> issue key. Cite the issue that justifies it in the subject scope, 'feat(<area>, $prefix-<n>): ...', or a 'Closes: $prefix-<n>' trailer; with no issue yet, file one linked to its discussion: spool issue create --title <t> --discussions <topic id> --epic $prefix-<epic>"
    return 1
  fi
  [[ "$hub" == none ]] && return 0
  for k in $ks; do
    read -r f n < <(jq -r --arg k "$k" '.[$k] // {} | "\(.found // false) \(.discussions // 0)"' <<<"$links")
    [[ "$f" == true && "$n" -gt 0 ]] && return 0
    if [[ "$f" == true ]]; then nod+=" $k"; else miss+=" $k"; fi
  done
  [[ -n "$miss" ]] && echo -n "names${miss} that $tenant has no issue for. "
  [[ -n "$nod" ]] && echo -n "${nod# } links no discussion of its own (only the $tenant backlog topic): spool issue link --ref ${nod##* } --discussion <topic id where it came from>. "
  [[ -z "$nod" ]] && echo -n "Cite an existing $tenant issue, or file one linked to its discussion: spool issue create --title <t> --discussions <topic id> --epic $prefix-<epic>"
  echo
  return 1
}

# _spl_cl_keys <prefix>: the whole-word <prefix>-<n> keys of the message on
# stdin, first appearance order, space-separated.
_spl_cl_keys() {
  grep -oE "(^|[^A-Za-z0-9_-])$1-[1-9][0-9]{0,8}([^A-Za-z0-9_]|\$)" |
    grep -oE "$1-[0-9]+" | awk '!seen[$0]++' | paste -sd' ' -
}

# _spl_cl_cnf <repo> <key>: env.hub.<key> of the rendered prd cnf ("" when absent).
_spl_cl_cnf() {
  local f="$1/csi-spl-cnf/csi-spl/prd.env.json"
  [[ -r "$f" ]] && jq -r --arg k "$2" '.env.hub[$k] // ""' "$f" 2>/dev/null || true
}

# _spl_cl_hub: dev, prd or none. Unset = prd when this box holds the prd
# project's SA key, else none (as the owner-orders gate decides).
_spl_cl_hub() {
  local h="${COMMIT_LINKS_HUB:-}"
  if [[ -z "$h" ]]; then
    h=none
    # shellcheck disable=SC2030 # ENV is the subshell's own
    ( ENV=prd; do_spl_cloud_cnf >/dev/null 2>&1 && do_gcp_sa_key_file "$SPL_CNF" >/dev/null 2>&1 ) && h=prd
  fi
  [[ "$h" =~ ^(dev|prd|none)$ ]] || { do_log "FATAL COMMIT_LINKS_HUB must be dev, prd or none (got '$h')"; return 1; }
  echo "$h"
}

# _spl_cl_hub_links <env> <tenant> <keys, one per line>: the operator check's
# answer as {key: {found, discussions, default_only}}; rc 1 on a failed read
# or an answer that does not parse, 4 when the hub has no such route (a plain
# 404, not the hub's JSON error). Its stdout is the answer alone: the read
# runs with stdout on stderr and writes the answer to fd 3, so no do_log line
# of the cnf, the account pin or the call can reach it (SPL-4832: two INFO
# lines of the pin made every key read as "no issue").
_spl_cl_hub_links() {
  local body
  body="$(jq -cRn --arg t "$2" '{tenant: $t, keys: [inputs | select(length > 0)][:200]}' <<<"$3")" || return 1
  _spl_cl_hub_read "$1" "$body" 3>&1 1>&2
}

# _spl_cl_hub_read <env> <request body>: the hub read; the answer goes to
# fd 3, anything else on stdout lands on stderr (the caller's redirect).
_spl_cl_hub_read() {
  local body="$2"
  (
    # shellcheck disable=SC2031 # ENV is this subshell's own
    ENV="$1"
    do_require_bin yq curl gcloud || exit 1
    do_spl_cloud_cnf || exit 1
    spl_hub_operator_url || exit 1
    do_gcp_pin_account "$SPL_CNF" || exit 1
    spl_hub_operator_call POST /v1/operator/commit-links "$body" || exit 1
    [[ "$SPL_HUB_OP_STATUS" == 404 ]] && ! jq -e .error <<<"$SPL_HUB_OP_BODY" >/dev/null 2>&1 && exit 4
    [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
      { do_log "FATAL POST /v1/operator/commit-links on $1 answered HTTP $SPL_HUB_OP_STATUS: $(jq -r '.message // .error // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"; exit 1; }
    jq -ce '[.keys[] | {key: .key, value: .}] | from_entries' <<<"$SPL_HUB_OP_BODY" >&3 2>/dev/null ||
      { do_log "FATAL POST /v1/operator/commit-links on $1 answered HTTP 200, but its body could not be parsed as the links JSON: $(head -c 200 <<<"$SPL_HUB_OP_BODY")"; exit 1; }
  )
}
