#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Reliability round row 10 (rel-10, SPL-2661, Refs: SPL-2364):
# @description Cloud SQL daily backup verification. Automated backups run daily
# @description at 01:00, but backup failures due to disk locks or maintenance
# @description conflicts are silent unless verified.
# @description
# @description Reuses gcloud sql backups list --instance=csi-spl-<env>-pg --account="$GCP_ACCOUNT" --limit=10
# @description from spl-db-health.func.sh:115.
# @description Resolves instance name csi-spl-<env>-pg from cnf (not -db).
# @description Verifies latest backup has status: SUCCESSFUL and timestamp within last 26 hours.
# @description Exits 0 when backup < 26h; exits 1 with alert if backup is stale,
# @description missing, non-successful, or unreachable; strictly read-only.
# @param ENV - required: dev or prd
# @param CLOUD_SQL_INSTANCE (optional) - instance name override, default from cnf
# @param CLOUD_SQL_PROJECT (optional) - project override, default from cnf
# @param CLOUD_SQL_BACKUP_MAX_AGE_HOURS (optional) - max backup age in hours, default 26
# @param CLOUD_SQL_BACKUP_MAX_AGE_SECONDS (optional) - max backup age in seconds, default 93600 (26h)
# @param CLOUD_SQL_BACKUP_LIST_CMD (optional) - backup list command override (testing)
# @param CLOUD_SQL_BACKUP_STATE_DIR (optional) - state dir for stamps
# @param CLOUD_SQL_BACKUP_STAMP_FILE (optional) - alert throttling stamp file
# @param CLOUD_SQL_BACKUP_THROTTLE_S (optional) - alert throttling interval in seconds, default 86400
# @param CLOUD_SQL_BACKUP_ALERT_SEND_BIN (optional) - spool-send tool path
# @param CLOUD_SQL_BACKUP_ALERT_TO (optional) - spool alert recipient (default "orchestrator")
# @param CLOUD_SQL_BACKUP_ALERT_FROM (optional) - spool alert sender
# @param CLOUD_SQL_BACKUP_ALERT_TASK (optional) - spool alert task id (default "cloud-sql-backup-verify")
# @param NOW_EPOCH (optional) - override current timestamp in seconds (testing)
# @param DRY_RUN (optional) - 1 (default) plans spool alert; 0 sends note
# @example cd csi-spl-utl && ENV=prd ./run -a do_cloud_sql_backup_verify
# @example cd csi-spl-utl && ENV=dev ./run -a do_cloud_sql_backup_verify
#------------------------------------------------------------------------------
type do_log &>/dev/null || do_log() { echo "$*"; }

_csq_cnf_dir() {
  local d
  if [[ -n "${CLOUD_SQL_CNF_DIR:-}" && -d "${CLOUD_SQL_CNF_DIR}" ]]; then
    printf '%s' "${CLOUD_SQL_CNF_DIR}"
    return 0
  fi
  for d in \
    "${PROJ_PATH:-.}/../csi-spl-cnf/csi-spl" \
    "${PROJ_PATH:-.}/../../csi-spl-cnf/csi-spl" \
    "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-cnf/csi-spl"; do
    if [[ -d "$d" ]]; then
      (cd "$d" && pwd)
      return 0
    fi
  done
  return 1
}

_csq_resolve_instance() {
  local env="$1" inst="" cnf_dir
  if [[ -n "${CLOUD_SQL_INSTANCE:-}" ]]; then
    printf '%s' "${CLOUD_SQL_INSTANCE}"
    return 0
  fi
  cnf_dir="$(_csq_cnf_dir 2>/dev/null)" || true
  if [[ -n "$cnf_dir" ]] && command -v yq >/dev/null 2>&1; then
    if [[ -f "$cnf_dir/$env.env.yaml" ]]; then
      inst="$(yq -r '.env.steps."040-cloud-sql-postgres".instance_name // ""' "$cnf_dir/$env.env.yaml" 2>/dev/null || true)"
    fi
    if [[ -z "$inst" && -f "$cnf_dir/all.env.yaml" ]]; then
      inst="$(yq -r '.env.steps."040-cloud-sql-postgres".instance_name // ""' "$cnf_dir/all.env.yaml" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$inst" ]] || inst="csi-spl-$env-pg"
  printf '%s' "$inst"
}

