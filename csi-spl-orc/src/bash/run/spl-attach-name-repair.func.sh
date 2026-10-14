#!/bin/bash
#------------------------------------------------------------------------------
# @description Give the old attachments still named by their own sha256 a real
# @description file name (SPL-1808, owner HUM-10 t1 4f98d07c msg f5564d9f).
# @description Before SPL-1776 a file attached by id was named by its 64-hex
# @description hash, and the WUI, which picks the preview by the extension,
# @description offered every such picture as a nameless download. The bytes
# @description were always intact. Per workspace this box's desk is seated in:
# @description   1. READ-ONLY, through the Cloud SQL proxy: the messages THIS
# @description      desk box sent that still carry a hash-named file
# @description   2. `spool attach-rename --msg-id <id>` on the desk root, one
# @description      per message: the box sniffs each blob's type from its magic
# @description      bytes (png, jpg, gif, webp, pdf, zip, md, txt, ...), names
# @description      it file-<12 hex>.<ext> and re-signs the envelope with ITS
# @description      key. The hub takes it only as a names-only edit: never the
# @description      bytes, the file_id or the body, and no new revision. A
# @description      file of no known type keeps its name and is counted
# @description   3. after a real run, the query again: what is left
# @description A message of another box, or of a box whose pin is revoked, is
# @description that box's to repair: run this action where its desk lives.
# @description Prints one JSON line per workspace (messages, files, renamed per
# @description type, unknown, 5 sample before/after names, failures, left).
# @description Dry run unless DRY_RUN=0: the dry run reads and sniffs, and
# @description sends nothing.
# @param ENV - required: dev or prd
# @param TENANT_IDS (optional) - space- or comma-separated workspaces; default every
# @param   workspace whose DESK_BOX desk is pinned here (<state>/desk/*/<box>/pinned)
# @param DESK_BOX (optional) - default the desk box, the same value do_spl_desk_up used
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd ./run -a do_spl_attach_name_repair
# @example ENV=prd TENANT_IDS=t1 DRY_RUN=0 ./run -a do_spl_attach_name_repair
#------------------------------------------------------------------------------
do_spl_attach_name_repair() {
  do_require_bin python3 yq psql || return 1
  spl_require_cloud_env || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local box="${DESK_BOX:-$(spl_desk_box_default)}" tenants t rc=0
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ && "$box" != box-wui ]] || { do_log "FATAL DESK_BOX '$box' is not a box id"; return 1; }
  tenants="$(tr ',' ' ' <<<"${TENANT_IDS:-}" | xargs)"
  [[ -n "$tenants" ]] || tenants="$(_spl_anr_tenants "$box")"
  [[ -n "$tenants" ]] || { do_log "FATAL no desk of $box is pinned in $SPL_STATE_DIR/desk: nothing to repair here"; return 1; }
  for t in $tenants; do
    spl_require_tenant_slug "$t" || return 1
    [[ -s "$SPL_STATE_DIR/desk/$t/$box/pinned" ]] || { do_log "FATAL no pinned desk for $box in $t ($SPL_STATE_DIR/desk/$t/$box)"; return 1; }
  done
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_host_spool || return 1
  for t in $tenants; do
    _spl_anr_tenant "$t" "$box" "$dry" || rc=1
  done
  (( dry )) && do_log "OK DRY_RUN nothing was renamed. Re-run with DRY_RUN=0 to rename."
  return $rc
}

