#!/bin/bash
#------------------------------------------------------------------------------
# @description Canary roll of the hub Cloud Run service (SPL-2249, Cloud Run
# @description radar step 3). No load balancer (owner 2026-10-07): Cloud Run's
# @description own traffic split and revision tags, which the 032 domain
# @description mappings and the WUI's Firebase rewrite both honour.
# @description   1. the revision serving 100 % now is the OLD one; a split
# @description      already in place (a killed run) is pinned to its largest
# @description      share first. Nothing to roll only when the template runs
# @description      IMAGE_REF AND the latest ready revision serves 100 %
# @description   2. gcloud run services update --image IMAGE_REF --no-traffic
# @description      --tag <tag>: a new revision, 0 % of traffic, its own URL
# @description      https://<tag>---<service url host>
# @description   3. pre-traffic probes on that URL: /v1/health 200 and, with
# @description      EXPECT_COMMIT, /version .commit == it
# @description   4. update-traffic --to-tags <tag>=<percent>; for <minutes> probe
# @description      the tag URL every <probe_interval_s>; 2 non-200 in a row fail
# @description   5. after <metrics_lag_s>, Monitoring request_count of the NEW
# @description      revision over the window, by response class. Fail when
# @description      5xx >= max_5xx AND 5xx > max_5xx_pct % of its requests, or
# @description      when no WS upgrade (1xx) reached it although its share of
# @description      the old revision's upgrades predicts >= 5 (the 2026-10-16
# @description      hello deadlock: 1xx fell to 0 while requests piled up)
# @description   6. pass: update-traffic --to-latest (latest 100 %, the shape
# @description      do_heal_hub_deploy and do_gcp_hub_restart need); fail: pin
# @description      the old revision at 100 %, rc 1. Both remove the tag.
# @description Knobs: cnf env.hub.cloud_run.canary (enabled, percent, minutes,
# @description tag, probe_interval_s, metrics_lag_s, max_5xx, max_5xx_pct).
# @description Identity: the env's project SA (do_gcp_pin_account), --account
# @description on every gcloud call; never the owner account.
# @param ENV - required: dev or prd
# @param IMAGE_REF - required for run: the minted image to canary
# @param CANARY_CMD (optional) - run (default) | rollback (pin the 100 % revision of a split, drop the tag) | status (read only)
# @param EXPECT_COMMIT (optional) - the commit the new revision's /version must report
# @param DRY_RUN (optional) - 1 (default): print every mutation, make none; 0: make them
# @param GCP_ACCOUNT (optional) - the identity (the deploy job passes its deploy SA)
# @example ENV=dev CANARY_CMD=status ./run -a do_canary_hub_deploy
# @example ENV=dev IMAGE_REF=<ref> EXPECT_COMMIT=<sha> DRY_RUN=0 ./run -a do_canary_hub_deploy
#------------------------------------------------------------------------------
do_canary_hub_deploy() {
  local cmd="${CANARY_CMD:-run}" dry="${DRY_RUN:-1}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 1; }
  [[ "$cmd" =~ ^(run|rollback|status)$ ]] || { do_log "FATAL CANARY_CMD must be run, rollback or status, got: $cmd"; return 1; }
  spl_require_cloud_env || return 1
  do_require_bin yq jq curl python3 gcloud || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  _chd_cnf || return 1
  _chd_read || return 1
  case "$cmd" in
    status) _chd_status; return 0 ;;
    rollback) _chd_rollback "$dry"; return $? ;;
  esac
  [[ -n "${IMAGE_REF:-}" ]] || { do_log "FATAL IMAGE_REF must be set (no default): the minted image to canary"; return 1; }
  if [[ -n "$CHD_SPLIT" ]]; then
    # the deploy job is serialised per env, so a split seen here was left by
    # a killed run (timeout, cancel): end it before anything else
    echo "canary: WARN $CHD_SVC already splits traffic ($CHD_SPLIT), left by a killed run: pinning its largest share first"
    _chd_rollback "$dry" || return 1
    [[ "$dry" == 1 ]] && { echo "canary: DRY_RUN stops here (the split must end first)"; return 0; }
    _chd_read || return 1
  fi
  [[ -n "$CHD_OLD" ]] || { do_log "FATAL cannot tell which revision of $CHD_SVC serves 100 %"; return 1; }
  # Current only when the template runs the image AND the latest ready
  # revision serves 100 %: after a rolled-back canary the template already
  # names IMAGE_REF while the old revision is pinned, and a re-run must retry.
  if [[ "$CHD_IMAGE" == "$IMAGE_REF" && "$CHD_OLD" == "$CHD_LATEST" ]]; then
    echo "canary: $ENV $CHD_SVC already runs $IMAGE_REF -- nothing to roll"; return 0
  fi
  _chd_run "$dry"
}

