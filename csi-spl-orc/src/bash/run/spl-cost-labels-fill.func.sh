#!/bin/bash
#------------------------------------------------------------------------------
# @description Fill every existing cost label in all 19 interface languages
# @description (SPL-6053, spec 123 section 16.5; owner HUM-10, csitea 720fa031,
# @description poll f0c06053 answer A: "fill all 19 languages for every
# @description existing label now"). Reads LABELS_MAP, a JSON file kept OUTSIDE
# @description git (estate data; refused inside a git tree or when other users
# @description can read it):
# @description   {"master_locale": "en",
# @description    "entries":    {"<today's cost_entries.label>": {<19 locales>}},
# @description    "components": {"<hr component>": {<19 locales>}}}
# @description An entry matches on today's text OR its master-locale text, so a
# @description second run finds the same rows and changes nothing (idempotent).
# @description Writes, in ONE transaction, as the env's project service account
# @description through the Cloud SQL proxy in the operator RLS scope (like
# @description do_spl_db_query). Store-level SQL, not the hub: PATCH
# @description /v1/operator/cost-entries/{id}/labels refuses the master row and
# @description hr_cost_component_labels has no route.
# @description   cost_entries.label        becomes the master-locale text, which
# @description                             the master row must equal
# @description                             (CheckCostEntryLabels)
# @description   cost_entry_labels         every locale's row, master included
# @description   hr_cost_component_labels  every locale's row
# @description Who wrote a row (rdb 0303, spec 123 16.6.4; SPL-6165): the
# @description master row is origin 'hand', source_text NULL, and always
# @description follows the mapping; every other row is written origin
# @description 'machine', source_text = the text it was made from (the
# @description entry's text after the rename, the component's master text),
# @description reviewed_at NULL. A row a person wrote (origin 'hand') is never
# @description written, only counted (PLAN ... hand=). A machine row made from
# @description another text (a rename) is re-made from the new one in the same
# @description transaction; a hand row stays, stale (16.6.2 point 5).
# @description Refused before any write: no cost_label_settings row (e.g. no
# @description operator scope), a master_locale other than its, a rename whose
# @description old OR new text a cost_allocations row keys on (source
# @description cost_entry), an entry this action did not rename (its master row
# @description is not stamped do_spl_cost_labels_fill) already carrying a new
# @description text (two items would merge), a component the table lacks; and by the
# @description file check: a locale missing, a text outside 1..100 characters,
# @description two keys sharing one master text. DRY_RUN=1 (default) runs it all
# @description in a transaction that is rolled back and prints the plan. The
# @description output is counts only, never a label text: COUNT before/after
# @description per table and locale, PLAN insert/update/hand per table and locale,
# @description the entries renamed and the entries no mapping covers.
# @param ENV (required) - dev or prd
# @param LABELS_MAP (required) - the mapping JSON (mode 0640 or tighter, outside git)
# @param DRY_RUN (optional) - 1 (default) prints the plan, 0 writes
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=dev LABELS_MAP=<dispatch dir>/mapping.json ./run -a do_spl_cost_labels_fill
# @example ENV=dev LABELS_MAP=<dispatch dir>/mapping.json DRY_RUN=0 ./run -a do_spl_cost_labels_fill
#------------------------------------------------------------------------------
do_spl_cost_labels_fill() {
  do_require_bin yq psql python3 || return 1
  local dry=1 map="${LABELS_MAP:-}"
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_cost_labels_map_ok "$map" || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_CL_MAP="$map" SPL_CL_DRY="$dry" spl_via_proxy _spl_cost_labels_fill_run
}

