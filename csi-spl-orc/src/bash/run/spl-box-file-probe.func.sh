#!/bin/bash
#------------------------------------------------------------------------------
# @description Upload ONE random test file from the probe box on THIS machine
# @description into a cloud tenant (POST /v1/files, 027 T020), and prove the
# @description hub stored it under the sha256 of the bytes sent:
# @description   1. the probe box must already be pinned: do_spl_box_msg_probe
# @description      (DRY_RUN=0) pins it on its first run and this reuses it
# @description   2. PROBE_FILE_MIB MiB from /dev/urandom into a 0600 scratch file;
# @description      its sha256 is computed locally
# @description   3. `spool hub-sync`, then `spool send --put-file` a self-note
# @description      (SPOOL_MIRROR_LOCAL=1). The send uploads the file first and
# @description      fails unless the hub answers 201 with file_id == that sha
# @description      (hubclient UploadFile), so a non-201 or a wrong id is FATAL
# @description   4. `spool hub-tail --task <id> --json`: the run FAILS unless the
# @description      hub-held message carries that file_id
# @description Prints one JSON line (sha256, bytes, msg_id, task_id, seconds)
# @description and removes the scratch file. The object stays in the tenant's
# @description files prefix (content-addressed; it counts against its quota).
# @description Dry run unless DRY_RUN=0.
# @description TEARDOWN: this reuses the box do_spl_box_msg_probe pinned; it
# @description leaves the roster only with do_spl_box_purge (pin-semantics.md 6).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param PROBE_BOX (optional) - default box-orc-probe
# @param PROBE_AGENT (optional) - default ORC-1
# @param PROBE_FILE_MIB (optional) - 1..32, default 8
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 PROBE_FILE_MIB=8 DRY_RUN=0 ./run -a do_spl_box_file_probe
#------------------------------------------------------------------------------
do_spl_box_file_probe() {
  do_require_bin python3 yq sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-orc-probe}" agent="${PROBE_AGENT:-ORC-1}"
  local mib="${PROBE_FILE_MIB:-8}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL PROBE_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }
  [[ "$agent" =~ ^[A-Z]{2,4}-[0-9]+$ ]] || { do_log "FATAL PROBE_AGENT '$agent' is not an agent id (e.g. ORC-1)"; return 1; }
  [[ "$mib" =~ ^[0-9]+$ ]] && (( mib >= 1 && mib <= 32 )) || { do_log "FATAL PROBE_FILE_MIB must be 1..32 (the hub's per-file limit), got: '$mib'"; return 1; }

  local hub d="$SPL_STATE_DIR/probe/$tenant/$box"
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  if (( dry )); then
    do_log "INFO DRY_RUN would: upload $mib MiB of random bytes from $agent@$box to $hub as tenant $tenant (POST /v1/files) as a self-note attachment, then hub-tail it"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to upload."
    return 0
  fi
  [[ -f "$d/pinned" ]] || { do_log "FATAL $box is not pinned under $tenant ($d/pinned missing): run ENV=$ENV TENANT_ID=$tenant ROOT_KEY_JSON=<json> DRY_RUN=0 ./run -a do_spl_box_msg_probe first"; return 1; }
  spl_host_spool || return 1
  _probe() { SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" SPOOL_MIRROR_LOCAL=1 "$SPL_SPOOL" "$@"; }

  local f sha stamp sync1 sent tail t0 t1 rc=0
  f="$(umask 077 && mktemp "${TMPDIR:-/tmp}/spl-file-probe.XXXXXX")" || return 1
  head -c "$((mib * 1024 * 1024))" /dev/urandom >"$f" || { rm -f "$f"; return 1; }
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  sync1="$(_probe hub-sync 2>&1)" || { rm -f "$f"; unset -f _probe; do_log "FATAL hub-sync of $box: $sync1"; return 1; }
  t0="$(date +%s.%N)"
  sent="$(_probe send --from "$agent" --to "$agent" --to-box "$box" --kind note \
    --body "[orc-probe] file ${sha:0:16} $stamp" --put-file "$f" 2>&1)" || rc=$?
  t1="$(date +%s.%N)"
  rm -f "$f"
  (( rc == 0 )) || { unset -f _probe; do_log "FATAL upload + send from $agent@$box: $sent"; return 1; }
  local task msg
  task="$(yq -p json -r '.task_id // ""' <<<"$sent")"
  msg="$(yq -p json -r '.msg_id // ""' <<<"$sent")"
  _probe hub-sync >/dev/null 2>&1 || true
  tail="$(_probe hub-tail --task "$task" --json 2>&1)" || rc=$?
  unset -f _probe
  python3 - "$ENV" "$tenant" "$hub" "$sha" "$((mib * 1024 * 1024))" "$msg" "$task" "$t0" "$t1" <<'EOF_PY'
import json, sys
env, tenant, hub, sha, n, msg, task, t0, t1 = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "hub": hub, "sha256": sha, "bytes": int(n),
                  "msg_id": msg, "task_id": task, "upload_send_seconds": round(float(t1) - float(t0), 3)},
                 sort_keys=True))
EOF_PY
  (( rc == 0 )) || { do_log "FAIL hub-tail of task $task: $tail"; return 1; }
  grep -q "$sha" <<<"$tail" || { do_log "FAIL the hub-held message $msg does not carry file_id $sha"; return 1; }
  do_log "OK $mib MiB uploaded to $tenant ($ENV): the hub answered 201 with file_id = sha256 of the bytes sent ($sha)"
}
