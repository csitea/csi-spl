#!/usr/bin/env bash
# SPL-6053: do_spl_cost_labels_fill writes every existing cost label in all
# 19 locales from a mapping file. Against a REAL throwaway Postgres with the
# real rdb migrations, as a NON-owner runtime login (rdb 0285's operator RLS
# binds), with SYNTHETIC labels only (no estate text):
#   1. the file check refuses: no LABELS_MAP, a file other users can read, a
#      file inside a git tree, a missing locale, a text over 100 characters,
#      two keys sharing one master text; and passes the good file
#   2. DRY_RUN=1 prints the plan per table and locale and writes nothing
#   3. DRY_RUN=0: the hr text becomes its en text (cost_entries.label and the
#      master row agree), every mapped entry and component has 19 rows, the
#      fi row reads the fi text, an unmapped entry is untouched
#   4. a second run plans 0 and changes nothing (idempotent)
#   5. refused, nothing written: a cost_allocations row keyed on a text to be
#      renamed; a rename INTO a text an allocation keys on; a rename into the
#      text another entry (not renamed by this action) already carries; a
#      mapping whose master_locale is not the table's
#   6. (SPL-6165) every row the fill writes but the master's reads
#      origin = 'machine' with source_text = the entry's text; a person's
#      ('hand') row, entry or component, is left byte for byte and counted
#      as hand= in the plan; a rename re-makes the entry's machine rows from
#      the new text (reviewed_at NULL) and keeps its hand rows (stale, spec
#      123 16.6.2 point 5); a second run changes nothing
#   CONTROLS (mutated copies of the action): without each of the three
#   rename guards its case commits; with the rename UPDATE removed the master
#   row check trips (rc != 0, nothing written); without the operator scope
#   cost_label_settings reads no row and the run is refused (RLS binds);
#   without the origin guard the fill overwrites the person's row.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"; APP_ROOT="$(cd "$PROJ_ROOT/.." && pwd)"
T="$(mktemp -d)"; fails=0
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: no docker / psql / cached $PG_IMAGE image; $(basename "$0") is not run"; exit 0
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-cost-labels-fill-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$HERE/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
psql_owner() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" "$@"; }
psql_owner -c "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
psql_owner -v runtime_role=spool_rt -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
q() { psql_owner -c "SET app.rls_scope = 'operator'" -c "$1" | tail -n +1; }

# synthetic entries, each with its master (en) row as rdb 0285 copied it
psql_owner <<'PSQL' >/dev/null || fail "seed"
SET app.rls_scope = 'operator';
INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('w1', decode(repeat('ab', 32), 'hex'));
INSERT INTO cost_entries (id, type, label, amount, currency, period, created_by) VALUES
  ('00000000-0000-4000-8000-000000000001', 'hr', 'Тестова заплата (сметка 1)', 10, 'EUR', '2026-01-01', 'seed'),
  ('00000000-0000-4000-8000-000000000002', 'hr', 'Тестова заплата (сметка 1)', 10, 'EUR', '2026-02-01', 'seed'),
  ('00000000-0000-4000-8000-000000000003', 'cloud', 'Vendor Example Oy', 5, 'EUR', '2026-01-01', 'seed'),
  ('00000000-0000-4000-8000-000000000004', 'hr', 'Unmapped fixture', 5, 'EUR', '2026-01-01', 'seed');
INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by) SELECT id, 'en', label, 'rdb 0285' FROM cost_entries;
INSERT INTO cost_allocations (source, project_or_vendor, kind, workspace_id, share_bp, created_by)
  VALUES ('cost_entry', 'Vendor Example Oy', 'cloud', 'w1', 10000, 'seed');
PSQL

