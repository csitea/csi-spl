#!/bin/bash
#------------------------------------------------------------------------------
# @description Live proof of the hub's per-workspace docs (spec 075 phase 2):
# @description the 030 env var SPOOL_HUB_WORKSPACE_DOCS_BUCKET is set and the
# @description 052 bucket of TENANT_ID is read and written by the hub.
# @description   1. anonymous GET /v1/workspace/docs/tree.json: must NOT be
# @description      404 workspace_docs_off (the routes are on; anonymous is
# @description      refused at the door instead)
# @description   2. as a member agent (the desk seat DESK_BOX of TENANT_ID, its
# @description      role=cli token): `spool doc-list` (tree.json) must answer
# @description   3. `spool doc-write` a fresh random doc under probe/, then
# @description      `spool doc-read` it back: the bytes must round-trip
# @description   4. `spool doc-delete` it; `spool doc-list` must no longer name it
# @description Prints one JSON line (tenant, path, anon code, list/write/read/
# @description delete verdicts) and FAILS unless every step passed.
# @description Dry run unless DRY_RUN=0. TEARDOWN: step 4 deletes the doc; the
# @description bucket keeps its old generation and the hub's .history/ record
# @description (versioning is the point of 052), nothing else is left.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (its 052 bucket must exist)
# @param DESK_BOX (optional) - the seat box, default spl_desk_box_default
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_workspace_docs_probe
#------------------------------------------------------------------------------
do_spl_workspace_docs_probe() {
  do_require_bin python3 yq curl || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" box="${DESK_BOX:-$(spl_desk_box_default)}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id (box-wui is reserved)"; return 1; }

  local api_fqdn hub d
  spl_cnf_api_fqdn api_fqdn || return 1
  hub="https://$api_fqdn"
  d="$SPL_STATE_DIR/desk/$tenant/$box"
  if (( dry )); then
    do_log "INFO DRY_RUN would: GET $hub/v1/workspace/docs/tree.json anonymously (want not workspace_docs_off), then as seat $box of $tenant doc-list, doc-write + doc-read a probe/ doc, doc-delete it"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0 to probe."
    return 0
  fi
  [[ -d "$d/keys" ]] || { do_log "FATAL no desk seat $box in $tenant ($d): run do_spl_desk_up first"; return 1; }
  spl_host_spool || return 1
  _wsdoc() { SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$box" SPOOL_HUB_URL="$hub" SPOOL_TENANT="$tenant" "$SPL_SPOOL" "$@"; }

  local tmp anon anon_off=0 path list=FAIL write=FAIL read=FAIL del=FAIL gone=FAIL rc=0
  tmp="$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/spl-wsdoc-probe.XXXXXX")" || return 1
  anon="$(curl -s -m 20 -o "$tmp/anon" -w '%{http_code}' -H "X-Spool-Tenant: $tenant" "$hub/v1/workspace/docs/tree.json")"
  grep -q workspace_docs_off "$tmp/anon" 2>/dev/null && anon_off=1
  path="probe/ws-docs-probe-$(date -u +%Y%m%dT%H%M%SZ)-$$.md"
  printf '# workspace docs probe\n\n%s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" >"$tmp/doc"
  _wsdoc doc-list >"$tmp/list" 2>"$tmp/err" && list=PASS
  if [[ $list == PASS ]]; then
    _wsdoc doc-write "$path" --file "$tmp/doc" >"$tmp/write" 2>>"$tmp/err" && write=PASS
    _wsdoc doc-read "$path" >"$tmp/read" 2>>"$tmp/err" && cmp -s "$tmp/doc" "$tmp/read" && read=PASS
    _wsdoc doc-delete "$path" >"$tmp/del" 2>>"$tmp/err" && del=PASS
    _wsdoc doc-list probe/ >"$tmp/list2" 2>>"$tmp/err" && ! grep -qF "$path" "$tmp/list2" && gone=PASS
  fi
  python3 -c 'import json,sys; print(json.dumps(dict(zip(["tenant","path","anon_code","anon_off","list","write","read","delete","gone"], sys.argv[1:]))))' \
    "$tenant" "$path" "$anon" "$anon_off" "$list" "$write" "$read" "$del" "$gone"
  if (( anon_off )) || [[ "$list$write$read$del$gone" != PASSPASSPASSPASSPASS ]]; then
    do_log "FAIL workspace docs probe on $hub as $box/$tenant: $(head -c 400 "$tmp/err" "$tmp/anon" 2>/dev/null | tr '\n' ' ')"
    rc=1
  else
    do_log "OK workspace docs on $hub: $tenant list, write, read, delete round-trip"
  fi
  rm -rf "$tmp"
  return $rc
}
