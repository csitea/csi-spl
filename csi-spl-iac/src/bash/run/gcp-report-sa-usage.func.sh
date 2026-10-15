#!/bin/bash
# shellcheck source=../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh
declare -F spl_gcp_temp_sdk_config >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/gcp-temp-sdk-config.func.sh"
#------------------------------------------------------------------------------
# @description READ-ONLY: what one service account really did in one env's
# @description project, from Cloud Audit Logs (security round 1 row 1, the
# @description input of the least-privilege split, spec 139). Reads, as the
# @description env's project SA in a private gcloud config, every audit log
# @description entry of the last SA_USAGE_DAYS days whose principal is
# @description SA_USAGE_TARGET (default: that same env SA), then prints a
# @description markdown report: which audit logs are enabled (auditConfigs),
# @description entries per log type, distinct methods and permissions per
# @description service with counts, and per caller class (terraform, gcloud,
# @description go client, other: from the user agent, never the IP).
# @description Second source, also read-only: the IAM recommender's policy
# @description insights (google.iam.policy.Insight, 90 days of permission
# @description usage, data reads included, whatever auditConfigs say): the
# @description exercised permissions per role binding of the target. An
# @description unreadable insight list is reported as such, never as empty.
# @description Every number carries the command that produced it. Writes the
# @description slim entries and the report 0600 under SA_USAGE_DIR (0700).
# @description Mutates nothing in GCP.
# @param ENV - required: dev or prd
# @param SA_USAGE_DAYS (optional) - window in days, default 30 (1..400)
# @param SA_USAGE_TARGET (optional) - principal to report, default the env SA
# @param SA_USAGE_DIR (optional) - default $HOME/.local/share/<org>-<app>/sa-usage
# @example ENV=prd ./run -a do_gcp_report_sa_usage
# @example ENV=dev SA_USAGE_DAYS=7 ./run -a do_gcp_report_sa_usage
#------------------------------------------------------------------------------
do_gcp_report_sa_usage() {
  local _spl_sdk_saved _spl_sdk_dir
  local days="${SA_USAGE_DAYS:-30}"
  [[ "$days" =~ ^[0-9]+$ ]] && ((days >= 1 && days <= 400)) \
    || { do_log "FATAL SA_USAGE_DAYS must be 1..400, got: '$days'"; return 1; }
  spl_gcp_temp_sdk_config || return 1
  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN

  do_require_bin python3 || return 1
  do_gcp_spl_proj_id || return 1
  local p="$PROJ_ID"
  do_gcp_pin_account || return 1
  local sa="$GCP_ACCOUNT" target="${SA_USAGE_TARGET:-$GCP_ACCOUNT}"
  [[ "$target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] || { do_log "FATAL SA_USAGE_TARGET is not an email: '$target'"; return 1; }

  local dir="${SA_USAGE_DIR:-$HOME/.local/share/$ORG-$APP/sa-usage}"
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  local since out
  since="$(date -u -d "-${days} days" +%Y-%m-%dT%H:%M:%SZ)" || return 1
  out="$dir/$ENV-$(date -u +%Y%m%dT%H%M%SZ)"

  local filter="logName:\"cloudaudit.googleapis.com\" AND protoPayload.authenticationInfo.principalEmail=\"$target\" AND timestamp>=\"$since\""
  local fields='json(logName,timestamp,protoPayload.serviceName,protoPayload.methodName,protoPayload.authorizationInfo,protoPayload.requestMetadata.callerSuppliedUserAgent)'
  local cmd_read="gcloud logging read '$filter' --project=$p --account=<env SA> --format='$fields'"
  local cmd_audit="gcloud projects get-iam-policy $p --account=<env SA> --format='json(auditConfigs)'"
  local cmd_ins="gcloud recommender insights list --insight-type=google.iam.policy.Insight --location=global --project=$p --account=<env SA> --format=json"

  (
    umask 077
    gcloud projects get-iam-policy "$p" --account="$sa" --format='json(auditConfigs)' >"$out.audit-configs.json" 2>"$out.err" \
      || { do_log "FATAL $cmd_audit failed: $(head -c 300 "$out.err")"; exit 1; }
    do_log "INFO reading $days days of audit logs of $target in $p (can take minutes)"
    gcloud logging read "$filter" --project="$p" --account="$sa" --format="$fields" >"$out.entries.json" 2>"$out.err" \
      || { do_log "FATAL $cmd_read failed: $(head -c 300 "$out.err")"; exit 1; }
    gcloud recommender insights list --insight-type=google.iam.policy.Insight --location=global \
      --project="$p" --account="$sa" --format=json >"$out.insights.json" 2>"$out.err" \
      || { do_log "WARN $cmd_ins failed: $(head -c 300 "$out.err")"; echo '{"error":"unreadable"}' >"$out.insights.json"; }
    python3 "$PROJ_PATH/src/bash/scripts/sa-usage-report.py" "$out.entries.json" "$out.audit-configs.json" \
      "$p" "$target" "$since" "$days" "$cmd_read" "$cmd_audit" "$out.insights.json" "$cmd_ins" >"$out.md" \
      || { do_log "FATAL sa-usage-report.py failed"; exit 1; }
  ) || return 1
  rm -f "$out.err"
  cat "$out.md"
  do_log "OK SA usage report of $target in $p: $out.md"
}