# _chd_cnf -> CHD_SVC + the CHD_* knobs from cnf env.hub.cloud_run.canary
_chd_cnf() {
  local c v
  CHD_SVC="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$CHD_SVC" && "$CHD_SVC" != null ]] || { do_log "FATAL cnf env.hub.service_name is empty for $ENV"; return 1; }
  c="$(yq -o json '.env.hub.cloud_run.canary // {}' "$SPL_CNF")" || return 1
  CHD_PCT="$(jq -r '.percent // 10' <<<"$c")" CHD_MIN="$(jq -r '.minutes // 10' <<<"$c")"
  CHD_TAG="$(jq -r '.tag // "canary"' <<<"$c")" CHD_EVERY="$(jq -r '.probe_interval_s // 30' <<<"$c")"
  CHD_LAG="$(jq -r '.metrics_lag_s // 120' <<<"$c")" CHD_MAX5="$(jq -r '.max_5xx // 3' <<<"$c")"
  CHD_MAX5P="$(jq -r '.max_5xx_pct // 1' <<<"$c")"
  for v in "$CHD_MIN" "$CHD_EVERY" "$CHD_MAX5" "$CHD_MAX5P"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL cnf hub.cloud_run.canary: minutes, probe_interval_s, max_5xx, max_5xx_pct must be positive integers, got: $v"; return 1; }
  done
  [[ "$CHD_LAG" =~ ^[0-9]+$ ]] || { do_log "FATAL cnf hub.cloud_run.canary.metrics_lag_s must be an integer, got: $CHD_LAG"; return 1; }
  [[ "$CHD_PCT" =~ ^[0-9]+$ ]] && ((CHD_PCT >= 1 && CHD_PCT <= 50)) ||
    { do_log "FATAL cnf hub.cloud_run.canary.percent must be 1..50, got: $CHD_PCT"; return 1; }
  [[ "$CHD_TAG" =~ ^[a-z][a-z0-9-]{0,45}$ ]] || { do_log "FATAL cnf hub.cloud_run.canary.tag '$CHD_TAG' is not a Cloud Run tag"; return 1; }
}

# _chd_read -> CHD_IMAGE (template), CHD_LATEST (latest ready), CHD_OLD (the 100 % revision),
# CHD_SPLIT ("rev:pct,..." when more than one revision has traffic, else "")
_chd_read() {
  local json
  json="$(gcloud run services describe "$CHD_SVC" --project="$SPL_PROJECT" --region="$SPL_REGION" --account="$GCP_ACCOUNT" --format=json 2>&1)" ||
    { do_log "FATAL cannot describe $CHD_SVC in $SPL_PROJECT/$SPL_REGION as $GCP_ACCOUNT: $(tail -1 <<<"$json")"; return 1; }
  CHD_JSON="$json"
  CHD_IMAGE="$(jq -r '.spec.template.spec.containers[0].image // ""' <<<"$json")"
  CHD_LATEST="$(jq -r '.status.latestReadyRevisionName // ""' <<<"$json")"
  CHD_OLD="$(jq -r '[.status.traffic[]? | select((.percent // 0) == 100)][0].revisionName // ""' <<<"$json")"
  CHD_SPLIT="$(jq -r '[.status.traffic[]? | select((.percent // 0) > 0)] | if length > 1
    then map("\(.revisionName):\(.percent)") | join(",") else "" end' <<<"$json")"
}

_chd_status() {
  echo "canary: $ENV $CHD_SVC image=$CHD_IMAGE"
  jq -r '.status.traffic[]? | "  traffic \(.revisionName) \(.percent // 0)%\(if .tag then " tag=\(.tag) \(.url // "")" else "" end)"' <<<"$CHD_JSON"
  echo "  knobs percent=$CHD_PCT minutes=$CHD_MIN tag=$CHD_TAG probe_interval_s=$CHD_EVERY metrics_lag_s=$CHD_LAG max_5xx=$CHD_MAX5 max_5xx_pct=$CHD_MAX5P"
}

