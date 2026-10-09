#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 112 8.2 (ORC-3), the READ half: propose roadmap backfill
# @description candidates from ONE workspace's hub topics (owner decisions,
# @description drills, launches). Never do_spl_db_query: that action takes the
# @description operator RLS scope, which reads every workspace. This one runs
# @description BEGIN TRANSACTION READ ONLY + SET LOCAL app.tenant_id =
# @description WORKSPACE and no rls_scope, as the env's project SA through the
# @description Cloud SQL proxy, so rdb 0014 row-level security is the fence:
# @description the SQL never filters by tenant itself, and a login that
# @description bypasses RLS (superuser / BYPASSRLS) is refused inside the
# @description transaction. "Owner" = a member of WORKSPACE holding biz_owner
# @description or admin there (spec 12.3, ORC-6: rbac role ids, never a person).
# @description Output: a 0600 TSV under $HOME, never in the repo, one row per
# @description candidate: topic_id, msg_id, ts, kind (decision|drill|launch),
# @description quote (<= 140 chars of that owner message, whitespace folded);
# @description nothing else of any message text. The log names the file and
# @description the count, never a quote.
# @description With KEPT_FILE set, the WRITE half instead (8.2 step 4): the rows
# @description a human kept of that file go to PUT /v1/calendar/sync, see
# @description spl_goals_backfill_db_write below.
# @param ENV - required: dev or prd
# @param WORKSPACE - required, no default: the tenant slug to read, and the workspace each db: event names
# @param KEPT_FILE (optional) - the write half: a candidates file of WORKSPACE, under $HOME, 0600
# @param SINCE (optional) - only messages after this ISO-8601 UTC time (the incremental run)
# @param GOALS_BACKFILL_DIR (optional) - output dir under $HOME, default $HOME/.csi-spl/goals-backfill
# @example ENV=dev WORKSPACE=t1 ./run -a do_spl_goals_backfill_db
# @example ENV=dev WORKSPACE=t1 SINCE=2026-10-01T00:00:00Z ./run -a do_spl_goals_backfill_db
# @example ENV=dev WORKSPACE=t1 KEPT_FILE=$HOME/.csi-spl/goals-backfill/db-candidates-dev-t1-<ts>.tsv ./run -a do_spl_goals_backfill_db
#------------------------------------------------------------------------------
do_spl_goals_backfill_db() {
  [[ -n "${WORKSPACE:-}" ]] || { do_log "FATAL WORKSPACE must be set (no default)"; return 1; }
  spl_require_cloud_env || return 1
  [[ "$WORKSPACE" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL WORKSPACE must be a tenant slug, got: '$WORKSPACE'"; return 1; }
  [[ -z "${KEPT_FILE:-}" ]] || { spl_goals_backfill_db_write "$KEPT_FILE"; return; }
  local since="${SINCE:-1970-01-01T00:00:00Z}" dir out n
  [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { do_log "FATAL SINCE must be YYYY-MM-DDTHH:MM:SSZ, got: '$since'"; return 1; }
  do_require_bin psql || return 1
  do_spl_cloud_cnf || return 1
  dir="$(spl_goals_backfill_dir)" || return 1
  out="$dir/db-candidates-$ENV-$WORKSPACE-$(date -u +%Y%m%dT%H%M%SZ).tsv"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_goals_backfill_db_run "$out" "$WORKSPACE" "$since" || { rm -f "$out"; return 1; }
  n=$(( $(wc -l <"$out") - 1 ))
  do_log "OK $n backfill candidate(s) of workspace $WORKSPACE in $ENV ($GCP_ACCOUNT, tenant scope) -> $out (0600; mark the kept rows, then KEPT_FILE=<it>)"
}

# spl_goals_backfill_dir -> prints the 0700 output dir, which must sit under $HOME.
spl_goals_backfill_dir() {
  [[ -n "${HOME:-}" ]] || { do_log "FATAL HOME must be set"; return 1; }
  local d="${GOALS_BACKFILL_DIR:-$HOME/.csi-spl/goals-backfill}"
  [[ "$d" == "$HOME"/* && "$d" != *..* ]] || { do_log "FATAL GOALS_BACKFILL_DIR must be under \$HOME, got: $d"; return 1; }
  { ( umask 077; mkdir -p "$d" ) && chmod 700 "$d"; } || { do_log "FATAL cannot create $d"; return 1; }
  printf '%s' "$d"
}

# spl_goals_backfill_db_write <kept-file>: the WRITE half (spec 8.2 step 4).
# The kept file is a candidates file of this ENV and WORKSPACE (its name says
# so), 0600 under $HOME, after a human pruned it: every row left is kept, or,
# when the human added a 6th column "keep", only the rows marked y/yes/x/1.
# Each kept topic becomes ONE event db:<topic_id> (its earliest kept row:
# title = the quote, kind milestone, at the message ts, audience internal,
# topic_id, workspace WORKSPACE), PUT as the env SA's id token
# (spl_hub_operator_call) to the hub sync route, which writes each event into
# the workspace it names (spec 12.4, HUB-2: no cnf workspace); the file is
# WORKSPACE's own, so a topic never lands in another workspace's calendar.
# The batch carries ONLY the db: family: no goals[] and no goal:/spec:/
# release: key, so the route prunes nothing (it soft-deletes only within a
# goal:/spec: family a request carries, c-610's finding 1); a non-db: key is
# refused here before any call. Quotes never reach argv or a log line: jq reads
# the file and the body goes to curl as @<0600 file>; the log names counts.
spl_goals_backfill_db_write() {
  local kept="$1" dir body n
  dir="$(spl_goals_backfill_dir)" || return 1
  [[ "$kept" == "$dir/db-candidates-$ENV-$WORKSPACE-"*.tsv && "$kept" != *..* && -f "$kept" ]] ||
    { do_log "FATAL KEPT_FILE must be a db-candidates-$ENV-$WORKSPACE-*.tsv file in $dir, got: $kept"; return 1; }
  [[ "$(stat -c '%a' "$kept")" == 600 ]] || { do_log "FATAL KEPT_FILE must be mode 0600: $kept"; return 1; }
  do_require_bin jq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  body="$(umask 077; mktemp "$dir/.sync-body.XXXXXX")" || return 1
  spl_goals_backfill_db_body "$WORKSPACE" <"$kept" >"$body" 2>/dev/null || { do_log "FATAL $kept is not a candidates file"; rm -f "$body"; return 1; }
  n="$(jq '.events | length' "$body")"
  jq -e '(has("goals") | not) and all(.events[]; .source_key | startswith("db:"))' "$body" >/dev/null ||
    { do_log "FATAL the batch carries a non-db: key: refused, nothing sent"; rm -f "$body"; return 1; }
  jq -e --arg ws "$WORKSPACE" 'all(.events[]; .workspace == $ws)' "$body" >/dev/null ||
    { do_log "FATAL an event names a workspace other than $WORKSPACE: refused, nothing sent"; rm -f "$body"; return 1; }
  (( n > 0 )) || { do_log "FATAL no kept row in $kept: nothing to send"; rm -f "$body"; return 1; }
  { do_gcp_pin_account "$SPL_CNF" && do_gcp_require_live_account "$GCP_ACCOUNT" &&
    spl_hub_operator_call PUT /v1/calendar/sync "@$body"; } || { rm -f "$body"; return 1; }
  rm -f "$body"
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
    { do_log "FATAL the sync answered $SPL_HUB_OP_STATUS $(jq -r '.error // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null) ($n db: event(s) not written)"; return 1; }
  do_log "OK $n db: event(s) of workspace $WORKSPACE synced in $ENV ($GCP_ACCOUNT): $(jq -c '{created, updated, unchanged, deleted}' <<<"$SPL_HUB_OP_BODY")"
}

# spl_goals_backfill_db_body <workspace>: a kept candidates TSV on stdin -> the
# sync body {"events": [...]} on stdout, one db:<topic_id> event per kept topic,
# each naming <workspace> (HUB-2 answers 400 for an event without one).
spl_goals_backfill_db_body() {
  jq -R -s -c --arg ws "$1" '
    split("\n") | map(select(length > 0) | split("\t")) as $r
    | if $r[0][0:5] != ["topic_id", "msg_id", "ts", "kind", "quote"] then error("header") else . end
    | ($r[0] | index("keep")) as $k
    | [$r[1:][] | select($k == null or ((.[$k] // "") | ascii_downcase | test("^(y|yes|x|1)$")))
        | select(.[0] | test("^[0-9a-f-]{36}$"))]
    | group_by(.[0]) | map(min_by(.[2]))
    | {events: map({source_key: ("db:" + .[0]),
        title: (.[3] as $kind | (.[4] // "") | if length > 0 then .[0:200] else "owner " + $kind end),
        description: ("owner " + .[3]), kind: "milestone", starts_at: .[2], ends_at: .[2],
        all_day: false, audience: "internal", topic_id: .[0], workspace: $ws})}'
}

# _spl_goals_backfill_db_run <out> <workspace> <since>: the tenant-scoped
# read on $SPL_PROXY_DSN; writes the header + the candidates to <out> (0600).
_spl_goals_backfill_db_run() {
  local out="$1" rows err
  err="$(mktemp)" || return 1
  rows="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v ws="$2" -v since="$3" 2>"$err" <<<"$(spl_goals_backfill_db_sql)")" \
    || { do_log "FATAL the backfill read of workspace $2 failed: $(tr '\n' ' ' <"$err")"; rm -f "$err"; return 1; }
  rm -f "$err"
  ( umask 077; { printf 'topic_id\tmsg_id\tts\tkind\tquote\n'; [[ -z "$rows" ]] || printf '%s\n' "$rows"; } >"$out" ) || return 1
  chmod 600 "$out"
}

# spl_goals_backfill_db_sql: prints the SQL (psql vars :'ws' :'since').
# No tenant_id predicate on purpose: RLS (0014) is the one fence, and the test
# proves it. An owner holds biz_owner or admin in the workspace (spec 12.3),
# the same two roles the hub's sync accepts for a goal approval. The author is the human who posted (from_id HUM-n) or who typed
# it through a box (typed_by, rdb 0040).
spl_goals_backfill_db_sql() {
  cat <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'ws';
DO $$ BEGIN
  IF (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
    RAISE EXCEPTION 'login % bypasses row-level security: refused', current_user;
  END IF;
END $$;
WITH owners AS (
  SELECT human_id FROM tenant_memberships WHERE role IN ('biz_owner', 'admin')
), m AS (
  SELECT task_id, msg_id, ts,
         CASE WHEN from_id ~ '^HUM-[0-9]+$' THEN from_id ELSE typed_by END AS author,
         btrim(regexp_replace(body, '\s+', ' ', 'g')) AS text
    FROM messages
   WHERE ts > :'since'::timestamptz
), c AS (
  SELECT m.*, CASE
           WHEN text ~* '\mdrill(s|ed|ing)?\M' THEN 'drill'
           WHEN text ~* '\m(launch(es|ed)?|go[- ]live|went live|released)\M' THEN 'launch'
           WHEN text ~* '^(go|yes|ok|approved|agreed|decided)\M' OR text ~ '\mDECIDED\M' THEN 'decision'
         END AS kind
    FROM m JOIN owners o ON o.human_id = m.author
)
SELECT task_id, msg_id, to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), kind, left(text, 140)
  FROM c WHERE kind IS NOT NULL
 ORDER BY ts, msg_id;
ROLLBACK;
SQL
}
