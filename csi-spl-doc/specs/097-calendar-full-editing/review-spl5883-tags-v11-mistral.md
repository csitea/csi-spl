review: m-841 mistral PASS bce9fe6af2bb4ea9ab3c05ab6204e3748bc80e77 seat-file: review/c002-spl5883-tags-v11-mistral-review

# Mistral review of SPL-5883: spec 097 section 11 v1.1 (the owner's answers written in)

- Reviewer: m-841 (mistral), cross-vendor doc review, 2026-11-19. Author: c-836 (claude).
- Reviewed sha: `bce9fe6af2bb4ea9ab3c05ab6204e3748bc80e77`, branch
  `review/c002-spl5883-tags-spec-v11`. `git ls-remote origin review/c002-spl5883-tags-spec-v11`
  -> `bce9fe6af2bb4ea9ab3c05ab6204e3748bc80e77` (matches the brief). Parent
  `git log -1 --format=%P bce9fe6af` -> `86572482f2afd0d651005c345606f5dec20307f2`,
  and `git ls-remote origin master` -> `86572482f...` (on origin/master at review time).
- Diff reviewed: `git diff 86572482f bce9fe6af` -> `git diff --stat` prints
  `csi-spl-doc/specs/097-calendar-full-editing/spec.md | 153 +++...---`,
  `1 file changed, 117 insertions(+), 36 deletions(-)`; `git diff --name-only` ->
  only that one file. Section 11 is lines 862-1328 on the sha
  (`git show bce9fe6af:...spec.md | grep -n '^## 11\.'` -> `862:## 11. ...`),
  11.12 at 1313, section 12 at 1329 — all as the brief says.
- Every file:line cited below was checked with
  `git show <sha>:<file> | sed -n <N>p` on the named sha (86572482f = the author's
  measured tree, bce9fe6af = the reviewed sha).

**Verdict: PASS.** No defects. Notes N1..N3 below.

## Check 1 — the answers match the owner's words

The v1.0 owner-questions table on origin/master:
`git show origin/master:csi-spl-doc/specs/097-calendar-full-editing/spec.md | sed -n '1242,1246p'`
prints the rows in order O1, O2, O3, O5, O6 (O4 dropped in v1.0):

- `1242: | O1 | Who may create a tag? | any member who writes events | admins only ... | A (delete stays admin-only) |`
- `1243: | O2 | ... show events with... | any of them | all of them | A |`
- `1244: | O3 | ... | the issue labels | no filter in To-do | A |`
- `1245: | O5 | The chosen filter is kept... | in the link only ... | also remembered for you across visits | A |`
- `1246: | O6 | Send the first tag's colour ...? | yes | no | A, as a later row after T11 |`

The owner's answer (author brief, verbatim; the dispatch note
`/var/spool-hub/c-002/archive/20261119T070009Z--c-001--hum-10-answered-poll-c15f11e0-a4-a353415c.json`
prints "HUM-10 answered poll c15f11e0 ... with A/B/A/B/A (msg cde26d3f...)"):
Answer 1: A, 2: B, 3: A, 4: B, 5: A. The poll's five questions are the table's
rows in order, so O1=A, O2=B, O3=A, O5=B, O6=A.

The spec's 11.12 on the sha (`sed -n '1313,1328p'`) decides exactly that:
O1 **A as proposed**, O2 **B all of them (not the proposal)**, O3 **A as
proposed**, O5 **B also remembered (not the proposal)**, O6 **A as proposed,
later, row T15**. And each decided answer is stated where it lands, not left
as the proposal:

- O1: `sed -n '1096,1098p'` -> "**Decided** (O1 = A ...): any member who writes
  events (`notes.send`) creates, renames, recolours and reorders a tag;
  deleting a tag stays admin-only (`channels.manage`)." The 11.5 table above it
  (lines 1083-1090) already carries the same rule per act.
- O2 = B "all of them": 11.4.3 line 1052-1053 -> "**all, not any** (O2 = B ...):
  ... `tag_ids @> $1`" — the choice, not the v1.0 proposal A (`&&`).
- O3 = A: 11.8.3 line 1252 -> To-do lists the workspace's issue labels, decided.
- O5 = B "also remembered": 11.8.2 line 1191 -> "**Remembered across visits**
  (O5 = B ...)" — the choice, not the v1.0 proposal A (link only).
- O6 = A: 11.9 line 1266-1268 -> "**Later** (O6 = A ..., row T15 after T11)".

## Check 2 — O2 "all": `@>`, `none` alone, unknown ids dropped, consistent, red control flipped

- 11.4.3 (lines 1052-1062 on the sha): `tag_ids @> $1` for "all";
  `none` "**only valid alone**: `tags=none,<id>` is `400 bad_tags_filter`"
  (line 1057); unknown id "dropped from `$1` before the query ... a list of
  unknown ids only is no filter" (lines 1059-1061); "at most 20 ids" (line 1049).
