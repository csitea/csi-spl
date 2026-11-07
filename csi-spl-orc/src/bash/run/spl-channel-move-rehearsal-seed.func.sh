#!/bin/bash
#------------------------------------------------------------------------------
# @description Seed the two throwaway DEV workspaces of the channel move's dev
# @description rehearsal (spec 169 row T13), or remove them. DEV only: prd is
# @description refused before any cnf, gcloud or psql call, and the slugs are
# @description fixed here (seed-move-src, seed-move-dst, channel rehearsal-move),
# @description so this can never touch a real workspace.
# @description <SRC> gets the channel with REHEARSAL_MSGS posts over 100 topics
# @description (every 50th post a thread of its own), a reaction, a revision and
# @description a queued delivery on the first posts, one issue, two blobs, and a
# @description staying channel with what must stay: a post that links a moved
# @description topic (5.4), a post moved out of the channel (M6b), a DM about a
# @description moved topic (M9) and a post sharing one blob (5.5). <DST> gets a
# @description pin of box-seed under another key (F10) and c-001 on its roster
# @description (W2, P2's orchestrator seat). No person is seated: nobody is added
# @description to either workspace. No agent seat either, so P2b sends no probe:
# @description the record of the run says so. No host either: both statements
# @description close the tenant_hosts row the triggers open, so the host
# @description reconcile (wf 40) neither adds nor removes one.
# @description Runs as the hub's runtime login under the operator RLS scope, as
# @description do_spl_search_seed does; re-running resumes (ON CONFLICT DO
# @description NOTHING). Rows expire after 14 days. REHEARSAL_CMD=purge deletes
# @description both tenant rows (ON DELETE CASCADE takes their rows, the journal
# @description and the redirects) and their blobs. Dry run unless DRY_RUN=0:
# @description prints the SQL, calls no cloud.
# @param ENV - required: dev (prd is refused)
# @param REHEARSAL_CMD (optional) - seed (default) or purge
# @param REHEARSAL_MSGS (optional) - the channel's posts, 100..20000, default 3650 (spec F13's largest channel)
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_channel_move_rehearsal_seed
# @example ENV=dev REHEARSAL_CMD=purge DRY_RUN=0 ./run -a do_spl_channel_move_rehearsal_seed
#------------------------------------------------------------------------------
SPL_CMR_SRC=seed-move-src
SPL_CMR_DST=seed-move-dst
SPL_CMR_CH=rehearsal-move
SPL_CMR_STAY=rehearsal-stay

do_spl_channel_move_rehearsal_seed() {
  do_require_bin yq psql gcloud sha256sum || return 1
  spl_cmr_args || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    if [[ "$REHEARSAL_CMD" == purge ]]; then spl_cmr_purge_sql; else spl_cmr_seed_sql; fi
    do_log "INFO DRY_RUN=1: nothing written ($REHEARSAL_CMD; DRY_RUN=0 runs it)"
    return 0
  fi
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local bucket
  bucket="$(yq -r '.env.steps."050-gcs-files".files_bucket_name // ""' "$SPL_CNF")"
  [[ -n "$bucket" && "$bucket" != null ]] || { do_log "FATAL cnf steps.050-gcs-files.files_bucket_name is empty for $ENV"; return 1; }
  if [[ "$REHEARSAL_CMD" == purge ]]; then
    spl_via_proxy _spl_cmr_psql_purge || return 1
    spl_cmr_blobs_rm "$bucket"
    do_log "OK removed $SPL_CMR_SRC and $SPL_CMR_DST from $ENV"
    return 0
  fi
  spl_cmr_blobs_put "$bucket" || return 1
  spl_via_proxy _spl_cmr_psql_seed || return 1
  do_log "OK seeded $SPL_CMR_SRC/$SPL_CMR_CH ($REHEARSAL_MSGS posts) and $SPL_CMR_DST on $ENV. MOVE_CALLER=c-001@box-seed"
}

# spl_cmr_args: nothing is called before it passes.
spl_cmr_args() {
  [[ "${ENV:-}" == dev ]] || { do_log "FATAL the channel move rehearsal is DEV only (ENV=${ENV:-})"; return 1; }
  REHEARSAL_CMD="${REHEARSAL_CMD:-seed}" REHEARSAL_MSGS="${REHEARSAL_MSGS:-3650}"
  [[ "$REHEARSAL_CMD" =~ ^(seed|purge)$ ]] || { do_log "FATAL REHEARSAL_CMD must be seed or purge, got: $REHEARSAL_CMD"; return 1; }
  [[ "$REHEARSAL_MSGS" =~ ^[0-9]{1,5}$ ]] && (( REHEARSAL_MSGS >= 100 && REHEARSAL_MSGS <= 20000 )) ||
    { do_log "FATAL REHEARSAL_MSGS must be an integer 100..20000, got: $REHEARSAL_MSGS"; return 1; }
}

