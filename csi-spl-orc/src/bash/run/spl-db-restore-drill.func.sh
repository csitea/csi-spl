#!/bin/bash
#------------------------------------------------------------------------------
# @description The RESTORE DRILL of the hub DB backup (spec 029 §6.9, SPL-2310):
# @description "a backup that has never been restored is not a backup".
# @description Takes the newest DEV dump in the 045 bucket, restores it into a
# @description THROWAWAY postgres container (never Cloud SQL, never prd),
# @description removed whatever happens, and proves the restored copy is one
# @description today's hub can run on, WITHOUT the live database:
# @description   1. the dump downloads and is gzip; the restore lands tables,
# @description      into a cluster that first gets the NOLOGIN group roles the
# @description      migrations create (a dump carries no role, SPL-3173)
# @description   2. schema: every spool_schema_migrations row that names a
# @description      file in the repo's rdb tree has that file's sha256 (the
# @description      hub's migrate refuses a changed file); a row naming no
# @description      file (a rename) is a WARN; the dump's schema head and the
# @description      files still pending are printed
# @description   3. migrate: the hub's own `spool migrate` runs on the copy
# @description      and afterwards every repo file is applied
# @description   4. sanity: the core tables (SPL_RESTORE_DRILL_NONEMPTY) are
# @description      present and hold rows
# @description Prints one timing line (download, restore, migrate, total) and
# @description fails loud on any step. The compare against LIVE is
# @description do_spl_db_backup_verify's job; the drill reads no live row, so
# @description it is also what a restore looks like when live is gone.
# @description prd is refused: a prd drill takes the owner's go per run.
# @description Exit: 0 green, 1 a setup step, 4 not gzip, 5 empty dump, no
# @description table or a core table empty, 8 schema mismatch, 9 migrate failed.
# @param ENV - required: dev (prd is refused)
# @param BACKUP_URI (optional) - a gs:// .sql.gz under gs://<045 bucket>/dev/, or latest (default)
# @param SPL_RESTORE_DRILL_SPOOL (optional) - the spool binary that migrates, default `spool` on the PATH
# @param SPL_RESTORE_DRILL_NONEMPTY (optional) - tables that must hold rows, default "tenants messages"
# @param SPL_RESTORE_IMAGE (optional) - default postgres:16-alpine
# @example ENV=dev ./run -a do_spl_db_restore_drill
# @example ENV=dev SPL_RESTORE_DRILL_SPOOL=$HOME/.local/bin/spool ./run -a do_spl_db_restore_drill
#------------------------------------------------------------------------------
do_spl_db_restore_drill() {
  [[ "${ENV:-}" == dev ]] ||
    { do_log "FATAL the restore drill runs on dev only (got ENV=${ENV:-}); a prd drill takes the owner's go per run"; return 1; }
  do_require_bin gcloud docker python3 yq || return 1
  local spool="${SPL_RESTORE_DRILL_SPOOL:-spool}"
  command -v "$spool" >/dev/null 2>&1 ||
    { do_log "FATAL no spool binary to migrate with: $spool (set SPL_RESTORE_DRILL_SPOOL)"; return 1; }
  do_spl_cloud_cnf || return 1
  local bucket uri="${BACKUP_URI:-latest}" migdir
  bucket="$(spl_db_backup_bucket)" || return 1
  migdir="$(spl_db_backup_migrations_dir)"
  [[ -d "$migdir" ]] || { do_log "FATAL no migrations dir at $migdir"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  # the env identity reads the 045 bucket (_spl_db_restore_gcloud)
  # shellcheck disable=SC2034 # read by _spl_db_restore_gcloud
  local SPL_RESTORE_WHO=env
  local base="gs://$bucket/$ENV"
  if [[ "$uri" == latest ]]; then
    uri="$(spl_gs_names "$base" | grep '\.sql\.gz$' | tail -1)"
    [[ -n "$uri" ]] || { do_log "FATAL $ENV: no dump under $base"; return 1; }
    uri="$base/$uri"
  fi
  [[ "$uri" == "$base/"*.sql.gz ]] ||
    { do_log "FATAL BACKUP_URI must be a .sql.gz object under $base, got: $uri"; return 1; }
  local age
  age="$(spl_db_restore_age "$uri")" || return 1
  do_log "INFO $ENV: restore drill of $uri (age ${age}s) into a throwaway container"

  local work rc=0 t0 t1
  work="$(umask 077 && mktemp -d)" || return 1
  t0="$(date +%s)"
  if _spl_db_restore_gcloud storage cp "$uri" "$work/dump.sql.gz" >/dev/null 2>&1; then
    t1="$(date +%s)"
    SPL_RESTORE_DRILL_DL_S=$(( t1 - t0 )) SPL_RESTORE_DRILL_T0="$t0" \
      spl_db_restore_drill_file "$work/dump.sql.gz" "$spool" "$migdir" || rc=$?
  else
    do_log "FATAL $ENV: cannot download $uri"; rc=1
  fi
  rm -rf "$work"
  if (( rc == 0 )); then do_log "OK $ENV: restore drill green for $uri (age ${age}s)"
  else do_log "FAIL $ENV: restore drill red (rc=$rc) for $uri"; fi
  return $rc
}

# spl_db_restore_drill_file <dump.sql.gz> <spool bin> <migrations dir> -> the
# drill on a local dump: no cloud call, so the tests drive it with fixtures.
spl_db_restore_drill_file() {
  local gz="$1" dump="${1%.gz}" rc=0 t0="${SPL_RESTORE_DRILL_T0:-$(date +%s)}" tr0 tr1
  [[ -s "$gz" ]] || { do_log "FAIL ${ENV:-dev}: the dump is empty (0 bytes)"; return 5; }
  gunzip -f "$gz" 2>/dev/null || { do_log "FAIL ${ENV:-dev}: the dump is not gzip"; return 4; }
  do_log "INFO ${ENV:-dev}: $(stat -c %s "$dump") bytes of SQL"
  do_require_bin docker || return 1
  tr0="$(date +%s)"
  # read by spl_db_restore_drill_check, the hook spl_db_backup_restore_counts calls
  # shellcheck disable=SC2034
  local SPL_RESTORE_CHECK=spl_db_restore_drill_check SPL_RESTORE_DRILL_BIN="$2" SPL_RESTORE_DRILL_MIGDIR="$3"
  # shellcheck disable=SC2034 # read by spl_db_backup_restore_counts
  local SPL_RESTORE_PREP=spl_db_restore_drill_roles
  # shellcheck disable=SC2034
  local SPL_RESTORE_DRILL_STATE="${dump}.drill"
  spl_db_backup_restore_counts "$dump" >"$dump.counts" || rc=$?
  tr1="$(date +%s)"
  if (( rc == 0 )); then spl_db_restore_drill_sanity "$dump.counts" || rc=$?; fi
  local mig_s; mig_s="$(cat "${dump}.drill.migrate_s" 2>/dev/null || echo -)"
  printf 'restore_drill env=%s rc=%s download_s=%s restore_s=%s migrate_s=%s total_s=%s\n' \
    "${ENV:-dev}" "$rc" "${SPL_RESTORE_DRILL_DL_S:--}" "$(( tr1 - tr0 ))" "$mig_s" "$(( $(date +%s) - t0 ))"
  return $rc
}

# spl_db_restore_drill_roles <container> -> the SPL_RESTORE_PREP hook of
# spl_db_backup_restore_counts: create, in the empty cluster and BEFORE the
# restore, every NOLOGIN group role the migrations create. Roles live in the
# cluster, not in a database, so a dump carries none: without them the dump's
# GRANT and CREATE POLICY lines naming a role fail (ON_ERROR_STOP is off) and
# the first pending migration that names one fails the migrate. Measured
# 2026-10-24, wf 49 run 40067941157: 0197 (creates spool_channel_scoped) in
# the ledger, the role absent, `apply 0219_dedicated_agents.sql: ERROR: role
# "spool_channel_scoped" does not exist`. The one source is the migration
# files themselves (spl_db_restore_drill_group_roles), no second list.
spl_db_restore_drill_roles() {
  local con="$1" roles
  if ! roles="$(spl_db_restore_drill_group_roles "$SPL_RESTORE_DRILL_MIGDIR")"; then
    grep '^UNREADABLE ' <<<"$roles" | while read -r l; do do_log "FAIL ${ENV:-dev} roles: ${l#UNREADABLE }"; done
    do_log "FATAL ${ENV:-dev} roles: cannot read the group roles from $SPL_RESTORE_DRILL_MIGDIR"
    return 1
  fi
  [[ -n "$roles" ]] || { do_log "INFO ${ENV:-dev} roles: the migrations create no group role"; return 0; }
  # names are \w+ and attributes upper-case words (the parser's own match)
  local n a sql=""
  while read -r n a; do
    sql+="SELECT format('CREATE ROLE %I $a', '$n') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$n')"$'\n\\gexec\n'
  done <<<"$roles"
  docker exec -i "$con" psql -q -U postgres -h 127.0.0.1 -d restorecheck -X -v ON_ERROR_STOP=1 <<<"$sql" >/dev/null 2>&1 ||
    { do_log "FATAL ${ENV:-dev} roles: cannot create the group roles in $con"; return 1; }
  do_log "INFO ${ENV:-dev} roles: $(wc -l <<<"$roles") group role(s) before the restore: $(awk '{ print $1 }' <<<"$roles" | paste -sd, -)"
}

# spl_db_restore_drill_group_roles <migrations dir> -> "<role> <attributes>"
# per line, sorted: every `CREATE ROLE <name> NOLOGIN ...` in the migration
# files, and every name of the ARRAY a `CREATE ROLE %I NOLOGIN ...` loops over
# (rdb 0168). Any other CREATE ROLE form is exit 1, so a new form is a red
# drill and a test, never a role silently missing from the copy: it prints
# one "UNREADABLE <file>: <text>" line per such statement.
spl_db_restore_drill_group_roles() {
  python3 -c '
import os, re, sys
migdir = sys.argv[1]
roles, bad = {}, []
stmt = re.compile(r"CREATE\s+ROLE\s+(%I|\w+)\s+(NOLOGIN(?:\s+[A-Z]+)*)")
for fn in sorted(os.listdir(migdir)):
    if not fn.endswith(".sql"):
        continue
    code = "\n".join(l.split("--", 1)[0] for l in open(os.path.join(migdir, fn)).read().splitlines())
    for m in re.finditer(r"CREATE\s+ROLE\b", code):
        s = stmt.match(code, m.start())
        if not s:
            bad.append("%s: %s" % (fn, code[m.start():m.start() + 60].split("\n")[0])); continue
        names = [s.group(1)]
        if s.group(1) == "%I":
            arr = re.findall(r"ARRAY\[([^\]]*)\]", code[:m.start()])
            names = re.findall(r"\x27(\w+)\x27", arr[-1]) if arr else []
            if not names:
                bad.append("%s: CREATE ROLE %%I with no ARRAY of names before it" % fn); continue
        for n in names:
            roles.setdefault(n, s.group(2))
for b in bad:
    print("UNREADABLE " + b)
for n in sorted(roles):
    print(n, roles[n])
sys.exit(1 if bad else 0)
' "$1"
}

# spl_db_restore_drill_check <container> -> the SPL_RESTORE_CHECK hook of
# spl_db_backup_restore_counts: the schema check, then the hub's migrate, on
# the restored copy while its container still exists. stdout is the caller's
# count list, so everything here reports through do_log.
spl_db_restore_drill_check() {
  local con="$1" ledger ip rc=0 m0 st="$SPL_RESTORE_DRILL_STATE"
  ledger="$(_spl_db_restore_drill_ledger_of "$con")" ||
    { do_log "FAIL ${ENV:-dev} schema: the restore has no spool_schema_migrations"; return 8; }
  [[ -n "$ledger" ]] || { do_log "FAIL ${ENV:-dev} schema: spool_schema_migrations is empty"; return 8; }
  spl_db_restore_drill_ledger "$ledger" "$SPL_RESTORE_DRILL_MIGDIR" before || return $?

  ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$con" 2>/dev/null)"
  [[ "$ip" =~ ^[0-9.]+$ ]] || { do_log "FATAL ${ENV:-dev}: no bridge address for $con: '$ip'"; return 1; }
  m0="$(date +%s)"
  "$SPL_RESTORE_DRILL_BIN" migrate --db "postgres://postgres:restorecheck@$ip:5432/restorecheck?sslmode=disable" \
    --sql-dir "$SPL_RESTORE_DRILL_MIGDIR" >"$st.migrate.log" 2>&1 || rc=9
  echo "$(( $(date +%s) - m0 ))" >"$st.migrate_s"
  if (( rc != 0 )); then
    do_log "FAIL ${ENV:-dev} migrate: spool migrate failed on the restored copy:"
    tail -5 "$st.migrate.log" | while read -r l; do do_log "FAIL   $l"; done
    return 9
  fi
  do_log "INFO ${ENV:-dev} migrate: $(grep -c '^applied ' "$st.migrate.log") applied, $(grep -c '^skipped ' "$st.migrate.log") already there"
  ledger="$(_spl_db_restore_drill_ledger_of "$con")" || ledger=""
  spl_db_restore_drill_ledger "$ledger" "$SPL_RESTORE_DRILL_MIGDIR" after
}

# _spl_db_restore_drill_ledger_of <container> -> "filename sha256" per line.
_spl_db_restore_drill_ledger_of() {
  docker exec "$1" psql -U postgres -h 127.0.0.1 -d restorecheck -XAtF ' ' -v ON_ERROR_STOP=1 -c \
    "SELECT filename, sha256 FROM spool_schema_migrations ORDER BY 1" 2>/dev/null | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

# spl_db_restore_drill_ledger <"filename sha" lines> <migrations dir> <before|after>
# -> the schema verdict. Exit 8 when the ledger is empty, when an applied file's
# bytes changed (the migrate would refuse it), and, after the migrate, when a
# repo file is still not applied. A ledger row naming no repo file is a WARN:
# a rename leaves the old name behind (measured 2026-10-17 on dev: 0040 and
# 0046 renamed by b4ef06302 on 2026-09-25), and the migrate never reads it.
spl_db_restore_drill_ledger() {
  local v code
  v="$(python3 -c '
import hashlib, os, sys
ledger, migdir, phase = sys.argv[1], sys.argv[2], sys.argv[3]
repo = {}
for fn in sorted(os.listdir(migdir)):
    if fn.endswith(".sql"):
        repo[fn] = hashlib.sha256(open(os.path.join(migdir, fn), "rb").read()).hexdigest()
rows = {}
for line in ledger.splitlines():
    p = line.split()
    if len(p) == 2:
        rows[p[0]] = p[1]
unknown = sorted(f for f in rows if f not in repo)
changed = sorted(f for f in rows if f in repo and rows[f] != repo[f])
pending = sorted(f for f in repo if f not in rows)
head = max(rows) if rows else ""
gaps = [f for f in pending if f < head]
print("SCHEMA %s head=%s repo_head=%s applied=%d pending=%d gaps=%d" % (
    phase, head or "-", max(repo) if repo else "-", len(rows), len(pending), len(gaps)))
bad = []
if not rows: bad.append("the ledger is empty")
if unknown:
    # a renamed file leaves its old name in the ledger; the migrate loops over
    # the repo files only, so the row is history, not a fault
    print("WARN %d ledger row(s) name no repo file (renamed or removed since): %s" % (len(unknown), ",".join(unknown[:5])))
if changed: bad.append("%d applied file(s) changed since: %s" % (len(changed), ",".join(changed[:5])))
if phase == "after" and pending: bad.append("%d repo file(s) still not applied: %s" % (len(pending), ",".join(pending[:5])))
if not repo: bad.append("no *.sql in the migrations dir")
print("VERDICT %d %s" % (8 if bad else 0, "; ".join(bad) or "every applied repo file matches its sha256"))
' "$1" "$2" "$3")" || { do_log "FATAL cannot read the schema ledger"; return 1; }
  do_log "INFO ${ENV:-dev} $(grep '^SCHEMA ' <<<"$v")"
  grep '^WARN ' <<<"$v" | while read -r l; do do_log "WARN ${ENV:-dev} schema $3: ${l#WARN }"; done
  code="$(sed -n 's/^VERDICT \([0-9]*\) .*/\1/p' <<<"$v")"
  if [[ "$code" == 0 ]]; then do_log "OK ${ENV:-dev} schema $3: ${v##*VERDICT 0 }"; return 0; fi
  do_log "FAIL ${ENV:-dev} schema $3: $(sed -n 's/^VERDICT [0-9]* //p' <<<"$v")"
  return 8
}

# spl_db_restore_drill_sanity <counts file> -> exit 5 unless the restore holds
# tables and every SPL_RESTORE_DRILL_NONEMPTY table is present with rows.
spl_db_restore_drill_sanity() {
  local f="$1" t n bad=0 tables rows
  tables="$(awk 'NF == 2' "$f" | wc -l)"
  rows="$(awk 'NF == 2 && $2 ~ /^[0-9]+$/ { s += $2 } END { print s + 0 }' "$f")"
  (( tables > 0 )) || { do_log "FAIL ${ENV:-dev} sanity: the restore holds no table"; return 5; }
  for t in ${SPL_RESTORE_DRILL_NONEMPTY:-tenants messages}; do
    n="$(awk -v t="$t" '$1 == t { print $2 }' "$f")"
    if [[ -z "$n" ]]; then do_log "FAIL ${ENV:-dev} sanity: core table $t is missing"; bad=1
    elif [[ ! "$n" =~ ^[0-9]+$ || "$n" == 0 ]]; then do_log "FAIL ${ENV:-dev} sanity: core table $t holds no row ($n)"; bad=1
    else do_log "INFO ${ENV:-dev} sanity: $t $n row(s)"; fi
  done
  (( bad == 0 )) || return 5
  do_log "OK ${ENV:-dev} sanity: $tables table(s), $rows row(s) restored"
}
