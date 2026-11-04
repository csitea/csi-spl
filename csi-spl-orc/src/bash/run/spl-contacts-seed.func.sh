#!/bin/bash
#------------------------------------------------------------------------------
# @description Add the rows of a CSV file to ONE named person's contacts
# @description (spec 154 rdb 0226 personal.contacts; SPL-4635, owner HUM-10
# @description poll 2102c889: an agent adds his own list, once, past the
# @description person-only rule of /v1/me/contacts). The route and its gate
# @description are untouched: this writes through the Cloud SQL proxy as the
# @description hub runtime login, in that person's RLS scope (app.person_id,
# @description as the store's inPerson), so the person_scope policy binds it.
# @description The file: header person_id,first_name,last_name,email,phone.
# @description Refused whole, before any DB call: a row of another person
# @description than CONTACTS_PERSON, a row with no name, a value rdb 0226
# @description would refuse. Running it twice adds nothing twice: a row is
# @description already there when a live contact of the person has its
# @description email (or, with no email, its first and last name).
# @description Prints one JSON line of counts and contact ids, never a value
# @description (spec 154 2.6, C12); psql errors print their SQLSTATE only.
# @param ENV - required: dev or prd
# @param CONTACTS_PERSON - required: the person whose list gets the rows, HUM-<n>
# @param CONTACTS_FILE - required: the CSV file path (keep it mode 600)
# @param DRY_RUN (optional) - 1 (default): count in a READ ONLY transaction, add nothing
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA (do_gcp_account)
# @example ENV=dev CONTACTS_PERSON=HUM-4 CONTACTS_FILE=<file> ./run -a do_spl_contacts_seed
# @example ENV=dev CONTACTS_PERSON=HUM-4 CONTACTS_FILE=<file> DRY_RUN=0 ./run -a do_spl_contacts_seed
#------------------------------------------------------------------------------
do_spl_contacts_seed() {
  spl_require_cloud_env || return 1
  local dry=1 person="${CONTACTS_PERSON:-}" file="${CONTACTS_FILE:-}" sql out rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  [[ "$person" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL CONTACTS_PERSON must be a person id HUM-<n>, got: '$person'"; return 1; }
  [[ -n "$file" && -f "$file" && -r "$file" ]] || { do_log "FATAL CONTACTS_FILE is not a readable file: '$file'"; return 1; }
  do_require_bin python3 yq psql || return 1
  # The SQL file holds the values: one 0700 dir, removed on every return and
  # on INT / TERM (_spl_contacts_seed_clean clears the traps again).
  _SPL_CS_TMP="$(mktemp -d)" || return 1
  trap _spl_contacts_seed_clean RETURN
  trap '_spl_contacts_seed_clean; exit 130' INT
  trap '_spl_contacts_seed_clean; exit 143' TERM
  sql="$_SPL_CS_TMP/seed.sql" out="$_SPL_CS_TMP/out"
  if ! _spl_contacts_seed_rows "$file" "$person" | _spl_contacts_seed_sql "$dry" >"$sql"; then
    do_log "FATAL $file refused, nothing was added"; return 1
  fi
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  CONTACTS_PERSON="$person" spl_via_proxy _spl_contacts_seed_run "$sql" "$out" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL the contacts seed of $person in $ENV failed, nothing was committed: $(grep -m 1 -oE 'ERROR: +[0-9A-Z]{5}' "$out")"
    return 1
  fi
  _spl_contacts_seed_summary "$person" "$dry" <"$out" || return 1
  if (( dry )); then
    do_log "OK DRY_RUN counted the contacts to add to $person in $ENV, added nothing. Re-run with DRY_RUN=0 to add them."
  else
    do_log "OK added the new contacts to $person in $ENV"
  fi
}

# _spl_contacts_seed_clean: removes the action's temp dir and clears its traps.
_spl_contacts_seed_clean() {
  [[ -n "${_SPL_CS_TMP:-}" ]] && rm -rf "$_SPL_CS_TMP"
  _SPL_CS_TMP=""
  trap - RETURN INT TERM
}

# _spl_contacts_seed_rows <file> <person> -> the file's rows on stdout as one
# JSON array, checked as the hub's cleanContact does and deduplicated. A
# refusal names the row and the field on stderr, never a value, and exits 1.
_spl_contacts_seed_rows() {
  python3 - "$@" <<'PY'
import csv, json, re, sys

path, person = sys.argv[1], sys.argv[2]
HEADER = ["person_id", "first_name", "last_name", "email", "phone"]
PHONE = re.compile(r"^[+0-9 ().-]{3,40}$")
bad = []

def email_ok(e):
    at = e.find("@")
    return 3 <= len(e) <= 320 and 0 < at < len(e) - 1 and not re.search(r"[ \t\r\n\x00]", e)

try:
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.reader(f))
except (OSError, UnicodeDecodeError, csv.Error):
    print("refused: the file is not readable UTF-8 CSV", file=sys.stderr)
    sys.exit(1)
if not rows or [h.strip() for h in rows[0]] != HEADER:
    print("refused: the header is not " + ",".join(HEADER), file=sys.stderr)
    sys.exit(1)
out, seen, dups = [], set(), 0
for n, r in enumerate(rows[1:], start=1):
    if not any(c.strip() for c in r):
        continue
    if len(r) != len(HEADER):
        bad.append(f"row {n}: {len(r)} fields, not {len(HEADER)}")
        continue
    pid, first, last, email, phone = (c.strip() for c in r)
    email = email.lower()
    if pid != person:
        bad.append(f"row {n}: person_id is not CONTACTS_PERSON")
    if not first and not last:
        bad.append(f"row {n}: no name")
    for field, v in (("first_name", first), ("last_name", last)):
        if len(v) > 100 or "\x00" in v:
            bad.append(f"row {n}: {field} above 100 characters or not text")
    if email and not email_ok(email):
        bad.append(f"row {n}: email is not an address")
    if phone and not PHONE.match(phone):
        bad.append(f"row {n}: phone is not a phone number")
    key = ("e", email) if email else ("n", first, last)
    if key in seen:
        dups += 1
        continue
    seen.add(key)
    out.append({"n": n, "first_name": first, "last_name": last, "email": email or None, "phone": phone or None})
if bad:
    print("refused: " + "; ".join(bad), file=sys.stderr)
    sys.exit(1)
if not out:
    print("refused: the file has no rows", file=sys.stderr)
    sys.exit(1)
print(json.dumps({"dups": dups, "rows": out}, ensure_ascii=False))
PY
}

# _spl_contacts_seed_sql <dry> -> the psql script on stdout for the JSON rows
# on stdin (fd 3 to python), as one dollar-quoted literal (never argv).
# Exits 1 on empty input, so a refused file never reaches psql.
_spl_contacts_seed_sql() {
  python3 - "$@" 3<&0 <<'PY'
import json, os, secrets, sys

dry = sys.argv[1] == "1"
raw = os.fdopen(3, encoding="utf-8").read().strip()
if not raw:
    sys.exit(1)
got = json.loads(raw)
doc = json.dumps(got["rows"], ensure_ascii=False)
tag = "seed_" + secrets.token_hex(8)
while tag in doc:
    tag = "seed_" + secrets.token_hex(8)
src = (f"jsonb_to_recordset(${tag}${doc}${tag}$::jsonb)"
       " AS s(n int, first_name text, last_name text, email text, phone text)")
there = ("EXISTS (SELECT 1 FROM personal.contacts c WHERE c.person_id = :'person' AND c.deleted_at IS NULL"
         " AND ((s.email IS NOT NULL AND c.email = s.email) OR (s.email IS NULL AND c.email IS NULL"
         " AND c.first_name = s.first_name AND c.last_name = s.last_name)))")
print("\\set VERBOSITY sqlstate")
print("BEGIN READ ONLY;" if dry else "BEGIN;")
print(f"SELECT 'dups {int(got['dups'])}';")
print("SELECT set_config('app.person_id', :'person', true) \\g /dev/null")
if not dry:
    print("SELECT pg_advisory_xact_lock(hashtext('spl-contacts-seed:' || :'person')) \\g /dev/null")
print(f"SELECT 'rows ' || count(*) FROM {src};")
print(f"SELECT 'already ' || count(*) FROM {src} WHERE {there};")
if dry:
    print(f"SELECT 'would_add ' || count(*) FROM {src} WHERE NOT {there};")
else:
    print("WITH ins AS (INSERT INTO personal.contacts (person_id, first_name, last_name, email, phone)"
          f" SELECT :'person', s.first_name, s.last_name, s.email, s.phone FROM {src}"
          f" WHERE NOT {there} ORDER BY s.n RETURNING contact_id) SELECT 'added ' || contact_id FROM ins;")
print("SELECT 'live ' || count(*) FROM personal.contacts WHERE person_id = :'person' AND deleted_at IS NULL;")
print("ROLLBACK;" if dry else "COMMIT;")
PY
}

# _spl_contacts_seed_run <sql> <out>: the script through $SPL_PROXY_DSN; <out>
# gets the "<key> <value>" lines, or psql's SQLSTATE-only error.
_spl_contacts_seed_run() {
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v person="$CONTACTS_PERSON" <"$1" >"$2" 2>&1
}

# _spl_contacts_seed_summary <person> <dry>: the JSON line from the run's
# output on stdin; exit 1 when a count is missing.
_spl_contacts_seed_summary() {
  python3 -c '
import json, sys
env, person, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
got, ids = {}, []
for line in sys.stdin:
    k, _, v = line.strip().partition(" ")
    if k == "added":
        ids.append(v)
    elif k in ("dups", "rows", "already", "would_add", "live"):
        got[k] = int(v)
need = ["dups", "rows", "already", "live"] + (["would_add"] if dry else [])
if any(k not in got for k in need):
    print("FATAL the run printed no counts", file=sys.stderr)
    sys.exit(1)
out = {"env": env, "person": person, "dry_run": dry, "rows": got["rows"], "file_duplicates": got["dups"],
       "already": got["already"]}
if dry:
    out["would_add"] = got["would_add"]
else:
    out["added"] = len(ids)
    out["contact_ids"] = ids
out["live"] = got["live"]
print(json.dumps(out, sort_keys=True))
' "$ENV" "$1" "$2"
}
