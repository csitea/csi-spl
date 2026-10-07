#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY report of the topic-head shadow (spec 099 section 5.1
# @description and section 8 step 4, T006): sums the hub's log lines of a cloud
# @description env over a window, per query shape:
# @description   topic_head_shadow    every 10 min, one line per shape:
# @description                        {"message": "topic_head_shadow", "shape": <s>,
# @description                         "compared": <n>, "mismatched": <k>}
# @description   topic_head_mismatch  one line per mismatched request:
# @description                        {"message": "topic_head_mismatch", "shape": <s>, ...}
# @description Prints one row per shape (compared, mismatched, mismatch lines)
# @description and a total line "compared=<n> mismatched=<k> mismatch_lines=<m>
# @description shapes=<s>". The prd gate before `on` (spec 7.6): n >= 500 over
# @description all six shapes, 0 mismatches, >= 24 h.
# @description Exit 0 when nothing mismatched, 3 when anything did, 1 on error.
# @description Nothing is mutated: one `gcloud logging read` as the env SA.
# @param ENV - required: dev or prd
# @param SHADOW_HOURS (optional) - window in hours ending now, default 24 (1..168)
# @param SHADOW_LIMIT (optional) - log entries read at most, default 50000
# @example ENV=dev ./run -a do_spl_topic_head_shadow_report
# @example ENV=prd SHADOW_HOURS=48 ./run -a do_spl_topic_head_shadow_report
#------------------------------------------------------------------------------
do_spl_topic_head_shadow_report() {
  do_require_bin gcloud python3 yq || return 1
  local hours="${SHADOW_HOURS:-24}" limit="${SHADOW_LIMIT:-50000}"
  if [[ ! "$hours" =~ ^[0-9]+$ ]] || (( hours < 1 || hours > 168 )); then
    do_log "FATAL SHADOW_HOURS must be 1..168, got '$hours'"; return 1
  fi
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || (( limit < 1 || limit > 200000 )); then
    do_log "FATAL SHADOW_LIMIT must be 1..200000, got '$limit'"; return 1
  fi
  do_spl_cloud_cnf || return 1
  local svc since
  svc="$(yq -r '.env.hub.service_name // ""' "$SPL_CNF")"
  [[ -n "$svc" && "$svc" != null ]] || { do_log "FATAL env.hub.service_name is not set in $SPL_CNF"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  since="$(date -u -d "$hours hours ago" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  printf '===== topic-head shadow: env=%s service=%s window=%sh since %s\n' "$ENV" "$svc" "$hours" "$since"
  local rows rc=0
  rows="$(gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$svc\" AND (jsonPayload.message=\"topic_head_shadow\" OR jsonPayload.message=\"topic_head_mismatch\") AND timestamp>=\"$since\"" \
    --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --limit="$limit" --format=json)" ||
    { do_log "FATAL gcloud logging read failed for $svc in $SPL_PROJECT"; return 1; }
  spl_topic_head_shadow_table "$limit" <<<"$rows" || rc=$?
  return $rc
}

# spl_topic_head_shadow_table <limit> < gcloud json -> the per-shape table and
# the total line. Exit 3 when anything mismatched, 1 on unreadable input.
spl_topic_head_shadow_table() {
  python3 -c '
import json, sys
limit = int(sys.argv[1])
try:
    rows = json.load(sys.stdin) or []
except ValueError as e:
    print("FATAL cannot parse the log JSON: %s" % e); sys.exit(1)
per = {}
def cell(s):
    return per.setdefault(s or "?", [0, 0, 0])
for r in rows:
    p = r.get("jsonPayload") or {}
    msg = p.get("message")
    if msg == "topic_head_shadow":
        c = cell(p.get("shape"))
        c[0] += int(p.get("compared") or 0)
        c[1] += int(p.get("mismatched") or 0)
    elif msg == "topic_head_mismatch":
        cell(p.get("shape"))[2] += 1
print("%-40s %10s %10s %10s" % ("shape", "compared", "mismatched", "mm_lines"))
for s in sorted(per):
    c = per[s]
    print("%-40s %10d %10d %10d" % (s, c[0], c[1], c[2]))
n = sum(c[0] for c in per.values()); k = sum(c[1] for c in per.values()); m = sum(c[2] for c in per.values())
if len(rows) >= limit:
    print("WARN read %d entries = SHADOW_LIMIT: the window is cut, raise SHADOW_LIMIT" % len(rows))
print("compared=%d mismatched=%d mismatch_lines=%d shapes=%d" % (n, k, m, sum(1 for c in per.values() if c[0])))
sys.exit(3 if (k or m) else 0)
' "$1"
}
