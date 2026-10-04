#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Static scan of the spool migration SQL for vendor lock-in
# @description (spec 076, owner decision 5): standard PostgreSQL only, so the
# @description same files run on Cloud SQL, RDS and a local PostgreSQL.
# @description A deny list cannot prove absence. It only catches the identifier
# @description prefixes it names. A construct that is not one of those prefixes
# @description passes, including every contrib extension (unaccent, pg_trgm).
# @description
# @description Deny list, matched case-insensitively as a whole identifier on
# @description the SQL that remains after `--` and `/* */` comments are removed
# @description (a comment may name a role; a string and a function body may not):
# @description   cloudsql*   Cloud SQL system roles, users and flags
# @description               (cloudsqlsuperuser, cloudsqladmin, cloudsqliamuser,
# @description               cloudsqliamgroup, cloudsqliamserviceaccount,
# @description               cloudsqliamgroupuser, cloudsqliamgroupserviceaccount,
# @description               cloudsqlinactiveuser, cloudsqlagent,
# @description               cloudsqlconnpooladmin, cloudsqlimportexport,
# @description               cloudsqllogical, cloudsqlobservability,
# @description               cloudsqlreplica, and cloudsql.* database flags)
# @description   google_*    Cloud SQL extensions and functions
# @description               (google_ml_integration, google_read_only_session,
# @description               google_ml.*, google_db_advisor_*, google_insights)
# @description   alloydb*    AlloyDB-only extensions and roles
# @description   rds_*       RDS roles (rds_superuser, rds_iam, ...)
# @description   rdsadmin*   the RDS admin role
# @description   aws_*       RDS extensions (aws_s3, aws_commons, aws_lambda, aws_ml)
# @description   aurora_*    Aurora-only helpers (aurora_version)
# @description
# @description Hits print as file:line: token. One summary line:
# @description   SQL_PORTABLE n=<files> hits=<n>
# @description and one limit line, SQL_PORTABLE_LIMIT, restating that the list
# @description cannot prove a file is free of vendor SQL.
# @description Exit 0 when hits=0, 1 when a named token is present, 2 when a
# @description configured directory is missing or holds no .sql (a scan that
# @description read nothing proved nothing).
# @param SQL_PORTABLE_TREE (optional) - checkout root, default $APP_PATH
# @param SQL_PORTABLE_DIRS (optional) - space-separated dirs under the tree.
# @param        Default: csi-spl-rdb/src/sql/postgres/spool-hub and
# @param        csi-spl-rdb/src/sql/postgres/spool-hub-roles
# @example ./run -a do_check_sql_portable
#------------------------------------------------------------------------------

# Folded to lower-case by the scanner. A whole identifier: letters that merely
# sit inside a longer name do not match.
_SQL_PORTABLE_RE='(^|[^a-z0-9_])(cloudsql[a-z0-9_]*|google_[a-z0-9_]*|alloydb[a-z0-9_]*|rdsadmin[a-z0-9_]*|rds_[a-z0-9_]*|aws_[a-z0-9_]*|aurora_[a-z0-9_]*)'