LOCS="bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl"
# mkmap <file> [python edit] -> the synthetic mapping, mode 0640
mkmap() {
  python3 -I - "$1" "$LOCS" "${2:-}" <<'PY'
import json, sys
path, L, edit = sys.argv[1], sys.argv[2].split(), sys.argv[3]
def all19(f): return {l: f(l) for l in L}
d = {"master_locale": "en",
     "entries": {"Тестова заплата (сметка 1)": all19(lambda l: {"bg": "Тестова заплата (сметка 1)", "en": "Test salary (account 1)"}.get(l, f"Test salary {l} (account 1)")),
                 "Vendor Example Oy": all19(lambda l: "Vendor Example Oy")},
     "components": {"base_pay": all19(lambda l: "Base pay" if l == "en" else f"Base pay {l}"),
                    "overtime": all19(lambda l: "Overtime" if l == "en" else f"Overtime {l}")}}
exec(edit)
json.dump(d, open(path, "w", encoding="utf-8"), ensure_ascii=False)
PY
  chmod 0640 "$1"
}
mkdir -p "$T/maps"; MAP="$T/maps/map.json"; mkmap "$MAP"
ACTION="$PROJ_ROOT/src/bash/run/spl-cost-labels-fill.func.sh"
# run <action file> <fn> [args] -> the action's function, as the runtime login
run() {
  env PROJ_PATH="$PROJ_ROOT" SPL_PROXY_DSN="${DSN:-$RT_DSN}" SPL_CL_MAP="${RMAP:-$MAP}" SPL_CL_DRY="${DRY:-1}" A="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$A"
    shift; "$@"' _ "$@" >"$T/out" 2>&1
}
snap() { q "SELECT string_agg(entry_id || locale || label || updated_at, ',' ORDER BY entry_id, locale) FROM cost_entry_labels" | md5sum; }

# 1 --------------------------------------------------------------------------
run "$ACTION" spl_cost_labels_map_ok ""; [[ $? -ne 0 ]] && grep -q "LABELS_MAP is required" "$T/out" && pass "1 no LABELS_MAP refused" || fail "1 no map: $(cat "$T/out")"
cp "$MAP" "$T/maps/wide.json"; chmod 0644 "$T/maps/wide.json"
run "$ACTION" spl_cost_labels_map_ok "$T/maps/wide.json"; [[ $? -ne 0 ]] && grep -q "mode 644" "$T/out" && pass "1 a world-readable file refused" || fail "1 mode: $(cat "$T/out")"
mkdir -p "$T/repo" && git -C "$T/repo" init -q && cp "$MAP" "$T/repo/map.json"
run "$ACTION" spl_cost_labels_map_ok "$T/repo/map.json"; [[ $? -ne 0 ]] && grep -q "inside a git tree" "$T/out" && pass "1 a file inside git refused" || fail "1 git: $(cat "$T/out")"
for c in "missing|del d['components']['base_pay']['nl']|exactly the 19 locales" \
         "long|d['entries']['Vendor Example Oy']['sv'] = 'x' * 101|1..100 characters" \
         "merge|d['entries']['Vendor Example Oy']['en'] = 'Test salary (account 1)'|share one en text"; do
  IFS='|' read -r name edit want <<<"$c"; mkmap "$T/maps/$name.json" "$edit"
  run "$ACTION" spl_cost_labels_map_ok "$T/maps/$name.json"
  [[ $? -ne 0 ]] && grep -q "$want" "$T/out" && ! grep -q "x\{101\}" "$T/out" && pass "1 refused: $name" || fail "1 $name: $(cat "$T/out")"
done
run "$ACTION" spl_cost_labels_map_ok "$MAP"; [[ $? -eq 0 ]] && grep -q "ok entries=2 components=2 master=en" "$T/out" && pass "1 the good file passes" || fail "1 good: $(cat "$T/out")"

# 2 --------------------------------------------------------------------------
before="$(snap)"
DRY=1 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 ]] && grep -qx "PLAN cost_entries.label rename=2 matched=3" "$T/out" && grep -qx "PLAN cost_entries unmapped=1" "$T/out" &&
  grep -qx "PLAN cost_entry_labels en insert=0 update=2 hand=0" "$T/out" && grep -qx "PLAN cost_entry_labels fi insert=3 update=0 hand=0" "$T/out" &&
  grep -qx "PLAN hr_cost_component_labels fi insert=2 update=0 hand=0" "$T/out" && grep -qx "PLAN hr_cost_component_labels en insert=0 update=0 hand=0" "$T/out" &&
  grep -qx "COUNT after cost_entry_labels fi 3" "$T/out" && grep -q "OK DRY_RUN=1" "$T/out" &&
  pass "2 DRY_RUN=1 plans per table and locale" || fail "2 dry rc=$rc: $(cat "$T/out")"
