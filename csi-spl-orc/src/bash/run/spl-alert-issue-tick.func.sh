#!/bin/bash
#------------------------------------------------------------------------------
# @description A new alert gets its prio 1 issue and ONE read-only investigator
# @description lane; its repeats fold into the open issue (SPL-4828, spec 146
# @description "An alert files its issue"; owner HUM-10, t1 6c9aa54b msg 84726fdc "BUILD" on
# @description the c-002 proposal f520f8bb). Code, no model. Each tick reads
# @description three sources since the last tick: the #alerts topics (`spool
# @description topics --channel alerts`, as the orch holder through this
# @description box's desk), do_gcp_list_alert_incidents (csi-spl-iac) and the
# @description disk notes (task disk-headroom of the local spool). The fold
# @description (src/bash/scripts/alert-issue-fold.py) gives each alert a
# @description fingerprint: its text with digits, times, ids and the severity
# @description word stripped, plus the box (a disk note: box + mount + blocks
# @description or inodes; a GCP incident: env + policy), so the WARN and the
# @description CRITICAL of one mount are one fingerprint. Then, per fingerprint:
# @description   - its issue is open: ONE comment with the count, no lane
# @description   - no issue: file it prio 1 (do_spl_issue_create, the epic and
# @description     spec below) and enqueue ONE lane (do_spl_ask_put, then
# @description     do_spl_spawn_enqueue SPAWN_CLASS=bug SPAWN_PLACE=claude:<slug>)
# @description     with a generated read-only brief in <spool root>/dispatch/briefs/
# @description   - its issue is done: reopened (todo + a comment + a lane) only
# @description     for an alert newer than the fix (the committer time of the
# @description     newest origin/master commit that closes the key, by the
# @description     closer's own rule, issue-close-landed.py --keys), else held
# @description   - at most one lane per fingerprint per 24 h and 3 a day; over
# @description     a cap the issue is still filed, with no lane
# @description Runs only on the machine whose agent holds the orch role
# @description (<spool root>/dispatch/lease.orch), so the fleet files once; a
# @description live tick reads lease.orch again after its reads and before each
# @description issue it files or reopens, and stops filing when the role moved.
# @description The state is ONE file, <spool root>/dispatch/alert-issue/state.json
# @description (a dry run keeps its own state.dry.json): `jq . <file>` reads it.
# @description A dry run (the default) reads the sources and prints one PLAN
# @description line per action; it files, comments and enqueues nothing.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param ALERT_ISSUE (optional) - 0 turns the tick off, default 1 (also lease.conf)
# @param ALERT_ISSUE_EVERY_S (optional) - at most one tick per this many seconds, default 300
# @param ALERT_ISSUE_LANES_PER_DAY (optional) - lanes in any 24 h, fleet-wide, default 3
# @param ALERT_ISSUE_LANE_GAP_S (optional) - seconds between two lanes of one fingerprint, default 86400
# @param ALERT_ISSUE_FIRST_SINCE_S (optional) - how far a first tick reads back, default 5400
# @param ALERT_ISSUE_EPIC (optional) - the epic of a filed issue, default SPL-2364 (also lease.conf)
# @param ALERT_ISSUE_SPEC (optional) - the spec of a filed issue, default csi-spl-doc/specs/146-reliability-round
# @param ALERT_ISSUE_DISCUSSION (required when DRY_RUN=0) - the topic (a lowercase UUID) a disk or GCP alert's issue links; an #alerts alert links its own topic (also lease.conf)
# @param ALERT_ISSUE_GCP (optional) - 0 skips the GCP incident read, default 1
# @param ALERT_ISSUE_HOLDER (optional) - the orch holder <ID>@<box> (the asks tick passes it); default lease.orch
# @param ALERT_ISSUE_BOX (optional) - this machine's box id, default spl_desk_box_default
# @param ALERT_ISSUE_ALERTS_CMD ALERT_ISSUE_DISK_CMD ALERT_ISSUE_GCP_CMD (optional, tests) - replace a source read: print its raw output
# @param ALERT_ISSUE_RUN (optional, tests) - replaces ./run for the issue, ask and enqueue actions
# @param ALERT_ISSUE_GIT_DIR (optional) - the checkout whose origin/master proves a fix, default the repo of this tree
# @param ALERT_ISSUE_NOW (optional, tests) - epoch seconds
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_alert_issue_tick
# @example ALERT_ISSUE_DISCUSSION=6c9aa54b-f876-4ff5-951a-a74f17166904 DRY_RUN=0 ./run -a do_spl_alert_issue_tick
# @example jq . /var/spool-hub/dispatch/alert-issue/state.json
#------------------------------------------------------------------------------
do_spl_alert_issue_tick() {
  local root dir now st src plan rc=0
  root="${SPOOL_ROOT:-/var/spool-hub}"; dir="$root/dispatch/alert-issue"
  spl_ai_conf "$root"
  [[ "${ALERT_ISSUE:-1}" == 1 ]] || { do_log "INFO alert issue tick off (ALERT_ISSUE=0)"; return 0; }
  AI_DRY="${DRY_RUN:-1}"
  if [[ "$AI_DRY" == 0 && ! "${ALERT_ISSUE_DISCUSSION:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    do_log "FATAL ALERT_ISSUE_DISCUSSION must be a topic id (a lowercase UUID) for a live run: the issue of a disk or GCP alert links it"
    return 1
  fi
  spl_ai_holder_here || return 0
  spl_ai_moved && return "$AI_HOP_RC"
  mkdir -p "$dir" || return 1
  exec 6>>"$dir/.lock"
  flock -n 6 || { exec 6>&-; return 0; }
  now="${ALERT_ISSUE_NOW:-$(date +%s)}"
  st="$dir/state.json"; [[ "$AI_DRY" == 0 ]] || st="$dir/state.dry.json"
  if ! spl_ai_due "$st" "$now"; then exec 6>&-; return 0; fi
  src="$(mktemp -d)" || return 1
  spl_ai_read_sources "$src" "$st" "$now"
  # the desk the hub reads and writes go through; a dry run reads without one
  AI_DESK=1; spl_ai_desk || AI_DESK=0
  if [[ "$AI_DRY" == 0 && "$AI_DESK" == 0 ]]; then rm -rf "$src"; exec 6>&-; return 1; fi
  spl_ai_issues "$src" "$st" >"$src/issues.json"
  plan="$(python3 "$PROJ_PATH/src/bash/scripts/alert-issue-fold.py" plan "$src" "$st" "$now" "$src/issues.json")" ||
    { do_log "ERROR the alert fold failed: nothing filed"; rm -rf "$src"; exec 6>&-; return 1; }
  jq -c '.state' <<<"$plan" >"$src/state.json"
  # the orch role can move during the reads (minutes: GCP 180 s, each hub
  # read 120 s): re-read lease.orch before any write
  if ! spl_ai_holder_still; then
    do_log "INFO the orch role moved during this tick: nothing filed, the window does not move"
    rm -rf "$src"; exec 6>&-; return 0
  fi
  spl_ai_apply "$src" "$plan" || rc=1
  # a failed action's alerts must be read again: the window does not move
  if (( rc != 0 )); then
    jq -c --argjson w "$(( $(cat "$src/since") + 900 ))" '.window_from = $w' "$src/state.json" >"$src/state.json.new" &&
      mv "$src/state.json.new" "$src/state.json"
  fi
  mv "$src/state.json" "$st" || rc=1
  spl_ai_summary "$plan"
  rm -rf "$src"; exec 6>&-
  return "$rc"
}

# ALERT_ISSUE* from the lease.conf for the keys not already set. Read, never sourced.
spl_ai_conf() {
  local f="$1/dispatch/lease.conf" k v
  [[ -f "$f" ]] || return 0
  while IFS='=' read -r k v; do
    [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v"
  done < <(grep -E '^ALERT_ISSUE(_DISCUSSION|_EPIC|_DRY_RUN|_LANES_PER_DAY)?=[A-Za-z0-9-]+$' "$f")
  return 0
}

# spl_ai_moved: 0 when the lease's desk moved and the whole tick just re-ran
# as its owner, whose rc is in AI_HOP_RC; 1 when it runs here. The asks tick
# starts this tick from the fleet lease loop, which stays the box user's, and
# spl_ai_desk, the status reads and every filing need the desk (spec 069 8.4,
# R7 W1 of SPL-4985 by c-369). The owner reads the GCP source with its own HOME.
spl_ai_moved() {
  local ENV="${ENV:-}" TENANT_ID="${TENANT_ID:-}" box hop_to v
  local -a vars=(APP_PATH ORG APP)
  spl_lane_issue_where "$root" >/dev/null 2>&1 || return 1
  box="${DESK_BOX:-$(spl_desk_box_default)}"
  hop_to="$(spl_desk_action_hop_to "$TENANT_ID" "$box")" || return 1
  while read -r v; do vars+=("$v"); done < <(compgen -v ALERT_ISSUE)
  AI_HOP_RC=0
  spl_desk_action_hop do_spl_alert_issue_tick "$hop_to" "$TENANT_ID" "$box" "${DESK_AGENT:-}" "${vars[@]}" || AI_HOP_RC=$?
}

# 0 when this machine's agent holds the orch role. AI_HOLDER = <ID>@<box>.
spl_ai_holder_here() {
  local h="${ALERT_ISSUE_HOLDER:-}" box
  [[ -n "$h" || ! -r "$root/dispatch/lease.orch" ]] || read -r h _ <"$root/dispatch/lease.orch"
  box="${ALERT_ISSUE_BOX:-$(spl_desk_box_default 2>/dev/null)}"
  case "$h" in
    ''|none@*|unknown:*) do_log "INFO no orchestrator holds the orch role: no alert is filed"; return 1 ;;
  esac
  if [[ "${h##*@}" != "$box" ]]; then
    do_log "INFO the orch role is held on ${h##*@} ($h): its machine files the alerts"
    return 1
  fi
  AI_HOLDER="$h"
}

# A live run's re-check before a write: lease.orch read again (the holder
# the asks tick passed is the one of the tick's start); with no lease.orch
# the holder it was given. A dry run writes nothing: always 0.
spl_ai_holder_still() {
  [[ "$AI_DRY" == 0 ]] || return 0
  if [[ -r "$root/dispatch/lease.orch" ]]; then ALERT_ISSUE_HOLDER='' spl_ai_holder_here; else spl_ai_holder_here; fi
}

# 0 when ALERT_ISSUE_EVERY_S passed since the state's last tick.
spl_ai_due() {
  local last
  last="$(jq -r '.last_tick // 0' "$1" 2>/dev/null)" || last=0
  (( $2 - ${last:-0} >= ${ALERT_ISSUE_EVERY_S:-300} ))
}

# The three sources, each into its file; a failed read is a WARN, never a stop.
spl_ai_read_sources() {
  local src="$1" last since_m
  last="$(jq -r '.window_from // .last_tick // 0' "$2" 2>/dev/null)" || last=0
  # no state, or a stale one (this box was not the holder): read back
  # ALERT_ISSUE_FIRST_SINCE_S at most; the holder that was filed the rest
  if (( ${last:-0} <= 0 )) || spl_ai_stale "$2" "$3"; then
    (( ${last:-0} >= $3 - ${ALERT_ISSUE_FIRST_SINCE_S:-5400} )) || last=$(( $3 - ${ALERT_ISSUE_FIRST_SINCE_S:-5400} ))
  fi
  since_m=$(( ($3 - last) / 60 + 15 ))
  (( since_m <= 1440 )) || since_m=1440
  # a 15 min overlap for a post the hub synced late; the seen refs dedupe it
  printf '%s\n' "$(( last - 900 ))" >"$src/since"
  spl_ai_src alerts "$src/alerts.json" "${ALERT_ISSUE_ALERTS_CMD:-spl_ai_read_alerts}"
  spl_ai_src disk "$src/disk.ndjson" "${ALERT_ISSUE_DISK_CMD:-spl_ai_read_disk}"
  [[ "${ALERT_ISSUE_GCP:-1}" == 1 ]] &&
    AI_SINCE="${since_m}m" spl_ai_src gcp "$src/gcp.txt" "${ALERT_ISSUE_GCP_CMD:-spl_ai_read_gcp}"
  return 0
}

# 0 when the state is missing or its last tick is older than 2 x
# ALERT_ISSUE_EVERY_S: this box was not the holder, the hub knows better.
spl_ai_stale() {
  local last
  last="$(jq -r '.last_tick // 0' "$1" 2>/dev/null)" || last=0
  (( $2 - ${last:-0} > 2 * ${ALERT_ISSUE_EVERY_S:-300} ))
}

spl_ai_src() {  # NAME FILE CMD...
  # shellcheck disable=SC2086 # a command line, split on purpose
  ${3} >"$2" 2>"$2.err" 6>&- || do_log "WARN the $1 source did not answer: $(tr '\n' ' ' <"$2.err" | cut -c1-200)"
}

spl_ai_read_alerts() {
  declare -F spl_asks_init >/dev/null || return 1
  ( spl_asks_init >/dev/null 2>&1 && [[ "$LANE_MODE" == hub ]] &&
      spl_lane_spool topics --as "${AI_HOLDER%@*}" --channel alerts --limit 100 --json )
}

spl_ai_read_disk() {
  SPOOL_ROOT="$root" timeout 30 "${SPL_SPOOL:-spool}" tail --task disk-headroom --json
}

spl_ai_read_gcp() {
  ( cd "${APP_PATH:-$PROJ_PATH/..}/csi-spl-iac" && ORG="${ORG:-csi}" APP="${APP:-spl}" SINCE="$AI_SINCE" \
      ENV='' GCP_LIST_ENVS="${ALERT_ISSUE_GCP_ENVS:-dev prd}" timeout 180 ./run -a do_gcp_list_alert_incidents )
}

# {"<key>": {status, fixed_at}, "hub": {hash: key}, "hub_lanes": {hash: epoch}}
# for what the plan needs. The hub's [fp:] issues are read when an alert has
# no key here, and on every tick of a missing or stale state (a lease move).
spl_ai_issues() {
  local src="$1" st="$2" out='{}' k s f hub=0 fps
  spl_ai_stale "$st" "$now" && hub=1
  while read -r what k; do
    case "$what" in
      key)
        s="$(spl_ai_run ISSUE_REF="$k" -- do_spl_issue_status | awk -F'\t' '$1 == "issue-status" { print $3 }' | tail -1)"
        out="$(spl_ai_issue_put "$out" "$k" "$s")" ;;
      hub) hub=1 ;;
    esac
  done < <(python3 "$PROJ_PATH/src/bash/scripts/alert-issue-fold.py" keys "$src" "$st" 2>/dev/null)
  if [[ "$hub" == 1 ]]; then
    fps="$(spl_ai_hub_fps)"
    out="$(jq -c --argjson f "$fps" '.hub = $f.hub | .hub_lanes = $f.lanes' <<<"$out")"
    while read -r k s; do
      [[ -n "$k" ]] && out="$(spl_ai_issue_put "$out" "$k" "$s")"
    done < <(jq -r '.status | to_entries[] | "\(.key) \(.value)"' <<<"$fps")
  fi
  printf '%s\n' "$out"
}

