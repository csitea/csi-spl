#!/bin/bash
#------------------------------------------------------------------------------
# @description Put back deleted fleet_tokens cost lines (SPL-2230 step 2,
# @description owner go t1 dbf2f39b msg f0b235c6: "INS - Put back the 2,380
# @description deleted lines only"): reads a reinsert file (one statement per
# @description line, as SPL-2319's PITR read wrote it) and keeps ONLY its
# @description INSERT INTO cost_lines rows whose source is fleet_tokens.<box>.
# @description The file's BEGIN / COMMIT / SET LOCAL app.rls_scope = 'operator'
# @description / '-- ' comment lines are dropped, its UPDATE cost_lines ... WHERE
# @description id = N lines are dropped and NOT RUN only when their count is
# @description REINSERT_DROP_UPDATES exactly; any other line (DELETE, DDL,
# @description another table, a second statement, ON CONFLICT, a non
# @description fleet_tokens source) refuses the whole run before any SQL.
# @description DRY_RUN=1 (default): a READ ONLY transaction, rolled back, prints
# @description the rows it would insert, the live cost_lines counts and how many
# @description of the rows' keys are live now; writes nothing.
# @description DRY_RUN=0: ONE transaction: refuses when a key is live now, a key
# @description repeats in the file or the row count is not REINSERT_EXPECT;
# @description inserts; commits only when the cost_lines count grew by exactly
# @description the row count, else rolls back. Same path as do_spl_db_query:
# @description the env's project service account (never the owner account),
# @description the Cloud SQL proxy, operator RLS scope. The file holds tenant
# @description data: no value is ever printed (psql VERBOSITY terse, line
# @description numbers only in refusals), the SQL is built in a 0700 temp dir
# @description that is removed on every way out.
# @param ENV - required: dev or prd
# @param REINSERT_FILE - required: the reinsert .sql file (no default)
# @param REINSERT_MD5 (optional) - the file's md5; refused when it differs
# @param REINSERT_EXPECT (optional) - the row count it must hold (default: what it holds)
# @param REINSERT_DROP_UPDATES (optional) - the exact count of UPDATE cost_lines lines to drop, default 0
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd REINSERT_FILE=<file> REINSERT_MD5=<md5> REINSERT_EXPECT=2380 REINSERT_DROP_UPDATES=108 ./run -a do_spl_db_cost_reinsert
# @example ENV=prd REINSERT_FILE=<file> REINSERT_MD5=<md5> REINSERT_EXPECT=2380 REINSERT_DROP_UPDATES=108 DRY_RUN=0 ./run -a do_spl_db_cost_reinsert
#------------------------------------------------------------------------------
do_spl_db_cost_reinsert() {
  do_require_bin yq psql python3 || return 1
  local dry=1 file="${REINSERT_FILE:-}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ -n "$file" ]] || { do_log "FATAL REINSERT_FILE is required (no default)"; return 1; }
  [[ -f "$file" && -r "$file" ]] || { do_log "FATAL REINSERT_FILE is not a readable file: $file"; return 1; }
  if [[ -n "${REINSERT_MD5:-}" ]]; then
    local md5; md5="$(md5sum "$file" | cut -d' ' -f1)"
    [[ "$md5" == "$REINSERT_MD5" ]] || { do_log "FATAL REINSERT_FILE md5 is $md5, not REINSERT_MD5 $REINSERT_MD5"; return 1; }
  fi
  [[ -z "${REINSERT_EXPECT:-}" || "$REINSERT_EXPECT" =~ ^[1-9][0-9]{0,6}$ ]] ||
    { do_log "FATAL REINSERT_EXPECT must be a positive count, got: '$REINSERT_EXPECT'"; return 1; }
  [[ "${REINSERT_DROP_UPDATES:-0}" =~ ^[0-9]{1,7}$ ]] ||
    { do_log "FATAL REINSERT_DROP_UPDATES must be a count, got: '$REINSERT_DROP_UPDATES'"; return 1; }
  do_spl_cloud_cnf || return 1
  ( spl_cost_reinsert_main "$file" "$dry" )
}