_csq_resolve_project() {
  local env="$1" proj="" cnf_dir
  if [[ -n "${CLOUD_SQL_PROJECT:-}" ]]; then
    printf '%s' "${CLOUD_SQL_PROJECT}"
    return 0
  fi
  if [[ -n "${SPL_PROJECT:-}" ]]; then
    printf '%s' "${SPL_PROJECT}"
    return 0
  fi
  cnf_dir="$(_csq_cnf_dir 2>/dev/null)" || true
  if [[ -n "$cnf_dir" ]] && command -v yq >/dev/null 2>&1; then
    if [[ -f "$cnf_dir/$env.env.yaml" ]]; then
      proj="$(yq -r '.env.gcp.gcp_project // ""' "$cnf_dir/$env.env.yaml" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$proj" ]] || proj="csi-spl-$env"
  printf '%s' "$proj"
}

_csq_resolve_account() {
  local env="$1" project="$2" key email lib
  if [[ -n "${GCP_ACCOUNT:-}" ]]; then
    return 0
  fi
  if [[ -n "${ACCOUNT:-}" ]]; then
    export GCP_ACCOUNT="${ACCOUNT}"
    return 0
  fi
  export SPL_PROJECT="$project"
  export ORG="${ORG:-csi}" APP="${APP:-spl}"
  for lib in \
    "${PROJ_PATH:-.}/../csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh" \
    "${PROJ_PATH:-.}/../csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh" \
    "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-iac/lib/bash/funcs/gcp-account-pin.func.sh"; do
    if [[ -f "$lib" ]]; then
      # shellcheck source=/dev/null
      source "$lib" 2>/dev/null || continue
      if declare -f do_gcp_pin_account >/dev/null 2>&1; then
        do_gcp_pin_account >/dev/null 2>&1 && return 0
      fi
    fi
  done
  for key in "$HOME/.gcp/.csi/key-$project.json" "$HOME/.gcp/.csi/key-csi-spl-$env.json"; do
    if [[ -f "$key" ]]; then
      email="$(jq -r '.client_email // ""' "$key" 2>/dev/null || true)"
      if [[ -n "$email" ]]; then
        if [[ -z "${CLOUDSDK_CONFIG:-}" || "${CLOUDSDK_CONFIG:-}" == "$HOME/.config/gcloud" ]]; then
          export CLOUDSDK_CONFIG="$(umask 077 && mktemp -d /tmp/gcp-cfg.XXXXXX)"
        fi
        gcloud auth activate-service-account --key-file="$key" --quiet >/dev/null 2>&1 || true
        export GCP_ACCOUNT="$email"
        return 0
      fi
    fi
  done
  do_log "FATAL no gcloud account: set GCP_ACCOUNT or provide SA key" >&2
  return 1
}

_csq_fetch_backups() {
  local instance="$1" project="$2"
  if [[ -n "${CLOUD_SQL_BACKUP_LIST_CMD:-}" ]]; then
    eval "${CLOUD_SQL_BACKUP_LIST_CMD}"
    return $?
  fi
  gcloud sql backups list --instance="$instance" --project="$project" --account="$GCP_ACCOUNT" --limit=10 --format=json
}

