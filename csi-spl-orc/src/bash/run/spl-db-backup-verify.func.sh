#!/bin/bash
# The verify half of the daily backup (spec 029 §4.4). Its own file because
# csi-rel's runner maps ONE action per file: do_load_functions derives
# do_<snake> from <kebab>.func.sh, so a second do_* function in
# spl-db-backup.func.sh is sourced but never registered as an action
# (measured 2026-09-21: `./run -a do_spl_db_backup_verify` -> actions_found=0).
# The shared helpers (spl_db_backup_bucket) stay next door; every *.func.sh is
# sourced before any action runs.

#------------------------------------------------------------------------------
# @description PROVE a dump restores. Downloads one object from the env's 045
# @description bucket, restores it into a THROWAWAY local postgres container,
# @description counts every table, and compares that against the live database
# @description read-only. Nothing in GCP is mutated and the live DB is only
# @description read: the scratch database is a container on this box (or on the
# @description runner), and it is removed either way.
# @description
# @description The comparison is deliberately NOT "the counts are equal". The
# @description dump and the live read are two different instants, and dev takes
# @description writes between them, so equality would be red for the wrong
# @description reason. What it asserts instead is what a broken dump actually
# @description looks like: a table that the live DB has and the restore does
# @description not, or a table that restores EMPTY while the live one has rows.
# @description A table created by a migration newer than the dump's
# @description spool_schema_migrations max is "expected missing" and is listed
# @description with that migration; it is not a failure. A table the dump's
# @description level should already hold, missing, still fails the check.
# @description The full per-table table is printed so drift is visible.
# @param ENV - required: dev or prd
# @param OBJECT (optional) - the gs:// uri to verify; default the newest in the bucket
# @param SPL_RESTORE_IMAGE (optional) - default postgres:16-alpine
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev ./run -a do_spl_db_backup_verify
# @example ENV=prd OBJECT=gs://csi-spl-prd-db-backups/prd/spool-20260921T051700Z.sql.gz ./run -a do_spl_db_backup_verify
#------------------------------------------------------------------------------
do_spl_db_backup_verify() {
  do_require_bin gcloud docker psql python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local bucket
  bucket="$(spl_db_backup_bucket)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1

  local uri="${OBJECT:-}"
  [[ -n "$uri" ]] || uri="$(spl_db_backup_newest "$bucket")" ||
    { do_log "FATAL $ENV: no object in gs://$bucket to verify"; return 1; }
  do_log "INFO $ENV: verifying $uri"

  local work rc=0
  work="$(mktemp -d)" || return 1
  gcloud storage cp "$uri" "$work/dump.sql.gz" --account="$GCP_ACCOUNT" >/dev/null 2>&1 ||
    { rm -rf "$work"; do_log "FATAL $ENV: cannot download $uri"; return 1; }
  gunzip -f "$work/dump.sql.gz" ||
    { rm -rf "$work"; do_log "FATAL $ENV: $uri is not gzip"; return 4; }
  do_log "INFO $ENV: downloaded $(stat -c %s "$work/dump.sql") bytes of SQL"

  spl_db_backup_restore_counts "$work/dump.sql" >"$work/restored.txt" || rc=$?
  (( rc == 0 )) || { rm -rf "$work"; return $rc; }
  spl_via_proxy _spl_db_backup_live_counts >"$work/live.txt" || rc=$?
  (( rc == 0 )) || { rm -rf "$work"; do_log "FATAL $ENV: cannot read the live counts"; return 1; }

  spl_db_backup_compare "$work/restored.txt" "$work/live.txt" \
    "$(spl_db_backup_dump_max "$work/dump.sql")" || rc=$?
  rm -rf "$work"
  return $rc
}

# spl_db_backup_newest <bucket> -> the newest object uri in the bucket.
spl_db_backup_newest() {
  local u
  u="$(gcloud storage ls "gs://$1/**" --account="$GCP_ACCOUNT" 2>/dev/null | sort | tail -1)"
  [[ -n "$u" ]] || return 1
  printf '%s' "$u"
}

