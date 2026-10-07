#!/bin/bash
#------------------------------------------------------------------------------
# @description Live proof of the hub's FILE read door (rdb 0030, CLE-34962):
# @description a private attachment is served to an end of its message and
# @description refused (404 not_found) to a box that is neither end nor a
# @description delivery target of it.
# @description   1. both probe boxes must already be pinned: do_spl_box_msg_probe
# @description      (DRY_RUN=0) with PROBE_BOX=<box> pins each on its first run
# @description   2. PROBE_BOX sends a self-note (PROBE_AGENT to itself, that box
# @description      at both ends) carrying a fresh 4 KiB random file; nothing
# @description      real is attached and no other box or human receives it
# @description   3. `spool hub-get-file` as PROBE_BOX: the end - must fetch
# @description   4. `spool hub-get-file` as STRANGER_BOX: must be not_found
# @description Prints one JSON line (sha256, msg_id, task_id, end / stranger
# @description answers as HTTP codes) and FAILS unless end=200 and stranger=404.
# @description Dry run unless DRY_RUN=0.
# @description TEARDOWN: the self-note expires with retention and the hub's
# @description file sweep then deletes its blob; the boxes stay pinned until
# @description do_spl_box_purge (pin-semantics.md 6).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param PROBE_BOX (optional) - the sender, default box-orc-probe
# @param STRANGER_BOX (optional) - the non-end, default box-orc-stranger
# @param PROBE_AGENT (optional) - default c-903: legacy test ids such as ORC-1
#   ended with specs/061 section 0 and move to c-9NN (061 section 2); c-903 is
#   this probe's own id (do_spl_box_msg_probe c-901, do_spl_box_file_probe c-902)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 PROBE_BOX=box-door-a STRANGER_BOX=box-door-b DRY_RUN=0 ./run -a do_spl_file_door_probe
#------------------------------------------------------------------------------
do_spl_file_door_probe() {
  do_require_bin python3 yq sha256sum || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${PROBE_BOX:-box-orc-probe}" other="${STRANGER_BOX:-box-orc-stranger}"
  local agent="${PROBE_AGENT:-c-903}"
  spl_require_tenant_slug "$tenant" || return 1
  local b
  for b in "$box" "$other"; do
    [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$b" != box-wui ]] || { do_log "FATAL '$b' is not a box id (box-wui is reserved)"; return 1; }
  done
  [[ "$box" != "$other" ]] || { do_log "FATAL PROBE_BOX and STRANGER_BOX must differ, both are '$box'"; return 1; }
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_is_participant_id "$agent" || { do_log "FATAL PROBE_AGENT '$agent' is not an agent id (e.g. c-903)"; return 1; }

  local hub
  hub="https://$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  if (( dry )); then
    do_log "INFO DRY_RUN would: send a 4 KiB self-note file from $agent@$box to $hub as tenant $tenant, then GET it as $box (want 200) and as $other (want 404)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to probe."
    return 0
  fi
  for b in "$box" "$other"; do
    [[ -f "$SPL_STATE_DIR/probe/$tenant/$b/pinned" ]] || { do_log "FATAL $b is not pinned under $tenant: run ENV=$ENV TENANT_ID=$tenant PROBE_BOX=$b ROOT_KEY_JSON=<json> DRY_RUN=0 ./run -a do_spl_box_msg_probe first"; return 1; }
  done
  spl_host_spool || return 1
  _door() { local d="$SPL_STATE_DIR/probe/$tenant/$1"; shift
    SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="${d##*/}" SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" SPOOL_MIRROR_LOCAL=1 "$SPL_SPOOL" "$@"; }

  local f sha sent rc=0 task msg endo stro endc strc
  f="$(umask 077 && mktemp "${TMPDIR:-/tmp}/spl-door-probe.XXXXXX")" || return 1
  head -c 4096 /dev/urandom >"$f" || { rm -f "$f"; return 1; }
  sha="$(sha256sum "$f" | cut -d' ' -f1)"
  _door "$box" hub-sync >/dev/null 2>&1
  sent="$(_door "$box" send --from "$agent" --to "$agent" --to-box "$box" --kind note \
    --body "[orc-probe] file door ${sha:0:16} $(date -u +%Y%m%dT%H%M%SZ)" --put-file "$f" 2>&1)" || rc=$?
  rm -f "$f"
  (( rc == 0 )) || { unset -f _door; do_log "FATAL upload + send from $agent@$box: $sent"; return 1; }
  task="$(yq -p json -r '.task_id // ""' <<<"$sent")"
  msg="$(yq -p json -r '.msg_id // ""' <<<"$sent")"
  endo="$(_door "$box" hub-get-file --file-id "$sha" 2>&1)" && endc=200 || endc=$(grep -q not_found <<<"$endo" && echo 404 || echo err)
  stro="$(_door "$other" hub-get-file --file-id "$sha" 2>&1)" && strc=200 || strc=$(grep -q not_found <<<"$stro" && echo 404 || echo err)
  unset -f _door
  python3 - "$ENV" "$tenant" "$hub" "$sha" "$msg" "$task" "$box" "$endc" "$other" "$strc" <<'EOF_PY'
import json, sys
env, tenant, hub, sha, msg, task, box, endc, other, strc = sys.argv[1:]
print(json.dumps({"env": env, "tenant": tenant, "hub": hub, "sha256": sha, "msg_id": msg, "task_id": task,
                  "end": {"box": box, "status": endc}, "stranger": {"box": other, "status": strc}}, sort_keys=True))
EOF_PY
  [[ "$endc" == 200 ]] || { do_log "FAIL the end $box could not fetch its own attachment: $endo"; return 1; }
  [[ "$strc" == 404 ]] || { do_log "FAIL the stranger $other was not refused ($strc): $stro"; return 1; }
  do_log "OK file door on $tenant ($ENV): end $box 200, stranger $other 404 (file $sha)"
}