_csq_judge_backups() {
  local raw_json="$1" max_age_s="$2" now_epoch="$3"
  local count backup_id status btype start_time window_start_time end_time ts backup_epoch age_s age_h
  count="$(jq '. | length' <<<"$raw_json" 2>/dev/null || echo -1)"
  if [[ "$count" -lt 0 ]]; then
    printf 'INVALID_JSON 0 - - - - "invalid JSON from backups query"\n'
    return 1
  fi
  if [[ "$count" -eq 0 ]]; then
    printf 'NO_BACKUPS 0 - - - - "no backups found for instance"\n'
    return 1
  fi

  backup_id="$(jq -r '.[0].id // "-"' <<<"$raw_json")"
  status="$(jq -r '.[0].status // "-"' <<<"$raw_json")"
  btype="$(jq -r '.[0].type // "UNKNOWN"' <<<"$raw_json")"
  start_time="$(jq -r '.[0].startTime // ""' <<<"$raw_json")"
  window_start_time="$(jq -r '.[0].windowStartTime // ""' <<<"$raw_json")"
  end_time="$(jq -r '.[0].endTime // ""' <<<"$raw_json")"

  ts="${start_time:-$window_start_time}"
  ts="${ts:-$end_time}"
  if [[ -z "$ts" ]]; then
    printf 'NO_TIMESTAMP 0 %s %s %s - "backup has no timestamp"\n' "$backup_id" "$status" "$btype"
    return 1
  fi

  backup_epoch="$(date -u -d "$ts" +%s 2>/dev/null || true)"
  if [[ -z "$backup_epoch" ]]; then
    printf 'TIMESTAMP_PARSE_ERROR 0 %s %s %s %s "cannot parse backup timestamp: %s"\n' \
      "$backup_id" "$status" "$btype" "$ts" "$ts"
    return 1
  fi

  age_s=$(( now_epoch - backup_epoch ))
  if (( age_s < 0 && age_s >= -300 )); then
    age_s=0
  fi
  age_h=$(( age_s / 3600 ))

  if [[ "$status" != "SUCCESSFUL" ]]; then
    printf 'STATUS_FAIL %d %s %s %s %s "latest backup %s has status '\''%s'\'' (expected SUCCESSFUL)"\n' \
      "$age_s" "$backup_id" "$status" "$btype" "$ts" "$backup_id" "$status"
    return 1
  fi

  if (( age_s > max_age_s )); then
    printf 'STALE %d %s %s %s %s "latest backup %s is stale: age %dh (%ds) exceeds limit (%ds)"\n' \
      "$age_s" "$backup_id" "$status" "$btype" "$ts" "$backup_id" "$age_h" "$age_s" "$max_age_s"
    return 1
  fi

  if (( age_s < -300 )); then
    printf 'FUTURE_TIMESTAMP %d %s %s %s %s "latest backup %s has future timestamp: %s"\n' \
      "$age_s" "$backup_id" "$status" "$btype" "$ts" "$backup_id" "$ts"
    return 1
  fi

  printf 'OK %d %s %s %s %s "backup %s is fresh and SUCCESSFUL"\n' \
    "$age_s" "$backup_id" "$status" "$btype" "$ts" "$backup_id"
  return 0
}

_csq_send_spool() {
  local from="$1" to="$2" task="$3" body="$4" send_bin
  send_bin="${CLOUD_SQL_BACKUP_ALERT_SEND_BIN:-}"
  if [[ -z "$send_bin" ]]; then
    if [[ -n "${PROJ_PATH:-}" && -f "$PROJ_PATH/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" ]]; then
      send_bin="$PROJ_PATH/../csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
    elif command -v spool-send.sh >/dev/null 2>&1; then
      send_bin="$(command -v spool-send.sh)"
    fi
  fi
  if [[ -n "$send_bin" && -x "$send_bin" ]]; then
    SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send_bin" \
      --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1 && return 0
  fi
  if command -v spool >/dev/null 2>&1; then
    SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spool send \
      --from "$from" --to "$to" --kind note --task "$task" --body "$body" >/dev/null 2>&1 && return 0
  fi
  return 1
}

_csq_alert() {
  local env="$1" instance="$2" code="$3" reason="$4" dry="$5"
  local box_name state_dir stamp_file throttle_s now_iso to from task body now_ep stamp_mtime age_s
  box_name="$(hostname -s 2>/dev/null || echo "unknown")"
  state_dir="${CLOUD_SQL_BACKUP_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl/cloud-sql-backup-verify}}"
  stamp_file="${CLOUD_SQL_BACKUP_STAMP_FILE:-$state_dir/cloud-sql-backup-alert-$env.stamp}"
  throttle_s="${CLOUD_SQL_BACKUP_THROTTLE_S:-86400}"
  now_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
  to="${CLOUD_SQL_BACKUP_ALERT_TO:-orchestrator}"
  from="${CLOUD_SQL_BACKUP_ALERT_FROM:-${SPOOL_AGENT_ID:-cloud-sql-backup-verify@$box_name}}"
  task="${CLOUD_SQL_BACKUP_ALERT_TASK:-cloud-sql-backup-verify}"

  body=$(printf 'CLOUD SQL BACKUP VERIFICATION ALERT\nEnvironment: %s\nInstance: %s\nBox: %s\nCode: %s\nReason: %s\nTimestamp: %s\n' \
    "$env" "$instance" "$box_name" "$code" "$reason" "$now_iso")

  if [[ -f "$stamp_file" ]]; then
    now_ep="$(date +%s)"
    stamp_mtime="$(stat -c %Y "$stamp_file" 2>/dev/null || echo 0)"
    age_s=$(( now_ep - stamp_mtime ))
    if (( age_s >= 0 && age_s < throttle_s )) && grep -q "^CODE=$code" "$stamp_file" 2>/dev/null; then
      do_log "INFO alert throttled by $stamp_file (age: ${age_s}s < ${throttle_s}s, code: $code)"
      return 0
    fi
  fi

  if [[ "$dry" == "1" ]]; then
    do_log "INFO PLAN note to $to: $body"
    return 0
  fi

  mkdir -p "$state_dir" 2>/dev/null || true
  if _csq_send_spool "$from" "$to" "$task" "$body"; then
    printf 'CODE=%s\nINSTANCE=%s\nENV=%s\nTS=%s\n' "$code" "$instance" "$env" "$now_iso" >"$stamp_file" 2>/dev/null || true
  else
    do_log "WARN failed to deliver alert spool note to $to"
  fi
}