# spl_db_backup_restore_counts <dump.sql> -> "<table> <count>" per line, from a
# THROWAWAY postgres container that is removed whatever happens. The container
# is the scratch database: nothing local and nothing in the cloud is touched.
spl_db_backup_restore_counts() {
  local dump="$1" img="${SPL_RESTORE_IMAGE:-postgres:16-alpine}" con i
  con="spl-restorecheck-$ENV-$$"
  docker run -d --rm --name "$con" -e POSTGRES_PASSWORD=restorecheck -e POSTGRES_DB=restorecheck \
    "$img" >/dev/null 2>&1 || { do_log "FATAL cannot start $img for the restore check"; return 1; }
  # shellcheck disable=SC2064
  trap "docker rm -fv '$con' >/dev/null 2>&1 || true; trap - RETURN" RETURN
  # READINESS OVER TCP, NOT THE UNIX SOCKET. The postgres image runs a
  # TEMPORARY server during initdb that listens on the unix socket only, so
  # `pg_isready -U postgres` answers YES while the real server has not started
  # yet; the restore then runs into the restart and loses everything. Measured
  # 2026-09-21 on the first prd verify: "ready after 2s", psql exit 2, ZERO
  # tables restored, and the verdict blamed the dump - which was fine. The
  # temporary server never listens on 127.0.0.1, so a TCP probe cannot see it,
  # and a real `select 1` over TCP is the proof the door is open for good.
  # `if` and not `probe && break`: a bare failing probe as the last command of
  # a loop body is one errexit away from killing the run.
  local ready=0
  for i in {1..120}; do
    if docker exec "$con" psql -U postgres -h 127.0.0.1 -d restorecheck -XAtc 'SELECT 1' >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 1
  done
  if (( ready == 0 )); then
    do_log "FATAL the restore-check container was not ready after 120 s; its last log lines:"
    docker logs --tail 20 "$con" 2>&1 | while read -r l; do do_log "FATAL   $l"; done
    return 1
  fi
  do_log "INFO restore-check container accepted TCP after ${i}s"

  # The dump names the cloud logins as owners; they do not exist here, so
  # ON_ERROR_STOP stays OFF and the count comparison is what decides, not the
  # exit code of a role-grant line.
  local log="${dump%.sql}.restore.log"
  docker exec -i "$con" psql -q -U postgres -h 127.0.0.1 -d restorecheck -v ON_ERROR_STOP=0 <"$dump" >"$log" 2>&1
  local tables
  tables="$(docker exec "$con" psql -U postgres -h 127.0.0.1 -d restorecheck -XAtc "
    SELECT table_name FROM information_schema.tables
     WHERE table_type = 'BASE TABLE' AND table_schema = 'public' ORDER BY 1" 2>/dev/null)"
  # A restore that lands NO table is a fault in the RESTORE, not in the dump,
  # and saying so with psql's own words is the difference between a fixable
  # report and "26 tables missing" pointing at an innocent backup.
  if [[ -z "$tables" ]]; then
    do_log "FATAL the restore produced no table; psql said:"
    tail -20 "$log" 2>/dev/null | while read -r l; do do_log "FATAL   $l"; done
    return 1
  fi
  # The dump's schema level is max(filename), the same head spool migrate
  # records. Written beside the dump so the compare can run after this
  # container is gone. Empty when the ledger is absent: the compare then
  # treats every missing table as a real failure.
  local maxf=""
  if grep -qx 'spool_schema_migrations' <<<"$tables"; then
    maxf="$(docker exec "$con" psql -U postgres -h 127.0.0.1 -d restorecheck -XAtc \
      "SELECT coalesce(max(filename), '') FROM spool_schema_migrations" 2>/dev/null || true)"
    # psql on a docker exec can leave a CR; the filename compare is exact.
    maxf="$(printf '%s' "$maxf" | tr -d '[:space:]')"
  fi
  printf '%s\n' "$maxf" >"${dump}.schema-max"
  local t
  while read -r t; do
    [[ -n "$t" ]] || continue
    printf '%s %s\n' "$t" "$(docker exec "$con" psql -U postgres -h 127.0.0.1 -d restorecheck -XAtc "SELECT count(*) FROM \"$t\"" 2>/dev/null)"
  done <<<"$tables"
  # A caller's own check of the restored copy while the container still exists
  # (spec 099 T007: the topic-head verify). SPL_RESTORE_CHECK names a function,
  # called with the container; its output goes to stderr, since stdout is the
  # count list, and a failure fails the restore check.
  if [[ -n "${SPL_RESTORE_CHECK:-}" ]]; then
    "$SPL_RESTORE_CHECK" "$con" >&2 || return $?
  fi
}

# _spl_db_backup_live_counts -> "<table> <count>" per line from the LIVE DB,
# read-only, in the operator RLS scope (without it every tenant table counts 0
# and the comparison would pass a dump that is actually empty).
_spl_db_backup_live_counts() {
  local tables
  tables="$(spl_psql_ro "$SPL_PROXY_DSN" "SELECT table_name FROM information_schema.tables
     WHERE table_type = 'BASE TABLE' AND table_schema = 'public' ORDER BY 1;")" || return 1
  local t sql=""
  while read -r t; do
    [[ -n "$t" ]] || continue
    sql+="SELECT '$t', count(*) FROM \"$t\" UNION ALL "
  done <<<"$tables"
  [[ -n "$sql" ]] || { do_log "FATAL the live DB reports no table"; return 1; }
  spl_psql_ro "$SPL_PROXY_DSN" "${sql%UNION ALL } ORDER BY 1;" | tr '|' ' '
}

# spl_db_backup_dump_max <dump.sql> -> the schema head restore_counts wrote
# beside that dump (one filename, or empty).
spl_db_backup_dump_max() {
  local f="${1}.schema-max"
  [[ -f "$f" ]] || return 0
  tr -d '\n' <"$f"
}