spl_cmr_file_text() { printf 'channel move rehearsal file %s\n' "$1"; }
spl_cmr_file_sha() { spl_cmr_file_text "$1" | sha256sum | cut -d' ' -f1; }

# spl_cmr_file_json <kind>: the messages.files item of a blob (M4).
spl_cmr_file_json() {
  local sha n
  sha="$(spl_cmr_file_sha "$1")"; n="$(spl_cmr_file_text "$1" | wc -c)"
  printf '{"file_id":"%s","sha256":"%s","name":"%s.txt","bytes":%d,"mode":"blob"}' "$sha" "$sha" "$1" "$n"
}

spl_cmr_blobs_put() {
  local kind f rc=0
  f="$(mktemp)" || return 1
  for kind in moved shared; do
    spl_cmr_file_text "$kind" >"$f"
    gcloud storage cp "$f" "gs://$1/t/$SPL_CMR_SRC/files/$(spl_cmr_file_sha "$kind")" --account="$GCP_ACCOUNT" --project="$SPL_PROJECT" --quiet || rc=1
  done
  rm -f "$f"
  (( rc == 0 )) || do_log "FATAL a rehearsal blob was not written to gs://$1 as $GCP_ACCOUNT"
  return "$rc"
}

# spl_cmr_blobs_rm: a blob that is already gone (P6 moved it) is no failure.
spl_cmr_blobs_rm() {
  local t
  for t in "$SPL_CMR_SRC" "$SPL_CMR_DST"; do
    gcloud storage rm -r "gs://$1/t/$t/" --account="$GCP_ACCOUNT" --project="$SPL_PROJECT" --quiet 2>/dev/null ||
      do_log "INFO no blobs left under t/$t/"
  done
  return 0
}

# spl_cmr_seed_sql prints the seed script. Every value is a constant above or a
# validated integer. Ids are md5 of a fixed text, so a re-run hits ON CONFLICT.
spl_cmr_seed_sql() {
  local s="$SPL_CMR_SRC" d="$SPL_CMR_DST" c="$SPL_CMR_CH" y="$SPL_CMR_STAY" moved shared
  moved="$(spl_cmr_file_json moved)"; shared="$(spl_cmr_file_json shared)"
  cat <<SQL
SET statement_timeout = 0;
SELECT set_config('app.rls_scope', 'operator', false);
BEGIN;
INSERT INTO tenants (tenant_id, root_pubkey, display_name) VALUES
  ('$s', decode(repeat('00', 32), 'hex'), 'Channel move rehearsal, source (throwaway)'),
  ('$d', decode(repeat('00', 32), 'hex'), 'Channel move rehearsal, target (throwaway)')
  ON CONFLICT (tenant_id) DO NOTHING;
$(spl_cmr_close_hosts_sql)
INSERT INTO boxes (tenant_id, box_id) VALUES ('$s', 'box-seed'), ('$d', 'box-seed') ON CONFLICT DO NOTHING;
INSERT INTO pins (tenant_id, box_id, pubkey) VALUES
  ('$s', 'box-seed', decode(md5('$s-pin') || md5('$s-pin2'), 'hex')),
  ('$d', 'box-seed', decode(md5('$d-pin') || md5('$d-pin2'), 'hex'))
  ON CONFLICT DO NOTHING;
INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('$d', 'box-seed', 'c-001') ON CONFLICT DO NOTHING;
INSERT INTO channels (tenant_id, channel_id, name, created_by) VALUES
  ('$s', '$c', '$c', 'HUM-1'), ('$s', '$y', '$y', 'HUM-1') ON CONFLICT DO NOTHING;
INSERT INTO issue_counters (tenant_id, prefix, last_number) VALUES ('$s', 'MVS', 1), ('$d', 'MVD', 0) ON CONFLICT DO NOTHING;
INSERT INTO messages (tenant_id, msg_id, task_id, parent_task_id, ts, from_box, from_id, to_box, to_id, kind, body,
    files, msg, env_sig, env, received_at, expires_at, channel)
SELECT '$s', md5('$s-m-' || i)::uuid,
    CASE WHEN i % 50 = 49 THEN md5('$s-th-' || i)::uuid ELSE md5('$s-t-' || (i % 100))::uuid END,
    CASE WHEN i % 50 = 49 THEN md5('$s-t-' || (i % 100))::uuid END,
    now() - (i::float8 / $REHEARSAL_MSGS) * interval '7 days', 'box-seed', 'c-100', 'box-wui', 'ALL-0', 'note',
    'rehearsal post ' || i,
    CASE i WHEN 0 THEN '[$moved]'::jsonb WHEN 1 THEN '[$shared]'::jsonb ELSE '[]'::jsonb END,
    '{}'::jsonb, 'seed', '\\x00'::bytea, now(), now() + interval '14 days', '$c'
  FROM generate_series(0, $REHEARSAL_MSGS - 1) i
  ON CONFLICT (tenant_id, msg_id) DO NOTHING;
INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji)
  SELECT '$s', md5('$s-m-' || i)::uuid, 'c-101', 'ok' FROM generate_series(0, 9) i ON CONFLICT DO NOTHING;
