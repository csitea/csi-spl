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
# @description transaction. "Owner" = a member of WORKSPACE holding the
# @description approver role (D2: an rbac role id, never a person).
# @description Output: a 0600 TSV under $HOME, never in the repo, one row per
# @description candidate: topic_id, msg_id, ts, kind (decision|drill|launch),
# @description quote (<= 140 chars of that owner message, whitespace folded);
# @description nothing else of any message text. The log names the file and
# @description the count, never a quote. Writing the kept ones (db:<topic_id>,
# @description audience internal) waits for the hub sync route (HUB-1).
# @param ENV - required: dev or prd
# @param WORKSPACE - required, no default: the tenant slug to read
# @param APPROVER_ROLE (optional) - the rbac role id whose messages count; default cnf env.roadmap.approver_role, else FATAL
# @param SINCE (optional) - only messages after this ISO-8601 UTC time (the incremental run)
# @param GOALS_BACKFILL_DIR (optional) - output dir under $HOME, default $HOME/.csi-spl/goals-backfill
# @example ENV=dev WORKSPACE=t1 APPROVER_ROLE=admin ./run -a do_spl_goals_backfill_db
# @example ENV=dev WORKSPACE=t1 SINCE=2026-10-01T00:00:00Z ./run -a do_spl_goals_backfill_db
#------------------------------------------------------------------------------
do_spl_goals_backfill_db() {
  [[ -n "${WORKSPACE:-}" ]] || { do_log "FATAL WORKSPACE must be set (no default)"; return 1; }
  spl_require_cloud_env || return 1
  [[ "$WORKSPACE" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL WORKSPACE must be a tenant slug, got: '$WORKSPACE'"; return 1; }
  local since="${SINCE:-1970-01-01T00:00:00Z}" role dir out n
  [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { do_log "FATAL SINCE must be YYYY-MM-DDTHH:MM:SSZ, got: '$since'"; return 1; }
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  role="${APPROVER_ROLE:-$(yq -r '.env.roadmap.approver_role // ""' "$SPL_CNF")}"
  [[ "$role" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || { do_log "FATAL APPROVER_ROLE / cnf env.roadmap.approver_role must be an rbac role id, got: '$role'"; return 1; }
  dir="$(spl_goals_backfill_dir)" || return 1
  out="$dir/db-candidates-$ENV-$WORKSPACE-$(date -u +%Y%m%dT%H%M%SZ).tsv"
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_goals_backfill_db_run "$out" "$WORKSPACE" "$role" "$since" || { rm -f "$out"; return 1; }
  n=$(( $(wc -l <"$out") - 1 ))
  do_log "OK $n backfill candidate(s) of workspace $WORKSPACE in $ENV ($GCP_ACCOUNT, tenant scope) -> $out (0600; the write half waits for HUB-1)"
}

# spl_goals_backfill_dir -> prints the 0700 output dir, which must sit under $HOME.
spl_goals_backfill_dir() {
  [[ -n "${HOME:-}" ]] || { do_log "FATAL HOME must be set"; return 1; }
  local d="${GOALS_BACKFILL_DIR:-$HOME/.csi-spl/goals-backfill}"
  [[ "$d" == "$HOME"/* && "$d" != *..* ]] || { do_log "FATAL GOALS_BACKFILL_DIR must be under \$HOME, got: $d"; return 1; }
  { ( umask 077; mkdir -p "$d" ) && chmod 700 "$d"; } || { do_log "FATAL cannot create $d"; return 1; }
  printf '%s' "$d"
}

# _spl_goals_backfill_db_run <out> <workspace> <role> <since>: the tenant-scoped
# read on $SPL_PROXY_DSN; writes the header + the candidates to <out> (0600).
_spl_goals_backfill_db_run() {
  local out="$1" rows err
  err="$(mktemp)" || return 1
  rows="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -v ws="$2" -v role="$3" -v since="$4" 2>"$err" <<<"$(spl_goals_backfill_db_sql)")" \
    || { do_log "FATAL the backfill read of workspace $2 failed: $(tr '\n' ' ' <"$err")"; rm -f "$err"; return 1; }
  rm -f "$err"
  ( umask 077; { printf 'topic_id\tmsg_id\tts\tkind\tquote\n'; [[ -z "$rows" ]] || printf '%s\n' "$rows"; } >"$out" ) || return 1
  chmod 600 "$out"
}

# spl_goals_backfill_db_sql: prints the SQL (psql vars :'ws' :'role' :'since').
# No tenant_id predicate on purpose: RLS (0014) is the one fence, and the test
# proves it. The author is the human who posted (from_id HUM-n) or who typed
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
  SELECT human_id FROM tenant_memberships WHERE role = :'role'
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
