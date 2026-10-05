#!/bin/bash
#------------------------------------------------------------------------------
# @description Generate spool-hub-roles/public-export-grants.sql from the public
# @description dataset allow-list (spec 091 T004, fence 1, spec 5.1): REVOKE ALL
# @description from the export login, then one column-level GRANT SELECT
# @description (<public cols>) ON <table> per allow-list table, in file order,
# @description plus SELECT on public_export_workspace (rdb 0126). Nothing else:
# @description a query naming any other column fails in Postgres itself.
# @description The file is committed; the store test and the bash test pin it
# @description equal to this output, and do_spl_public_export_role refuses a
# @description stale one. No cloud, no database: a pure render.
# @param ALLOW_LIST_VERSION (optional) - default: the highest allow-list.v<N>.yaml in csi-spl-orc/cnf/public-dataset
# @param CHECK (optional) - 1: write nothing; exit 1 when the committed file differs
# @param OUT (optional) - write here instead of the committed path
# @example ./run -a do_spl_public_export_grants_gen
# @example CHECK=1 ./run -a do_spl_public_export_grants_gen
#------------------------------------------------------------------------------
do_spl_public_export_grants_gen() {
  do_require_bin yq sha256sum || return 1
  local list dest="$APP_PATH/csi-spl-rdb/src/sql/postgres/spool-hub-roles/public-export-grants.sql"
  list="$(spl_public_allow_list)" || return 1
  [[ "${CHECK:-0}" =~ ^[01]$ ]] || { do_log "FATAL CHECK must be 0 or 1"; return 1; }

  local tmp
  tmp="$(mktemp)" || return 1
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'; trap - RETURN" RETURN
  spl_public_export_grants_sql "$list" >"$tmp" || return 1

  if [[ "${CHECK:-0}" == 1 ]]; then
    cmp -s "$tmp" "$dest" ||
      { do_log "FAIL $dest is not what $list generates: run ./run -a do_spl_public_export_grants_gen and commit it"; return 1; }
    do_log "OK $(basename "$dest") equals what $(basename "$list") generates"
    return 0
  fi
  local out="${OUT:-$dest}"
  cat "$tmp" >"$out" || { do_log "FATAL cannot write $out"; return 1; }
  do_log "OK generated $out from $(basename "$list") ($(grep -c '^GRANT SELECT (' "$out") table(s))"
}

# spl_public_allow_list -> the path of the allow-list file (refusals on
# stderr: callers capture stdout): version
# ALLOW_LIST_VERSION when set, else the highest allow-list.v<N>.yaml
spl_public_allow_list() {
  local dir="$PROJ_PATH/cnf/public-dataset" f
  if [[ -n "${ALLOW_LIST_VERSION:-}" ]]; then
    [[ "$ALLOW_LIST_VERSION" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL ALLOW_LIST_VERSION must be a positive integer" >&2; return 1; }
    f="$dir/allow-list.v$ALLOW_LIST_VERSION.yaml"
  else
    f="$(ls "$dir"/allow-list.v*.yaml 2>/dev/null | sort -V | tail -1)"
  fi
  [[ -n "$f" && -s "$f" ]] || { do_log "FATAL no allow-list ${f:-in $dir}" >&2; return 1; }
  echo "$f"
}

# spl_public_export_grants_sql <allow-list> -> the grants file on stdout. Every
# identifier is checked to be a plain lower-case name before it is printed.
spl_public_export_grants_sql() {
  local list="$1" rows sum ver
  ver="$(yq -r '.version // ""' "$list")" || return 1
  [[ "$(basename "$list")" == "allow-list.v$ver.yaml" ]] ||
    { do_log "FATAL $list says version '$ver'" >&2; return 1; }
  rows="$(yq -r '.tables | to_entries[] | .key + " " + (.value.public | join(","))' "$list")" || return 1
  [[ -n "$rows" ]] || { do_log "FATAL $list lists no table" >&2; return 1; }
  grep -qvE '^[a-z_][a-z0-9_]* [a-z_][a-z0-9_]*(,[a-z_][a-z0-9_]*)*$' <<<"$rows" &&
    { do_log "FATAL $list has a table without public columns or a name that is not [a-z0-9_]" >&2; return 1; }
  sum="$(sha256sum <"$list" | cut -d' ' -f1)"
  cat <<EOF_SQL
-- public-export-grants.sql - GENERATED, do not edit (spec 091 T004, fence 1).
-- Source: csi-spl-orc/cnf/public-dataset/$(basename "$list") (sha256 $sum)
-- by csi-spl-orc ./run -a do_spl_public_export_grants_gen. A change to the
-- allow-list is a change to this file in the same commit (the store test
-- TestPublicExportGrantsEqualAllowList and public-export-grants-gen.tst.sh).
-- NOT a migration: psql runs it AS THE SCHEMA OWNER from
-- do_spl_public_export_role, after public-export-role.sql. Idempotent.
--
-- The export login holds column-level SELECT on exactly the public columns
-- of spec 4.1 and SELECT on public_export_workspace (fence 2, rdb 0126), so a
-- query naming any other column or table fails in Postgres itself. REVOKE ALL
-- on a table also revokes its column privileges.

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM spool_public_export;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM spool_public_export;
GRANT USAGE ON SCHEMA public TO spool_public_export;

EOF_SQL
  local t cols
  while read -r t cols; do
    printf 'GRANT SELECT (%s) ON %s TO spool_public_export;\n' "${cols//,/, }" "$t"
  done <<<"$rows"
  printf 'GRANT SELECT ON public_export_workspace TO spool_public_export;\n'
}