INSERT INTO message_revisions (tenant_id, msg_id, revision, body, edited_by, edited_at)
  SELECT '$s', md5('$s-m-' || i)::uuid, 1, 'rehearsal post, first text ' || i, 'c-100', now() FROM generate_series(0, 9) i ON CONFLICT DO NOTHING;
INSERT INTO deliveries (tenant_id, msg_id, to_box, expires_at)
  SELECT '$s', md5('$s-m-' || i)::uuid, 'box-seed', now() + interval '14 days' FROM generate_series(10, 19) i ON CONFLICT DO NOTHING;
INSERT INTO issues (tenant_id, number, title, task_id, created_by, updated_by)
  VALUES ('$s', 1, 'rehearsal issue', md5('$s-t-0')::uuid, 'c-100', 'c-100') ON CONFLICT DO NOTHING;
INSERT INTO issue_discussions (tenant_id, number, task_id, linked_by)
  VALUES ('$s', 1, md5('$s-t-0')::uuid, 'c-100') ON CONFLICT DO NOTHING;
INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env,
    received_at, expires_at, channel, ref_task_id, moved_from_channel)
  VALUES
  ('$s', md5('$s-stay-link')::uuid, md5('$s-stay-t1')::uuid, now(), 'box-seed', 'c-100', 'box-wui', 'ALL-0', 'note',
    'see /t/' || md5('$s-t-1')::uuid, '[]'::jsonb, '{}'::jsonb, 'seed', '\\x00'::bytea, now(), now() + interval '14 days', '$y', NULL, NULL),
  ('$s', md5('$s-stay-out')::uuid, md5('$s-stay-t2')::uuid, now(), 'box-seed', 'c-100', 'box-wui', 'ALL-0', 'note',
    'a post moved out of the channel', '[]'::jsonb, '{}'::jsonb, 'seed', '\\x00'::bytea, now(), now() + interval '14 days', '$y', NULL, '$c'),
  ('$s', md5('$s-stay-file')::uuid, md5('$s-stay-t3')::uuid, now(), 'box-seed', 'c-100', 'box-wui', 'ALL-0', 'note',
    'a staying post with the shared file', '[$shared]'::jsonb, '{}'::jsonb, 'seed', '\\x00'::bytea, now(), now() + interval '14 days', '$y', NULL, NULL),
  ('$s', md5('$s-dm')::uuid, md5('$s-dm-t')::uuid, now(), 'box-seed', 'c-100', 'box-seed', 'c-101', 'note',
    'a DM about a moved topic', '[]'::jsonb, '{}'::jsonb, 'seed', '\\x00'::bytea, now(), now() + interval '14 days', NULL, md5('$s-t-2')::uuid, NULL)
  ON CONFLICT (tenant_id, msg_id) DO NOTHING;
COMMIT;
SELECT count(*) AS seeded FROM messages WHERE tenant_id = '$s' AND channel = '$c';
SQL
}

# spl_cmr_close_hosts_sql: these workspaces never get a host. The triggers on
# tenants open a tenant_hosts row on insert (pending) and on delete (removing),
# and the reconcile (wf 40) reads an open row as a host to add or to remove, so
# each statement closes it in the same transaction, as do_spl_tenant_test_purge does.
spl_cmr_close_hosts_sql() {
  cat <<SQL
UPDATE tenant_hosts SET status = 'removed', detail = 'throwaway rehearsal workspace, no host (spec 169 T13)', updated_at = now()
  WHERE tenant_id IN ('$SPL_CMR_SRC', '$SPL_CMR_DST') AND status IN ('pending', 'failed', 'removing');
SQL
}

spl_cmr_purge_sql() {
  cat <<SQL
SET statement_timeout = 0;
SELECT set_config('app.rls_scope', 'operator', false);
BEGIN;
DELETE FROM tenants WHERE tenant_id IN ('$SPL_CMR_SRC', '$SPL_CMR_DST') AND tenant_id LIKE 'seed-move-%';
$(spl_cmr_close_hosts_sql)
COMMIT;
SELECT count(*) AS left_after FROM tenants WHERE tenant_id IN ('$SPL_CMR_SRC', '$SPL_CMR_DST');
SQL
}

_spl_cmr_psql_seed() { spl_cmr_seed_sql | spl_pg_env "$SPL_PROXY_DSN" psql -X -q -v ON_ERROR_STOP=1 -P pager=off -f -; }
_spl_cmr_psql_purge() { spl_cmr_purge_sql | spl_pg_env "$SPL_PROXY_DSN" psql -X -q -v ON_ERROR_STOP=1 -P pager=off -f -; }