# Fills _SQL_PORTABLE_FILES with the *.sql under the configured dirs.
# Exit 2 when a dir is missing or none of them holds a .sql file.
_sql_portable_collect() {
  local tree="$1" d abs f
  local -a dirs=()
  _SQL_PORTABLE_FILES=()
  if [[ -z "${SQL_PORTABLE_DIRS+x}" ]]; then
    dirs=(
      csi-spl-rdb/src/sql/postgres/spool-hub
      csi-spl-rdb/src/sql/postgres/spool-hub-roles
    )
  elif [[ -z "$SQL_PORTABLE_DIRS" ]]; then
    do_log "FATAL sql portable: SQL_PORTABLE_DIRS is empty -- the scan proved nothing"
    return 2
  else
    read -r -a dirs <<< "$SQL_PORTABLE_DIRS" || true
  fi
  if [[ ${#dirs[@]} -eq 0 ]]; then
    do_log "FATAL sql portable: no directories to scan -- the scan proved nothing"
    return 2
  fi
  for d in "${dirs[@]}"; do
    case "$d" in
      /*|..|../*|*/..|*/../*)
        do_log "FATAL sql portable: dir must be relative to the checkout, got $d"
        return 2 ;;
    esac
    abs="$tree/$d"
    if [[ ! -d "$abs" ]]; then
      do_log "FATAL sql portable: missing dir $d under $tree -- the scan proved nothing"
      return 2
    fi
    while IFS= read -r -d '' f; do
      _SQL_PORTABLE_FILES+=("$f")
    done < <(find "$abs" -type f -name '*.sql' -print0 | LC_ALL=C sort -z)
  done
  if [[ ${#_SQL_PORTABLE_FILES[@]} -eq 0 ]]; then
    do_log "FATAL sql portable: no .sql under the configured dirs -- the scan proved nothing"
    return 2
  fi
}

# Print file:line: token for one SQL file. Comments are not constructs.
_sql_portable_one() {
  local rel="$1" src="$2"
  awk -v file="$rel" -v re="$_SQL_PORTABLE_RE" '
    BEGIN { state = 0; bret = 0; sret = 0; dq = ""; q = sprintf("%c", 39) }
    {
      line = $0
      sub(/\r$/, "", line)
      out = ""
      i = 1
      nch = length(line)
      while (i <= nch) {
        c = substr(line, i, 1)
        if (state == 1) {
          if (c == "*" && substr(line, i + 1, 1) == "/") { state = bret; i += 2; continue }
          i++
          continue
        }
        if (state == 2) {
          out = out c
          if (c == q && substr(line, i + 1, 1) == q) { out = out q; i += 2; continue }
          if (c == q) state = sret
          i++
          continue
        }
        if (state == 3 && length(dq) > 0 && substr(line, i, length(dq)) == dq) {
          out = out dq
          i += length(dq)
          state = 0
          dq = ""
          continue
        }
        if (c == "-" && substr(line, i + 1, 1) == "-") break
        if (c == "/" && substr(line, i + 1, 1) == "*") { bret = state; state = 1; i += 2; continue }
        if (c == q) { sret = state; state = 2; out = out c; i++; continue }
        if (state == 0 && c == "$") {
          rest = substr(line, i)
          if (match(rest, /^\$[A-Za-z0-9_]*\$/)) {
            dq = substr(rest, 1, RLENGTH)
            out = out dq
            i += RLENGTH
            state = 3
            continue
          }
        }
        out = out c
        i++
      }
      low = tolower(out)
      while (match(low, re)) {
        tok = substr(low, RSTART, RLENGTH)
        sub(/^[^a-z0-9_]/, "", tok)
        printf "%s:%d: %s\n", file, NR, tok
        low = substr(low, RSTART + RLENGTH)
        if (low == "") break
      }
    }
  ' "$src"
}

do_check_sql_portable() {
  local tree app="" f rel n=0 hits=0 rc=0 hitfile=""
  # APP_PATH is exported by ./run. A caller may pass SQL_PORTABLE_TREE instead.
  # shellcheck disable=SC2154
  app="${APP_PATH:-}"
  tree="${SQL_PORTABLE_TREE:-$app}"
  if [[ -z "$tree" ]]; then
    do_log "FATAL sql portable: SQL_PORTABLE_TREE or APP_PATH must name the checkout -- the scan proved nothing"
    return 2
  fi
  tree=$(cd "$tree" 2>/dev/null && pwd) || {
    do_log "FATAL sql portable: no directory at $tree -- the scan proved nothing"
    return 2
  }
  _sql_portable_collect "$tree" || return
  hitfile=$(mktemp) || return 2
  for f in "${_SQL_PORTABLE_FILES[@]}"; do
    n=$((n + 1))
    rel="${f#"$tree"/}"
    if ! _sql_portable_one "$rel" "$f" >>"$hitfile"; then
      rm -f "$hitfile"
      do_log "FATAL sql portable: scanner failed on $rel"
      return 2
    fi
  done
  if [[ -s "$hitfile" ]]; then
    cat "$hitfile"
    hits=$(wc -l <"$hitfile")
    hits=${hits//[[:space:]]/}
    rc=1
    do_log "FATAL sql portable: $hits vendor token(s) in $n file(s) -- file:line above"
  else
    do_log "INFO sql portable: n=$n hits=0"
  fi
  rm -f "$hitfile"
  printf 'SQL_PORTABLE n=%s hits=%s\n' "$n" "$hits"
  printf '%s\n' "SQL_PORTABLE_LIMIT a deny list only catches the tokens it names; it cannot prove absence"
  printf '%s\n' "SQL_PORTABLE_DENY cloudsql* google_* alloydb* rds_* rdsadmin* aws_* aurora_*"
  return "$rc"
}