# _chd_mutate <dry> <gcloud args...> -> runs or prints one mutating gcloud call
_chd_mutate() {
  local dry="$1"; shift
  if [[ "$dry" == 1 ]]; then echo "canary: DRY_RUN would run: gcloud $* --project=$SPL_PROJECT --region=$SPL_REGION --account=$GCP_ACCOUNT --quiet"; return 0; fi
  echo "canary: gcloud $*"
  gcloud "$@" --project="$SPL_PROJECT" --region="$SPL_REGION" --account="$GCP_ACCOUNT" --quiet >/dev/null || { do_log "FATAL gcloud $* failed"; return 1; }
}

# _chd_rollback <dry> -> the revision with the largest share gets 100 %, the tag goes
_chd_rollback() {
  local keep
  keep="${CHD_KEEP:-$(jq -r '[.status.traffic[]? | select(.revisionName != null)] | max_by(.percent // 0).revisionName // ""' <<<"$CHD_JSON")}"
  [[ -n "$keep" ]] || { do_log "FATAL $CHD_SVC: no revision to pin"; return 1; }
  local -a untag=()
  jq -e --arg t "$CHD_TAG" 'any(.status.traffic[]?; .tag == $t)' <<<"$CHD_JSON" >/dev/null && untag=(--remove-tags="$CHD_TAG")
  echo "canary: $ENV $CHD_SVC rollback: $keep -> 100 %"
  _chd_mutate "$1" run services update-traffic "$CHD_SVC" --to-revisions="$keep=100" "${untag[@]}"
}

_chd_run() {
  local dry="$1" new tagurl t0 t1
  echo "canary: $ENV $CHD_SVC $CHD_OLD ($CHD_IMAGE) -> $IMAGE_REF at $CHD_PCT % for $CHD_MIN min"
  _chd_mutate "$dry" run services update "$CHD_SVC" --image="$IMAGE_REF" --no-traffic --tag="$CHD_TAG" || return 1
  if [[ "$dry" == 1 ]]; then
    _chd_mutate 1 run services update-traffic "$CHD_SVC" --to-tags="$CHD_TAG=$CHD_PCT"
    echo "canary: DRY_RUN then probes ${CHD_TAG}---<host>/v1/health every ${CHD_EVERY}s for ${CHD_MIN} min, reads the 5xx/1xx gate, and promotes (--to-latest) or pins $CHD_OLD"
    return 0
  fi
  _chd_read || return 1
  new="$(jq -r '.status.latestCreatedRevisionName // ""' <<<"$CHD_JSON")"
  tagurl="$(jq -r --arg t "$CHD_TAG" '[.status.traffic[]? | select(.tag == $t)][0].url // ""' <<<"$CHD_JSON")"
  [[ -n "$new" && "$new" != "$CHD_OLD" && -n "$tagurl" ]] ||
    { do_log "ERROR no tagged new revision (new='$new' url='$tagurl')"; CHD_KEEP="$CHD_OLD" _chd_rollback 0; return 1; }
  _chd_probe "$tagurl" 3 || { echo "canary: $new failed its 0 % probes"; CHD_KEEP="$CHD_OLD" _chd_rollback 0; return 1; }
  _chd_mutate 0 run services update-traffic "$CHD_SVC" --to-tags="$CHD_TAG=$CHD_PCT" ||
    { CHD_KEEP="$CHD_OLD" _chd_rollback 0; return 1; }
  t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _chd_watch "$tagurl" || { echo "canary: $new failed its probes under traffic"; CHD_KEEP="$CHD_OLD" _chd_rollback 0; return 1; }
  sleep "$CHD_LAG"
  t1="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _chd_verdict "$new" "$t0" "$t1" || { CHD_KEEP="$CHD_OLD" _chd_rollback 0; return 1; }
  _chd_mutate 0 run services update-traffic "$CHD_SVC" --to-latest --remove-tags="$CHD_TAG" || return 1
  echo "canary: $ENV $CHD_SVC promoted $new to latest 100 %"
}