- 11.8.1 (line 1177): "No tag" is exclusive, header says "Events with all the
  chosen tags".
- 11.8.3 (lines 1251-1252): event views show "only events carrying **every**
  chosen tag (or no tag, for 'No tag', alone)"; To-do "every chosen label".
- T6 (line 1300): "**all** (`tag_ids @> $1`), `none` alone, unknown ids dropped";
  test "filter of two tags returns only events carrying both (an event with one
  of them is left out)"; red control "turn `@>` into `&&`: the 'all' case (event
  with one of two tags left out) red".
- Consistent across 11.4.3, 11.8.1, 11.8.3 and T6: yes, all four say "all".
- The flipped red control does turn T6 red: with `&&` (any) an event carrying
  one of the two chosen tags is returned, so T6's "left out" assertion fails.
- The GIN claim holds: 11.3 line 970 on the sha ->
  `CREATE INDEX IF NOT EXISTS calendar_events_tags ON calendar_events USING gin (tag_ids)`
  — the default `array_ops` GIN opclass serves both `@>` and `&&`.

## Check 3 — O3 To-do "all" on labels; the hub's "any" today; T17 breaks no caller

On 86572482f:

- `git show 86572482f:csi-spl-api/src/go/spool-hub-api/internal/hub/issues.go | sed -n '605p'`
  -> `f := issueFilter{status: csvSet(get("status")), label: csvSet(get("label")), ...}`
- `... | sed -n '681p'` -> `!allows(f.level, i.Level) || !allows(f.assignee, i.Assignee) || !allowsAny(f.label, i.Labels) {`
- `git grep -n 'func allowsAny' 86572482f -- .../internal/hub/` -> `issues.go:697:func allowsAny...`

So `label=a,b` matches ANY today, as the spec says (11.8.3 line 1252 cites
`hub/issues.go:605`, `:681` `allowsAny` — both verified). New row T17 (line 1311):
`label_match=all` on `GET /v1/view/issues`, "default `any`, today's answer
unchanged", red control "use `allowsAny` for `all`: red". Default unchanged means
no current caller breaks; the Issues view keeps "any" as stated.

## Check 4 — O5 remembered per member and workspace; every cited measurement verified on 86572482f

Each command the spec's 11.8.2 table (lines 1196-1206) claims, re-run by me on
86572482f, with what it printed:

- `git show 86572482f:.../internal/auth/handler.go | sed -n '26p'` ->
  `const RoutePrefix = "/api/v1/auth/"`
- `... | sed -n '294p'` -> `mux.HandleFunc("PUT "+RoutePrefix+"preferences", h.putPreferences)`
- `... | sed -n '1112,1138p'` -> `type preferencesReq struct {` with 25
  `json.RawMessage` fields (counted: preferred_locale .. phone = 25)
- `... | sed -n '1431p'` -> the comment "issues_sort, pane_sizes, time_zone,
  keyboard_shortcuts, hours_reading, await_anims and second_currency have no
  humans column: they live ONLY here."