[[ "$(snap)" == "$before" && "$(q "SELECT count(*) FROM cost_entries WHERE label = 'Test salary (account 1)'")" == 0 ]] &&
  pass "2 DRY_RUN=1 wrote nothing" || fail "2 dry wrote"
! grep -q "Test salary\|Тестова\|Base pay" "$T/out" && pass "2 the output carries no label text" || fail "2 a label text in the output"

# 3 --------------------------------------------------------------------------
DRY=0 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 ]] && grep -q "OK DRY_RUN=0: committed" "$T/out" && grep -q "CHECK master rows unequal to cost_entries.label= 0" "$T/out" &&
  pass "3 DRY_RUN=0 commits, every master row equals its entry label" || fail "3 apply rc=$rc: $(cat "$T/out")"
[[ "$(q "SELECT count(*) FROM cost_entries WHERE label = 'Test salary (account 1)'")" == 2 &&
   "$(q "SELECT count(*) FROM cost_entry_labels l JOIN cost_entries e ON e.id = l.entry_id WHERE e.label <> 'Unmapped fixture'")" == 57 &&
   "$(q "SELECT label FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000001' AND locale = 'fi'")" == "Test salary fi (account 1)" &&
   "$(q "SELECT label FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000001' AND locale = 'bg'")" == "Тестова заплата (сметка 1)" &&
   "$(q "SELECT count(*) FROM hr_cost_component_labels WHERE component IN ('base_pay', 'overtime')")" == 38 &&
   "$(q "SELECT count(*) FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000004'")" == 1 ]] &&
  pass "3 rename + 19 rows per entry and component, the bg row keeps the source text, the unmapped entry untouched" || fail "3 rows: $(q "SELECT locale||'='||label FROM cost_entry_labels ORDER BY 1")"

# 4 --------------------------------------------------------------------------
before="$(snap)"
DRY=0 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 ]] && grep -qx "PLAN cost_entries.label rename=0 matched=3" "$T/out" && ! grep "^PLAN cost_entry_labels\|^PLAN hr_cost" "$T/out" | grep -v "insert=0 update=0" >/dev/null &&
  [[ "$(snap)" == "$before" ]] && pass "4 a second run plans 0 and changes nothing" || fail "4 second run rc=$rc: $(cat "$T/out")"

# 5 --------------------------------------------------------------------------
psql_owner -c "SET app.rls_scope = 'operator'" -c "INSERT INTO cost_entries (id, type, label, amount, currency, period, created_by) VALUES
  ('00000000-0000-4000-8000-000000000005', 'hr', 'Allocated fixture', 5, 'EUR', '2026-01-01', 'seed');
  INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by) VALUES ('00000000-0000-4000-8000-000000000005', 'en', 'Allocated fixture', 'seed');
  INSERT INTO cost_allocations (source, project_or_vendor, kind, workspace_id, share_bp, created_by) VALUES ('cost_entry', 'Allocated fixture', 'hr', 'w1', 10000, 'seed')" >/dev/null
mkmap "$T/maps/alloc.json" "d['entries']['Allocated fixture'] = all19(lambda l: 'Allocated fixture renamed')"
before="$(snap)"
RMAP="$T/maps/alloc.json" DRY=0 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -ne 0 ]] && grep -q "REFUSED a renamed entry text is a cost_allocations key" "$T/out" && [[ "$(snap)" == "$before" ]] &&
  pass "5 a renamed text an allocation keys on is refused, nothing written" || fail "5 alloc rc=$rc: $(cat "$T/out")"
mkmap "$T/maps/fi.json" "d['master_locale'] = 'fi'"
RMAP="$T/maps/fi.json" DRY=0 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -ne 0 ]] && grep -q "REFUSED the mapping's master_locale" "$T/out" && [[ "$(snap)" == "$before" ]] &&
  pass "5 a master_locale other than the table's is refused" || fail "5 master rc=$rc: $(cat "$T/out")"