# spl_cost_reinsert_main <file> <dry> -> runs in a subshell: the temp dir and
# its EXIT trap live and die with it.
spl_cost_reinsert_main() {
  local file="$1" dry="$2" work out rows
  work="$(mktemp -d "${TMPDIR:-/tmp}/spl-cost-reinsert.XXXXXX")" || { do_log "FATAL mktemp"; return 1; }
  chmod 700 "$work"
  # shellcheck disable=SC2064 # expand $work now
  trap "rm -rf '$work'" EXIT
  out="$(spl_cost_reinsert_extract "$file" "$work" "${REINSERT_DROP_UPDATES:-0}")" ||
    { do_log "FATAL $out"; return 1; }
  rows="${out#rows=}"; rows="${rows%% *}"
  if [[ -n "${REINSERT_EXPECT:-}" && "$rows" != "$REINSERT_EXPECT" ]]; then
    do_log "FATAL REINSERT_FILE holds $rows rows, not REINSERT_EXPECT $REINSERT_EXPECT"; return 1
  fi
  do_log "INFO REINSERT_FILE kept: $out"
  spl_cost_reinsert_sql "$work" "$dry" >"$work/run.sql" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_CR_SQL="$work/run.sql" SPL_CR_ROWS="$rows" SPL_CR_DRY="$dry" spl_via_proxy _spl_cost_reinsert_run
}

# spl_cost_reinsert_extract <file> <dir> <drop_updates> -> writes <dir>/cols
# (the one column list) and <dir>/tuples (one VALUES tuple per line) and
# prints "rows=<n> dropped_updates=<n> skipped=<n>"; or prints the refusal
# (a line number and its first word, never its values) and fails.
spl_cost_reinsert_extract() {
  python3 -I -c "$(spl_cost_reinsert_py_lib)
$(spl_cost_reinsert_py_main)" "$@"
}

# spl_cost_reinsert_py_lib -> the Python patterns and the VALUES tuple
# splitter of spl_cost_reinsert_extract.
spl_cost_reinsert_py_lib() {
  cat <<'PY'
import re, sys
path, out, drop_want = sys.argv[1], sys.argv[2], int(sys.argv[3])
KEY = ["day", "source", "project_or_vendor", "tenant_id", "agent_id", "model", "kind"]
LIT = re.compile(r"'(?:[^']|'')*'")
INS = re.compile(r"^INSERT INTO (?:public\.)?cost_lines \(([a-z_, ]+)\) VALUES (\(.*\));$", re.I)
UPD = re.compile(r"^UPDATE (?:public\.)?cost_lines SET [a-z_]+ = '(?:[^']|'')*'(?:, [a-z_]+ = '(?:[^']|'')*')*"
                 r" WHERE id = [0-9]+ AND superseded_by IS NULL;$", re.I)
SKIP = {"begin;", "commit;", "set local app.rls_scope = 'operator';"}
BAD = re.compile(r"\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|select|copy|returning|"
                 r"conflict|do|execute|call|set|with|merge|lock|vacuum|into|from)\b|;|\$|--|/\*", re.I)

def refuse(n, line, why):
    word = (line.split() or ["<empty>"])[0][:20]
    print(f"line {n} ({word} ...): {why}; nothing run")
    sys.exit(1)

def values(n, line, tuple_text):
    literals = []
    def keep(m):
        literals.append(m.group(0))
        return f"\x00{len(literals) - 1}\x00"
    stripped = LIT.sub(keep, tuple_text)
    if BAD.search(stripped):
        refuse(n, line, "a keyword, ';', '$' or a comment outside a string literal")
    depth, vals, cur = 0, [], ""
    for i, ch in enumerate(stripped):
        if ch == "(":
            depth += 1
            if depth > 1:
                refuse(n, line, "a nested '(' in VALUES")
            continue
        if ch == ")":
            depth -= 1
            if depth == 0 and i != len(stripped) - 1:
                refuse(n, line, "more than one VALUES tuple")
            continue
        if ch == "," and depth == 1:
            vals.append(cur.strip())
            cur = ""
            continue
        cur += ch
    vals.append(cur.strip())
    return [re.sub(r"\x00(\d+)\x00", lambda m: literals[int(m.group(1))], v) for v in vals]
PY
}