- `... | sed -n '1448,1454p'` -> the no-active-tenant branch: per-tenant-only
  settings "cannot be kept ... not stored" (matches T16's "no active workspace =
  not stored")
- `git show 86572482f:csi-spl-rdb/src/sql/postgres/spool-hub/0078_membership_settings.sql | sed -n '16,31p'`
  -> the `settings jsonb` column comment ("A key ABSENT ... = no override ...
  the CHECK pins it to a JSON object"); `| grep -n CHECK` ->
  `35: CHECK (settings IS NULL OR jsonb_typeof(settings) = 'object')`
- `git show 86572482f:.../internal/auth/settings.go | sed -n '67p'` ->
  `type MembershipSettings struct {`
- `git show 86572482f:.../internal/store/membership_settings.go | sed -n '85p;125p'`
  -> `func (s *Postgres) SetMembershipSettings(...)` / `func (s *Memory) SetMembershipSettings(...)`
- `git show 86572482f:csi-spl-wui/src/stores/session.ts | sed -n '141p;186p'` ->
  `function mirror(patch: Partial<SessionClaims>) {` / `function setIssuesSort(...)`
- `git show 86572482f:csi-spl-wui/src/composables/useIssueListUrl.ts | sed -n '9,13p'`
  -> "A URL with `view=` is a complete link ... the reader's stored choices do
  not apply. A URL without it ... takes the stored choices, and the address is
  then completed with them."
- `git grep -n localStorage 86572482f -- 'csi-spl-wui/src/*.vue' 'csi-spl-wui/src/*.ts' 'csi-spl-wui/src/*.mjs' | wc -l`
  -> `184`
- `git grep -n calendar 86572482f -- .../internal/auth/settings.go | wc -l` -> `0`
  (no calendar preference today)
- Spot examples: `calendar.vue:124` -> `localStorage.getItem(HOURS_PANEL_KEY)`;
  `CalendarPhone.vue:285` -> `window.localStorage.getItem(VIEW_KEY)`;
  `useIssueFilters.ts:142` -> "a per-browser convenience (localStorage), not a hub setting";
  `calendar.vue:89-100` -> the `v` / `d` / `k` query handling the `tags` param sits beside.

"No new table, no migration" is true: 0078's CHECK (line 35) only pins a JSON
object, and the hub admits a new key by its parse (T16). The rules are all
stated in 11.8.2 (lines 1222-1245): link wins over stored (1232-1236), opening a
link never saves (1230), Clear saves `calendar_filter: null` (1240), deleted tag
ids are dropped by the read and pruned by the WUI, saved once (1242-1245), cap
"at most 20 of each" (1224), per workspace not global (1218-1220, matching
handler.go:1448-1454).

## Check 5 — O6 later row T15: first tag's `colorId`, colour in the sync hash only when set

T15 (line 1309) says: out sync sets `colorId` from the first tag's colour; the
colour joins the sync hash only when set, "so an untagged event hashes as before
and no event is rewritten for nothing"; untagged sends no `colorId`. So as
written it cannot rewrite untagged events on the next sync. Verified on
86572482f: `git show 86572482f:.../internal/hub/gcal_map.go | sed -n '27p;49p'` ->
`func GcalSyncHash(e store.CalendarEvent) string {` / `func GcalEventOf(e store.CalendarEvent) gcal.Event {`;
`git grep -n colorId 86572482f -- csi-spl-api/src/go/spool-hub-api/internal | wc -l`
-> `0` (today no colour goes out, as 11.9 line 1269 claims). Spec 149 section 2.5
exists: `git show bce9fe6af:csi-spl-doc/specs/149-google-calendar-connect/spec.md | grep -n '^### 2.5'`
-> `192:### 2.5 Sync`. The "same 11 colour names" is the spec's own catalogue
(11.3, lines 918 and 1015 on the sha).

## Check 6 — build rows

From the diff: T6 (line 1300), T12 (1306) and T14 (1308) changed; T15 (1309),
T16 (1310), T17 (1311) are new rows after T14. Dependency order: T12 depends on
"T6, T11, T16, T17" — so T12 comes after T16 and T17, consistent; T15 depends on
T11 and sits after it, marked "**later**" as the owner chose. Each changed/new
row names its test file and a red control: T6 (inline test + `@>`->`&&` red),
T12 (unit + e2e, two red controls), T14 (`help-calendar-tags.test.mjs` + red),
T15 (`hub/gcal_map_test.go`, two reds), T16 (`auth/preferences_test.go` + red),
T17 (`hub/issues_*_test.go` + red). T13 (line 1307) still says "**agy review** of
the 18 drafts" before ship.

## Check 7 — nothing else changed

`git diff 86572482f bce9fe6af --name-only` -> only
`csi-spl-doc/specs/097-calendar-full-editing/spec.md`. The 8 hunks
(`git diff ... | grep '^@@'` -> @@ -861,8 / -929,8 / -1048,10 / -1081,8 /
-1159,27 / -1193,9 / -1225,31 / -1261,4) all land inside section 11 (862-1328)
and the section 12 version log (1329+; the last hunk flips the
`<!-- version: 1.1 -->` comment). Every hunk is one of the O1/O2/O3/O5/O6
answers, the status line, or the v1.1 version-log row; v1.0 text the owner did
not answer about is unchanged.

## Check 8 — repo rules on the reviewed tree

Run in a temporary worktree checked out at the reviewed sha
(`git worktree add /tmp/review-wt-bce9fe6a bce9fe6af...`, removed afterwards):

- `cd /tmp/review-wt-bce9fe6a/csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree ...` (exit 0)
- `cd /tmp/review-wt-bce9fe6a/csi-spl-orc && ./run -a do_check_fleet_rules_drift` ->
  `OK fleet rules: no drift over 9 pinned facts ...` (exit 0)

## Defects

None.

## Notes

- N1: the `pages/calendar.vue:89-100` citation for the `tags` URL param points at
  the `v`/`d`/`k` query handling (verified on 86572482f); no `tags` query read
  exists in the WUI yet because section 11 is unbuilt — a plan-level citation
  carried over unchanged from v1.0 (which m-707 passed), not a defect of v1.1.
- N2: 11.4.3's "the GIN index of 11.3 serves `@>` as it serves `&&`" is correct
  for the default `array_ops` opclass of the index at 11.3 line 970; if a later
  row ever changes the opclass, that sentence must change with it.
- N3: T16's "no active workspace = not stored" matches the existing behaviour of
  the other per-tenant-only keys (handler.go:1448-1454 on 86572482f), so the new
  key inherits a proven edge case rather than inventing one.
