#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: consumer lag per box in a cloud env's hub Postgres
# @description (spec 059 §11.1 S4, Kafka's consumer lag): the delivery rows
# @description the hub sent that the box has not committed (rdb 0100
# @description deliveries.acked_at NULL), the age of the oldest, the rows still
# @description queued, and the box's last hello. One JSON line per box with
# @description any such row, then one summary line. A box with no hello for
# @description LAG_DEAD_HOURS is DEAD: its rows are reported as lag, never kept
# @description or deleted silently. A LIVE box whose oldest uncommitted row is
# @description older than LAG_ALERT_MIN prints an ALERT line, and the action
# @description exits 3. Same identity and transport as do_spl_db_message_show:
# @description the env's project service account in a throwaway
# @description CLOUDSDK_CONFIG, the DSN from Secret Manager, the Cloud SQL Auth
# @description Proxy on 127.0.0.1, psql in BEGIN READ ONLY with the operator
# @description row-level-security scope. Prints no message body.
# @param ENV - required: dev or prd
# @param LAG_ALERT_MIN (optional) - alert age of a live box's oldest uncommitted row, minutes (1..10080, default 30)
# @param LAG_DEAD_HOURS (optional) - no hello for this long = a dead box, hours (1..8760, default 72)
# @param SPL_SA_KEY (optional) - default $HOME/.gcp/.<org>/key-<project>.json
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @param LAG_FORMAT (optional) - auto (default): an aligned table on a tty, one
# @param LAG_FORMAT JSON object per line (ndjson) otherwise; table or ndjson forces one
# @example ENV=dev ./run -a do_spl_consumer_lag
# @example ENV=prd LAG_ALERT_MIN=60 ./run -a do_spl_consumer_lag
# @example ENV=prd LAG_FORMAT=ndjson ./run -a do_spl_consumer_lag | grep '^{' | jq -C .
#------------------------------------------------------------------------------
do_spl_consumer_lag() {
  do_require_bin gcloud psql python3 || return 1
  local alert_min="${LAG_ALERT_MIN:-30}" dead_h="${LAG_DEAD_HOURS:-72}"
  [[ "$alert_min" =~ ^[0-9]+$ ]] && ((alert_min >= 1 && alert_min <= 10080)) ||
    { do_log "FATAL LAG_ALERT_MIN must be 1..10080 minutes, got: '$alert_min'"; return 1; }
  [[ "$dead_h" =~ ^[0-9]+$ ]] && ((dead_h >= 1 && dead_h <= 8760)) ||
    { do_log "FATAL LAG_DEAD_HOURS must be 1..8760 hours, got: '$dead_h'"; return 1; }
  local fmt="${LAG_FORMAT:-auto}"
  [[ "$fmt" =~ ^(auto|table|ndjson)$ ]] ||
    { do_log "FATAL LAG_FORMAT must be auto, table or ndjson, got: '$fmt'"; return 1; }
  [[ "$fmt" == auto ]] && { [[ -t 1 ]] && fmt=table || fmt=ndjson; }
  do_spl_cloud_cnf || return 1
  local key="${SPL_SA_KEY:-$HOME/.gcp/.${SPL_ORG_APP%%-*}/key-$SPL_PROJECT.json}"
  [[ -r "$key" ]] || { do_log "FATAL no service-account key for $SPL_PROJECT at $key (set SPL_SA_KEY)"; return 1; }
  local cfg rc=0
  cfg="$(mktemp -d)" || return 1
  (
    export CLOUDSDK_CONFIG="$cfg"
    gcloud auth activate-service-account --key-file="$key" >/dev/null 2>&1 ||
      { do_log "FATAL cannot activate the $SPL_PROJECT key $key"; exit 1; }
    GCP_ACCOUNT="$(do_gcp_isolated_active_account)" || exit 1
    export GCP_ACCOUNT
    local cloud_dsn dsn out qrc summary
    cloud_dsn="$(spl_read_dsn)"
    [[ -n "$cloud_dsn" ]] || { do_log "FATAL cannot read $SPL_DSN_SECRET in $SPL_PROJECT as $GCP_ACCOUNT"; exit 1; }
    spl_sql_proxy_start || exit 1
    dsn="$(spl_proxy_dsn "$cloud_dsn" "$SPL_PROXY_PORT")" ||
      { spl_sql_proxy_stop; do_log "FATAL unexpected DSN shape in $SPL_DSN_SECRET"; exit 1; }
    out="$(spl_psql_ro "$dsn" "$(spl_consumer_lag_sql "$alert_min" "$dead_h")")"
    qrc=$?
    spl_sql_proxy_stop
    [[ $qrc == 0 ]] || { do_log "FATAL read-only query on $SPL_SQL_CONN/$SPL_DB_NAME failed: $out"; exit 1; }
    spl_consumer_lag_render "$out" "$fmt" || { do_log "FATAL cannot parse the lag rows"; exit 1; }
    summary="$(spl_consumer_lag_summary "$out")" || { do_log "FATAL cannot parse the lag rows"; exit 1; }
    printf '%s\n' "$summary"
    if grep -q '^ALERT ' <<<"$summary"; then
      do_log "ALERT consumer lag past ${alert_min}m on a live box in $SPL_PROJECT/$SPL_DB_NAME (read-only, as $GCP_ACCOUNT)"
      exit 3
    fi
    do_log "OK consumer lag read in $SPL_PROJECT/$SPL_DB_NAME, no live box past ${alert_min}m (read-only, as $GCP_ACCOUNT)"
  ) || rc=$?
  rm -rf "$cfg"
  return $rc
}