# spl_cost_reinsert_py_main -> the line loop of spl_cost_reinsert_extract.
spl_cost_reinsert_py_main() {
  cat <<'PY'
cols_ref, tuples, dropped, skipped = None, [], 0, 0
with open(path, encoding="utf-8") as fh:
    for n, raw in enumerate(fh, 1):
        line = raw.strip()
        if not line or line.startswith("-- ") or line == "--" or line.lower() in SKIP:
            skipped += 1
            continue
        if UPD.match(line):
            dropped += 1
            continue
        m = INS.match(line)
        if not m:
            refuse(n, line, "not an INSERT INTO cost_lines row, a dropped UPDATE cost_lines ... WHERE id = N, "
                            "BEGIN, COMMIT, the operator scope SET or a '-- ' comment")
        cols = [c.strip() for c in m.group(1).split(",")]
        if cols_ref is None:
            missing = [k for k in KEY if k not in cols]
            if missing:
                refuse(n, line, "the column list lacks the key column(s) " + ",".join(missing))
            for c in ("id", "superseded_by"):
                if c in cols:
                    refuse(n, line, f"the column list names {c}")
            if len(set(cols)) != len(cols):
                refuse(n, line, "a column named twice")
            cols_ref = cols
        elif cols != cols_ref:
            refuse(n, line, "a column list that differs from the first INSERT's")
        vals = values(n, line, m.group(2))
        if len(vals) != len(cols):
            refuse(n, line, f"{len(vals)} values for {len(cols)} columns")
        if not re.fullmatch(r"'fleet_tokens\.[a-z0-9_.-]+'", vals[cols.index("source")]):
            refuse(n, line, "a source that is not 'fleet_tokens.<box>'")
        tuples.append(m.group(2))
if not tuples:
    print("no INSERT INTO cost_lines row in the file; nothing run")
    sys.exit(1)
if dropped != drop_want:
    print(f"{dropped} UPDATE cost_lines lines, REINSERT_DROP_UPDATES says {drop_want}; nothing run")
    sys.exit(1)
with open(f"{out}/cols", "w") as fh:
    fh.write(", ".join(cols_ref) + "\n")
with open(f"{out}/tuples", "w") as fh:
    fh.write("\n".join(tuples) + "\n")
print(f"rows={len(tuples)} dropped_updates={dropped} skipped={skipped}")
PY
}