psql_owner -c "SET app.rls_scope = 'operator'" -c "INSERT INTO cost_entries (id, type, label, amount, currency, period, created_by) VALUES
  ('00000000-0000-4000-8000-000000000006', 'hr', 'Into alloc src', 5, 'EUR', '2026-01-01', 'seed'),
  ('00000000-0000-4000-8000-000000000007', 'hr', 'Into unmapped src', 5, 'EUR', '2026-01-01', 'seed'),
  ('00000000-0000-4000-8000-000000000008', 'hr', 'Master check src', 5, 'EUR', '2026-01-01', 'seed');
  INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by) SELECT id, 'en', label, 'seed' FROM cost_entries
    WHERE id IN ('00000000-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000007', '00000000-0000-4000-8000-000000000008');
  INSERT INTO cost_allocations (source, project_or_vendor, kind, workspace_id, share_bp, created_by) VALUES ('cost_entry', 'Into alloc target', 'hr', 'w1', 10000, 'seed')" >/dev/null
mkmap "$T/maps/into-alloc.json" "d['entries']['Into alloc src'] = all19(lambda l: 'Into alloc target')"
mkmap "$T/maps/into-unmapped.json" "d['entries']['Into unmapped src'] = all19(lambda l: 'Unmapped fixture')"
mkmap "$T/maps/master-check.json" "d['entries']['Master check src'] = all19(lambda l: 'Master check new')"
before="$(snap)"
RMAP="$T/maps/into-alloc.json" DRY=0 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -ne 0 ]] && grep -q "REFUSED a renamed entry's new text is already a cost_allocations key" "$T/out" && [[ "$(snap)" == "$before" ]] &&
  pass "5 a rename INTO a text an allocation keys on is refused, nothing written" || fail "5 into-alloc rc=$rc: $(cat "$T/out")"
RMAP="$T/maps/into-unmapped.json" DRY=0 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -ne 0 ]] && grep -q "REFUSED an entry already carries a renamed text and this action did not rename it" "$T/out" && [[ "$(snap)" == "$before" ]] &&
  pass "5 a rename into the text another entry already carries is refused, nothing written" || fail "5 into-unmapped rc=$rc: $(cat "$T/out")"

# CONTROLS -------------------------------------------------------------------
# mutate <out> <needle>: the action without the WHEN line holding needle and
# its 2 following lines (the guard's condition and its THEN)
mutate() { awk -v n="$2" 'index($0, n) { skip = 3 } skip > 0 { skip--; next } { print }' "$ACTION" >"$1"; }
mutate "$T/no-guard.sh" "a.project_or_vendor = t.cur"
RMAP="$T/maps/alloc.json" DRY=0 run "$T/no-guard.sh" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 && "$(q "SELECT count(*) FROM cost_entries WHERE label = 'Allocated fixture renamed'")" == 1 ]] &&
  pass "CONTROL without the allocation guard the rename commits (the guard is what refuses)" || fail "CONTROL guard rc=$rc: $(cat "$T/out")"
mutate "$T/no-into-alloc.sh" "a.project_or_vendor = t.master_text"
RMAP="$T/maps/into-alloc.json" DRY=0 run "$T/no-into-alloc.sh" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 && "$(q "SELECT count(*) FROM cost_entries WHERE label = 'Into alloc target'")" == 1 ]] &&
  pass "CONTROL without the new-text allocation guard the rename into an allocation key commits" || fail "CONTROL into-alloc rc=$rc: $(cat "$T/out")"
mutate "$T/no-into-unmapped.sh" "FROM cl_t t JOIN cost_entry_labels l ON l.entry_id = t.id"
RMAP="$T/maps/into-unmapped.json" DRY=0 run "$T/no-into-unmapped.sh" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 && "$(q "SELECT count(*) FROM cost_entries WHERE label = 'Unmapped fixture'")" == 2 ]] &&
  pass "CONTROL without the foreign-entry guard the rename merges two items into one text" || fail "CONTROL into-unmapped rc=$rc: $(cat "$T/out")"
sed "/^UPDATE cost_entries ce SET label = t.master_text/d" "$ACTION" >"$T/no-rename.sh"
before="$(snap)"
RMAP="$T/maps/master-check.json" DRY=0 run "$T/no-rename.sh" _spl_cost_labels_fill_run; rc=$?
[[ $rc -ne 0 ]] && grep -q "CHECK master rows unequal to cost_entries.label= 1" "$T/out" && [[ "$(snap)" == "$before" &&
   "$(q "SELECT count(*) FROM cost_entries WHERE label = 'Master check src'")" == 1 ]] &&
  pass "CONTROL with the rename UPDATE removed the master row check trips, rc != 0, nothing written" || fail "CONTROL master check rc=$rc: $(cat "$T/out")"
