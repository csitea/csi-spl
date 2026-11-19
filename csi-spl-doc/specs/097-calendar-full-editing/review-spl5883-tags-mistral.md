# Review SPL-5883: spec 097 section 11 "Event tags" — mistral cross-vendor review

- **Verdict: PASS** on `421d63630cdb14e9c5f75e4dd67caa738709e252`
- Reviewer: m-707 (mistral), 2026-11-19. Author lane: c-702 (claude), report 4dede474.
- Reviewed sha: `421d63630cdb14e9c5f75e4dd67caa738709e252`, branch
  `review/c002-spl5883-calendar-event-tags-spec`, parent `386b38058` (verified on
  origin/master: `git merge-base --is-ancestor 386b38058 origin/master` -> exit 0).
  `git ls-remote origin review/c002-spl5883-calendar-event-tags-spec` ->
  `421d63630cdb14e9c5f75e4dd67caa738709e252` (matches the brief).
- Reviewed only that sha: `git diff 386b38058 421d63630`. New section `## 11. Event
  tags with colours (SPL-5883)` is lines 862-1248 of
  `csi-spl-doc/specs/097-calendar-full-editing/spec.md` at that sha
  (`git show 421d63630:...spec.md | grep -n '^## '` -> `862:## 11. ...`,
  `1249:## 12. Version log`); the version log was section 11 at `386b38058`
  (line 862 there).
- Every file:line below was checked with `git show 386b38058:<file> | sed -n '<N>p'`
  (or `git grep`); the output is quoted. Paths: `api/` =
  `csi-spl-api/src/go/spool-hub-api/`, `wui/` = `csi-spl-wui/`, `rdb/` =
  `csi-spl-rdb/src/sql/postgres/spool-hub/`.
- Owner posts read in topic t1 `f5778b9f-9feb-4935-8c1c-0e19cb5e49d4`
  (`spool_read_link https://spool-hub.ai/t/f5778b9f-...`, 11 messages): 3ada46ca,
  9884e085 (poll f99b4cb2), 2d3164e8, 62e387eb (answer B), 7f371baa, 5a9f7682
  (agreed scope), 2c7979b8 (SPL-5883).

## 1. Scope — covered

Section 11.0 (spec lines 868-887) restates the agreed scope of dispatcher post
`5a9f7682` exactly: (1) workspace tags each with a colour; (2) several tags per
event, all chips shown, 5 px left stripe from the FIRST tag, theme default for
untagged; (3) a tag filter in every view (Day, 3 days, Week, Month, To-do).
11.2-11.7 build (1) and (2); 11.8 builds (3).

Filter per view (11.8.3, lines 1176-1183): Day, 3 days, Week, Month (desktop and
phone), phone Year marks, search, and To-do all have the filter. **No view lacks a
filter.** The To-do choice (issue labels, line 1181, question O3 line 1243) does
not contradict owner msg `7f371baa` ("in each view ... labels or tags"): the To-do
view lists issues, not events (`git show 386b38058:wui/src/components/CalendarTodoView.vue | sed -n '1,13p'`
-> "Tasks only (open issues ...), never events"; `:91` -> `api.listIssues`), and
the owner's wording says "labels or tags". The spec surfaces the choice as O3
instead of deciding silently — correct.

## 2. Decision "own table `calendar_tags`, not issue labels" — all four reasons backed by the tree on 386b38058

1. **Colour** (spec line 914): `git show 386b38058:rdb/0047_issues.sql | grep -n color`
   -> `38: color text NOT NULL DEFAULT '#6b7280' CHECK (color ~ '^#[0-9a-f]{6}$')`
   (free hex). Q9 chose the 11 named colours: spec 097 at 386b38058 line 860
   (`| Q9 | Event colours: Google's 11 named colours ... DECIDED ... msg 92b3e0d6`)
   and line 194 (the 11 names). `variables.css:421` and `:434` both print
   `--cal-color-tomato` (`:root` dark default at 421, `:root[data-theme^="light"]`
   at 434). Backed — but see W1: the spec cites `0047:39`, line 39 is `created_by`.
2. **Rename/delete** (spec line 917): label_id is the slug of the name
   (`0047:36` -> `CHECK (label_id ~ '^[a-z0-9][a-z0-9-]{0,39}$')`); the only route is
   create: `git grep -n 'issue-labels' 386b38058 -- api/internal/hub/` ->
   `issues.go:863: mux.HandleFunc("POST /v1/issue-labels", ...)` plus OPTIONS; no
   PATCH/DELETE route exists. Backed.
