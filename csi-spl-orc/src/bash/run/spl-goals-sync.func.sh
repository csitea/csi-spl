#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 112 4.2 / 12.2 / 12.4 (ORC-2): the deploy-time goal sync.
# @description Reads every csi-spl-doc/goals/<id>-<slug>/goal.yaml and PUTs ONE
# @description batch to the hub's /v1/calendar/sync (HUB-2), where each goal
# @description and each event names the goal's own `workspace`:
# @description   goals[]  {id, workspace, approval {msg_id}} (the hub checks it)
# @description   goal:<Gnn>:deadline  kind goal, all-day, with the goal's
# @description                        `specs` and `done_lines` (WUI-3 reads them)
# @description   goal:<Gnn>:m:<key>   kind milestone, all-day, one per milestone
# @description Every event carries roadmap_url
# @description /roadmap?ws=<ws>&goal=<Gnn>#spec-<first spec>, which the hub
# @description stores as props.roadmap_url. The batch sends NO audience: HUB-2
# @description sets internal or public from the workspace's roadmap switch and
# @description answers 400 to a goal: key that carries one.
# @description A goal without `workspace` (or with a bad id / deadline) fails
# @description the run BEFORE any call. No goal.yaml at all is a no-op, rc 0.
# @description Idempotent: the hub upserts by (workspace, source_key), so a
# @description second run of the same tree adds 0 events.
# @description Authenticated as the env's project service account (operator id
# @description token, spl_hub_operator_call), never the owner account.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): print the batch, call nothing; 0: PUT it
# @param GOALS_DIR (optional) - default $APP_PATH/csi-spl-doc/goals
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev ./run -a do_spl_goals_sync
# @example ENV=prd DRY_RUN=0 ./run -a do_spl_goals_sync
#------------------------------------------------------------------------------
do_spl_goals_sync() {
  spl_require_cloud_env || return 1
  do_require_bin yq jq || return 1
  local dir="${GOALS_DIR:-${APP_PATH:-}/csi-spl-doc/goals}" d n
  local -a files=()
  [[ -d "$dir" ]] || { do_log "FATAL GOALS_DIR is not a directory: '$dir'"; return 1; }
  mapfile -t files < <(find "$dir" -mindepth 2 -maxdepth 2 -name goal.yaml -type f | LC_ALL=C sort)
  ((${#files[@]})) || { do_log "INFO no goal.yaml under $dir: nothing to sync in $ENV"; return 0; }
  d="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$d'; trap - RETURN" RETURN
  spl_goals_sync_body "${files[@]}" >"$d/body.json" || return 1
  n="$(jq '.events | length' "$d/body.json")"
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    cat "$d/body.json"
    do_log "INFO DRY_RUN: ${#files[@]} goal(s), $n event(s) for $ENV, nothing sent (DRY_RUN=0 sends them)" >&2
    return 0
  fi
  spl_goals_sync_put "$d/body.json" "${#files[@]}" "$n"
}

# spl_goals_sync_put <body.json> <goals> <events>: the one PUT, as the env SA.
spl_goals_sync_put() {
  local body="$1" w
  do_require_bin curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_hub_operator_call PUT /v1/calendar/sync "@$body" || return 1
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
    { do_log "FATAL PUT /v1/calendar/sync answered HTTP $SPL_HUB_OP_STATUS: $(jq -r '.message // .error // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null) ($2 goal(s), $3 event(s) not written)"; return 1; }
  while IFS= read -r w; do do_log "$w"; done < <(jq -r '.unapproved // [] | .[] | "WARN goal \(.id) of workspace \(.workspace) is not approved, no event written: \(.reason)"' <<<"$SPL_HUB_OP_BODY")
  do_log "OK $2 goal(s), $3 event(s) synced in $ENV ($GCP_ACCOUNT): $(jq -c '{created, updated, unchanged, deleted, carried}' <<<"$SPL_HUB_OP_BODY")"
}

# spl_goals_sync_body <goal.yaml>...: the sync body {goals, events} on stdout.
# Every goal is checked first; one bad goal fails the whole body (and so the
# run, before any call), naming its file.
spl_goals_sync_body() {
  local f g err
  local -a goals=()
  for f in "$@"; do
    g="$(yq -o=json '.' "$f" 2>/dev/null)" || { do_log "FATAL $f is not YAML"; return 1; }
    err="$(jq -r "$(spl_goals_sync_check_jq)" <<<"$g" 2>/dev/null)" || { do_log "FATAL $f is not a goal mapping"; return 1; }
    [[ -z "$err" ]] || { do_log "FATAL $f: $err; nothing sent"; return 1; }
    goals+=("$g")
  done
  printf '%s\n' "${goals[@]}" | jq -c -s "$(spl_goals_sync_body_jq)"
}

# spl_goals_sync_check_jq: a goal object -> "" when it can be sent, else why.
spl_goals_sync_check_jq() {
  cat <<'JQ'
def day: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
def slug($re): type == "string" and test($re);
if type != "object" then error("not a mapping")
elif (.id | slug("^G[0-9]{2}-[a-z0-9-]{1,48}$") | not) then "id must be G<nn>-<slug>, got: \(.id)"
elif (.workspace | slug("^[a-z0-9][a-z0-9-]{0,31}$") | not) then "goal \(.id) is missing 'workspace' (a workspace slug, required, no default)"
elif (.deadline | day | not) then "goal \(.id): deadline must be YYYY-MM-DD"
elif any((.milestones // [])[]; (.key | slug("^[a-z0-9-]{1,32}$") | not) or (.date | day | not)) then "goal \(.id): every milestone needs key [a-z0-9-]{1,32} and date YYYY-MM-DD"
elif has("audience") then "goal \(.id) carries 'audience': the workspace's roadmap switch sets it, never the repo"
else "" end
JQ
}

# spl_goals_sync_body_jq: the goal objects (slurped) -> {goals, events}; the
# keys, titles and dates are HUB-3's for a goal doc (roadmap_goal_docs.go).
spl_goals_sync_body_jq() {
  cat <<'JQ'
def at: . + "T00:00:00Z";
def spec_id: tostring | if test("^[0-9]+$") then ("000" + .)[-3:] else . end;
{goals: map({id, workspace, approval: {msg_id: ((.approval.msg_id // "") | tostring)}}),
 events: [.[] | .id as $id | .workspace as $ws | ($id[0:3]) as $g | ((.specs // []) | map(spec_id)) as $specs
   | ("/roadmap?ws=\($ws)&goal=\($g)" + (if ($specs | length) > 0 then "#spec-\($specs[0])" else "" end)) as $url
   | {source_key: "goal:\($g):deadline", workspace: $ws, title: "\($id) deadline", kind: "goal",
      starts_at: (.deadline | at), ends_at: (.deadline | at), all_day: true, roadmap_url: $url,
      specs: $specs, done_lines: ((.done_lines // []) | map(tostring))},
     ((.milestones // [])[] | .key as $k
      | {source_key: "goal:\($g):m:\($k)", workspace: $ws, title: ((.title // "") | if . == "" then "\($id) \($k)" else . end),
         kind: "milestone", starts_at: (.date | at), ends_at: (.date | at), all_day: true, roadmap_url: $url})]}
JQ
}