RMAP="$T/maps/master-check.json" DRY=0 run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 ]] && grep -q "CHECK master rows unequal to cost_entries.label= 0" "$T/out" &&
  pass "the same mapping through the real action commits with the check at 0" || fail "master check real rc=$rc: $(cat "$T/out")"
sed "/SET LOCAL app.rls_scope = 'operator';/d" "$ACTION" >"$T/no-scope.sh"
DRY=1 run "$T/no-scope.sh" _spl_cost_labels_fill_run
grep -q "REFUSED cost_label_settings reads no row" "$T/out" && ! grep -q "^PLAN" "$T/out" &&
  pass "CONTROL without the operator scope cost_label_settings reads no row and the run is refused (RLS binds)" ||
  fail "CONTROL scope: $(cat "$T/out")"

# 6 --------------------------------------------------------------------------
# SPL-6165, spec 123 16.6.2 point 5 and 16.6.4: the fill's rows say machine
# and carry the text they were made from; a person's row is never written; a
# rename re-makes the entry's machine rows from the new text
q "SELECT count(*) || ' ' || count(*) FILTER (WHERE origin = 'machine' AND source_text = 'Test salary (account 1)')
     FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000001' AND locale <> 'en'" | grep -qx "18 18" &&
  [[ "$(q "SELECT origin || ':' || coalesce(source_text, 'NULL') FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000001' AND locale = 'en'")" == "hand:NULL" ]] &&
  [[ "$(q "SELECT count(*) FROM hr_cost_component_labels WHERE component = 'base_pay' AND locale <> 'en' AND origin = 'machine' AND source_text = 'Base pay'")" == 18 ]] &&
  pass "6a the fill's rows read machine with source_text = the entry's (renamed) text, the master row hand" ||
  fail "6a origin: $(q "SELECT locale||'='||origin||':'||coalesce(source_text, 'NULL') FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000001' ORDER BY 1" | tr '\n' ' ')"
psql_owner -c "SET app.rls_scope = 'operator'" -c "INSERT INTO cost_entries (id, type, label, amount, currency, period, created_by) VALUES
  ('00000000-0000-4000-8000-000000000009', 'hr', 'Hand fixture', 5, 'EUR', '2026-01-01', 'seed'),
  ('00000000-0000-4000-8000-00000000000a', 'hr', 'Rename old', 5, 'EUR', '2026-01-01', 'seed');
  INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin, source_text, reviewed_at, updated_at) VALUES
  ('00000000-0000-4000-8000-000000000009', 'en', 'Hand fixture', 'seed', 'hand', NULL, NULL, '2026-01-01T00:00:00Z'),
  ('00000000-0000-4000-8000-000000000009', 'fi', 'Käsin kirjoitettu', 'person', 'hand', 'Hand fixture', NULL, '2026-01-01T00:00:00Z'),
  ('00000000-0000-4000-8000-00000000000a', 'en', 'Rename old', 'seed', 'hand', NULL, NULL, '2026-01-01T00:00:00Z'),
  ('00000000-0000-4000-8000-00000000000a', 'fi', 'Rename fi', 'machine', 'machine', 'Rename old', '2026-01-02T00:00:00Z', '2026-01-01T00:00:00Z'),
  ('00000000-0000-4000-8000-00000000000a', 'sv', 'Käsi sv', 'person', 'hand', 'Rename old', NULL, '2026-01-01T00:00:00Z');
  UPDATE hr_cost_component_labels SET label = 'Ylityö käsin', origin = 'hand', source_text = 'Overtime' WHERE component = 'overtime' AND locale = 'fi'" >/dev/null
# lrow <entry id> <locale> -> the whole cost_entry_labels row as text; crow the same for a component
lrow() { q "SELECT row(l.*)::text FROM cost_entry_labels l WHERE entry_id = '$1' AND locale = '$2'"; }
crow() { q "SELECT row(l.*)::text FROM hr_cost_component_labels l WHERE component = '$1' AND locale = '$2'"; }
hand_fi="$(lrow 00000000-0000-4000-8000-000000000009 'fi')"; hand_sv="$(lrow 00000000-0000-4000-8000-00000000000a sv)"; comp_fi="$(crow overtime 'fi')"
mkmap "$T/maps/origin.json" "d['entries']['Hand fixture'] = all19(lambda l: 'Hand fixture' if l == 'en' else f'Hand fixture {l}'); d['entries']['Rename old'] = all19(lambda l: {'en': 'Rename new', 'fi': 'Rename fi'}.get(l, f'Rename {l}'))"
DRY=1 RMAP="$T/maps/origin.json" run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 ]] && grep -qx "PLAN cost_entry_labels fi insert=0 update=1 hand=1" "$T/out" && grep -qx "PLAN cost_entry_labels sv insert=1 update=0 hand=1" "$T/out" &&
  grep -qx "PLAN hr_cost_component_labels fi insert=0 update=0 hand=1" "$T/out" &&
  pass "6 DRY_RUN=1 counts the hand rows it keeps apart from the updates" || fail "6 plan rc=$rc: $(grep -E '^PLAN [a-z_]+ (fi|sv) ' "$T/out" | tr '\n' ' ')"