3. **Meaning / `epic`** (spec line 920): `git show 386b38058:rdb/0049_issue_epics.sql | sed -n '20,21p'`
   -> `INSERT INTO issue_labels ... SELECT DISTINCT i.tenant_id, 'epic', 'epic', '#8b5cf6', 'hub'`. Backed.
4. **Isolation / who may write** (spec line 923): `git show 386b38058:api/internal/hub/issues.go | sed -n '928,933p'`
   -> `issueWriter` requires `rbac.NotesSend` AND `rbac.TopicsManage`; both
   constants exist (`git grep -n '"notes.send"\|"topics.manage"' 386b38058 -- api/internal/rbac/rbac.go`
   -> `rbac.go:21`, `:45`). Backed.

## 3. Built-code facts of 11.1 (spec lines 889-907) — each verified on 386b38058

| claim | command -> output |
|---|---|
| one fixed `kind`, 7 values, widened to nine; no tag/label | `0125_calendar.sql:24` -> `kind text NOT NULL CHECK (kind IN ('release','deploy','maintenance','freeze','agent_task','reminder','other'))`; `0156_calendar_source_key.sql:31` -> same CHECK plus `'goal','milestone'`; `git show 386b38058:rdb/0125_calendar.sql \| grep -in 'tag\|label'` -> empty |
| own colour `props.color`, 11 palette names | `api/internal/hub/calendar_props.go:45,53` -> `calendarPropKeys` incl. `calPropColor`; `calendarColors` comment "Google's palette of 11 (spec 3.3, Q9)"; `wui/src/utils/calendar-event-form.mjs:49` -> `export const CAL_COLORS = ['tomato', ... 'graphite']` (11) |
| palette names are theme variables, dark + light | `wui/src/assets/css/variables.css:421` -> `--cal-color-tomato: #ff6b6b;` inside `:root`; `:434` -> `--cal-color-tomato: #d50000;` inside `:root[data-theme^="light"]` |
| stripe today 4 px desktop timed, 3 px Month + all-day, dot on phone | `CalendarMainView.vue:715` -> `border-inline-start: 4px solid var(--cal-ev-color, var(--color-accent));`; `:623` -> `box-shadow: inset 3px 0 0 var(--cal-ev-color);`; `CalendarDeskMonth.vue:132` -> `border-inline-start: 3px solid ...`; `CalendarPhoneDay.vue:528,535` -> `.calday__dot` with `background: var(--cal-ev-color, var(--color-accent))`; `CalendarPhoneWeek.vue:121` and `CalendarPhoneMonth.vue:154` -> `dotStyle` set the dot colour |
| stripe colour `--cal-ev-color` else `--color-accent` | `CalendarMainView.vue:529` -> style sets `'--cal-ev-color': var(--cal-color-<ev.color>)`; `:715` fallback `--color-accent` |
| issue labels per workspace, slug id, free hex, create only, `notes.send`+`topics.manage` | `0047_issues.sql:33,41` -> `CREATE TABLE issue_labels (...)` with the checks above; `issues.go:863` -> POST route; `:928,933` -> issueWriter permits; `:1188` -> `handleCreateIssueLabel` |
| `epic` system label | `0049_issue_epics.sql:20` -> the INSERT (see check 2) |
| synced event read-only to member PATCH/DELETE | `calendar.go:1064` and `:1164` -> `if cur.SourceKey != ""`; the refusal `409 synced_read_only` at `:1101` |
| sync upsert rewrites a fixed column list | `api/internal/store/calendar_sync.go:208,212` -> `ON CONFLICT ... DO UPDATE SET title = EXCLUDED.title, ...` (explicit list; restore adds `deleted_at = NULL` at :214) |
| To-do lists issues, never events | `CalendarTodoView.vue:1,13` -> comment "Tasks only (open issues ...), never events"; `:91` -> `api.listIssues({ filter })` |
| view state in URL: `v`, `d`, `k=todo`, `event` | `wui/src/pages/calendar.vue:80,116` -> `route.query.d`, `calDeskView(route.query.v)`, `calTodoKind(route.query)`, `event: ev.id`; `:89,100` -> `v` and `k` |
| range read returns issue deadlines + official days | `wui/src/types/calendar-shims.d.ts:21,22` -> `source: 'event' \| 'issue' \| 'official_day'` |
| channel move copies events; label catalogue re-created by name | `api/internal/channelmove/catalogue.go:95` -> `{Table: "calendar_events", Class: Moved, ...}`; `:183` -> `notChannel("... T5b creates each missing label_id ...", "issue_labels")` |
| migration head 0295 | `git ls-tree 386b38058 rdb/ \| tail -1` -> `0295_hours_prices_commit_ledger.sql`; `git ls-tree 386b38058 rdb/ \| grep -i tag` -> empty (no collision) |
| 19 locales | `git ls-tree 386b38058 csi-spl-wui/i18n/locales/ \| wc -l` -> `19` |