# spl_db_backup_migrations_dir -> the spool-hub migration files on THIS box,
# whose CREATE TABLE statements say which migration introduced a table.
# SPL_MIGRATIONS_DIR is the path inside the hub image (cnf
# SPOOL_HUB_MIGRATIONS_DIR); it is not a directory here. Tests set
# SPL_DB_BACKUP_MIGRATIONS_DIR. A real run uses cnf hub.image.sql_src
# (SPL_IMAGE_SQL_SRC), then the tree next to this module.
spl_db_backup_migrations_dir() {
  if [[ -n "${SPL_DB_BACKUP_MIGRATIONS_DIR:-}" ]]; then
    printf '%s' "$SPL_DB_BACKUP_MIGRATIONS_DIR"
    return 0
  fi
  if [[ -n "${SPL_IMAGE_SQL_SRC:-}" && -d "$SPL_IMAGE_SQL_SRC" ]]; then
    printf '%s' "$SPL_IMAGE_SQL_SRC"
    return 0
  fi
  local root="${APP_PATH:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "${PROJ_PATH:-}/.." 2>/dev/null && pwd)" || root=""
  fi
  printf '%s' "$root/csi-spl-rdb/src/sql/postgres/spool-hub"
}

# spl_db_backup_compare <restored> <live> [dump_schema_max] -> the verdict.
# Exit 5 when a live table is missing from the restore, or restored EMPTY
# while the live one has rows. Those are what a truncated or RLS-blanked dump
# looks like; a plain count difference is not, because the two reads are
# minutes apart. A table whose CREATE TABLE sits in a migration file strictly
# newer than the dump's spool_schema_migrations max is expected missing
# (newer than the dump: <that file>) and is not a failure. No max, or a table
# the catalog does not name, stays a failure.
spl_db_backup_compare() {
  local v migdir dump_max="${3:-}"
  migdir="$(spl_db_backup_migrations_dir)"
  do_log "INFO ${ENV:-restore}: dump schema max [${dump_max:-}] migrations ${migdir}"
  v="$(SPL_MIGRATIONS_DIR="$migdir" python3 -c '
import os, re, sys
def load(p):
    d = {}
    for line in open(p):
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            d[parts[0]] = int(parts[1])
    return d
res, live = load(sys.argv[1]), load(sys.argv[2])
dump_max = (sys.argv[3] if len(sys.argv) > 3 else "").strip()
if not re.fullmatch(r"[0-9]{4}_[A-Za-z0-9_]+\.sql", dump_max):
    dump_max = ""
created = {}
migdir = os.environ.get("SPL_MIGRATIONS_DIR", "")
pat = re.compile(
    "create\\s+(?:unlogged\\s+)?table\\s+(?:if\\s+not\\s+exists\\s+)?(?:only\\s+)?"
    "(?:\"?(?:public\"?\\s*\\.\\s*\"?)?)([A-Za-z_][A-Za-z0-9_]*)",
    re.I)
if dump_max and os.path.isdir(migdir):
    for fn in sorted(os.listdir(migdir)):
        if not fn.endswith(".sql"):
            continue
        path = os.path.join(migdir, fn)
        text = open(path, encoding="utf-8", errors="replace").read()
        text = re.sub("/\\*.*?\\*/", " ", text, flags=re.S)
        text = re.sub("--[^\\n]*", " ", text)
        for m in pat.finditer(text):
            created.setdefault(m.group(1), fn)
missing, expected = [], []
for t in sorted(x for x in live if x not in res):
    mig = created.get(t, "")
    if dump_max and mig > dump_max:
        expected.append((t, mig))
    else:
        missing.append(t)
blank = sorted(t for t in live if t in res and live[t] > 0 and res[t] == 0)
note = {}
for t, mig in expected:
    note[t] = "expected missing (newer than the dump: %s)" % mig
print("TABLE RESTORED LIVE")
for t in sorted(set(res) | set(live)):
    extra = (" " + note[t]) if t in note else ""
    print("%s %s %s%s" % (t, res.get(t, "-"), live.get(t, "-"), extra))
if missing:
    print("VERDICT 5 %d live table(s) missing from the restore: %s" % (len(missing), ",".join(missing)))
elif blank:
    print("VERDICT 5 %d table(s) restored EMPTY while live has rows: %s" % (len(blank), ",".join(blank)))
elif not res:
    print("VERDICT 5 the restore produced no table at all")
else:
    rows = sum(res.values())
    msg = "%d table(s), %d row(s) restored; every live table is present and non-empty where live is" % (len(res), rows)
    if expected:
        listed = ", ".join("%s (%s)" % (t, mig) for t, mig in expected)
        msg += "; %d expected missing (newer than the dump): %s" % (len(expected), listed)
    print("VERDICT 0 " + msg)
' "$1" "$2" "$dump_max")" || { do_log "FATAL cannot compare the counts"; return 1; }
  printf '%s\n' "$v" | grep -v '^VERDICT '
  local line code msg
  line="$(grep '^VERDICT ' <<<"$v")"
  code="$(awk '{print $2}' <<<"$line")"
  msg="${line#VERDICT $code }"
  if [[ "$code" == 0 ]]; then do_log "OK $ENV restore check: $msg"; else do_log "FAIL $ENV restore check: $msg"; fi
  return "$code"
}