# _chd_probe <url> <n> -> 0 when n /v1/health probes answer 200 (and /version
# .commit == EXPECT_COMMIT when set)
_chd_probe() {
  local url="$1" n="$2" i code got
  for ((i = 1; i <= n; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url/v1/health")" || code=000
    [[ "$code" == 200 ]] || { echo "canary: probe $i/$n $url/v1/health -> $code"; return 1; }
  done
  [[ -z "${EXPECT_COMMIT:-}" ]] && return 0
  got="$(curl -s --max-time 10 "$url/version" | jq -r '.commit // ""' 2>/dev/null)"
  [[ "$got" == "$EXPECT_COMMIT" ]] || { echo "canary: $url/version commit '${got:0:12}' != ${EXPECT_COMMIT:0:12}"; return 1; }
}

# _chd_watch <url> -> 0 unless 2 probes in a row fail over CHD_MIN minutes
_chd_watch() {
  local url="$1" i miss=0 n=$(( (CHD_MIN * 60 + CHD_EVERY - 1) / CHD_EVERY ))
  for ((i = 1; i <= n; i++)); do
    if _chd_probe "$url" 1 >/dev/null; then miss=0; else miss=$((miss + 1)); fi
    ((miss >= 2)) && { echo "canary: 2 failed probes in a row at $i/$n"; return 1; }
    ((i < n)) && sleep "$CHD_EVERY"
  done
  return 0
}

# _chd_verdict <new revision> <since> <until> -> reads Monitoring, then _chd_gate
_chd_verdict() {
  local new="$1" c_new c_old
  c_new="$(_chd_counts "$new" "$2" "$3")" || { echo "canary: cannot read Monitoring for $new -- failing closed"; return 1; }
  c_old="$(_chd_counts "$CHD_OLD" "$2" "$3")" || { echo "canary: cannot read Monitoring for $CHD_OLD -- failing closed"; return 1; }
  echo "canary: $new 1xx..5xx = $c_new; $CHD_OLD = $c_old ($2 .. $3)"
  # shellcheck disable=SC2086
  _chd_gate $c_new "${c_old%% *}" "$CHD_PCT" "$CHD_MAX5" "$CHD_MAX5P"
}

# _chd_counts <revision> <since> <until> -> "1xx 2xx 3xx 4xx 5xx" request sums
_chd_counts() {
  local tok hdr out rc=0
  tok="$(gcloud auth print-access-token --account="$GCP_ACCOUNT" 2>/dev/null)"
  [[ -n "$tok" ]] || return 1
  hdr="$(mktemp)" || return 1
  ( umask 077; printf 'header = "Authorization: Bearer %s"\n' "$tok" >"$hdr"; )
  out="$(curl -s --connect-timeout 10 --max-time 30 -G "https://monitoring.googleapis.com/v3/projects/$SPL_PROJECT/timeSeries" -K "$hdr" \
    --data-urlencode "filter=metric.type=\"run.googleapis.com/request_count\" AND resource.labels.service_name=\"$CHD_SVC\" AND resource.labels.revision_name=\"$1\"" \
    --data-urlencode "interval.startTime=$2" --data-urlencode "interval.endTime=$3" \
    --data-urlencode "aggregation.alignmentPeriod=60s" --data-urlencode "aggregation.perSeriesAligner=ALIGN_SUM")" || rc=1
  rm -f "$hdr"
  ((rc == 0)) || return 1
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
if "error" in d: sys.exit(1)
n = {c: 0 for c in ("1xx", "2xx", "3xx", "4xx", "5xx")}
for s in d.get("timeSeries", []):
    c = s.get("metric", {}).get("labels", {}).get("response_code_class", "")
    if c in n:
        n[c] += sum(int(p.get("value", {}).get("int64Value", 0)) for p in s.get("points", []))
print(" ".join(str(n[c]) for c in ("1xx", "2xx", "3xx", "4xx", "5xx")))' "$out"
}

# _chd_gate <1xx> <2xx> <3xx> <4xx> <5xx> <old 1xx> <pct> <max 5xx> <max 5xx %>
# -> 0 pass, 1 fail; one line saying which
_chd_gate() {
  local c1="$1" c2="$2" c3="$3" c4="$4" c5="$5" o1="$6" pct="$7" m5="$8" m5p="$9" total want
  total=$((c1 + c2 + c3 + c4 + c5))
  want=$(( o1 * pct / (100 - pct) ))
  if ((c5 >= m5 && c5 * 100 > m5p * total)); then
    echo "canary: FAIL 5xx $c5 of $total requests (limit $m5 and $m5p %)"; return 1
  fi
  if ((want >= 5 && c1 == 0)); then
    echo "canary: FAIL no WS upgrade reached the canary (its $pct % share of $o1 predicts $want)"; return 1
  fi
  echo "canary: PASS 5xx $c5 of $total, WS upgrades $c1 (share predicts $want)"
}