# spl_cost_reinsert_sql <dir> <dry> -> the psql script on stdout: the checks
# read the rows as a VALUES list (keys compared NULLS NOT DISTINCT, like the
# cost_lines_key index), the run inserts them in one statement.
spl_cost_reinsert_sql() {
  local dir="$1" dry="$2" cols vlist begin=BEGIN
  cols="$(<"$dir/cols")"
  vlist="$(sed '$!s/$/,/' "$dir/tuples")"
  ((dry)) && begin='BEGIN TRANSACTION READ ONLY'
  cat <<SQL
\\set VERBOSITY terse
\\set ON_ERROR_STOP on
$begin;
SET LOCAL app.rls_scope = 'operator';
SET LOCAL lock_timeout = '5s';
WITH v ($cols) AS (VALUES
$vlist
)
SELECT count(*) AS rows,
       count(*) FILTER (WHERE v.source !~ '^fleet_tokens[.]') AS foreign_src,
       count(*) - (SELECT count(*) FROM (SELECT DISTINCT day, source, project_or_vendor, tenant_id, agent_id, model, kind FROM v) d) AS dup_keys,
       (SELECT count(*) FROM v JOIN cost_lines c ON c.superseded_by IS NULL AND c.day = v.day::date
          AND c.source = v.source AND c.project_or_vendor = v.project_or_vendor
          AND c.tenant_id IS NOT DISTINCT FROM v.tenant_id AND c.agent_id IS NOT DISTINCT FROM v.agent_id
          AND c.model IS NOT DISTINCT FROM v.model AND c.kind = v.kind) AS live_keys
  FROM v \\gset
SELECT count(*) AS before_all, count(*) FILTER (WHERE source LIKE 'fleet\\_tokens.%') AS before_ft FROM cost_lines \\gset
\\echo PLAN rows=:rows live_keys=:live_keys dup_keys=:dup_keys foreign_src=:foreign_src cost_lines=:before_all fleet_tokens_lines=:before_ft
SQL
  if ((dry)); then echo 'ROLLBACK;'; return 0; fi
  cat <<SQL
SELECT (:live_keys = 0 AND :dup_keys = 0 AND :foreign_src = 0 AND :rows = :expect) AS go \\gset
\\if :go
\\else
  ROLLBACK;
  \\echo REFUSED rows=:rows expect=:expect live_keys=:live_keys dup_keys=:dup_keys foreign_src=:foreign_src
  \\quit
\\endif
INSERT INTO cost_lines ($cols) VALUES
$vlist;
SELECT count(*) AS after_all, count(*) FILTER (WHERE source LIKE 'fleet\\_tokens.%') AS after_ft FROM cost_lines \\gset
SELECT (:after_all - :before_all = :expect) AS delta_ok \\gset
\\if :delta_ok
  COMMIT;
  \\echo COMMITTED cost_lines=:before_all->:after_all fleet_tokens_lines=:before_ft->:after_ft
\\else
  ROLLBACK;
  \\echo ROLLED_BACK cost_lines=:before_all->:after_all fleet_tokens_lines=:before_ft->:after_ft expected_delta=:expect
\\endif
SQL
}

# _spl_cost_reinsert_run -> runs the script as the login in $SPL_PROXY_DSN and
# judges its PLAN / REFUSED / COMMITTED / ROLLED_BACK line.
_spl_cost_reinsert_run() {
  local out rc=0 plan
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v expect="$SPL_CR_ROWS" -f "$SPL_CR_SQL" 2>&1)" || rc=$?
  plan="$(grep -m1 '^PLAN ' <<<"$out")"
  if ((rc)); then
    do_log "FATAL psql failed on $ENV (rc $rc), the transaction is rolled back: $(grep -m1 -E 'ERROR|FATAL' <<<"$out" | cut -c1-200)"
    return 1
  fi
  [[ -n "$plan" ]] || { do_log "FATAL no PLAN line from psql on $ENV"; return 1; }
  if [[ "$SPL_CR_DRY" == 1 ]]; then
    do_log "OK DRY_RUN $ENV would insert: ${plan#PLAN }; nothing written. Re-run with DRY_RUN=0."
    [[ "$plan" == *" live_keys=0 dup_keys=0 foreign_src=0 "* ]] ||
      { do_log "FATAL DRY_RUN $ENV: a DRY_RUN=0 run would be refused (live_keys, dup_keys or foreign_src not 0)"; return 1; }
    return 0
  fi
  if grep -q '^COMMITTED ' <<<"$out"; then
    do_log "OK $ENV ${plan#PLAN }; $(grep -m1 '^COMMITTED ' <<<"$out") (${GCP_ACCOUNT:-})"
    return 0
  fi
  do_log "FATAL $ENV ${plan#PLAN }; $(grep -m1 -E '^(REFUSED|ROLLED_BACK) ' <<<"$out" || echo 'no verdict line'); nothing written"
  return 1
}