## 4. Data model (11.3, lines 935-981) — consistent

- Migration named, not written: `rdb/NNNN_calendar_tags.sql`, number taken by the
  build lane with `do_rdb_migration_next`; head on 386b38058 is 0295 (verified
  above) and no `*calendar_tags*` file exists, so the placeholder cannot collide.
  Forward-only is stated (line 937).
- Tag order defined: the array's order, `tag_ids[1]` is the first tag, duplicates
  removed first kept (lines 971-973); the ordered `text[]` form is what `mentions`
  (0125:29 -> `mentions text[] NOT NULL DEFAULT '{}'`) and `issue_keys`
  (0247:18 -> `ADD COLUMN ... issue_keys text[] ...`) already use.
- 10-tag cap: `CHECK (cardinality(tag_ids) <= 10)`; GIN index:
  `USING gin (tag_ids) WHERE cardinality(tag_ids) > 0`; tag delete strips the id
  from every event of the workspace, trashed rows included, same transaction
  (line 982 + 11.4.1 DELETE route + 11.5 `channels.manage`) — consistent across
  11.3, 11.4.1 and 11.5. 100-tags-per-workspace cap consistent (11.3 line 984,
  11.4.1 line 1010).
- 098 promotion rule exists: `git grep -n 'promot' 386b38058 -- csi-spl-doc/specs/098-tenant-settings-jsonb/spec.md`
  -> `spec.md:101` (promotion trigger). "up to 2000 occurrences, 4.4": spec 097 at
  386b38058 line 316 -> "A response holds at most 2000". Exception rows: lines
  103/119/307. `seedTenantAll`/`TestCrossTenantEveryTable`:
  `api/internal/store/crosstenant_test.go:30,853`; `TestRLSCoversEveryTenantTable`:
  `api/internal/store/rls_test.go:93`.

## 5. API and sync (11.4.2 lines 1019-1037, 11.9 lines 1186-1208) — tags cannot be dropped as written

- `PUT /v1/calendar/events/{id}/tags` on a synced event: today every member
  PATCH/DELETE on a `source_key` event is `409 synced_read_only`
  (`calendar.go:1064`, `:1101`, `:1164` — verified above), so the new route is the
  one write allowed there, as the spec says.
- "Every sync and import keeps the tags": verified on 386b38058 that all three
  write paths upsert with an explicit column list that cannot contain `tag_ids`:
  `calendar_sync.go:208-214`, `api/internal/store/calendar_import.go:92-103`
  (`calendarImportUpsert` ... `DO UPDATE SET title = EXCLUDED.title, ...`),
  `api/internal/store/gcal_import.go:132-143` (`gcalImportUpsert`, same shape).
  Prune/restore only set `deleted_at`/`deleted_by` (`calendar_sync.go:214`,
  `:219,220`; the import prune likewise). ON CONFLICT DO UPDATE keeps unlisted
  columns, so a re-import, a Google/Outlook update, a soft-delete and a restore
  cannot drop tags under the design as written. See N4 for what enforces it.
- Spec 180 FR-1 "No body, no attendees" verified (`csi-spl-doc/specs/180-outlook-calendar-import/spec.md:87`);
  the Google in-half reads no `colorId` (`git grep -n 'colorId\|ColorId' 386b38058 -- api/internal` -> empty).
- `DisallowUnknownFields` on `calendarRequest`: struct at `calendar.go:210`,
  applied in `decodeCalendarRequest` at `calendar.go:555-560` (see N1).

## 6. Build rows T1-T14 (11.11, lines 1214-1235) — order consistent, one gap