spl_ai_issue_put() {  # JSON KEY STATUS
  local f=""
  [[ "$3" == "done" ]] && f="$(spl_ai_fixed_at "$2")"
  jq -c --arg k "$2" --arg s "$3" --arg f "$f" '.[$k] = {status: $s, fixed_at: ($f | tonumber? // null)}' <<<"$1"
}

# The committer time of the newest origin/master commit that closes KEY by the
# closer's rule (issue-close-landed.py --keys), or nothing.
spl_ai_fixed_at() {
  local g="${ALERT_ISSUE_GIT_DIR:-$PROJ_PATH/..}" sha ct
  while read -r sha ct; do
    python3 "$PROJ_PATH/src/bash/scripts/issue-close-landed.py" --keys "$g" "$sha" 2>/dev/null | grep -x "$1" >/dev/null &&
      { printf '%s\n' "$ct"; return 0; }
  done < <(git -C "$g" log origin/master -E --grep="\\b$1\\b" --format='%H %ct' -n 20 2>/dev/null)
}

# The hub's prio 1 issues titled "... [fp:<hash>]", of EVERY status (a done
# or dismissed one too): {hub: {hash: key}, status: {key: status},
# lanes: {hash: epoch}}. Per hash an open issue wins over a done one, a done
# one over a dismissed one, then the newest; lanes is the newest
# "alert-lane-at: <epoch>" line of its descriptions.
spl_ai_hub_fps() {
  local none='{"hub":{},"status":{},"lanes":{}}'
  [[ "$AI_DESK" == 1 ]] || { echo "$none"; return 0; }
  spl_ai_run ISSUE_ASSIGNEE= ISSUE_STATUS= ISSUE_PRIORITY=1 ISSUE_LIMIT=500 ENV="$ENV" TENANT_ID="$TENANT_ID" DESK_AGENT="$DESK_AGENT" \
    -- do_spl_issue_list 2>/dev/null |
    jq -c -s '[.[] | (.result.issues // .issues // [])[] | select(.title | test("\\[fp:[0-9a-f]{8}\\]"))
      | {h: (.title | capture("\\[fp:(?<h>[0-9a-f]{8})\\]").h), key, status: (.status // ""), created_at: (.created_at // ""),
         lane: ([(.description // "") | scan("alert-lane-at: ([0-9]+)") | .[0] | tonumber] | max // 0),
         rank: (if (.status // "") == "done" then 1 elif (.status // "") == "diss" then 0 else 2 end)}]
      | {hub: (group_by(.h) | map({key: .[0].h, value: (sort_by([.rank, .created_at]) | last | .key)}) | from_entries),
         status: (map({key, value: .status}) | from_entries),
         lanes: (group_by(.h) | map({key: .[0].h, value: (map(.lane) | max)}) | map(select(.value > 0)) | from_entries)}' 2>/dev/null |
    grep . || echo "$none"
}

# VAR=value... -- ACTION: one orc action with the lease's desk, its output on
# stdout. A read runs live in a dry run too; a write only with DRY_RUN=0.
spl_ai_run() {
  local -a vars=()
  while [[ $# -gt 0 && "$1" != -- ]]; do vars+=("$1"); shift; done
  shift
  env "${vars[@]}" DRY_RUN=0 SPOOL_ROOT="$root" timeout "${ALERT_ISSUE_TIMEOUT:-120}" \
    "${ALERT_ISSUE_RUN:-$PROJ_PATH/run}" -a "$1" </dev/null 2>&1 6>&- 7>&- 8>&-
}

# Every action of the plan; a failed one is taken out of the state, so the
# next tick sees its alerts again. 1 = one or more failed.
spl_ai_apply() {
  local src="$1" plan="$2" a op rc=0
  while IFS= read -r a; do
    op="$(jq -r '.op' <<<"$a")"
    if [[ "$AI_DRY" != 0 ]]; then
      jq -r '"PLAN \(.op) fp:\(.hash) \(.key // "" | if . == "" then "(new)" else . end) n=\(.n) count=\(.count)"
        + (if .lane then " +lane" else "" end) + (if (.why | length) > 0 then " (\(.why | join("; ")))" else "" end)
        + ": \(.text[0:160])"' <<<"$a"
      continue
    fi
    case "$op" in
      # a write only while this machine still holds the orch role; a move
      # rolls the action back, its alerts stay unseen for the new holder
      comment) spl_ai_holder_still && spl_ai_comment "$a" ;;
      file) spl_ai_holder_still && spl_ai_file "$src" "$a" ;;
      reopen) spl_ai_holder_still && spl_ai_reopen "$src" "$a" ;;
      hold) jq -r '"INFO held fp:\(.hash) \(.key): \(.why | join("; "))"' <<<"$a"; true ;;
    esac || { rc=1; spl_ai_rollback "$src/state.json" "$a"; }
  done < <(jq -c '.actions[]' <<<"$plan")
  return "$rc"
}

# ENV, TENANT_ID and DESK_AGENT of the lease's desk (do_spl_lane_issue's).
spl_ai_desk() {
  declare -F spl_lane_issue_desk >/dev/null || { do_log "FATAL spl_lane_issue_desk is not loaded"; return 1; }
  spl_lane_issue_desk "$root" 0 || { do_log "WARN no seated desk for the alert issues: the hub is not read, nothing is filed"; return 1; }
}

spl_ai_comment() {
  local a="$1" key body
  key="$(jq -r '.key' <<<"$a")"
  body="$(jq -r '"Alert fired again: \(.n) time(s) since the last tick, \(.count) in all (fingerprint `fp:\(.hash)`, source \(.src)). Latest: \(.text[0:300])"' <<<"$a")"
  spl_ai_run ISSUE_REF="$key" ISSUE_BODY="$body" ENV="$ENV" TENANT_ID="$TENANT_ID" DESK_AGENT="$DESK_AGENT" -- do_spl_issue_comment >/dev/null ||
    { do_log "WARN the comment on $key did not land"; return 1; }
  do_log "OK commented $key (fp:$(jq -r .hash <<<"$a"), count $(jq -r .count <<<"$a"))"
}

spl_ai_file() {
  local src="$1" a="$2" h title out key disc
  h="$(jq -r '.hash' <<<"$a")"
  title="$(jq -r '"Alert: \(.text | gsub("[*`\n]"; " ") | .[0:100]) [fp:\(.hash)]"' <<<"$a")"
  disc="$(jq -r '.topic' <<<"$a")"; [[ "$disc" =~ ^[0-9a-f-]{36}$ ]] || disc="$ALERT_ISSUE_DISCUSSION"
  spl_ai_description "$a" "$disc" >"$src/desc.$h.md"
  [[ "$(jq -r '.lane' <<<"$a")" == true ]] && printf '\nalert-lane-at: %s\n' "$now" >>"$src/desc.$h.md"
  out="$(spl_ai_run ISSUE_TITLE="$title" ISSUE_DESCRIPTION_FILE="$src/desc.$h.md" ISSUE_DISCUSSIONS="$disc" ISSUE_PRIORITY=1 \
    ISSUE_STATUS=todo ISSUE_EPIC="${ALERT_ISSUE_EPIC:-SPL-2364}" ENV="$ENV" TENANT_ID="$TENANT_ID" DESK_AGENT="$DESK_AGENT" -- do_spl_issue_create)"
  key="$(printf '%s\n' "$out" | jq -R -r 'fromjson? | (.result.issue.key // .result.key // empty)' 2>/dev/null | tail -1)"
  [[ "$key" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "WARN the issue of fp:$h was not filed: $(tail -3 <<<"$out" | tr '\n' ' ' | cut -c1-300)"; return 1; }
  jq -c --arg h "$h" --arg k "$key" '.fps[$h].key = $k' "$src/state.json" >"$src/state.json.new" && mv "$src/state.json.new" "$src/state.json"
  do_log "OK filed $key prio 1 for fp:$h"
  [[ "$(jq -r '.lane' <<<"$a")" == true ]] && spl_ai_lane "$a" "$key"
  return 0
}

spl_ai_reopen() {
  local src="$1" a="$2" key h disc
  key="$(jq -r '.key' <<<"$a")"; h="$(jq -r '.hash' <<<"$a")"
  local -a desc=()
  # a reopen with a lane re-writes the description with its alert-lane-at
  # line, so a holder on another box counts the lane (the history is in
  # the comments)
  if [[ "$(jq -r '.lane' <<<"$a")" == true ]]; then
    disc="$(jq -r '.topic' <<<"$a")"; [[ "$disc" =~ ^[0-9a-f-]{36}$ ]] || disc="$ALERT_ISSUE_DISCUSSION"
    { spl_ai_description "$a" "$disc"; printf '\nalert-lane-at: %s\n' "$now"; } >"$src/desc.$h.md"
    desc=(ISSUE_DESCRIPTION_FILE="$src/desc.$h.md")
  fi
  spl_ai_run ISSUE_REF="$key" ISSUE_STATUS=todo "${desc[@]}" ENV="$ENV" TENANT_ID="$TENANT_ID" DESK_AGENT="$DESK_AGENT" -- do_spl_issue_update >/dev/null ||
    { do_log "WARN $key was not reopened"; return 1; }
  spl_ai_run ISSUE_REF="$key" ENV="$ENV" TENANT_ID="$TENANT_ID" DESK_AGENT="$DESK_AGENT" \
    ISSUE_BODY="$(jq -r '"Reopened: the alert fired again after the fix landed (\(.n) time(s), fingerprint `fp:\(.hash)`). Latest: \(.text[0:300])"' <<<"$a")" \
    -- do_spl_issue_comment >/dev/null || do_log "WARN $key was reopened, its comment did not land"
  do_log "OK reopened $key (fp:$(jq -r .hash <<<"$a"))"
  [[ "$(jq -r '.lane' <<<"$a")" == true ]] && spl_ai_lane "$a" "$key"
  return 0
}

# The issue's description: the source link and the restart card (spec 135 Q4).
spl_ai_description() {
  jq -r --arg d "$2" --arg spec "${ALERT_ISSUE_SPEC:-csi-spl-doc/specs/146-reliability-round}" '
    "Source: /t/\($d)\n\nSpec: \($spec)\n\nFiled by `do_spl_alert_issue_tick` (SPL-4828): a new alert fingerprint.\n\n"
    + "- fingerprint: `fp:\(.hash)` = `\(.fp)`\n- source: \(.src)\n- alerts this tick: \(.n)\n- refs: \(.refs | join(", "))\n\n"
    + "Latest alert:\n\n> \(.text[0:600])\n\nRepeats are comments here; a lane is placed at most once per fingerprint per day."' <<<"$1"
}

# ONE read-only investigator lane: the brief, the ask, the queue row. A failed
# enqueue keeps the issue and the lane counters (no lane storm on a retry).
spl_ai_lane() {
  local a="$1" key="$2" h slug brief id out topic
  h="$(jq -r '.hash' <<<"$a")"
  # the lane's discussion: the #alerts topic, else ALERT_ISSUE_DISCUSSION; a
  # full uuid as the ask topic gives the lane row its link (spec 153 3.4)
  topic="$(jq -r '.topic' <<<"$a")"
  [[ "$topic" =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || topic="$ALERT_ISSUE_DISCUSSION"
  slug="alert-$h-$(date -u -d "@$now" +%Y%m%d%H%M 2>/dev/null || date -u +%Y%m%d%H%M)"
  brief="${ALERT_ISSUE_BRIEF_DIR:-$root/dispatch/briefs}/$slug.md"
  if ! spl_ai_brief "$a" "$key" "$slug" "$topic" >"$brief" || [[ ! -s "$brief" ]]; then
    do_log "WARN the brief $brief was not written: no lane for $key"; return 0
  fi
  id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  out="$(spl_ai_run ASK_ID="$id" ASK_KIND=task ASK_FROM="$AI_HOLDER" ASK_TOPIC="$topic" \
    ASK_SUMMARY="alert investigation $key: $(jq -r '.text[0:120]' <<<"$a")" ASK_DISCUSSION="$ALERT_ISSUE_DISCUSSION" -- do_spl_ask_put)" ||
    { do_log "WARN the ask for $key was not recorded: no lane ($(tail -1 <<<"$out" | cut -c1-200))"; return 0; }
  out="$(spl_ai_run ASK_ID="$id" SPAWN_CLASS=bug SPAWN_PLACE="claude:$slug" ASK_BY="$AI_HOLDER" \
    ASK_DISCUSSION="$ALERT_ISSUE_DISCUSSION" -- do_spl_spawn_enqueue)" ||
    { do_log "WARN the lane for $key was not enqueued ($(tail -1 <<<"$out" | cut -c1-200))"; return 0; }
  do_log "OK enqueued lane $slug for $key (ask ${id:0:8})"
}

spl_ai_brief() {
  jq -r --arg key "$2" --arg slug "$3" --arg topic "$4" --arg epic "${ALERT_ISSUE_EPIC:-SPL-2364}" \
    --arg spec "${ALERT_ISSUE_SPEC:-csi-spl-doc/specs/146-reliability-round}" '
"# Lane brief: investigate alert \($key), read-only (one small task, claude)

Origin-Issue: \($key)
Discussion: topic \($topic)
Epic: \($epic)
Spec: \($spec)
Class: bug
Kind: complex_coding

Placement slug `\($slug)`, filed by do_spl_alert_issue_tick (SPL-4828). The alert issue \($key) is the origin: the placer files this lane its own issue, and \($key) stays open for the fix lane. Report to the CURRENT dispatch lease holder (`cd csi-spl-orc && SPOOL_ROOT=/var/spool-hub LEASE_CMD=show ./run -a do_spl_dispatch_lease`), kind result, and comment your findings on \($key).

## The alert
- text: \(.text[0:600])
- source: \(.src)
- fingerprint: `fp:\(.hash)` = `\(.fp)`
- refs: \(.refs | join(", "))

## Do (READ-ONLY)
1. Find the cause: read the code on origin/master, the logs and the state the alert names. Re-measure; say n and the tree for every number.
2. Comment on \($key): the cause, the evidence (command + output), the file and test a fix needs, and its kind. Stop there.

## Do NOT
Edit any file, commit or push; write anything on prd or dev (no apply, no restart, no issue status change); install anything; spawn agents. A fix is a new lane the holder places.
"' <<<"$1"
}

# Take a failed action back out of the state: its alerts unseen, its count
# and, for a file, the fingerprint itself.
spl_ai_rollback() {
  local f="$1" a="$2"
  jq -c --argjson a "$a" '
    reduce $a.refs[] as $r (.; del(.seen[$r]))
    | if $a.op == "file" then del(.fps[$a.hash]) | (if $a.lane then .lanes |= .[:-1] else . end)
      else .fps[$a.hash].count -= $a.n
        | (if $a.op == "reopen" and $a.lane then .lanes |= .[:-1] | del(.fps[$a.hash].last_lane_at) else . end) end' "$f" >"$f.new" && mv "$f.new" "$f"
}

spl_ai_summary() {
  jq -r --arg dry "$AI_DRY" '"alert issue tick\(if $dry != "0" then " (dry run)" else "" end): \(.actions | length) fingerprint(s): "
    + "\([.actions[] | select(.op == "file")] | length) new, \([.actions[] | select(.op == "comment")] | length) repeat, "
    + "\([.actions[] | select(.op == "reopen")] | length) reopen, \([.actions[] | select(.op == "hold")] | length) held, "
    + "\([.actions[] | select(.lane)] | length) lane(s); \(.state.lanes | length) lane(s) in 24 h"' <<<"$1" |
    while IFS= read -r l; do do_log "INFO $l"; done
}