# spl_consumer_lag_sql <alert minutes> <dead hours> -> one json object per box
# with an uncommitted (sent, acked_at NULL) or an unexpired queued row. Both
# arguments were checked as integers by the caller, so the literals carry no
# SQL. The uncommitted half reads the deliveries_unacked partial index. alert is
# COALESCEd: a box that never said hello (hello NULL) reads false, not null.
spl_consumer_lag_sql() {
  cat <<EOF_SQL
SELECT json_build_object(
  'tenant_id', l.tenant_id, 'box', l.to_box, 'uncommitted', l.uncommitted, 'queued', l.queued,
  'oldest_sent_at', l.oldest, 'oldest_age_s', COALESCE(floor(extract(epoch FROM now() - l.oldest))::bigint, 0),
  'last_hello_at', l.hello,
  'dead', l.hello IS NULL OR l.hello < now() - interval '$2 hours',
  'alert', COALESCE(l.uncommitted > 0 AND l.hello >= now() - interval '$2 hours' AND l.oldest < now() - interval '$1 minutes', false))
FROM (SELECT d.tenant_id, d.to_box,
             count(*) FILTER (WHERE d.state = 'sent' AND d.acked_at IS NULL) AS uncommitted,
             count(*) FILTER (WHERE d.state = 'queued') AS queued,
             min(d.sent_at) FILTER (WHERE d.state = 'sent' AND d.acked_at IS NULL) AS oldest,
             b.last_hello_at AS hello
        FROM deliveries d
        LEFT JOIN boxes b ON b.tenant_id = d.tenant_id AND b.box_id = d.to_box
       WHERE (d.state = 'sent' AND d.acked_at IS NULL) OR (d.state = 'queued' AND d.expires_at > now())
       GROUP BY d.tenant_id, d.to_box, b.last_hello_at) l
ORDER BY l.tenant_id, l.to_box;
EOF_SQL
}

# spl_consumer_lag_render <json lines> <ndjson|table> -> ndjson: the rows as
# read, byte for byte (scripts and the S4 alert read them); table: a header and
# one aligned row per box, ages as 2h00m, alert rows red and dead rows dim on a
# tty (unless NO_COLOR). Nothing for no rows. Non-zero on a line that is not JSON.
spl_consumer_lag_render() {
  if [[ "$2" == ndjson ]]; then
    [[ -z "$1" ]] || printf '%s\n' "$1"
    return 0
  fi
  local color=0
  [[ -t 1 && -z "${NO_COLOR:-}" ]] && color=1
  python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.argv[1].splitlines() if l.strip()]
if not rows:
    sys.exit(0)
def age(s):
    d, s = divmod(int(s or 0), 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    if d:
        return "%dd%02dh" % (d, h)
    if h:
        return "%dh%02dm" % (h, m)
    return "%dm" % m if m else "-"
head = ("TENANT", "BOX", "UNCOMMITTED", "QUEUED", "OLDEST_AGE", "LAST_HELLO", "DEAD", "ALERT")
body = [(str(r["tenant_id"]), str(r["box"]), str(r["uncommitted"]), str(r["queued"]), age(r.get("oldest_age_s")),
         str(r.get("last_hello_at") or "never"), "dead" if r.get("dead") is True else "-",
         "ALERT" if r.get("alert") is True else "-") for r in rows]
w = [max(len(c[i]) for c in [head] + body) for i in range(len(head))]
def line(c):
    return "  ".join(v.rjust(w[i]) if i in (2, 3, 4) else v.ljust(w[i]) for i, v in enumerate(c)).rstrip()
color = sys.argv[2] == "1"
print("\033[1m%s\033[0m" % line(head) if color else line(head))
for r, c in zip(rows, body):
    on = "\033[31m" if r.get("alert") is True else "\033[2m" if r.get("dead") is True else ""
    print("%s%s\033[0m" % (on, line(c)) if color and on else line(c))
' "$1" "$color"
}

# spl_consumer_lag_summary <json lines> -> one "ALERT <tenant>/<box> ..." line per
# alerting live box, then "SUMMARY boxes=.. live_lagging=.. dead=.. uncommitted=..
# uncommitted_dead=.. queued=.. alerts=..". Non-zero on a line that is not JSON.
spl_consumer_lag_summary() {
  python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.argv[1].splitlines() if l.strip()]
alerts = [r for r in rows if r.get("alert") is True]
for r in alerts:
    print("ALERT %s/%s uncommitted=%d oldest_age_s=%d last_hello_at=%s" % (
        r["tenant_id"], r["box"], r["uncommitted"], r["oldest_age_s"], r["last_hello_at"]))
dead = [r for r in rows if r.get("dead") is True]
live_lag = [r for r in rows if r.get("dead") is not True and r["uncommitted"] > 0]
print("SUMMARY boxes=%d live_lagging=%d dead=%d uncommitted=%d uncommitted_dead=%d queued=%d alerts=%d" % (
    len(rows), len(live_lag), len(dead), sum(r["uncommitted"] for r in rows),
    sum(r["uncommitted"] for r in dead), sum(r["queued"] for r in rows), len(alerts)))
' "$1"
}