Every `depends` references an earlier row only: T2<-T1; T3<-T2; T4<-T2;
T5<-T3,T4; T6<-T5; T7<-T5; T8<-T2; T9<-T4; T10<-T5,T9; T11<-T10; T12<-T6,T11;
T13<-T9..T12; T14<-T12. Each row names its test; T1..T13 carry a red control.
Named test files exist on 386b38058: `csi-spl-orc/src/bash/tests/spl-calendar-event-add.tst.sh`,
`spl-calendar-event-update.tst.sh`; `csi-spl-doc/doc/help/calendar.md` exists.
T13 (line 1234) carries the **agy review** of the 18 non-English drafts, and 11.10
(line 1210) makes it the last step before ship — matches the fleet language rule.
Gap: T14 (line 1235) has red control `-` and no named test file — W5.

## 7. Owner questions O1-O6 (11.12, lines 1237-1246)

Each row is a real A/B choice with a proposal. O1, O2, O5, O6 appear in no owner
post of the topic (read in full, 11 messages) — genuinely open. O3 (line 1243) is
partially pre-answered by `7f371baa`'s "labels or tags" wording and is correctly
surfaced because To-do lists issues (N2). **O4 (line 1244) is already answered by
the owner**: msg `62e387eb` (poll `2d3164e8`, answer B) — "the stripe takes the
first tag's colour"; the proposal A matches it, so O4 re-asks a decided choice
(W4).

## 8. Nothing else changed

`git diff --stat 386b38058 421d63630` -> `1 file changed, 391 insertions(+), 3 deletions(-)`
(spec.md only). Hunks: `@@ -1,6 +1,6 @@` (top Status line), `@@ -859,10 +859,398 @@`
(section 11 inserted), `@@ -873,4 +1261,4 @@` (version log renumbered 11 -> 12,
v1.0 row added, version comment). Only spec 097 is touched (N3).

## 9. Repo rules

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree` (exit 0).
- `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift` ->
  `OK fleet rules: no drift over 9 pinned facts` (exit 0).
- New section hygiene: `git show 421d63630:...spec.md | sed -n '862,1248p'` piped to
  a grep for each banned literal class of `do_check_dist_hygiene` (box tags, OS
  user names, home-dir paths, personal names) -> empty.

## Defects

- **W1** — spec line 914 cites `0047:39` for the free-hex colour; the CHECK is at
  `0047:38` (`git show 386b38058:rdb/0047_issues.sql | grep -n color` -> `38:`),
  line 39 is `created_by`. Fact true, citation off by one.
- **W2** — spec line 1094 cites "5.1.6's rule"; no `5.1.6` exists in spec 097 at
  386b38058 (`grep -n '5\.1\.[0-9]'` -> empty). The full-screen sheet rule is
  section 6, line 659 (`#### 6. Event details` -> "opens `CalendarEventDialog` as
  a **full-screen sheet/modal**"), under 5.1's mobile-first bullets.
- **W3** — spec line 1076 cites "(089 4.2, Q4)" for the right to edit an event;
  spec 089's 4.2 is Audience (`089-calendar-section/spec.md:133`), and Q4 is spec
  097 section 10 line 855 (`| Q4 | Who may edit an event ... DECIDED ... msg 92b3e0d6').
  The fact is backed (097 Q4; 089 PATCH rules at `spec.md:143`, `:224`, `:284`),
  the citation names the wrong section/spec.
- **W4** — spec line 1244 (O4) re-asks a choice the owner already answered:
  msg `62e387eb` — "the stripe takes the first tag's colour". Proposal A matches
  the owner's answer; either drop O4 or mark it decided.
- **W5** — spec line 1235 (T14) has red control `-` and no named test file,
  against 11.11's own preamble ("Each row lands with its test and a red control")
  and developer guide 2.12.1.

## Notes

- **N1** — spec line 1017: `calendar.go:210` is the `calendarRequest` struct;
  `DisallowUnknownFields` is applied in `decodeCalendarRequest` at
  `calendar.go:555-560`. Acceptable, imprecise.
- **N2** — lines 1181/1243: the To-do filter choice (issue labels) is consistent
  with owner msg `7f371baa` ("labels or tags" in each view); no view lacks a filter.
- **N3** — the diff also edits the file's top Status line (line 3) and the version
  comment; same file, version bookkeeping, so check 8 still passes.
- **N4** — "every sync keeps the tags" rests on the three upserts not listing
  `tag_ids` (verified on 386b38058) and is enforced only by T3's red control, not
  by the schema: the array has no FK, the hub checks ids on every write (line 982).
- **N5** — spec line 982 cites `0047:58`; that line is the comment "the hub keeps
  them known and unique" above `labels text[]` at 0047:59 — acceptable.