DRY=0 RMAP="$T/maps/origin.json" run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 ]] && grep -q "CHECK master rows unequal to cost_entries.label= 0" "$T/out" || fail "6 apply rc=$rc: $(cat "$T/out")"
[[ "$(lrow 00000000-0000-4000-8000-000000000009 'fi')" == "$hand_fi" && "$(crow overtime 'fi')" == "$comp_fi" &&
   "$(q "SELECT origin || ':' || source_text FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000009' AND locale = 'sv'")" == "machine:Hand fixture" ]] &&
  pass "6b a person's row (entry and component) is left byte for byte, the empty locale beside it is filled machine" ||
  fail "6b hand: $(lrow 00000000-0000-4000-8000-000000000009 'fi') / $(crow overtime 'fi')"
[[ "$(q "SELECT label FROM cost_entries WHERE id = '00000000-0000-4000-8000-00000000000a'")" == "Rename new" &&
   "$(q "SELECT label || ':' || origin || ':' || source_text || ':' || coalesce(reviewed_at::text, 'NULL') FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-00000000000a' AND locale = 'fi'")" == "Rename fi:machine:Rename new:NULL" &&
   "$(lrow 00000000-0000-4000-8000-00000000000a sv)" == "$hand_sv" &&
   "$(q "SELECT label || ':' || origin || ':' || coalesce(source_text, 'NULL') FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-00000000000a' AND locale = 'en'")" == "Rename new:hand:NULL" ]] &&
  pass "6c a rename re-makes the machine row from the new text (unreviewed), keeps the hand row (stale), the master row follows" ||
  fail "6c rename: $(q "SELECT locale||'='||label||':'||origin||':'||coalesce(source_text, 'NULL') FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-00000000000a' AND locale IN ('en', 'fi', 'sv') ORDER BY 1" | tr '\n' ' ')"
before="$(snap)"
DRY=0 RMAP="$T/maps/origin.json" run "$ACTION" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 && "$(snap)" == "$before" ]] && ! grep "^PLAN cost_entry_labels\|^PLAN hr_cost" "$T/out" | grep -v "insert=0 update=0" >/dev/null &&
  pass "6 a second run over the hand rows plans 0 and changes nothing" || fail "6 second run rc=$rc: $(grep '^PLAN' "$T/out" | grep -v 'insert=0 update=0' | tr '\n' ' ')"
sed "s/^  WHERE cost_entry_labels.origin = 'machine'$/  WHERE true/" "$ACTION" >"$T/no-hand-guard.sh"
grep -q "^  WHERE true$" "$T/no-hand-guard.sh" || fail "CONTROL hand guard: the mutation did not apply"
DRY=0 RMAP="$T/maps/origin.json" run "$T/no-hand-guard.sh" _spl_cost_labels_fill_run; rc=$?
[[ $rc -eq 0 && "$(q "SELECT label FROM cost_entry_labels WHERE entry_id = '00000000-0000-4000-8000-000000000009' AND locale = 'fi'")" == "Hand fixture fi" ]] &&
  pass "CONTROL without the origin guard the fill overwrites the person's row" || fail "CONTROL hand guard rc=$rc: $(grep -c . "$T/out") lines"

echo "fails=$fails"
[[ $fails -eq 0 ]]