# _spl_anr_tenants <box>: every workspace whose <box> desk is pinned here.
_spl_anr_tenants() {
  local p
  for p in "$SPL_STATE_DIR"/desk/*/"$1"/pinned; do
    [[ -s "$p" ]] && basename "$(dirname "$(dirname "$p")")"
  done | sort -u | xargs
}

# _spl_anr_tenant <tenant> <box> <dry>: one workspace, end to end.
_spl_anr_tenant() {
  local tenant="$1" box="$2" dry="$3" d="$SPL_STATE_DIR/desk/$1/$2" rows id n out res left="" flag=()
  (( dry )) && flag=(--dry-run)
  rows="$(spl_via_proxy _spl_anr_candidates_run "$tenant" "$box")" ||
    { do_log "FATAL listing the hash-named files of $box in $tenant failed"; return 1; }
  res="$(mktemp)" || return 1
  while read -r id n; do
    [[ -n "$id" ]] || continue
    if out="$(spl_desk_spool "$d" "$box" "$tenant" "$SPL_HUB_URL" -- attach-rename --msg-id "$id" "${flag[@]}" 2>&1)"; then
      printf '%s\n' "$out" | tail -n 1 >>"$res"
    else
      python3 -c 'import json,sys; print(json.dumps({"msg_id": sys.argv[1], "error": sys.argv[2][-300:]}))' "$id" "$out" >>"$res"
    fi
  done <<<"$rows"
  if (( ! dry )); then
    left="$(spl_via_proxy _spl_anr_candidates_run "$tenant" "$box")" ||
      { rm -f "$res"; do_log "FATAL re-counting $box in $tenant after the rename failed"; return 1; }
    left="$(awk '{s += $2} END {print s + 0}' <<<"$left")"
  fi
  _spl_anr_summary "$tenant" "$box" "$dry" "$rows" "$left" <"$res"; local src=$?
  rm -f "$res"
  return $src
}

# _spl_anr_candidates_run <tenant> <box>: "<msg_id> <n>" per message <box> sent
# in <tenant>, in retention, with n files still named by their own sha256.
# Read only (Postgres refuses a write); values travel as psql variables.
_spl_anr_candidates_run() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -F ' ' -v ON_ERROR_STOP=1 -v tenant="$1" -v box="$2" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.rls_scope = 'operator';
SELECT m.msg_id::text, count(*)
  FROM messages m,
       jsonb_array_elements(CASE WHEN jsonb_typeof(m.files::jsonb) = 'array' THEN m.files::jsonb ELSE '[]'::jsonb END) f
 WHERE m.tenant_id = :'tenant' AND m.from_box = :'box' AND m.expires_at > now()
   AND f->>'name' ~ '^[0-9a-f]{64}$' AND (f->>'name' = f->>'file_id' OR f->>'name' = f->>'sha256')
 GROUP BY m.msg_id, m.received_at
 ORDER BY m.received_at, m.msg_id;
ROLLBACK;
SQL
}

# _spl_anr_summary <tenant> <box> <dry> <rows> <left>: the workspace's JSON
# line from the attach-rename results on stdin; exit 1 on any failure.
_spl_anr_summary() {
  python3 -c '
import json, sys
env, tenant, box, dry, rows, left = sys.argv[1:]
want = {l.split()[0]: int(l.split()[1]) for l in rows.splitlines() if l.strip()}
by_ext, samples, failed, renamed, unknown = {}, [], [], 0, 0
for line in sys.stdin:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if "error" in r:
        failed.append(r)
        continue
    for f in r.get("files", []):
        if f.get("to"):
            renamed += 1
            by_ext[f["ext"]] = by_ext.get(f["ext"], 0) + 1
            if len(samples) < 5:
                samples.append({"msg_id": r["msg_id"], "before": f["from"], "after": f["to"]})
        else:
            unknown += 1
out = {"env": env, "tenant": tenant, "box": box, "dry_run": dry == "1", "messages": len(want),
       "files": sum(want.values()), ("would_rename" if dry == "1" else "renamed"): renamed,
       "unknown": unknown, "by_type": by_ext, "samples": samples, "failed": failed}
if left != "":
    out["left"] = int(left)
print(json.dumps(out, sort_keys=True))
sys.exit(1 if failed else 0)
' "$ENV" "$1" "$2" "$3" "$4" "$5"
}