_csq_clear_alert() {
  local env="$1" instance="$2" dry="$3"
  local state_dir stamp_file
  [[ "$dry" == "0" ]] || return 0
  state_dir="${CLOUD_SQL_BACKUP_STATE_DIR:-${SPL_STATE_DIR:-$HOME/.local/state/csi-spl/cloud-sql-backup-verify}}"
  stamp_file="${CLOUD_SQL_BACKUP_STAMP_FILE:-$state_dir/cloud-sql-backup-alert-$env.stamp}"
  if [[ -f "$stamp_file" ]]; then
    rm -f "$stamp_file" 2>/dev/null || true
  fi
}

do_cloud_sql_backup_verify() {
  local env="${ENV:-}" dry="${DRY_RUN:-1}"
  local max_age_h="${CLOUD_SQL_BACKUP_MAX_AGE_HOURS:-26}"
  local max_age_s="${CLOUD_SQL_BACKUP_MAX_AGE_SECONDS:-$(( max_age_h * 3600 ))}"
  local now_ep="${NOW_EPOCH:-$(date -u +%s)}"
  local instance project raw_out j_code j_age j_id j_status j_type j_time j_reason rc=0

  command -v jq >/dev/null 2>&1 || { do_log "FATAL jq is not on PATH"; return 1; }
  command -v date >/dev/null 2>&1 || { do_log "FATAL date is not on PATH"; return 1; }

  if [[ "$env" != "dev" && "$env" != "prd" ]]; then
    do_log "FATAL ENV must be dev or prd, got: '$env'"
    return 1
  fi

  instance="$(_csq_resolve_instance "$env")"
  project="$(_csq_resolve_project "$env")"

  if [[ -z "${CLOUD_SQL_BACKUP_LIST_CMD:-}" ]]; then
    command -v gcloud >/dev/null 2>&1 || { do_log "FATAL gcloud is not on PATH"; return 1; }
    _csq_resolve_account "$env" "$project" || return 1
  fi

  if ! raw_out="$(_csq_fetch_backups "$instance" "$project" 2>&1)"; then
    do_log "ERROR gcloud sql backups list failed for instance $instance ($env): $raw_out"
    _csq_alert "$env" "$instance" "GCLOUD_ERROR" "gcloud sql backups list query failed: $raw_out" "$dry"
    return 1
  fi

  read -r j_code j_age j_id j_status j_type j_time j_reason < <(_csq_judge_backups "$raw_out" "$max_age_s" "$now_ep") || rc=$?

  if [[ "$rc" -ne 0 || "$j_code" != "OK" ]]; then
    do_log "ALERT [cloud-sql-backup-verify] $instance ($env): $j_reason"
    echo "cloud-sql-backup-verify env=$env instance=$instance backup_id=$j_id status=$j_status type=$j_type startTime=$j_time age_hours=$(( j_age / 3600 )) limit_hours=$max_age_h verdict=ALERT reason=$j_reason"
    _csq_alert "$env" "$instance" "$j_code" "$j_reason" "$dry"
    return 1
  fi

  do_log "INFO [cloud-sql-backup-verify] backup $j_id on $instance ($env) is SUCCESSFUL: age $(( j_age / 3600 ))h <= ${max_age_h}h (start=$j_time, type=$j_type)"
  echo "cloud-sql-backup-verify env=$env instance=$instance backup_id=$j_id status=$j_status type=$j_type startTime=$j_time age_hours=$(( j_age / 3600 )) limit_hours=$max_age_h verdict=OK"
  _csq_clear_alert "$env" "$instance" "$dry"
  return 0
}