# spl_cost_labels_map_ok <file> -> the file's place, mode and shape; one
# FATAL line (never a label text) and 1 when it is not fit.
spl_cost_labels_map_ok() {
  local map="$1" mode out
  [[ -n "$map" ]] || { do_log "FATAL LABELS_MAP is required (no default)"; return 1; }
  [[ -f "$map" && -r "$map" ]] || { do_log "FATAL LABELS_MAP is not a readable file: $map"; return 1; }
  if git -C "$(dirname "$map")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    do_log "FATAL LABELS_MAP is inside a git tree: estate data stays out of git"; return 1
  fi
  mode="$(stat -c %a "$map")"
  (( (8#$mode & 8#007) == 0 )) || { do_log "FATAL LABELS_MAP is mode $mode: other users may not read it (0640 or tighter)"; return 1; }
  out="$(python3 -I -c "$(spl_cost_labels_py_check)" "$map")" || { do_log "FATAL LABELS_MAP $out"; return 1; }
  do_log "INFO LABELS_MAP $out"
}

# spl_cost_labels_py_check -> the Python shape check of the mapping. It prints
# the counts, or the first fault by its key's position, never a text.
spl_cost_labels_py_check() {
  cat <<'PY'
import json, sys
L = "bg fi ru en sv he tr mk el lt et lv sr ro uk sk pl es nl".split()
def die(why):
    print(why); sys.exit(1)
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except (OSError, ValueError) as e:
    die(f"is not JSON: {type(e).__name__}")
if not isinstance(d, dict) or set(d) != {"master_locale", "entries", "components"}:
    die("must hold exactly master_locale, entries, components")
if d["master_locale"] not in L:
    die("master_locale is not one of the 19 locales")
for kind in ("entries", "components"):
    if not isinstance(d[kind], dict):
        die(f"{kind} must be an object")
    for i, (k, m) in enumerate(d[kind].items(), 1):
        if not isinstance(m, dict) or sorted(m) != sorted(L):
            die(f"{kind} #{i}: must carry exactly the 19 locales")
        for loc, v in m.items():
            if not isinstance(v, str) or not 1 <= len(v) <= 100 or v.strip() != v:
                die(f"{kind} #{i} {loc}: a text must be 1..100 characters, no outer space")
        if not 1 <= len(k) <= 100:
            die(f"{kind} #{i}: the key must be 1..100 characters")
master = d["master_locale"]
masters = [m[master] for m in d["entries"].values()]
if len(set(masters)) != len(masters):
    die(f"entries: two keys share one {master} text (they would merge into one item)")
for i, (k, t) in enumerate(zip(d["entries"], masters), 1):
    if t != k and t in d["entries"]:
        die(f"entries #{i}: its {master} text is another key (a second run would be ambiguous)")
print(f"ok entries={len(masters)} components={len(d['components'])} master={master}")
PY
}

# _spl_cost_labels_fill_run -> under spl_via_proxy ($SPL_PROXY_DSN): the
# plan, then COMMIT (SPL_CL_DRY=0) or ROLLBACK, in one psql session.
_spl_cost_labels_fill_run() {
  local work rc=0
  work="$(mktemp -d "${TMPDIR:-/tmp}/spl-cost-labels.XXXXXX")" || { do_log "FATAL mktemp"; return 1; }
  chmod 700 "$work"
  if ! { cp "$SPL_CL_MAP" "$work/map.json" && chmod 600 "$work/map.json"; }; then
    rm -rf "$work"; do_log "FATAL cannot copy LABELS_MAP"; return 1
  fi
  { spl_cost_labels_sql_plan; spl_cost_labels_sql_apply; } >"$work/run.sql"
  spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v VERBOSITY=terse \
    -v mapfile="$work/map.json" -v dry="$SPL_CL_DRY" -f "$work/run.sql" || rc=$?
  rm -rf "$work"
  [[ $rc -eq 0 ]] || { do_log "FATAL cost labels fill stopped (psql rc=$rc): nothing written"; return 1; }
  if [[ "$SPL_CL_DRY" == 1 ]]; then do_log "OK DRY_RUN=1: rolled back, nothing written"; else do_log "OK DRY_RUN=0: committed"; fi
}

# spl_cost_labels_sql_plan -> the SQL that loads the mapping (a psql
# variable, never spliced), checks it against the tables and prints the plan.
spl_cost_labels_sql_plan() {
  cat <<'SQL'
\set map `cat :'mapfile'`
BEGIN;
SET LOCAL app.rls_scope = 'operator';
CREATE TEMP TABLE cl_doc ON COMMIT DROP AS SELECT :'map'::jsonb AS d;
SELECT d ->> 'master_locale' AS master FROM cl_doc \gset
CREATE TEMP TABLE cl_e ON COMMIT DROP AS
  SELECT e.key AS src, e.value ->> (SELECT d ->> 'master_locale' FROM cl_doc) AS master_text, l.key AS locale, l.value AS label
    FROM cl_doc, jsonb_each(d -> 'entries') e, jsonb_each_text(e.value) l;
CREATE TEMP TABLE cl_t ON COMMIT DROP AS
  SELECT ce.id, ce.label AS cur, s.src, s.master_text
    FROM cost_entries ce JOIN (SELECT DISTINCT src, master_text FROM cl_e) s ON ce.label IN (s.src, s.master_text);
CREATE TEMP TABLE cl_want_e ON COMMIT DROP AS
  SELECT t.id AS entry_id, m.locale, m.label, CASE WHEN m.locale <> :'master' THEN t.master_text END AS source_text
    FROM cl_t t JOIN cl_e m ON m.src = t.src;
CREATE TEMP TABLE cl_want_c ON COMMIT DROP AS
  SELECT c.key AS component, l.key AS locale, l.value AS label, CASE WHEN l.key <> :'master' THEN c.value ->> :'master' END AS source_text
    FROM cl_doc, jsonb_each(d -> 'components') c, jsonb_each_text(c.value) l;
SELECT CASE
  WHEN NOT EXISTS (SELECT 1 FROM cost_label_settings)
    THEN 'cost_label_settings reads no row (no operator scope, or no master locale set)'
  WHEN (SELECT master_locale FROM cost_label_settings) IS DISTINCT FROM (SELECT d ->> 'master_locale' FROM cl_doc)
    THEN 'the mapping''s master_locale is not cost_label_settings.master_locale'
  WHEN EXISTS (SELECT 1 FROM cost_allocations a JOIN cl_t t ON a.source = 'cost_entry' AND a.project_or_vendor = t.cur
               WHERE t.cur <> t.master_text)
    THEN 'a renamed entry text is a cost_allocations key (source cost_entry)'
  WHEN EXISTS (SELECT 1 FROM cost_allocations a JOIN cl_t t ON a.source = 'cost_entry' AND a.project_or_vendor = t.master_text
               WHERE t.cur <> t.master_text)
    THEN 'a renamed entry''s new text is already a cost_allocations key (source cost_entry)'
  WHEN EXISTS (SELECT 1 FROM cl_t t JOIN cost_entry_labels l ON l.entry_id = t.id AND l.locale = (SELECT d ->> 'master_locale' FROM cl_doc)
               WHERE t.cur = t.master_text AND t.src <> t.master_text AND l.updated_by <> 'do_spl_cost_labels_fill')
    THEN 'an entry already carries a renamed text and this action did not rename it (two items would merge)'
  WHEN EXISTS (SELECT 1 FROM cl_want_c w LEFT JOIN hr_cost_components c USING (component) WHERE c.component IS NULL)
    THEN 'a mapped component is not in hr_cost_components'
  ELSE '' END AS refusal \gset
SELECT :'refusal' <> '' AS refused \gset
\if :refused
\echo REFUSED :refusal
ROLLBACK;
DO $$ BEGIN RAISE EXCEPTION 'cost labels fill refused'; END $$;
\endif
SELECT 'COUNT before cost_entry_labels ' || locale || ' ' || count(*) FROM cost_entry_labels GROUP BY locale ORDER BY locale;
SELECT 'COUNT before hr_cost_component_labels ' || locale || ' ' || count(*) FROM hr_cost_component_labels GROUP BY locale ORDER BY locale;
SELECT 'PLAN cost_entries.label rename=' || count(*) FILTER (WHERE cur <> master_text) || ' matched=' || count(*) FROM cl_t;
SELECT 'PLAN cost_entries unmapped=' || count(*) FROM cost_entries ce WHERE NOT EXISTS (SELECT 1 FROM cl_t t WHERE t.id = ce.id);
SELECT 'PLAN cost_entry_labels ' || w.locale || ' insert=' || count(*) FILTER (WHERE x.label IS NULL)
       || ' update=' || count(*) FILTER (WHERE (w.locale = :'master' OR x.origin = 'machine')
                                          AND (x.label <> w.label OR x.source_text IS DISTINCT FROM w.source_text))
       || ' hand=' || count(*) FILTER (WHERE w.locale <> :'master' AND x.origin = 'hand')
  FROM cl_want_e w LEFT JOIN cost_entry_labels x USING (entry_id, locale) GROUP BY w.locale ORDER BY w.locale;
SELECT 'PLAN hr_cost_component_labels ' || w.locale || ' insert=' || count(*) FILTER (WHERE x.label IS NULL)
       || ' update=' || count(*) FILTER (WHERE (w.locale = :'master' OR x.origin = 'machine')
                                          AND (x.label <> w.label OR x.source_text IS DISTINCT FROM w.source_text))
       || ' hand=' || count(*) FILTER (WHERE w.locale <> :'master' AND x.origin = 'hand')
  FROM cl_want_c w LEFT JOIN hr_cost_component_labels x USING (component, locale) GROUP BY w.locale ORDER BY w.locale;
SQL
}

# spl_cost_labels_sql_apply -> the writes, the after counts and the master
# row check, then COMMIT or (dry) ROLLBACK. The rename goes first: the
# master row then equals the new text. The master row is written as today
# (origin 'hand'); every other row is a machine row whose upsert carries the
# guard of the store's machine write (pgCostLabelMachineEntry, spec 123
# 16.6.4): a hand row is skipped in SQL.
spl_cost_labels_sql_apply() {
  cat <<'SQL'
UPDATE cost_entries ce SET label = t.master_text FROM cl_t t WHERE ce.id = t.id AND ce.label <> t.master_text;
INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin, source_text)
  SELECT entry_id, locale, label, 'do_spl_cost_labels_fill', 'hand', NULL FROM cl_want_e WHERE locale = :'master'
  ON CONFLICT (entry_id, locale) DO UPDATE SET label = EXCLUDED.label, updated_by = EXCLUDED.updated_by, updated_at = now()
  WHERE cost_entry_labels.label IS DISTINCT FROM EXCLUDED.label;
INSERT INTO cost_entry_labels (entry_id, locale, label, updated_by, origin, source_text)
  SELECT entry_id, locale, label, 'do_spl_cost_labels_fill', 'machine', source_text FROM cl_want_e WHERE locale <> :'master'
  ON CONFLICT (entry_id, locale) DO UPDATE SET label = EXCLUDED.label, updated_by = EXCLUDED.updated_by, updated_at = now(),
    source_text = EXCLUDED.source_text, reviewed_at = NULL
  WHERE cost_entry_labels.origin = 'machine'
    AND (cost_entry_labels.label IS DISTINCT FROM EXCLUDED.label OR cost_entry_labels.source_text IS DISTINCT FROM EXCLUDED.source_text);
INSERT INTO hr_cost_component_labels (component, locale, label, origin, source_text)
  SELECT component, locale, label, 'hand', NULL FROM cl_want_c WHERE locale = :'master'
  ON CONFLICT (component, locale) DO UPDATE SET label = EXCLUDED.label
  WHERE hr_cost_component_labels.label IS DISTINCT FROM EXCLUDED.label;
INSERT INTO hr_cost_component_labels (component, locale, label, origin, source_text)
  SELECT component, locale, label, 'machine', source_text FROM cl_want_c WHERE locale <> :'master'
  ON CONFLICT (component, locale) DO UPDATE SET label = EXCLUDED.label, source_text = EXCLUDED.source_text, reviewed_at = NULL
  WHERE hr_cost_component_labels.origin = 'machine'
    AND (hr_cost_component_labels.label IS DISTINCT FROM EXCLUDED.label
         OR hr_cost_component_labels.source_text IS DISTINCT FROM EXCLUDED.source_text);
SELECT 'COUNT after cost_entry_labels ' || locale || ' ' || count(*) FROM cost_entry_labels GROUP BY locale ORDER BY locale;
SELECT 'COUNT after hr_cost_component_labels ' || locale || ' ' || count(*) FROM hr_cost_component_labels GROUP BY locale ORDER BY locale;
SELECT count(*) AS master_bad FROM cost_entries ce JOIN cost_label_settings s ON true
  JOIN cost_entry_labels l ON l.entry_id = ce.id AND l.locale = s.master_locale WHERE l.label <> ce.label \gset
\echo CHECK master rows unequal to cost_entries.label= :master_bad
SELECT :master_bad > 0 AS master_broken \gset
\if :master_broken
ROLLBACK;
DO $$ BEGIN RAISE EXCEPTION 'a master row differs from its entry label'; END $$;
\endif
\if :dry
ROLLBACK;
\else
COMMIT;
\endif
SQL
}
